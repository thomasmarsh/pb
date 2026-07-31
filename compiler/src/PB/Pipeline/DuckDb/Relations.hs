-- | The DuckDB moat's Relations-loading boundary: typed Haskell builders that
-- materialize every relation the cross-file analyses read, plus the
-- fan-in diagnostics that guard against duplicate-key blow-up.
--
-- Two kinds of function live here:
--
--   * Relations builders ('initSchemaRelations' / 'initDeadCodeRelations' and their pure
--     row-shaping helpers) read already-populated DuckDB tables and
--     materialize the plain @leg_source@\/@stmt@\/@seed@\/@proc@\/@entry@\/...
--     relations via 'recreateTextTable' \/ 'appendTextRows'. They only
--     rename, cast, or filter by a static/structural predicate — never a
--     decision (see the "DuckDb Moat & Analysis Placement" discipline in
--     'compiler/AGENTS.md').
--   * Fan-in diagnostics ('legSourceFanout' / 'defLineFanout' /
--     'returnUseFanout') are cheap @GROUP BY@ passes that surface a
--     pathological duplicate-key shape before the analyses run.
module PB.Pipeline.DuckDb.Relations
  ( initSchemaRelations
  , SchemaInputRows (..)
  , LegSourceFanout (..)
  , legSourceFanout
  , TypeCoverageStats (..)
  , typeCoverageStats
  , legSourceRows
  , stmtRows
  , seedRows
  , joinLegRows
  , fkRows
  , initDeadCodeRelations
  , DeadCodeInputRows (..)
  , procRows
  , procMetaRows
  , inheritsRows
  , callRefRows
  , resolvedCallEdgeRows
  , entryRows
  , callsRows
  , CallRef (..)
  , ResolvedCallEdge (..)
  , CallEdge (..)
  , DefUseFanout (..)
  , defLineFanout
  , returnUseFanout
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb
  ( Handle, queryHandle, recreateTextTable, appendTextRows )
import PB.Pipeline.DuckDb.PhaseB.Query
  ( SchMorphismRow (..), ProcSummaryRow (..)
  , querySchemaObjects, querySchemaMorphismRows
  , queryObjectAncestors, queryProcedures, queryDwObjects
  )
import PB.Analysis.SchemaCategory
  ( SchObject (..), StmtId (..), CatFkRow (..), schObjectKey )
import PB.Pipeline.SqlParse (TableRef (..))
import PB.Analysis.Taint qualified as Taint
import PB.Lexing.Token (SourceSpan (..))

import Database.DuckDB.Simple.FromRow (FromRow (..), field)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Schema input relations

-- | Rows 'initSchemaRelations' already fetched from @schema_morphisms@\/
-- @schema_objects@, threaded into
-- 'PB.Analysis.SchemaClosure.materializeSchemaClosure' instead of it
-- re-querying the same two tables (Plan 187 §18 tier 1).
data SchemaInputRows = SchemaInputRows
  { sirMorphisms :: [SchMorphismRow]
  , sirObjects   :: [SchObject]
  }

-- | (Re)materialize the input relations every analysis below assumes already
-- exist: @leg_source@ over 'schema_morphisms', @stmt@\/@seed@ over
-- 'schema_objects'. Must run after 'PB.Pipeline.DuckDb.initSchema' AND after
-- 'schema_objects'\/'schema_morphisms' have been populated: the read here is
-- eager (a typed Haskell query materialized via 'recreateTextTable'\/
-- 'appendTextRows'), not a lazily-evaluated SQL view, so calling this before
-- 'PB.Pipeline.DuckDb.appendSchemaObjects'\/'appendSchemaMorphisms' populate
-- their source tables materializes empty relations.
--
-- No @dead@ relation is materialized here: @proc_dead@ is computed
-- by 'PB.Analysis.DeadCodeReachability.materializeDeadCodeClosure'
-- and read directly. @dead_code@ is
-- populated from @dead_code_rows@ via
-- 'PB.Pipeline.DuckDb.materializeDeadCode' and is the sole source for the
-- Dead Code Explorer API (@get_dead_code@).
--
-- @catFks@ is taken as a parameter rather than queried here: 'runPhaseB'
-- fetches it once and passes the same rows to both this function and
-- 'PB.Pipeline.Passes.buildSchemaCategory' (which independently needs it to build the
-- schema category) — see Plan 187 §18. Returns the morphisms\/objects rows
-- already fetched so 'PB.Analysis.SchemaClosure.materializeSchemaClosure'
-- can reuse them instead of re-querying the same two tables.
initSchemaRelations :: Handle -> [CatFkRow] -> IO SchemaInputRows
initSchemaRelations conn fks = do
  morphisms <- querySchemaMorphismRows conn
  objects   <- querySchemaObjects conn
  materialize "leg_source" ["x", "y", "kind"]                  (legSourceRows morphisms)
  materialize "stmt"       ["file", "object", "proc", "line"]  (stmtRows objects)
  materialize "seed"       ["x"]                                (seedRows objects)
  materialize "join_leg"   ["x", "y"]                           (joinLegRows morphisms)
  materialize "fk"         ["x", "y"]                           (fkRows fks)
  pure SchemaInputRows { sirMorphisms = morphisms, sirObjects = objects }
  where
    materialize name cols rows = do
      recreateTextTable conn name cols
      appendTextRows conn name rows

-- | Projects 'SchMorphismRow' into @leg_source@'s (x, y, kind) shape: a
-- pure rename of ('smrFromKey', 'smrToKey', 'smrLegKind'). 'smrLegSource'
-- is deliberately unused -- @leg_source@ carries no provenance column.
legSourceRows :: [SchMorphismRow] -> [[Text]]
legSourceRows = map (\r -> [smrFromKey r, smrToKey r, smrLegKind r])

-- | Projects 'SchObject' into @stmt@'s (file, object, proc, line) shape,
-- keeping only 'SqlStmtId' rows. 'DwRetrieveId' rows are excluded: a DW
-- retrieve's proc is always NULL, which would make @dead(Object,Proc)@
-- vacuously never match and every DW retrieve unconditionally "live".
stmtRows :: [SchObject] -> [[Text]]
stmtRows objs = [ [f, o, p, T.pack (show l)] | StmtObj (SqlStmtId f o p l) <- objs ]

-- | Projects 'SchObject' into @seed@'s single-column shape: keeps only
-- 'ColumnObj' rows, projected to their 'schObjectKey'.
seedRows :: [SchObject] -> [[Text]]
seedRows objs = [ [schObjectKey o] | o@(ColumnObj _ _) <- objs ]

-- | Projects 'SchMorphismRow' into @join_leg@'s (x, y) shape: DW-join-derived
-- edges only (@leg_source = "dw_join"@) -- the only 'PB.Analysis.
-- SchemaCategory.LegSource' that expresses a genuine two-table join
-- relationship distinct from a DDL-declared FK ('SrcDdlFk', already fully
-- captured by 'catalog_fks') or a statement's read\/write touch. Embedded
-- SQL @JOIN@s are not modeled as legs at all today (SQL-text legs are
-- single-table read\/write), so implied-FK discovery is scoped to
-- DataWindow joins only.
joinLegRows :: [SchMorphismRow] -> [[Text]]
joinLegRows rows = [ [smrFromKey r, smrToKey r] | r <- rows, smrLegSource r == "dw_join" ]

-- | Projects 'CatFkRow' into @fk@'s (x, y) shape, using the identical
-- 'schObjectKey' encoding 'PB.Analysis.SchemaCategory.buildSchema' applies
-- to the same 'catalog_fks' rows for its own 'SrcDdlFk' legs -- so a
-- declared FK's key here always matches the leg it produces there.
fkRows :: [CatFkRow] -> [[Text]]
fkRows = map $ \f ->
  [ schObjectKey (ColumnObj (TableRef (cfrFromNamespace f) (cfrFromTable f)) (cfrFromColumn f))
  , schObjectKey (ColumnObj (TableRef (cfrToNamespace f) (cfrToTable f)) (cfrToColumn f))
  ]

-- ---------------------------------------------------------------------------
-- Schema fan-in diagnostic

-- | Fan-in characterization for 'leg_source': total row count, distinct
-- (x, y) key count, and the largest number of rows sharing one key. A
-- single cheap DuckDB @GROUP BY@ pass, logged before 'PB.Analysis.SchemaClosure.materializeSchemaClosure' runs so a
-- corpus with pathological duplicate fan-in on one schema edge is visible
-- immediately rather than discovered only via a slow\/memory-hungry
-- recomputation. A large 'lsfMaxGroupSize' is worth an operator's attention on its
-- own terms: 'leg_source' has only ~3 distinct @kind@ buckets, so
-- hundreds\/thousands of rows sharing one exact (x, y) pair signals real
-- duplication in the upstream extractors (e.g. the same statement\/column
-- touch double-counted by two independent extraction techniques), not
-- legitimate diversity.
data LegSourceFanout = LegSourceFanout
  { lsfTotalRows    :: !Int
  , lsfDistinctKeys :: !Int
  , lsfMaxGroupSize :: !Int
  } deriving (Eq, Show)

newtype FanoutRow = FanoutRow LegSourceFanout

instance FromRow FanoutRow where
  fromRow = (\t k m -> FanoutRow (LegSourceFanout t k m)) <$> field <*> field <*> field

legSourceFanout :: Handle -> IO LegSourceFanout
legSourceFanout conn = do
  rows <- queryHandle conn
    "WITH g AS (SELECT x, y, COUNT(*) AS cnt FROM leg_source GROUP BY x, y) \
    \SELECT (SELECT COUNT(*) FROM leg_source), COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow f] -> f
    _             -> LegSourceFanout 0 0 0

-- ---------------------------------------------------------------------------
-- Type-resolution coverage diagnostic

-- | Plan 201 Phase 5a: type-resolution coverage, corrected to use the raw
--   lexed token stream ('identifier_tokens') as the denominator rather than
--   rows already present in 'resolved_var_refs'\/'resolved_calls' -- a chain
--   that never became a row (e.g. an unparsed @::@ scope-resolution chain)
--   is invisible to a row-based percentage, which over-reports coverage.
--   Excludes the embedded stdlib's synthetic @__stdlib__\/@-prefixed rows,
--   appended to every @--db@ run regardless of the target corpus.
data TypeCoverageStats = TypeCoverageStats
  { tcsTotalIdentifierTokens    :: !Int
  , tcsResolvedIdentifierTokens :: !Int
  , tcsVarRefTotal              :: !Int
  , tcsVarRefResolved           :: !Int
  , tcsCallTotal                :: !Int
  , tcsCallResolved             :: !Int
  } deriving (Eq, Show)

newtype CoverageRow = CoverageRow TypeCoverageStats

instance FromRow CoverageRow where
  fromRow = (\a b c d e f -> CoverageRow (TypeCoverageStats a b c d e f))
    <$> field <*> field <*> field <*> field <*> field <*> field

typeCoverageStats :: Handle -> IO TypeCoverageStats
typeCoverageStats conn = do
  rows <- queryHandle conn
    "WITH resolved_positions AS ( \
    \  SELECT file, name_start_line AS l, name_start_col AS c \
    \  FROM resolved_var_refs \
    \  WHERE name_start_line IS NOT NULL AND file NOT LIKE '__stdlib__/%' \
    \  UNION \
    \  SELECT file, to_name_start_line AS l, to_name_start_col AS c \
    \  FROM resolved_calls \
    \  WHERE to_name_start_line IS NOT NULL AND file NOT LIKE '__stdlib__/%' \
    \) \
    \SELECT \
    \  (SELECT COUNT(*) FROM identifier_tokens WHERE file NOT LIKE '__stdlib__/%'), \
    \  (SELECT COUNT(*) FROM identifier_tokens it \
    \     WHERE it.file NOT LIKE '__stdlib__/%' \
    \     AND EXISTS (SELECT 1 FROM resolved_positions rp \
    \                 WHERE rp.file = it.file AND rp.l = it.start_line AND rp.c = it.start_col)), \
    \  (SELECT COUNT(*) FROM resolved_var_refs WHERE file NOT LIKE '__stdlib__/%'), \
    \  (SELECT COUNT(*) FROM resolved_var_refs WHERE file NOT LIKE '__stdlib__/%' AND kind != 'unresolved'), \
    \  (SELECT COUNT(*) FROM resolved_calls WHERE file NOT LIKE '__stdlib__/%'), \
    \  (SELECT COUNT(*) FROM resolved_calls WHERE file NOT LIKE '__stdlib__/%' AND kind != 'unresolved')"
  pure $ case rows of
    [CoverageRow s] -> s
    _               -> TypeCoverageStats 0 0 0 0 0 0

-- ---------------------------------------------------------------------------
-- Dead-code input relations

-- | Materializes the input relations the dead-code analysis reads: @proc@
-- (every known procedure), @entry@ (event\/on handlers, plus DW-object
-- procedures with outbound calls), @calls@ (same-object case-insensitive
-- name-matched calls, unioned with cross-object resolved calls, both derived
-- from @resolved_calls@), @inherits@ (a faithful thin projection: @object@\/
-- @ancestor@ pairs from @objects@, the source inheritance fact -- no
-- closure, no derivation), @call_ref@\/@resolved_call_edge@ (the two
-- @resolved_calls@-derived relations @calls@ is itself built from -- see
-- 'callsRows'), and @proc_meta@ (procedure metadata for the caller-count\/
-- confidence classification). Must run after
-- 'PB.Pipeline.DuckDb.initSchema' and after @objects@\/@procedures@\/
-- @resolved_calls@\/@dw_objects@ have been populated.
--
-- @calls@ is computed by joining 'callRefRows'\/'resolvedCallEdgeRows''s
-- output directly in memory, so the order the relations below are
-- materialized in is cosmetic.
--
-- Every read of @procedures@ excludes @confidence = 'speculative'@ rows --
-- synthetic stub procedures registered for PB base classes
-- (@dwobject@\/@powerobject@\/@window@\/... method resolution), never real
-- workspace code. An unfiltered @proc@ relation inflates @proc_dead@ with
-- every one of these builtin stub methods.
-- | Rows 'initDeadCodeRelations' already fetched from @procedures@\/
-- @resolved_calls@\/object ancestors\/@dw_objects@, threaded into
-- 'PB.Analysis.DeadCodeReachability.materializeDeadCodeClosure' instead of
-- it re-querying the same four tables (Plan 187 §18 tier 1).
data DeadCodeInputRows = DeadCodeInputRows
  { dcrProcs     :: [ProcSummaryRow]
  , dcrCalls     :: [Taint.ResolvedCallRow]
  , dcrAncestors :: [(Text, Text)]
  , dcrDwObjects :: [Text]
  , dcrCallEdges :: [CallEdge]
    -- ^ The same @callEdges@ 'initDeadCodeRelations' already derives for the
    -- @calls@ table, exposed for reuse by
    -- 'PB.Analysis.EffectClosure.computeProcEffectClosure''s edge input
    -- instead of re-deriving 'callRefRows'\/'resolvedCallEdgeRows'\/
    -- 'callsRows' a second time (Plan 221 Phase 1).
  }

initDeadCodeRelations :: Handle -> [Taint.ResolvedCallRow] -> IO DeadCodeInputRows
initDeadCodeRelations conn calls0 = do
  procs     <- queryProcedures conn
  ancestors <- queryObjectAncestors conn
  dwObjs    <- queryDwObjects conn
  let refs      = callRefRows calls0
      edges     = resolvedCallEdgeRows calls0
      callEdges = callsRows refs procs edges
  materialize "proc"     ["object", "proc"] (procRows procs)
  materialize "entry"    ["object", "proc"] (entryRows procs calls0 dwObjs)
  materialize "inherits" ["child", "parent"] (inheritsRows ancestors)
  materialize "call_ref" ["caller_obj", "caller_proc", "callee_name"]
    (map (\r -> [crCallerObj r, crCallerProc r, crCalleeName r]) refs)
  materialize "resolved_call_edge"
    ["caller_obj", "caller_proc", "callee_obj", "callee_proc", "line"]
    (map (\e -> [rceCallerObj e, rceCallerProc e, rceCalleeObj e, rceCalleeProc e, rceLine e]) edges)
  materialize "calls" ["caller_obj", "caller_proc", "callee_obj", "callee_proc"]
    (map (\e -> [ceCallerObj e, ceCallerProc e, ceCalleeObj e, ceCalleeProc e]) callEdges)
  materialize "proc_meta" ["object", "proc", "proc_type", "cyclomatic", "proc_lower"]
    (procMetaRows procs)
  pure DeadCodeInputRows
    { dcrProcs = procs, dcrCalls = calls0, dcrAncestors = ancestors, dcrDwObjects = dwObjs
    , dcrCallEdges = callEdges
    }
  where
    materialize name cols rows = do
      recreateTextTable conn name cols
      appendTextRows conn name rows

-- | @proc@: every known procedure, excluding speculative (synthetic
-- builtin-class stub) rows.
procRows :: [ProcSummaryRow] -> [[Text]]
procRows procs =
  [ [psrObject r, psrProcName r]
  | r <- procs, psrConfidence r /= "speculative"
  ]

-- | @proc_meta@: procedure metadata for caller-count\/confidence
-- classification, same speculative filter as 'procRows'.
procMetaRows :: [ProcSummaryRow] -> [[Text]]
procMetaRows procs =
  [ [ psrObject r, psrProcName r, psrProcType r
    , maybe "" (T.pack . show) (psrCyclomatic r)
    , T.toLower (psrProcName r)
    ]
  | r <- procs, psrConfidence r /= "speculative"
  ]

-- | @inherits@: (object,ancestor) pairs renamed to (child,parent).
-- 'PB.Pipeline.DuckDb.queryObjectAncestors' already excludes NULL ancestors.
inheritsRows :: [(Text, Text)] -> [[Text]]
inheritsRows = map (\(child, parent) -> [child, parent])

-- | A @call_ref@ row: same-object case-insensitive callee-name reference,
-- derived from @resolved_calls@.
data CallRef = CallRef
  { crCallerObj  :: !Text
  , crCallerProc :: !Text
  , crCalleeName :: !Text
  } deriving (Eq, Ord, Show)

-- | A @resolved_call_edge@ row: a fully cross-object-resolved call site.
data ResolvedCallEdge = ResolvedCallEdge
  { rceCallerObj  :: !Text
  , rceCallerProc :: !Text
  , rceCalleeObj  :: !Text
  , rceCalleeProc :: !Text
  , rceLine       :: !Text
  } deriving (Eq, Ord, Show)

-- | A @calls@ row: the union 'callsRows' produces from 'CallRef'\/
-- 'ResolvedCallEdge' (no @line@ column -- 'calls' is a pure reachability
-- edge, unlike 'ResolvedCallEdge', which keeps @line@ so the scoped caller
-- count doesn't dedupe distinct call sites).
data CallEdge = CallEdge
  { ceCallerObj  :: !Text
  , ceCallerProc :: !Text
  , ceCalleeObj  :: !Text
  , ceCalleeProc :: !Text
  } deriving (Eq, Ord, Show)

-- | @call_ref@: same-object case-insensitive callee references, deduped to
-- one row per distinct (caller_obj,caller_proc,callee_name). The callee
-- name is the text after the last @.@ in @to_name@ (a control-qualified
-- call like @dw_1.retrieve()@), lowercased.
callRefRows :: [Taint.ResolvedCallRow] -> [CallRef]
callRefRows calls = Set.toList . Set.fromList $
  [ CallRef (Taint.rcrObject c) (Taint.rcrFromProc c)
            (T.toLower (lastDotSegment (Taint.rcrToName c)))
  | c <- calls
  ]

-- | The text after the last @.@ in @t@, or @t@ itself if it has none. Uses
-- @reverse@-then-case-match rather than list 'last' ('PB.Prelude' hides
-- partial functions) -- the same pattern 'PB.Analysis.CallClassify' uses for
-- its own dotted-chain splits.
lastDotSegment :: Text -> Text
lastDotSegment t = case reverse (T.splitOn "." t) of
  (x:_) -> x
  []    -> t

-- | @resolved_call_edge@: fully cross-object-resolved call sites (both a
-- target object and proc), with a missing line coalesced to @""@.
-- Deliberately not deduped (unlike 'callRefRows'): the scoped caller count must
-- count every call site, not collapse duplicates sharing the same
-- (caller,callee).
resolvedCallEdgeRows :: [Taint.ResolvedCallRow] -> [ResolvedCallEdge]
resolvedCallEdgeRows calls =
  [ ResolvedCallEdge (Taint.rcrObject c) (Taint.rcrFromProc c) to tp
      (maybe "" (T.pack . show . ssStartLine) (Taint.rcrSpan c))
  | c <- calls
  , Just to <- [Taint.rcrTargetObject c]
  , Just tp <- [Taint.rcrTargetProc c]
  ]

-- | @entry@: the union of (a) event\/on handlers (confidence-filtered, same
-- as 'procRows') and (b) every distinct (object,from_proc) pair from
-- @resolved_calls@ whose object is a known DW object.
entryRows :: [ProcSummaryRow] -> [Taint.ResolvedCallRow] -> [Text] -> [[Text]]
entryRows procs calls dwObjs =
  [ [o, p] | (o, p) <- Set.toList (Set.union fromProcs fromCalls) ]
  where
    dwObjSet = Set.fromList dwObjs
    fromProcs = Set.fromList
      [ (psrObject r, psrProcName r)
      | r <- procs
      , psrProcType r `elem` ["event", "on"]
      , psrConfidence r /= "speculative"
      ]
    fromCalls = Set.fromList
      [ (Taint.rcrObject c, Taint.rcrFromProc c)
      | c <- calls
      , Taint.rcrObject c `Set.member` dwObjSet
      ]

-- | @calls@: same-object case-insensitive name matches ('CallRef' joined
-- against @procedures@ by lowercased name, confidence-filtered) unioned
-- with 'ResolvedCallEdge' (its @line@ column dropped), deduped across the
-- combined result.
callsRows :: [CallRef] -> [ProcSummaryRow] -> [ResolvedCallEdge] -> [CallEdge]
callsRows refs procs edges =
  Set.toList . Set.fromList $ viaCallRef ++ viaResolved
  where
    procIndex = Map.fromListWith (++)
      [ ((psrObject p, T.toLower (psrProcName p)), [psrProcName p])
      | p <- procs, psrConfidence p /= "speculative"
      ]
    viaCallRef =
      [ CallEdge (crCallerObj r) (crCallerProc r) (crCallerObj r) calleeName
      | r <- refs
      , calleeName <- fromMaybe [] (Map.lookup (crCallerObj r, crCalleeName r) procIndex)
      ]
    viaResolved =
      [ CallEdge (rceCallerObj e) (rceCallerProc e) (rceCalleeObj e) (rceCalleeProc e)
      | e <- edges
      ]

-- ---------------------------------------------------------------------------
-- Taint fan-in diagnostics

-- | Fan-in characterization for a grouped-join key, mirroring
-- 'LegSourceFanout' -- computed directly in
-- DuckDB SQL against the already-materialized @proc_defs@\/@proc_uses@
-- tables. A duplicate-key fan-in blowup is the established failure shape
-- in this neighborhood (see compiler/CLAUDE.md's Appender-pool section
-- and the leg_source fan-in report), so this runs unconditionally as an
-- early-warning signal before the taint closure itself.
data DefUseFanout = DefUseFanout
  { dufTotalRows    :: !Int
  , dufDistinctKeys :: !Int
  , dufMaxGroupSize :: !Int
  } deriving (Eq, Show)

newtype FanoutRow2 = FanoutRow2 DefUseFanout

instance FromRow FanoutRow2 where
  fromRow = (\t k m -> FanoutRow2 (DefUseFanout t k m)) <$> field <*> field <*> field

-- | Fan-in of @proc_defs@ rows sharing one (object, proc_name, line) key.
defLineFanout :: Handle -> IO DefUseFanout
defLineFanout conn = do
  rows <- queryHandle conn
    "WITH g AS (SELECT object, proc_name, line, COUNT(*) AS cnt FROM proc_defs \
    \WHERE line IS NOT NULL GROUP BY object, proc_name, line) \
    \SELECT (SELECT COUNT(*) FROM proc_defs WHERE line IS NOT NULL), \
    \COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow2 f] -> f
    _             -> DefUseFanout 0 0 0

-- | Fan-in of @proc_uses@ rows tagged @kind = 'return'@ sharing one
-- (object, proc_name) key.
returnUseFanout :: Handle -> IO DefUseFanout
returnUseFanout conn = do
  rows <- queryHandle conn
    "WITH g AS (SELECT object, proc_name, COUNT(*) AS cnt FROM proc_uses \
    \WHERE kind = 'return' GROUP BY object, proc_name) \
    \SELECT (SELECT COUNT(*) FROM proc_uses WHERE kind = 'return'), \
    \COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow2 f] -> f
    _             -> DefUseFanout 0 0 0
