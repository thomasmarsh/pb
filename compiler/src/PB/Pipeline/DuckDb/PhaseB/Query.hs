{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.DuckDb.PhaseB.Query
  ( queryLocalVars
  , queryCallSites
  , queryGlobalVars
  , queryObjInfo
  , queryProcDefs
  , queryProcUses
  , queryResolvedCalls
  , queryTaintInputs
  , queryDwRetrieveColumns
  , queryDwWriteColumns
  , queryDwWhereColumns
  , queryDwJoinLegs
  , querySqlCols
  , queryCatFootprintColumns
  , queryCatColumns
  , queryCatFks
  , queryTaintIntraEdges
  , queryTaintReturnRows
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
import PB.AST.Type             (parseTypeText)
import PB.Analysis.TypeResolve
  ( LocalVar (..), CallSite (..), GlobalVar (..)
  )
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TaintEdges  qualified as TaintEdges
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  )
import PB.Pipeline.SqlParse    (TableRef (..))
import PB.Pipeline.DuckDb      (Handle, queryHandle)

import Database.DuckDB.Simple.FromRow  (FromRow (..), field)

import qualified Data.Map.Strict         as Map
import qualified Data.Set                as Set
import qualified Data.Text               as T

-- ---------------------------------------------------------------------------
-- FromRow instances (orphans for external types)

instance FromRow LocalVar where
  fromRow = do
    file_      <- field
    obj_       <- field
    proc_      <- field
    var_       <- field
    rawType_   <- field
    isParam_   <- field
    scopeLine_ <- field
    pure LocalVar
      { lvFile      = file_
      , lvObject    = obj_
      , lvProcName  = proc_
      , lvVarName   = var_
      , lvRawType   = rawType_
      , lvIsParam   = isParam_
      , lvScopeLine = scopeLine_
      , lvPbType    = parseTypeText rawType_
      }

instance FromRow CallSite where
  fromRow = CallSite <$> field <*> field <*> field <*> field <*> field <*> field

instance FromRow GlobalVar where
  fromRow = do
    f_  <- field
    o_  <- field
    n_  <- field
    t_  <- field
    ms_ <- field
    pure GlobalVar
      { gvFile   = f_
      , gvObject = o_
      , gvName   = n_
      , gvType   = t_
      , gvMods   = if T.null ms_ then [] else T.splitOn "|" ms_
      }

instance FromRow Taint.DefRow where
  fromRow = Taint.DefRow
    <$> field <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field

instance FromRow Taint.UseRow where
  fromRow = Taint.UseRow
    <$> field <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field

instance FromRow TaintEdges.TaintIntraEdgeRow where
  fromRow = TaintEdges.TaintIntraEdgeRow <$> field <*> field <*> field <*> field

instance FromRow TaintEdges.TaintReturnRow where
  fromRow = TaintEdges.TaintReturnRow <$> field <*> field <*> field

instance FromRow Taint.ResolvedCallRow where
  fromRow = do
    f_  <- field; o_  <- field; fp_ <- field; tn_ <- field; ct_ <- field
    l_  <- field; to_ <- field; tp_ <- field; k_  <- field; c_  <- field
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

data MetaRow6 = MetaRow6 !Text !Text !Text !Text !Text !Text

instance FromRow MetaRow6 where
  fromRow = MetaRow6 <$> field <*> field <*> field <*> field <*> field <*> field

newtype OneText = OneText Text

instance FromRow OneText where
  fromRow = OneText <$> field

data TwoText = TwoText !Text !Text

instance FromRow TwoText where
  fromRow = TwoText <$> field <*> field

-- ---------------------------------------------------------------------------
-- Phase B queries

queryLocalVars :: Handle -> IO [LocalVar]
queryLocalVars conn = queryHandle conn
  "SELECT file, object, proc_name, var_name, raw_type, is_param, scope_line \
  \FROM local_vars"

queryCallSites :: Handle -> IO [CallSite]
queryCallSites conn = queryHandle conn
  "SELECT file, object, from_proc, to_name, call_type, line FROM call_sites"

queryGlobalVars :: Handle -> IO [GlobalVar]
queryGlobalVars conn = queryHandle conn
  "SELECT file, object, var_name, var_type, mods FROM global_vars"

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

queryProcDefs :: Handle -> IO [Taint.DefRow]
queryProcDefs conn = queryHandle conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind \
  \FROM proc_defs"

queryProcUses :: Handle -> IO [Taint.UseRow]
queryProcUses conn = queryHandle conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind \
  \FROM proc_uses"

-- | Plan 182 Move 2: reads back 'PB.Pipeline.DuckDb.PhaseA.appendTaintIntraEdges''s output.
queryTaintIntraEdges :: Handle -> IO [TaintEdges.TaintIntraEdgeRow]
queryTaintIntraEdges conn = queryHandle conn
  "SELECT object, proc_name, use_var, def_var FROM taint_intra_edges"

-- | Plan 182b: reads back 'PB.Pipeline.DuckDb.PhaseA.appendTaintReturnRows''s output.
queryTaintReturnRows :: Handle -> IO [TaintEdges.TaintReturnRow]
queryTaintReturnRows conn = queryHandle conn
  "SELECT object, proc_name, var_name FROM taint_return_rows"

queryResolvedCalls :: Handle -> IO [Taint.ResolvedCallRow]
queryResolvedCalls conn = queryHandle conn
  "SELECT file, object, from_proc, to_name, call_type, line, \
  \target_object, target_proc, kind, confidence FROM resolved_calls"

-- | Reconstruct per-file TaintFileInputs from the sql_statements and
-- procedures tables.  SqlStmt values are re-derived from raw_sql using
-- the same classifyOperation / hasIntoClause logic as extractTaintInputs.
queryTaintInputs :: Handle -> IO [Taint.TaintFileInputs]
queryTaintInputs conn = do
  sqlRows  <- queryHandle conn
    "SELECT file, object, proc_name, line, raw_sql FROM sql_statements"
  metaRows <- queryHandle conn
    "SELECT file, object, proc_name, proc_type, params, return_type FROM procedures"
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
    rowToMeta (MetaRow6 f o p pt par rt) =
      Taint.ProcMeta f o p pt par rt Nothing

-- | Plan 148 Phase 1b: SchemaCategory read-side queries.
queryDwRetrieveColumns :: Handle -> IO [DwRetrieveColRow]
queryDwRetrieveColumns conn = queryHandle conn
  "SELECT file, dw_name, namespace, table_name, column_name FROM dw_retrieve_columns"

-- | Plan 163 Phase 6. Same 'DwRetrieveColRow' 'FromRow' shape as
-- 'queryDwRetrieveColumns' -- only the source table differs.
queryDwWriteColumns :: Handle -> IO [DwRetrieveColRow]
queryDwWriteColumns conn = queryHandle conn
  "SELECT file, dw_name, namespace, table_name, column_name FROM dw_write_columns"

queryDwWhereColumns :: Handle -> IO [DwRetrieveColRow]
queryDwWhereColumns conn = queryHandle conn
  "SELECT file, dw_name, namespace, table_name, column_name FROM dw_where_columns"

queryDwJoinLegs :: Handle -> IO [DwJoinLegRow]
queryDwJoinLegs conn = queryHandle conn
  "SELECT file, dw_name, left_ref, right_ref FROM dw_joins"

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
-- @inhRows@.
queryObjectAncestors :: Handle -> IO [(Text, Text)]
queryObjectAncestors conn = do
  rows <- queryHandle conn
    "SELECT object, ancestor FROM objects WHERE ancestor IS NOT NULL" :: IO [TwoText]
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

-- | Plan 163 Phase 3: same shape/query as 'querySqlCols', reading
-- 'cat_footprint_columns' instead -- the existing 'FromRow' 'SqlColRow'
-- instance is reused verbatim.
queryCatFootprintColumns :: Handle -> IO [SqlColRow]
queryCatFootprintColumns conn = queryHandle conn
  "SELECT file, object, proc_name, line, namespace, table_name, column_name, is_write \
  \FROM cat_footprint_columns"

queryCatColumns :: Handle -> IO [CatColumnRow]
queryCatColumns conn = queryHandle conn
  "SELECT namespace, table_name, column_name FROM catalog_columns"

queryCatFks :: Handle -> IO [CatFkRow]
queryCatFks conn = queryHandle conn
  "SELECT from_namespace, from_table, from_column, to_namespace, to_table, to_column \
  \FROM catalog_fks"
