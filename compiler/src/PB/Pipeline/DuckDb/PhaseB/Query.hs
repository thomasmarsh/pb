{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.DuckDb.PhaseB.Query
  ( queryCallSites
  , queryGlobalVars
  , queryObjInfo
  , queryCallableProcMap
  , queryProcDefs
  , queryProcUses
  , ProcRows (..)
  , CallGraphAndTaintReady (..)
  , DeadCodeClosureReady (..)
  , SchemaClosureReady (..)
  , queryResolvedCalls
  , queryTaintInputs
  , queryDwRetrieveColumns
  , queryDwJoinLegs
  , querySqlCols
  , queryCatColumns
  , queryCatFks
  -- Plan 175 Phase 1: typed relation-reshaping-layer readers
  , SchMorphismRow (..)
  , querySchemaObjects
  , querySchemaMorphismRows
  -- Plan 175 Phase 2: typed relation-reshaping-layer readers (DeadCode.hs)
  , ProcSummaryRow (..)
  , queryObjectAncestors
  , queryProcedures
  , queryDwObjects
  ) where

import PB.Prelude
import PB.AST.Ident             (Ident, IdentMap, IdentSet, identMapFromListWith, identSetSingleton, identSetUnion, mkIdent)
import PB.AST.Type             (parseTypeText, parseTypeTextAt)
import PB.Lexing.Token          (SourceSpan (..))
import PB.Analysis.TypeResolve
  ( CallSite (..), GlobalVar (..)
  )
import PB.Analysis.Taint            qualified as Taint
import PB.Analysis.TaintClosure        qualified as TaintClosure
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  )
import PB.Pipeline.SqlParse    (TableRef (..))
import PB.Pipeline.DuckDb      (Handle, queryHandle)

import Database.DuckDB.Simple.FromRow  (FromRow (..), RowParser, field)

import qualified Data.Map.Strict         as Map
import qualified Data.Set                as Set
import qualified Data.Text               as T

-- ---------------------------------------------------------------------------
-- FromRow instances (orphans for external types)

-- | Read four nullable INTEGER span columns (in @start_line, start_col,
-- end_line, end_col@ order) as one 'SourceSpan', all-or-nothing -- every
-- write site fills all four together or leaves all four NULL, so partial
-- construction never arises in practice.
fieldSpan :: RowParser (Maybe SourceSpan)
fieldSpan = do
  sl <- field; sc <- field; el <- field; ec <- field
  pure (SourceSpan <$> sl <*> sc <*> el <*> ec)

instance FromRow CallSite where
  fromRow = do
    f_  <- field; o_  <- field; fp_ <- field; tn_ <- field
    ct_ <- field; l_  <- field; ro_ <- field
    sp_ <- fieldSpan
    pure CallSite
      { csFile           = f_
      , csObject         = o_
      , csFromProc       = fp_
      , csToName         = tn_
      , csCallType       = ct_
      , csLine           = l_
      , csReceiverObject = ro_
      , csToNameSpan     = sp_
      }

instance FromRow GlobalVar where
  fromRow = do
    f_     <- field
    o_     <- field
    n_     <- field
    t_     <- field
    ms_    <- field
    typeSp_ <- fieldSpan
    pure GlobalVar
      { gvFile   = f_
      , gvObject = o_
      , gvName   = n_
      , gvType   = t_
      , gvMods   = if T.null ms_ then [] else T.splitOn "|" ms_
      , gvPbType = maybe (parseTypeText t_) (`parseTypeTextAt` t_) typeSp_
      }

instance FromRow Taint.DefRow where
  fromRow = Taint.DefRow
    <$> field <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field
    <*> fieldSpan

instance FromRow Taint.UseRow where
  fromRow = Taint.UseRow
    <$> field <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field
    <*> fieldSpan



instance FromRow Taint.ResolvedCallRow where
  fromRow = do
    f_  <- field; o_  <- field; fp_ <- field; tn_ <- field; ct_ <- field
    l_  <- field; to_ <- field; tp_ <- field; k_  <- field; c_  <- field
    sp_ <- fieldSpan
    pure Taint.ResolvedCallRow
      { Taint.rcrFile           = f_
      , Taint.rcrObject         = o_
      , Taint.rcrFromProc       = fp_
      , Taint.rcrToName         = tn_
      , Taint.rcrCallType       = ct_
      , Taint.rcrCallLine       = l_
      , Taint.rcrTargetObject   = to_
      , Taint.rcrTargetProc     = tp_
      , Taint.rcrResolutionKind = k_
      , Taint.rcrConfidence     = c_
      , Taint.rcrReturnType     = Nothing
      , Taint.rcrSpan           = sp_
      }

instance FromRow DwRetrieveColRow where
  fromRow = DwRetrieveColRow <$> field <*> field <*> field <*> field <*> field

instance FromRow DwJoinLegRow where
  fromRow = DwJoinLegRow <$> field <*> field <*> field <*> field

instance FromRow SqlColRow where
  fromRow = do
    f_  <- field
    o_  <- field
    p_  <- field
    l_  <- field
    ns_ <- field
    tb_ <- field
    c_  <- field
    w_  <- field
    pure SqlColRow
      { scStmt      = SqlStmtId f_ o_ p_ l_
      , scNamespace = ns_
      , scTable     = tb_
      , scColumn    = c_
      , scIsWrite   = w_
      }

instance FromRow CatColumnRow where
  fromRow = CatColumnRow <$> field <*> field <*> field

instance FromRow CatFkRow where
  fromRow = CatFkRow <$> field <*> field <*> field <*> field <*> field <*> field

-- Local row types for complex grouping queries
data SqlRow5 = SqlRow5 !Text !Text !Text !Int !Text

instance FromRow SqlRow5 where
  fromRow = SqlRow5 <$> field <*> field <*> field <*> field <*> field

data MetaRow6 = MetaRow6 !Text !Text !Text !Text !Text !Text !Text

instance FromRow MetaRow6 where
  fromRow = MetaRow6 <$> field <*> field <*> field <*> field <*> field <*> field <*> field

newtype OneText = OneText Text

instance FromRow OneText where
  fromRow = OneText <$> field

data TwoText = TwoText !Text !Text

instance FromRow TwoText where
  fromRow = TwoText <$> field <*> field

-- ---------------------------------------------------------------------------
-- Phase B queries

queryCallSites :: Handle -> IO [CallSite]
queryCallSites conn = queryHandle conn
  "SELECT file, object, proc_name, to_name, call_type, line, receiver_object, \
  \to_name_start_line, to_name_start_col, to_name_end_line, to_name_end_col \
  \FROM call_sites"

queryGlobalVars :: Handle -> IO [GlobalVar]
queryGlobalVars conn = queryHandle conn
  "SELECT file, object, var_name, var_type, mods, \
  \type_start_line, type_start_col, type_end_line, type_end_col \
  \FROM global_vars"

-- | Build the four workspace-wide maps needed by Pass 5 from the DB. The
-- inherits map is 'Ident'-keyed (Plan 179 Phase 5, mirroring
-- 'PB.Analysis.TypeResolve.buildInheritsMap''s JSON-pipeline counterpart) --
-- @objects.object@\/@objects.ancestor@ are read verbatim from independently
-- parsed files with no cross-row case normalization, so a declaration's own
-- casing and another file's reference to it as an ancestor can genuinely
-- differ; 'PB.Analysis.TypeResolve.ancestorChain''s canonical-'Ident' walk
-- is what makes that mismatch harmless. The proc map's own outer key is
-- 'IdentMap'-keyed the same way (Plan 179 procMap-outer-key fix), so
-- 'PB.Analysis.TypeResolve.resolveVirtual' recovers the target object's own
-- declared casing even when reached via such a mismatched reference.
queryObjInfo
  :: Handle
  -> IO (Set.Set Text, Set.Set Text, Map.Map Ident Ident, IdentMap IdentSet)
queryObjInfo conn = do
  objRows  <- queryHandle conn
    "SELECT object FROM objects \
    \WHERE LOWER(COALESCE(ancestor,'')) != 'structure'" :: IO [OneText]
  usrRows  <- queryHandle conn
    "SELECT object FROM objects WHERE LOWER(ancestor) = 'structure'" :: IO [OneText]
  inhRows  <- queryHandle conn
    "SELECT object, ancestor FROM objects WHERE ancestor IS NOT NULL" :: IO [TwoText]
  procRows <- queryHandle conn
    "SELECT object, proc_name FROM procedures" :: IO [TwoText]
  pure
    ( Set.fromList [t | OneText t <- objRows]
    , Set.fromList [t | OneText t <- usrRows]
    , Map.fromList [(mkIdent o, mkIdent a) | TwoText o a <- inhRows]
    , identMapFromListWith identSetUnion
        [(mkIdent o, identSetSingleton (mkIdent p)) | TwoText o p <- procRows]
    )

-- | Same shape as 'queryObjInfo''s proc map, restricted to proc kinds
-- actually invocable via a bare @name(...)@ call. @event@\/@on@-block
-- declarations (PowerScript event handlers) share 'queryObjInfo''s full
-- map so 'ExMethodCall'\/'ExCallArg' dispatch and the global fallback keep
-- seeing them, but a bare 'ExCall' can never legitimately target one --
-- events fire via @TriggerEvent@\/@PostEvent@\/the @Event@ keyword, never a
-- direct call. Real corpus evidence for why this must be a separate map,
-- not a filter applied uniformly: every window object registers an
-- @open@\/@close@ event, which would otherwise shadow the builtin
-- @Open@\/@Close@ free functions for any bare call made from inside that
-- window's own script.
queryCallableProcMap :: Handle -> IO (IdentMap IdentSet)
queryCallableProcMap conn = do
  procRows <- queryHandle conn
    "SELECT object, proc_name FROM procedures \
    \WHERE proc_type IN ('function', 'subroutine')" :: IO [TwoText]
  pure $ identMapFromListWith identSetUnion
    [(mkIdent o, identSetSingleton (mkIdent p)) | TwoText o p <- procRows]

queryProcDefs :: Handle -> IO [Taint.DefRow]
queryProcDefs conn = queryHandle conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind, \
  \var_start_line, var_start_col, var_end_line, var_end_col \
  \FROM proc_defs"

queryProcUses :: Handle -> IO [Taint.UseRow]
queryProcUses conn = queryHandle conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind, \
  \var_start_line, var_start_col, var_end_line, var_end_col \
  \FROM proc_uses"

-- | @proc_defs@\/@proc_uses@ rows 'PB.Pipeline.Passes.buildCallGraphAndTaint' already
-- fetched for interproc-edge building, threaded into
-- 'PB.Pipeline.DuckDb.materializeTaintAnnotations' instead of it re-querying
-- the same two tables (Plan 187 §18 tier 3).
data ProcRows = ProcRows
  { prDefs :: [Taint.DefRow]
  , prUses :: [Taint.UseRow]
  }

-- | Proof-of-completion token for 'PB.Pipeline.Passes.buildCallGraphAndTaint':
-- minted once that stage's writes (interproc edges, taint sources/sinks,
-- taint closure tables) are done, consumed by
-- 'PB.Pipeline.DuckDb.Materialize.materializeTaintPaths'\/'materializeTaintAnnotations'.
-- Its constructor is exported from this module (Haskell has no
-- "friend module" access control, and its one legitimate construction
-- site, 'PB.Pipeline.Passes.buildCallGraphAndTaint', lives in a
-- different module than this declaration) -- correctness rests on
-- convention plus review: exactly one call site constructs it, and
-- the @constraint-evasion@ skill's Step 5 is the mechanism that catches
-- a future construction site appearing anywhere it shouldn't.
data CallGraphAndTaintReady = CallGraphAndTaintReady
  { cgtrSources      :: ![Taint.TaintSource]
  , cgtrSinks        :: ![Taint.TaintSink]
  , cgtrReachesPairs :: ![(TaintClosure.TaintTriple, TaintClosure.TaintTriple)]
  , cgtrConfirmed    :: ![(Taint.TaintSource, Taint.TaintSink)]
  }

-- | Proof-of-completion token for
-- 'PB.Pipeline.Passes.computeDeadCodeClosure' (writes @proc_dead@),
-- consumed by 'PB.Pipeline.DuckDb.Materialize.materializeLiveProc'\/
-- 'materializeDeadCode'. No exported constructor at the type-class level,
-- but this constructor MUST be exported from this module's export list
-- (see module export list below) because its one legitimate construction
-- site lives in 'PB.Pipeline.Passes', a different module than its
-- declaration site. There is exactly one legitimate call site for this
-- constructor in the whole codebase:
-- 'PB.Pipeline.Passes.computeDeadCodeClosure'. Do not construct it
-- anywhere else.
newtype DeadCodeClosureReady = DeadCodeClosureReady ()

-- | Proof-of-completion token for
-- 'PB.Pipeline.Passes.computeSchemaClosure' (writes @reaches\/
-- path_leg_fwd\/path_leg_back@), consumed by
-- 'PB.Pipeline.DuckDb.Materialize.materializeRiskCount'\/
-- 'materializeDecompositionCoslice'. Same cross-module export
-- requirement and same one-legitimate-call-site rule as
-- 'DeadCodeClosureReady' above: the one legitimate construction site is
-- 'PB.Pipeline.Passes.computeSchemaClosure'.
newtype SchemaClosureReady = SchemaClosureReady ()

queryResolvedCalls :: Handle -> IO [Taint.ResolvedCallRow]
queryResolvedCalls conn = queryHandle conn
  "SELECT file, object, proc_name, to_name, call_type, line, \
  \target_object, target_proc, kind, confidence, \
  \to_name_start_line, to_name_start_col, to_name_end_line, to_name_end_col \
  \FROM resolved_calls"

-- | Reconstruct per-file TaintFileInputs from the sql_statements and
-- procedures tables.  SqlStmt values are re-derived from raw_sql using
-- the same classifyOperation / hasIntoClause logic as extractTaintInputs.
queryTaintInputs :: Handle -> IO [Taint.TaintFileInputs]
queryTaintInputs conn = do
  sqlRows  <- queryHandle conn
    "SELECT file, object, proc_name, line, raw_sql FROM sql_statements"
  metaRows <- queryHandle conn
    "SELECT file, object, proc_name, proc_type, params, return_type, param_names FROM procedures"
  objRows  <- queryHandle conn
    "SELECT file, object FROM objects WHERE kind='powerscript'" :: IO [TwoText]
  let stmts   = mapMaybe rowToStmt  (sqlRows  :: [SqlRow5])
      metas   = map      rowToMeta  (metaRows :: [MetaRow6])
      stmtMap = Map.fromListWith (<>)
                  [((Taint.ssFile s, Taint.ssObject s), [s]) | s <- stmts]
      metaMap = Map.fromListWith (<>)
                  [((Taint.pmFile m, Taint.pmObject m), [m]) | m <- metas]
      -- Include PS objects with no procedures (matches JSON path which runs
      -- extractTaintInputs on every successfully parsed PS file).
      objKeys = Set.fromList [(f, o) | TwoText f o <- objRows]
      allKeys = Set.toList (Map.keysSet stmtMap `Set.union` Map.keysSet metaMap
                            `Set.union` objKeys)
  pure [ Taint.TaintFileInputs f o
           (Map.findWithDefault [] (f, o) stmtMap)
           (Map.findWithDefault [] (f, o) metaMap)
       | (f, o) <- allKeys ]
  where
    skipped :: Set.Set Text
    skipped = Set.fromList
      ["DECLARE","OPEN","FETCH","CLOSE","COMMIT","ROLLBACK","CONNECT","DISCONNECT"]
    rowToStmt (SqlRow5 f o p l raw) =
      let op = Taint.classifyOperation raw
      in if T.null op || Set.member op skipped
         then Nothing
         else Just (Taint.SqlStmt f o p (Just l) op raw (Taint.hasIntoClause raw))
    rowToMeta (MetaRow6 f o p pt _par rt paramNames) =
      Taint.ProcMeta f o p pt (if T.null paramNames then [] else T.splitOn "|" paramNames) rt Nothing

-- | Plan 148 Phase 1b: SchemaCategory read-side queries.
queryDwRetrieveColumns :: Handle -> IO [DwRetrieveColRow]
queryDwRetrieveColumns conn = queryHandle conn
  "SELECT file, object, namespace, table_name, column_name FROM dw_retrieve_columns"

-- | Plan 163 Phase 6. Same 'DwRetrieveColRow' 'FromRow' shape as
-- 'queryDwRetrieveColumns' -- only the source table differs.
queryDwJoinLegs :: Handle -> IO [DwJoinLegRow]
queryDwJoinLegs conn = queryHandle conn
  "SELECT file, object, left_ref, right_ref FROM dw_joins"

querySqlCols :: Handle -> IO [SqlColRow]
querySqlCols conn = queryHandle conn
  "SELECT file, object, proc_name, line, namespace, table_name, column_name, is_write \
  \FROM sql_statement_columns"

-- | Plan 175 Phase 1: typed reader over 'schema_objects', the inverse of
-- 'PB.Pipeline.DuckDb.PhaseB.Append.appendSchemaObjects'. object_key is not
-- selected -- 'schObjectKey' is a pure function of the other columns, so it
-- is cheaper to recompute than to read back and never check for drift
-- against the stored value.
data SchObjectRow = SchObjectRow
  !Text !(Maybe Text) !(Maybe Text) !(Maybe Text)
  !(Maybe Text) !(Maybe Text) !(Maybe Text) !(Maybe Int)

instance FromRow SchObjectRow where
  fromRow = SchObjectRow
    <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

querySchemaObjects :: Handle -> IO [SchObject]
querySchemaObjects conn = do
  rows <- queryHandle conn
    "SELECT kind, namespace, table_name, column_name, \
    \stmt_file, stmt_object, stmt_proc, stmt_line FROM schema_objects"
  pure (map toSchObject rows)
  where
    toSchObject (SchObjectRow "column" ns (Just tbl) (Just col) _ _ _ _) =
      ColumnObj (TableRef ns tbl) col
    toSchObject (SchObjectRow "stmt" _ _ _ (Just f) (Just o) (Just p) (Just l)) =
      StmtObj (SqlStmtId f o p l)
    toSchObject (SchObjectRow "dw_retrieve" _ _ _ (Just f) (Just dw) _ _) =
      StmtObj (DwRetrieveId f dw)
    toSchObject _ =
      error "impossible: malformed schema_objects row (unknown kind or missing required column)"

-- | Plan 175 Phase 1: typed reader over 'schema_morphisms'. Deliberately
-- NOT 'SchemaCategory.SchMorphism' -- 'from_key'\/'to_key' are
-- 'schObjectKey'-sanitized, one-way concatenated strings (control
-- characters collapsed to space; see 'schObjectKey''s own doc comment), and
-- no inverse parser exists anywhere in this codebase. 'leg_source' (this
-- phase's only consumer) never needs the decoded object, only the raw key
-- text -- inventing a from_key\/to_key parser here would be unproven
-- machinery beyond this phase's scope.
data SchMorphismRow = SchMorphismRow
  { smrFromKey   :: !Text
  , smrToKey     :: !Text
  , smrLegKind   :: !Text
  , smrLegSource :: !Text
  } deriving (Eq, Show)

instance FromRow SchMorphismRow where
  fromRow = SchMorphismRow <$> field <*> field <*> field <*> field

querySchemaMorphismRows :: Handle -> IO [SchMorphismRow]
querySchemaMorphismRows conn = queryHandle conn
  "SELECT from_key, to_key, leg_kind, leg_source FROM schema_morphisms"

-- | Plan 175 Phase 2: typed reader over 'objects', feeding
-- 'PB.Pipeline.DuckDb.Relations.inheritsRows'. Deliberately not the write-side
-- 'ObjectRow' -- that type carries 'orLayoutJson'\/'orTypeBlocksJson', which
-- @inherits@ never reads; selecting only the two columns actually needed
-- avoids transferring that JSON for every object row. The @ancestor IS NOT
-- NULL@ filter is the same one 'queryObjInfo' already applies for its own
-- @inhRows@. Unioned with @type_ancestors@ (Plan 214 scope-item-3 follow-on:
-- @objects@ is one row per *file*, so a nested @within@-qualified control's
-- own ancestor -- e.g. an implicit system control like an MDI frame's
-- @mdi_1@ -- never appears there; @type_ancestors@ is the additive
-- per-'PB.AST.SourceFile.TypeBlock' counterpart, see
-- 'PB.Analysis.TypeEnv.extractNestedTypeDecls') so both the materialized
-- @inherits@ relation and dead-code reachability's ancestor closure see a
-- nested control's ancestor too.
queryObjectAncestors :: Handle -> IO [(Text, Text)]
queryObjectAncestors conn = do
  rows <- queryHandle conn
    "SELECT object, ancestor FROM objects WHERE ancestor IS NOT NULL \
    \UNION \
    \SELECT child, parent FROM type_ancestors" :: IO [TwoText]
  pure [(o, a) | TwoText o a <- rows]

-- | Plan 175 Phase 2: typed reader over 'procedures', feeding
-- 'PB.Pipeline.DuckDb.Relations.procRows'\/'procMetaRows'\/'entryRows'\/
-- 'callsRows'. Deliberately not the write-side 'ProcRow' -- that type
-- carries 'prCfgJson'\/'prInstrJson'\/'prWiringJson', none of which any of
-- the four consumers read; selecting only the five columns actually needed
-- avoids transferring that JSON for every procedure row.
data ProcSummaryRow = ProcSummaryRow
  { psrObject     :: !Text
  , psrProcName   :: !Text
  , psrProcType   :: !Text
  , psrCyclomatic :: !(Maybe Int)
  , psrConfidence :: !Text
  } deriving (Eq, Show)

instance FromRow ProcSummaryRow where
  fromRow = ProcSummaryRow <$> field <*> field <*> field <*> field <*> field

queryProcedures :: Handle -> IO [ProcSummaryRow]
queryProcedures conn = queryHandle conn
  "SELECT object, proc_name, proc_type, cyclomatic, confidence FROM procedures"

-- | Plan 175 Phase 2: typed reader over 'dw_objects', feeding
-- 'PB.Pipeline.DuckDb.Relations.entryRows''s DW-object membership check.
queryDwObjects :: Handle -> IO [Text]
queryDwObjects conn = do
  rows <- queryHandle conn "SELECT DISTINCT object FROM dw_objects" :: IO [OneText]
  pure [o | OneText o <- rows]

queryCatColumns :: Handle -> IO [CatColumnRow]
queryCatColumns conn = queryHandle conn
  "SELECT namespace, table_name, column_name FROM catalog_columns"

queryCatFks :: Handle -> IO [CatFkRow]
queryCatFks conn = queryHandle conn
  "SELECT from_namespace, from_table, from_column, to_namespace, to_table, to_column \
  \FROM catalog_fks"
