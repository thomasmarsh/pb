{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.DuckDb
  ( DuckConn
  , withWriteConn
  , initSchema
  -- Row types
  , ObjectRow (..)
  , ProcRow (..)
  , DwObjectRow (..)
  , DwControlRow (..)
  , DwRetrieveTableRow (..)
  , SqlStmtRow (..)
  , SourceFileRow (..)
  -- Phase A appenders
  , appendObjects
  , appendProcedures
  , appendDwObjects
  , appendDwControls
  , appendDwRetrieveTables
  , appendLocalVars
  , appendCallSites
  , appendGlobalVars
  , appendProcDefs
  , appendProcUses
  , appendSqlStmts
  , appendParseErrors
  , appendSourceFiles
  -- Phase B queries
  , queryLocalVars
  , queryCallSites
  , queryGlobalVars
  , queryObjInfo
  , queryProcDefs
  , queryProcUses
  , queryResolvedCalls
  , queryTaintInputs
  , queryProcInfos
  , queryDwObjectSet
  -- Phase B appenders
  , appendResolvedTypes
  , appendResolvedCalls
  , appendInterprocEdges
  , appendProcSummaries
  , appendTaintSources
  , appendTaintSinks
  , appendTaintPaths
  , appendTaintAnnotations
  , appendDeadCode
  ) where

import PB.Prelude
import PB.AST.Type             (parseTypeText)
import PB.Analysis.TypeResolve
  ( LocalVar (..), CallSite (..), GlobalVar (..)
  , ResolvedType (..), ResolvedCall (..)
  )
import PB.Analysis.Dataflow    qualified as Dataflow
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.DeadCode    qualified as DeadCode
import PB.Pipeline.Serialise   ()

import Database.DuckDB.Simple
  (Connection, Query, execute_, withConnection, query_)
import Database.DuckDB.Simple.Internal (withConnectionHandle)
import Database.DuckDB.Simple.FromRow  (FromRow (..), field)
import Database.DuckDB.FFI
  ( c_duckdb_appender_create
  , c_duckdb_appender_flush
  , c_duckdb_appender_destroy
  , c_duckdb_appender_end_row
  , c_duckdb_append_varchar
  , c_duckdb_append_int32
  , c_duckdb_append_bool
  , c_duckdb_append_null
  , DuckDBConnection
  , DuckDBAppender
  , DuckDBState (..)
  )

import Data.Aeson               (ToJSON, encode)
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Lazy    as BSL
import qualified Data.Map.Strict         as Map
import qualified Data.Set                as Set
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as TE
import           Control.Exception       (bracket)
import           Data.Int                (Int32)
import           Foreign                 (alloca, nullPtr, peek)
import           Foreign.C.Types         (CBool (..))

-- ---------------------------------------------------------------------------
-- Public connection helpers

type DuckConn = Connection

withWriteConn :: FilePath -> (DuckConn -> IO a) -> IO a
withWriteConn = withConnection

-- ---------------------------------------------------------------------------
-- Schema

initSchema :: DuckConn -> IO ()
initSchema conn = mapM_ (void . execute_ conn) allTables
  where
    allTables :: [Query]
    allTables =
      [ "CREATE TABLE IF NOT EXISTS objects \
        \(file TEXT, kind TEXT, object TEXT, ancestor TEXT, layout_json TEXT, \
        \type_blocks_json TEXT, confidence TEXT NOT NULL DEFAULT 'confirmed')"
      , "CREATE TABLE IF NOT EXISTS procedures \
        \(file TEXT, object TEXT, proc_name TEXT, proc_type TEXT, \
        \start_line INTEGER, end_line INTEGER, \
        \cfg_json TEXT, cps_graph_json TEXT, \
        \params TEXT, return_type TEXT, cyclomatic INTEGER, \
        \confidence TEXT NOT NULL DEFAULT 'confirmed')"
      , "CREATE TABLE IF NOT EXISTS local_vars \
        \(file TEXT, object TEXT, proc_name TEXT, \
        \var_name TEXT, raw_type TEXT, is_param BOOLEAN, scope_line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS call_sites \
        \(file TEXT, object TEXT, from_proc TEXT, \
        \to_name TEXT, call_type TEXT, line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS global_vars \
        \(file TEXT, object TEXT, var_name TEXT, var_type TEXT, mods TEXT)"
      , "CREATE TABLE IF NOT EXISTS proc_defs \
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \block_id TEXT, stmt_index INTEGER, line INTEGER, kind TEXT)"
      , "CREATE TABLE IF NOT EXISTS proc_uses \
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \block_id TEXT, stmt_index INTEGER, line INTEGER, kind TEXT)"
      , "CREATE TABLE IF NOT EXISTS sql_statements \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \operation TEXT, tables TEXT, columns TEXT, raw_sql TEXT, parse_ok BOOLEAN)"
      , "CREATE TABLE IF NOT EXISTS dw_objects \
        \(file TEXT, object TEXT, style TEXT, layout_json TEXT, retrieve_sql TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_retrieve_tables \
        \(file TEXT, dw_name TEXT, table_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_controls \
        \(file TEXT, object TEXT, band TEXT, control_type TEXT, name TEXT, \
        \x INTEGER, y INTEGER, width INTEGER, height INTEGER, expression TEXT)"
      , "CREATE TABLE IF NOT EXISTS parse_errors \
        \(file TEXT, error TEXT)"
      , "CREATE TABLE IF NOT EXISTS source_files \
        \(file TEXT PRIMARY KEY, lines TEXT)"
      -- Phase B tables
      , "CREATE TABLE IF NOT EXISTS resolved_types \
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \raw_type TEXT, kind TEXT, target TEXT, is_param BOOLEAN, scope_line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS resolved_calls \
        \(file TEXT, object TEXT, from_proc TEXT, to_name TEXT, \
        \call_type TEXT, line INTEGER, \
        \target_object TEXT, target_proc TEXT, kind TEXT, confidence TEXT)"
      , "CREATE TABLE IF NOT EXISTS interproc_edges \
        \(caller_object TEXT, caller_proc TEXT, caller_line INTEGER, \
        \callee_object TEXT, callee_proc TEXT, \
        \edge_kind TEXT, var_name TEXT, \
        \caller_context TEXT, callee_context TEXT)"
      , "CREATE TABLE IF NOT EXISTS procedure_summaries \
        \(file TEXT, object TEXT, proc_name TEXT, \
        \params_in TEXT, globals_read TEXT, globals_written TEXT, return_flows_to TEXT)"
      , "CREATE TABLE IF NOT EXISTS taint_sources \
        \(file TEXT, object TEXT, proc_name TEXT, \
        \var_name TEXT, source_type TEXT, line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS taint_sinks \
        \(file TEXT, object TEXT, proc_name TEXT, \
        \var_name TEXT, sink_type TEXT, severity TEXT, line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS taint_paths \
        \(source_file TEXT, source_object TEXT, source_proc TEXT, source_var TEXT, \
        \sink_file TEXT, sink_object TEXT, sink_proc TEXT, sink_var TEXT, \
        \severity TEXT, category TEXT, steps_json TEXT)"
      , "CREATE TABLE IF NOT EXISTS taint_annotations \
        \(file TEXT, object TEXT, proc_name TEXT, block_id TEXT, \
        \is_taint_entry BOOLEAN, is_taint_sink BOOLEAN, tainted_vars TEXT)"
      , "CREATE TABLE IF NOT EXISTS dead_code \
        \(object TEXT, proc_name TEXT, proc_type TEXT, cyclomatic INTEGER, \
        \confidence TEXT, caller_count_naive INTEGER, caller_count_scoped INTEGER)"
      , "CREATE OR REPLACE VIEW all_sql_tables AS \
        \SELECT file, dw_name AS object, 'datawindow' AS source, \
        \'retrieve' AS operation, table_name, NULL AS proc_name, NULL::INT AS line \
        \FROM dw_retrieve_tables \
        \UNION ALL \
        \SELECT s.file, s.object, 'powerscript' AS source, s.operation, \
        \TRIM(t) AS table_name, s.proc_name, s.line \
        \FROM sql_statements s, \
        \unnest(string_split(s.tables, ',')) t(t) \
        \WHERE s.tables IS NOT NULL AND s.tables != ''"
      ]

-- ---------------------------------------------------------------------------
-- Row types

data ObjectRow = ObjectRow
  { orFile           :: Text
  , orKind           :: Text
  , orObject         :: Text
  , orAncestor       :: Maybe Text
  , orLayoutJson     :: Maybe Text
  , orTypeBlocksJson :: Maybe Text
  , orConfidence     :: Text
  }

data ProcRow = ProcRow
  { prFile       :: Text
  , prObject     :: Text
  , prProcName   :: Text
  , prProcType   :: Text
  , prStartLine  :: Int
  , prEndLine    :: Int
  , prCfgJson    :: Text
  , prCpsJson    :: Text
  , prParams     :: Text
  , prReturnType :: Text
  , prCyclomatic :: Maybe Int
  , prConfidence :: Text
  }

data DwObjectRow = DwObjectRow
  { dorFile        :: Text
  , dorObject      :: Text
  , dorStyle       :: Text
  , dorLayoutJson  :: Text
  , dorRetrieveSql :: Maybe Text
  }

data DwControlRow = DwControlRow
  { dcrFile        :: Text
  , dcrObject      :: Text
  , dcrBand        :: Text
  , dcrControlType :: Text
  , dcrName        :: Text
  , dcrX           :: Maybe Int
  , dcrY           :: Maybe Int
  , dcrWidth       :: Maybe Int
  , dcrHeight      :: Maybe Int
  , dcrExpression  :: Maybe Text
  }

data DwRetrieveTableRow = DwRetrieveTableRow
  { drtrFile      :: Text
  , drtrDwName    :: Text
  , drtrTableName :: Text
  }

data SqlStmtRow = SqlStmtRow
  { ssrFile      :: Text
  , ssrObject    :: Text
  , ssrProcName  :: Text
  , ssrLine      :: Int
  , ssrOperation :: Maybe Text
  , ssrTables    :: Text
  , ssrColumns   :: Text
  , ssrRawSql    :: Text
  , ssrParseOk   :: Bool
  }

data SourceFileRow = SourceFileRow
  { sfrFile :: Text
  , sfrLines :: Text
  }

-- ---------------------------------------------------------------------------
-- Phase A appenders

appendObjects :: DuckConn -> [ObjectRow] -> IO ()
appendObjects _    [] = pure ()
appendObjects conn rows = withRaw conn "objects" $ \app ->
  for_ rows $ \r -> do
    aText      app (orFile           r)
    aText      app (orKind           r)
    aText      app (orObject         r)
    aMaybeText app (orAncestor       r)
    aMaybeText app (orLayoutJson     r)
    aMaybeText app (orTypeBlocksJson r)
    aText      app (orConfidence     r)
    endRow app

appendProcedures :: DuckConn -> [ProcRow] -> IO ()
appendProcedures _    [] = pure ()
appendProcedures conn rows = withRaw conn "procedures" $ \app ->
  for_ rows $ \r -> do
    aText     app (prFile       r)
    aText     app (prObject     r)
    aText     app (prProcName   r)
    aText     app (prProcType   r)
    aInt      app (prStartLine  r)
    aInt      app (prEndLine    r)
    aText     app (prCfgJson    r)
    aText     app (prCpsJson    r)
    aText     app (prParams     r)
    aText     app (prReturnType r)
    aMaybeInt app (prCyclomatic r)
    aText     app (prConfidence r)
    endRow app

appendDwObjects :: DuckConn -> [DwObjectRow] -> IO ()
appendDwObjects _    [] = pure ()
appendDwObjects conn rows = withRaw conn "dw_objects" $ \app ->
  for_ rows $ \r -> do
    aText     app (dorFile        r)
    aText     app (dorObject      r)
    aText     app (dorStyle       r)
    aText     app (dorLayoutJson  r)
    aMaybeText app (dorRetrieveSql r)
    endRow app

appendDwControls :: DuckConn -> [DwControlRow] -> IO ()
appendDwControls _    [] = pure ()
appendDwControls conn rows = withRaw conn "dw_controls" $ \app ->
  for_ rows $ \r -> do
    aText      app (dcrFile r)
    aText      app (dcrObject r)
    aText      app (dcrBand r)
    aText      app (dcrControlType r)
    aText      app (dcrName r)
    aMaybeInt  app (dcrX r)
    aMaybeInt  app (dcrY r)
    aMaybeInt  app (dcrWidth r)
    aMaybeInt  app (dcrHeight r)
    aMaybeText app (dcrExpression r)
    endRow app

appendDwRetrieveTables :: DuckConn -> [DwRetrieveTableRow] -> IO ()
appendDwRetrieveTables _    [] = pure ()
appendDwRetrieveTables conn rows = withRaw conn "dw_retrieve_tables" $ \app ->
  for_ rows $ \r -> do
    aText app (drtrFile r)
    aText app (drtrDwName r)
    aText app (drtrTableName r)
    endRow app

appendLocalVars :: DuckConn -> [LocalVar] -> IO ()
appendLocalVars _    [] = pure ()
appendLocalVars conn lvs = withRaw conn "local_vars" $ \app ->
  for_ lvs $ \lv -> do
    aText app (lvFile lv)
    aText app (lvObject lv)
    aText app (lvProcName lv)
    aText app (lvVarName lv)
    aText app (lvRawType lv)
    aBool app (lvIsParam lv)
    aInt  app (lvScopeLine lv)
    endRow app

appendCallSites :: DuckConn -> [CallSite] -> IO ()
appendCallSites _    [] = pure ()
appendCallSites conn css = withRaw conn "call_sites" $ \app ->
  for_ css $ \cs -> do
    aText     app (csFile cs)
    aText     app (csObject cs)
    aText     app (csFromProc cs)
    aText     app (csToName cs)
    aText     app (csCallType cs)
    aMaybeInt app (csLine cs)
    endRow app

appendGlobalVars :: DuckConn -> [GlobalVar] -> IO ()
appendGlobalVars _    [] = pure ()
appendGlobalVars conn gvs = withRaw conn "global_vars" $ \app ->
  for_ gvs $ \gv -> do
    aText app (gvFile gv)
    aText app (gvObject gv)
    aText app (gvName gv)
    aText app (gvType gv)
    aText app (T.intercalate "|" (gvMods gv))
    endRow app

appendProcDefs :: DuckConn -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
appendProcDefs _    [] = pure ()
appendProcDefs conn flows = withRaw conn "proc_defs" $ \app ->
  for_ flows $ \(file, obj, proc_, pf) ->
    for_ (concatMap Dataflow.bfDefs (Map.elems (Dataflow.pfBlocks pf))) $ \d -> do
      aText     app file
      aText     app obj
      aText     app proc_
      aText     app (Dataflow.dsVar d)
      aText     app (Dataflow.dsBlock d)
      aInt      app (Dataflow.dsStmtIdx d)
      aMaybeInt app (Dataflow.dsLine d)
      aText     app (Dataflow.dsKind d)
      endRow app

appendProcUses :: DuckConn -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
appendProcUses _    [] = pure ()
appendProcUses conn flows = withRaw conn "proc_uses" $ \app ->
  for_ flows $ \(file, obj, proc_, pf) ->
    for_ (concatMap Dataflow.bfUses (Map.elems (Dataflow.pfBlocks pf))) $ \u -> do
      aText     app file
      aText     app obj
      aText     app proc_
      aText     app (Dataflow.usVar u)
      aText     app (Dataflow.usBlock u)
      aInt      app (Dataflow.usStmtIdx u)
      aMaybeInt app (Dataflow.usLine u)
      aText     app (Dataflow.usKind u)
      endRow app

appendSqlStmts :: DuckConn -> [SqlStmtRow] -> IO ()
appendSqlStmts _    [] = pure ()
appendSqlStmts conn rows = withRaw conn "sql_statements" $ \app ->
  for_ rows $ \r -> do
    aText      app (ssrFile r)
    aText      app (ssrObject r)
    aText      app (ssrProcName r)
    aInt       app (ssrLine r)
    aMaybeText app (ssrOperation r)
    aText      app (ssrTables r)
    aText      app (ssrColumns r)
    aText      app (ssrRawSql r)
    aBool      app (ssrParseOk r)
    endRow app

appendParseErrors :: DuckConn -> [(FilePath, Text)] -> IO ()
appendParseErrors _    [] = pure ()
appendParseErrors conn errs = withRaw conn "parse_errors" $ \app ->
  for_ errs $ \(path, msg) -> do
    aText app (T.pack path)
    aText app msg
    endRow app

appendSourceFiles :: DuckConn -> [SourceFileRow] -> IO ()
appendSourceFiles _    [] = pure ()
appendSourceFiles conn rows = withRaw conn "source_files" $ \app ->
  for_ rows $ \r -> do
    aText app (sfrFile r)
    aText app (sfrLines r)
    endRow app

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

instance FromRow DeadCode.ProcInfo where
  fromRow = DeadCode.ProcInfo <$> field <*> field <*> field <*> field

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

queryLocalVars :: DuckConn -> IO [LocalVar]
queryLocalVars conn = query_ conn
  "SELECT file, object, proc_name, var_name, raw_type, is_param, scope_line \
  \FROM local_vars"

queryCallSites :: DuckConn -> IO [CallSite]
queryCallSites conn = query_ conn
  "SELECT file, object, from_proc, to_name, call_type, line FROM call_sites"

queryGlobalVars :: DuckConn -> IO [GlobalVar]
queryGlobalVars conn = query_ conn
  "SELECT file, object, var_name, var_type, mods FROM global_vars"

-- | Build the four workspace-wide maps needed by Pass 5 from the DB.
queryObjInfo
  :: DuckConn
  -> IO (Set.Set Text, Set.Set Text, Map.Map Text Text, Map.Map Text (Set.Set Text))
queryObjInfo conn = do
  objRows  <- query_ conn
    "SELECT object FROM objects \
    \WHERE LOWER(COALESCE(ancestor,'')) != 'structure'" :: IO [OneText]
  usrRows  <- query_ conn
    "SELECT object FROM objects WHERE LOWER(ancestor) = 'structure'" :: IO [OneText]
  inhRows  <- query_ conn
    "SELECT object, ancestor FROM objects WHERE ancestor IS NOT NULL" :: IO [TwoText]
  procRows <- query_ conn
    "SELECT object, proc_name FROM procedures" :: IO [TwoText]
  pure
    ( Set.fromList [t | OneText t <- objRows]
    , Set.fromList [t | OneText t <- usrRows]
    , Map.fromList [(o, a) | TwoText o a <- inhRows]
    , Map.fromListWith Set.union
        [(o, Set.singleton p) | TwoText o p <- procRows]
    )

queryProcDefs :: DuckConn -> IO [Taint.DefRow]
queryProcDefs conn = query_ conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind \
  \FROM proc_defs"

queryProcUses :: DuckConn -> IO [Taint.UseRow]
queryProcUses conn = query_ conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind \
  \FROM proc_uses"

queryResolvedCalls :: DuckConn -> IO [Taint.ResolvedCallRow]
queryResolvedCalls conn = query_ conn
  "SELECT file, object, from_proc, to_name, call_type, line, \
  \target_object, target_proc, kind, confidence FROM resolved_calls"

-- | Reconstruct per-file TaintFileInputs from the sql_statements and
-- procedures tables.  SqlStmt values are re-derived from raw_sql using
-- the same classifyOperation / hasIntoClause logic as extractTaintInputs.
queryTaintInputs :: DuckConn -> IO [Taint.TaintFileInputs]
queryTaintInputs conn = do
  sqlRows  <- query_ conn
    "SELECT file, object, proc_name, line, raw_sql FROM sql_statements"
  metaRows <- query_ conn
    "SELECT file, object, proc_name, proc_type, params, return_type FROM procedures"
  objRows  <- query_ conn
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

queryProcInfos :: DuckConn -> IO [DeadCode.ProcInfo]
queryProcInfos conn = query_ conn
  "SELECT object, proc_name, proc_type, cyclomatic FROM procedures WHERE confidence != 'speculative'"

queryDwObjectSet :: DuckConn -> IO (Set.Set Text)
queryDwObjectSet conn = do
  rows <- query_ conn "SELECT DISTINCT object FROM dw_objects" :: IO [OneText]
  pure (Set.fromList [t | OneText t <- rows])

-- ---------------------------------------------------------------------------
-- Phase B appenders

appendResolvedTypes :: DuckConn -> [ResolvedType] -> IO ()
appendResolvedTypes _    [] = pure ()
appendResolvedTypes conn rows = withRaw conn "resolved_types" $ \app ->
  for_ rows $ \r -> do
    aText      app (rtFile      r)
    aText      app (rtObject    r)
    aText      app (rtProcName  r)
    aText      app (rtVarName   r)
    aText      app (rtRawType   r)
    aText      app (rtKind      r)
    aMaybeText app (rtTarget    r)
    aBool      app (rtIsParam   r)
    aInt       app (rtScopeLine r)
    endRow app

appendResolvedCalls :: DuckConn -> [ResolvedCall] -> IO ()
appendResolvedCalls _    [] = pure ()
appendResolvedCalls conn rows = withRaw conn "resolved_calls" $ \app ->
  for_ rows $ \r -> do
    aText      app (rcFile         r)
    aText      app (rcObject       r)
    aText      app (rcFromProc     r)
    aText      app (rcToName       r)
    aText      app (rcCallType     r)
    aMaybeInt  app (rcLine         r)
    aMaybeText app (rcTargetObject r)
    aMaybeText app (rcTargetProc   r)
    aText      app (rcKind         r)
    aText      app (rcConfidence   r)
    endRow app

appendInterprocEdges :: DuckConn -> [Taint.InterprocEdge] -> IO ()
appendInterprocEdges _    [] = pure ()
appendInterprocEdges conn rows = withRaw conn "interproc_edges" $ \app ->
  for_ rows $ \e -> do
    aText     app (Taint.ieCallerObject  e)
    aText     app (Taint.ieCallerProc    e)
    aMaybeInt app (Taint.ieCallerLine    e)
    aText     app (Taint.ieCalleeObject  e)
    aText     app (Taint.ieCalleeProc    e)
    aText     app (Taint.ieEdgeKind      e)
    aText     app (Taint.ieVarName       e)
    aText     app (Taint.ieCallerContext e)
    aText     app (Taint.ieCalleeContext e)
    endRow app

appendProcSummaries :: DuckConn -> [Taint.ProcedureSummary] -> IO ()
appendProcSummaries _    [] = pure ()
appendProcSummaries conn rows = withRaw conn "procedure_summaries" $ \app ->
  for_ rows $ \s -> do
    aText app (Taint.psFile              s)
    aText app (Taint.psObject            s)
    aText app (Taint.psProcName          s)
    aText app (jsonList (Taint.psParamsIn       s))
    aText app (jsonList (Taint.psGlobalsRead    s))
    aText app (jsonList (Taint.psGlobalsWritten s))
    aText app (jsonList (Taint.psReturnFlowsTo  s))
    endRow app

appendTaintSources :: DuckConn -> [Taint.TaintSource] -> IO ()
appendTaintSources _    [] = pure ()
appendTaintSources conn rows = withRaw conn "taint_sources" $ \app ->
  for_ rows $ \s -> do
    aText     app (Taint.tsFile       s)
    aText     app (Taint.tsObject     s)
    aText     app (Taint.tsProcName   s)
    aText     app (Taint.tsVarName    s)
    aText     app (Taint.tsSourceType s)
    aMaybeInt app (Taint.tsLine       s)
    endRow app

appendTaintSinks :: DuckConn -> [Taint.TaintSink] -> IO ()
appendTaintSinks _    [] = pure ()
appendTaintSinks conn rows = withRaw conn "taint_sinks" $ \app ->
  for_ rows $ \s -> do
    aText     app (Taint.tskFile     s)
    aText     app (Taint.tskObject   s)
    aText     app (Taint.tskProcName s)
    aText     app (Taint.tskVarName  s)
    aText     app (Taint.tskSinkType s)
    aText     app (Taint.tskSeverity s)
    aMaybeInt app (Taint.tskLine     s)
    endRow app

appendTaintPaths :: DuckConn -> [Taint.TaintPath] -> IO ()
appendTaintPaths _    [] = pure ()
appendTaintPaths conn rows = withRaw conn "taint_paths" $ \app ->
  for_ rows $ \tp -> do
    let src = Taint.tpSource tp
        snk = Taint.tpSink   tp
        stepsJson = TE.decodeUtf8 . BSL.toStrict . encode $ Taint.tpSteps tp
    aText app (Taint.tsFile      src)
    aText app (Taint.tsObject    src)
    aText app (Taint.tsProcName  src)
    aText app (Taint.tsVarName   src)
    aText app (Taint.tskFile     snk)
    aText app (Taint.tskObject   snk)
    aText app (Taint.tskProcName snk)
    aText app (Taint.tskVarName  snk)
    aText app (Taint.tpSeverity  tp)
    aText app (Taint.tpCategory  tp)
    aText app stepsJson
    endRow app

appendTaintAnnotations :: DuckConn -> [Taint.TaintAnnotation] -> IO ()
appendTaintAnnotations _    [] = pure ()
appendTaintAnnotations conn rows = withRaw conn "taint_annotations" $ \app ->
  for_ rows $ \a -> do
    aText app (Taint.taFile         a)
    aText app (Taint.taObject       a)
    aText app (Taint.taProcName     a)
    aText app (Taint.taBlockId      a)
    aBool app (Taint.taIsTaintEntry a)
    aBool app (Taint.taIsTaintSink  a)
    aText app (T.intercalate "|" (Taint.taTaintedVars a))
    endRow app

appendDeadCode :: DuckConn -> [DeadCode.DeadProcedure] -> IO ()
appendDeadCode _    [] = pure ()
appendDeadCode conn rows = withRaw conn "dead_code" $ \app ->
  for_ rows $ \d -> do
    aText     app (DeadCode.dpObject          d)
    aText     app (DeadCode.dpName            d)
    aText     app (DeadCode.dpProcType        d)
    aMaybeInt app (DeadCode.dpCyclomatic      d)
    aText     app (DeadCode.dpConfidence      d)
    aInt      app (DeadCode.dpCallerCountNaive  d)
    aInt      app (DeadCode.dpCallerCountScoped d)
    endRow app

-- ---------------------------------------------------------------------------
-- Internal helpers

jsonList :: ToJSON a => [a] -> Text
jsonList = TE.decodeUtf8 . BSL.toStrict . encode

withRaw :: DuckConn -> Text -> (DuckDBAppender -> IO ()) -> IO ()
withRaw conn tbl action =
  withConnectionHandle conn $ \rawConn ->
    withAppender rawConn tbl action

withAppender :: DuckDBConnection -> Text -> (DuckDBAppender -> IO a) -> IO a
withAppender rawConn tbl action =
  alloca $ \appPtr -> do
    checkSt "appender_create" =<<
      BS.useAsCString (TE.encodeUtf8 tbl) (\t ->
        c_duckdb_appender_create rawConn nullPtr t appPtr)
    bracket
      (peek appPtr)
      (\_ -> void $ c_duckdb_appender_destroy appPtr)
      $ \app -> do
          result <- action app
          checkSt "appender_flush" =<< c_duckdb_appender_flush app
          pure result

aText :: DuckDBAppender -> Text -> IO ()
aText app t =
  checkSt "append_varchar" =<<
    BS.useAsCString (TE.encodeUtf8 t) (c_duckdb_append_varchar app)

aMaybeText :: DuckDBAppender -> Maybe Text -> IO ()
aMaybeText app Nothing  = checkSt "append_null" =<< c_duckdb_append_null app
aMaybeText app (Just t) = aText app t

aInt :: DuckDBAppender -> Int -> IO ()
aInt app n =
  checkSt "append_int32" =<< c_duckdb_append_int32 app (fromIntegral n :: Int32)

aMaybeInt :: DuckDBAppender -> Maybe Int -> IO ()
aMaybeInt app Nothing  = checkSt "append_null" =<< c_duckdb_append_null app
aMaybeInt app (Just n) = aInt app n

aBool :: DuckDBAppender -> Bool -> IO ()
aBool app b =
  checkSt "append_bool" =<< c_duckdb_append_bool app (if b then CBool 1 else CBool 0)

endRow :: DuckDBAppender -> IO ()
endRow app = checkSt "appender_end_row" =<< c_duckdb_appender_end_row app

checkSt :: String -> DuckDBState -> IO ()
checkSt ctx (DuckDBState n)
  | n == 0    = pure ()
  | otherwise = error $ "DuckDB appender error in " <> ctx
