-- | The dead-code EDB-relation materializers: the typed Haskell functions
-- that build the @proc@\/@entry@\/@calls@\/@inherits@\/@call_ref@\/
-- @resolved_call_edge@\/@proc_meta@ relations the dead-code analysis reads.
--
-- The live-procedure, caller-count, and dead-code-row relations
-- (@live_proc@, @confidence@, @caller_count_*@, @dead_code_rows@) are
-- materialized directly in DuckDB by 'PB.Pipeline.DuckDb'
-- ('materializeLiveProc', 'materializeCallerCounts', 'materializeDeadCodeRows')
-- and reshaped into @dead_code@ by 'PB.Pipeline.DuckDb.materializeDeadCode'.
--
-- @proc_dead@ itself is materialized by
-- 'PB.Analysis.DeadCodeAlgebra.materializeDeadCodeClosure', a Haskell
-- 'PB.Algebra.Closure.reachFrom' closure. The seeded reachability core
-- (including the @descendant@ transitive closure and derived @override_edge@
-- triple) is that same closure.
--
-- @inherits@ is a faithful projection of @objects.ancestor@.
module PB.Analysis.Rules.DeadCode
  ( initDeadReachEdbViews
  -- Pure EDB-relation-construction functions (exported for unit tests)
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
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb
  ( DuckConn, ProcSummaryRow (..)
  , queryObjectAncestors, queryProcedures, queryDwObjects, queryResolvedCalls
  , recreateTextTable, appendTextRows
  )
import PB.Analysis.Taint qualified as Taint

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- EDB relations for the reachability closure: seeds from 'entry', walks
-- 'calls', folds in inheritance overrides via @descendant@\/@override_edge@
-- (a Haskell 'PB.Algebra.Closure.reachFrom' closure in
-- 'PB.Analysis.DeadCodeAlgebra'). The downstream
-- 'PB.Pipeline.DuckDb.materializeLiveProc' reads @proc_dead@ directly to
-- build @live_proc@; 'PB.Pipeline.DuckDb.materializeCallerCounts' builds the
-- @confidence@\/@caller_count_*@ relations; and @dead_code@ is populated from
-- @dead_code_rows@ via 'PB.Pipeline.DuckDb.materializeDeadCode'.

-- | Materializes the EDB relations the dead-code analysis reads: @proc@
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
initDeadReachEdbViews :: DuckConn -> IO ()
initDeadReachEdbViews conn = do
  procs     <- queryProcedures conn
  calls0    <- queryResolvedCalls conn
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
      (maybe "" (T.pack . show) (Taint.rcrCallLine c))
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
-- Caller counts and @dead_code_rows@ are materialized directly in DuckDB by
-- 'PB.Pipeline.DuckDb.materializeCallerCounts' and
-- 'PB.Pipeline.DuckDb.materializeDeadCodeRows';
-- 'PB.Pipeline.DuckDb.materializeDeadCode' reshapes @dead_code_rows@ into
-- @dead_code@.

-- ---------------------------------------------------------------------------
-- @dead_code_rows@ is materialized directly in DuckDB by
-- 'PB.Pipeline.DuckDb.materializeDeadCodeRows';
-- 'PB.Pipeline.DuckDb.materializeDeadCode' reshapes it into @dead_code@.

-- | @proc_dead@ is materialized in Haskell (see
-- 'PB.Analysis.DeadCodeAlgebra.materializeDeadCodeClosure'); the
-- downstream 'PB.Pipeline.DuckDb.materializeLiveProc' reads it directly to
-- build @live_proc@.
