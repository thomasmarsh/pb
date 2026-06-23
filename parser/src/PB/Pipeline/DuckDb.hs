module PB.Pipeline.DuckDb
  ( DuckConn
  , withWriteConn
  , initSchema
  -- Row types
  , ObjectRow (..)
  , ProcRow (..)
  , DwObjectRow (..)
  , DwControlRow (..)
  , SqlStmtRow (..)
  -- Phase A appenders
  , appendObjects
  , appendProcedures
  , appendDwObjects
  , appendDwControls
  , appendLocalVars
  , appendCallSites
  , appendGlobalVars
  , appendProcDefs
  , appendProcUses
  , appendSqlStmts
  , appendParseErrors
  ) where

import PB.Prelude
import PB.Pipeline.TypeResolve (LocalVar (..), CallSite (..), GlobalVar (..))
import PB.Pipeline.Dataflow    qualified as Dataflow

import Database.DuckDB.Simple          (Connection, Query, execute_, withConnection)
import Database.DuckDB.Simple.Internal (withConnectionHandle)
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

import qualified Data.ByteString         as BS
import qualified Data.Map.Strict         as Map
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
initSchema conn = mapM_ (void . execute_ conn) phaseATables
  where
    phaseATables :: [Query]
    phaseATables =
      [ "CREATE TABLE IF NOT EXISTS objects \
        \(file TEXT, kind TEXT, object TEXT, ancestor TEXT)"
      , "CREATE TABLE IF NOT EXISTS procedures \
        \(file TEXT, object TEXT, proc_name TEXT, proc_type TEXT, \
        \start_line INTEGER, end_line INTEGER, \
        \cfg_json TEXT, cps_graph_json TEXT)"
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
        \(file TEXT, object TEXT, style TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_controls \
        \(file TEXT, object TEXT, band TEXT, control_type TEXT, name TEXT, \
        \x INTEGER, y INTEGER, width INTEGER, height INTEGER, expression TEXT)"
      , "CREATE TABLE IF NOT EXISTS parse_errors \
        \(file TEXT, error TEXT)"
      -- Phase B stubs (schema only, no appenders this session)
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
        \severity TEXT, category TEXT)"
      , "CREATE TABLE IF NOT EXISTS taint_annotations \
        \(file TEXT, object TEXT, proc_name TEXT, block_id TEXT, \
        \is_taint_entry BOOLEAN, is_taint_sink BOOLEAN, tainted_vars TEXT)"
      , "CREATE TABLE IF NOT EXISTS dead_code \
        \(object TEXT, proc_name TEXT, proc_type TEXT)"
      ]

-- ---------------------------------------------------------------------------
-- Row types

data ObjectRow = ObjectRow
  { orFile     :: Text
  , orKind     :: Text
  , orObject   :: Text
  , orAncestor :: Maybe Text
  }

data ProcRow = ProcRow
  { prFile      :: Text
  , prObject    :: Text
  , prProcName  :: Text
  , prProcType  :: Text
  , prStartLine :: Int
  , prEndLine   :: Int
  , prCfgJson   :: Text
  , prCpsJson   :: Text
  }

data DwObjectRow = DwObjectRow
  { dorFile   :: Text
  , dorObject :: Text
  , dorStyle  :: Text
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

-- ---------------------------------------------------------------------------
-- Phase A appenders

appendObjects :: DuckConn -> [ObjectRow] -> IO ()
appendObjects _    [] = pure ()
appendObjects conn rows = withRaw conn "objects" $ \app ->
  for_ rows $ \r -> do
    aText app (orFile r)
    aText app (orKind r)
    aText app (orObject r)
    aMaybeText app (orAncestor r)
    endRow app

appendProcedures :: DuckConn -> [ProcRow] -> IO ()
appendProcedures _    [] = pure ()
appendProcedures conn rows = withRaw conn "procedures" $ \app ->
  for_ rows $ \r -> do
    aText app (prFile r)
    aText app (prObject r)
    aText app (prProcName r)
    aText app (prProcType r)
    aInt  app (prStartLine r)
    aInt  app (prEndLine r)
    aText app (prCfgJson r)
    aText app (prCpsJson r)
    endRow app

appendDwObjects :: DuckConn -> [DwObjectRow] -> IO ()
appendDwObjects _    [] = pure ()
appendDwObjects conn rows = withRaw conn "dw_objects" $ \app ->
  for_ rows $ \r -> do
    aText app (dorFile r)
    aText app (dorObject r)
    aText app (dorStyle r)
    endRow app

appendDwControls :: DuckConn -> [DwControlRow] -> IO ()
appendDwControls _    [] = pure ()
appendDwControls conn rows = withRaw conn "dw_controls" $ \app ->
  for_ rows $ \r -> do
    aText     app (dcrFile r)
    aText     app (dcrObject r)
    aText     app (dcrBand r)
    aText     app (dcrControlType r)
    aText     app (dcrName r)
    aMaybeInt app (dcrX r)
    aMaybeInt app (dcrY r)
    aMaybeInt app (dcrWidth r)
    aMaybeInt app (dcrHeight r)
    aMaybeText app (dcrExpression r)
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

-- ---------------------------------------------------------------------------
-- Internal: appender lifecycle

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

-- ---------------------------------------------------------------------------
-- Internal: per-column append helpers

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
