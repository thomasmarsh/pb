module PB.Pipeline.DuckDb
  ( Handle
  , Config(..)
  , inMemory
  , new
  , close
  , withHandle
  , queryHandle
  , executeHandle
  , withHandleConnection
  , initSchema
  -- Generic input/derived relation bridge (dynamic-arity TEXT relations)
  , queryTextRows
  , recreateTextTable
  , appendTextRows
  -- Internal helpers shared by the DuckDb.* submodules
  , jsonList
  , withRaw
  , aText
  , aMaybeText
  , aInt
  , aMaybeInt
  , aMaybeSpan
  , aBool
  , checkSt
  , checkAppenderSt
  ) where

import PB.Prelude

import Database.DuckDB.Simple
  (Connection, Query (..), execute_, query_)
import qualified Database.DuckDB.Simple as DDB
import Database.DuckDB.Simple.Internal (withConnectionHandle)
import Database.DuckDB.Simple.FromRow  (FromRow (..), numFieldsRemaining, field)
import Database.DuckDB.FFI
  ( c_duckdb_appender_create
  , c_duckdb_appender_destroy
  , c_duckdb_appender_flush
  , c_duckdb_appender_end_row
  , c_duckdb_appender_error_data
  , c_duckdb_error_data_message
  , c_duckdb_destroy_error_data
  , c_duckdb_append_varchar
  , c_duckdb_append_int32
  , c_duckdb_append_bool
  , c_duckdb_append_null
  , DuckDBConnection
  , DuckDBAppender
  , DuckDBState (..)
  )

import Data.Aeson               (ToJSON, encode)
import PB.Lexing.Token          (SourceSpan (..))
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Lazy    as BSL
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as TE
import           Control.Exception       (bracket, bracket_)
import           Data.Int                (Int32)
import           Foreign                 (alloca, nullPtr, peek, poke)
import           Foreign.C.Types         (CBool (..))
import           Foreign.C.String        (peekCString)

-- ---------------------------------------------------------------------------
-- Connection handle (Plan 184: opaque moat)

-- | Opaque DuckDB connection handle. The constructor is not exported, so no
-- caller outside this module can name or construct a raw 'Connection' — the
-- DuckDb moat is enforced by construction rather than by module layout.
newtype Handle = Handle { hConn :: Connection }

-- | Where to open the database: a file path, or @":memory:"@ for an
-- in-process database.
data Config = Config { cfgDbPath :: FilePath }

-- | Convenience 'Config' for an in-memory database.
inMemory :: Config
inMemory = Config ":memory:"

-- | Open a connection for the given 'Config'. Pair with 'close', or use
-- 'withHandle' for exception-safe lifecycle management.
new :: Config -> IO Handle
new cfg = Handle <$> DDB.open (cfgDbPath cfg)

-- | Close a connection opened by 'new'.
close :: Handle -> IO ()
close (Handle c) = DDB.close c

-- | Exception-safe connection lifecycle: opens, runs the action, and closes
-- even on exception (via 'bracket').
withHandle :: Config -> (Handle -> IO a) -> IO a
withHandle cfg = bracket (new cfg) close

-- | Run a query against a 'Handle', unwrapping the opaque 'Connection'. This
-- is the only way non-'DuckDb' code may issue raw SQL — the 'Connection' is
-- never exposed, so the moat holds by construction (Plan 184).
queryHandle :: FromRow r => Handle -> Query -> IO [r]
queryHandle h q = query_ (hConn h) q

-- | Run a statement against a 'Handle', unwrapping the opaque 'Connection'
-- (the statement counterpart of 'queryHandle'). Returns the number of rows
-- affected, matching 'execute_'.
executeHandle :: Handle -> Query -> IO Int
executeHandle h q = execute_ (hConn h) q

-- | Hand the raw FFI 'DuckDBConnection' to @action@ for the scope of the
-- callback, without ever exposing 'Handle''s opaque 'Connection' itself —
-- the appender-pool machinery in 'PB.Pipeline.DuckDb.Appender' needs the raw
-- connection for @c_duckdb_appender_create@, but it lives in a sibling
-- module, so it reaches the connection through this scoped accessor rather
-- than through 'hConn' (private to this module, same as 'Connection').
withHandleConnection :: Handle -> (DuckDBConnection -> IO a) -> IO a
withHandleConnection h = withConnectionHandle (hConn h)

-- ---------------------------------------------------------------------------
-- Schema

initSchema :: Handle -> IO ()
initSchema conn = mapM_ (void . execute_ (hConn conn)) allTables
  where
    allTables :: [Query]
    allTables =
      [ "CREATE TABLE IF NOT EXISTS objects \
        \(file TEXT, kind TEXT, object TEXT, ancestor TEXT, layout_json TEXT, \
        \type_blocks_json TEXT, confidence TEXT NOT NULL DEFAULT 'confirmed')"
      -- param_names is a '|'-delimited ordered list of just the declared
      -- parameter names (mirrors global_vars.mods's convention) -- PB
      -- taint\/interproc analysis (Phase B, DB round-trip) only ever needs
      -- positional param names, never their declared types, and this is
      -- losslessly reversible unlike 'params' (a joined display string with
      -- mods/type/name intermixed, re-parsing which is exactly the anti-
      -- pattern Plan 196 Phase 3 removed from every in-memory consumer).
      , "CREATE TABLE IF NOT EXISTS procedures \
        \(file TEXT, object TEXT, proc_name TEXT, proc_type TEXT, \
        \start_line INTEGER, end_line INTEGER, \
        \cfg_json TEXT, instr_graph_json TEXT, wiring_json TEXT, \
        \params TEXT, return_type TEXT, cyclomatic INTEGER, \
        \confidence TEXT NOT NULL DEFAULT 'confirmed', param_names TEXT)"
      -- type_start_line/col, type_end_line/col carry the declared type
      -- name's own token span (additive, nullable -- NULL for a primitive/
      -- any/decimal type, which is a keyword, not an identifier reference).
      , "CREATE TABLE IF NOT EXISTS local_vars \
        \(file TEXT, object TEXT, proc_name TEXT, \
        \var_name TEXT, raw_type TEXT, is_param BOOLEAN, scope_line INTEGER, \
        \type_start_line INTEGER, type_start_col INTEGER, \
        \type_end_line INTEGER, type_end_col INTEGER)"
      -- Plan 195 Phase E.5b: to_name_start_line/col, to_name_end_line/col
      -- carry the callee identifier token's own span, additive alongside
      -- line (the enclosing statement's line, which
      -- PB.Analysis.Taint.buildInterprocEdges matches call sites against
      -- def/use sites by, and so must stay untouched).
      , "CREATE TABLE IF NOT EXISTS call_sites \
        \(file TEXT, object TEXT, proc_name TEXT, \
        \to_name TEXT, call_type TEXT, line INTEGER, receiver_object TEXT, \
        \to_name_start_line INTEGER, to_name_start_col INTEGER, \
        \to_name_end_line INTEGER, to_name_end_col INTEGER)"
      -- The canonical variable/property cross-reference relation
      -- (PB.Analysis.TypeResolve.ResolvedVarRef), parallel to resolved_calls
      -- but fully resolved at extraction time (no later cross-file stage
      -- needed -- see that type's own header comment for why).
      -- name_start_line/col, name_end_line/col carry the referenced
      -- identifier's own span, additive alongside line (the statement's
      -- line).
      , "CREATE TABLE IF NOT EXISTS resolved_var_refs \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \name TEXT, access TEXT, target_object TEXT, kind TEXT, confidence TEXT, \
        \name_start_line INTEGER, name_start_col INTEGER, \
        \name_end_line INTEGER, name_end_col INTEGER, declared_type TEXT)"
      -- type_start_line/col, type_end_line/col carry the declared type
      -- name's own token span, same convention as local_vars above.
      , "CREATE TABLE IF NOT EXISTS global_vars \
        \(file TEXT, object TEXT, var_name TEXT, var_type TEXT, mods TEXT, \
        \type_start_line INTEGER, type_start_col INTEGER, \
        \type_end_line INTEGER, type_end_col INTEGER)"
      -- var_start_line/col, var_end_line/col carry the def/use variable's
      -- own token span, additive alongside line (the statement's line,
      -- which buildInterprocEdges matches on -- see call_sites above).
      , "CREATE TABLE IF NOT EXISTS proc_defs \
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \block_id TEXT, stmt_index INTEGER, line INTEGER, kind TEXT, \
        \var_start_line INTEGER, var_start_col INTEGER, \
        \var_end_line INTEGER, var_end_col INTEGER)"
      , "CREATE TABLE IF NOT EXISTS proc_uses \
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \block_id TEXT, stmt_index INTEGER, line INTEGER, kind TEXT, \
        \var_start_line INTEGER, var_start_col INTEGER, \
        \var_end_line INTEGER, var_end_col INTEGER)"
      , "CREATE TABLE IF NOT EXISTS sql_statements \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \operation TEXT, tables TEXT, columns TEXT, raw_sql TEXT, parse_ok BOOLEAN)"
      , "CREATE TABLE IF NOT EXISTS sql_statement_columns \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \namespace TEXT, table_name TEXT, column_name TEXT, is_write BOOLEAN)"
      , "CREATE TABLE IF NOT EXISTS sql_statement_filters \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \namespace TEXT, table_name TEXT, column_name TEXT, op TEXT, values_json TEXT)"
      -- Plan 163 Phase 3: same shape as sql_statement_columns, populated by
      -- PB.Analysis.SchFootprint's EffTerm -> Sch functor instead of sqlglot
      -- text extraction (today: DataWindow SetItem calls with a literal
      -- column argument and a statically-resolvable control binding -- see
      -- that module's doc comment). Kept as its own table, not merged into
      -- sql_statement_columns, so Phase 4's leg_source column can tag rows
      -- by producer without an extra column on this table.
      , "CREATE TABLE IF NOT EXISTS cat_footprint_columns \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \namespace TEXT, table_name TEXT, column_name TEXT, is_write BOOLEAN)"
      -- Plan 182 Move 2 (2026-07-18): the intra-proc @(useVar, defVar)@
      -- edges 'PB.Analysis.TaintEdges.foldTaintEdgesEff' folds directly
      -- from each procedure's compiled EffTerm, populated in Phase A
      -- (PB.Pipeline.Runner.compileOne, same phase as cat_footprint_columns)
      -- and consumed by PB.Analysis.TaintClosure.buildTaintSuccessors in Phase B.
      , "CREATE TABLE IF NOT EXISTS taint_intra_edges \
        \(object TEXT, proc_name TEXT, use_var TEXT, def_var TEXT)"
      -- Plan 182b (2026-07-18): one row per var used in a procedure's
      -- 'PB.Compile.IR.EReturn' payload, populated in Phase A alongside
      -- taint_intra_edges and consumed by
      -- PB.Analysis.TaintClosure.buildTaintSuccessors in
      -- Phase B -- replaces the old index's prior dependency on proc_uses'
      -- kind='return' rows.
      , "CREATE TABLE IF NOT EXISTS taint_return_rows \
        \(object TEXT, proc_name TEXT, var_name TEXT)"
      -- Plan 157 Phase 4.5: namespace-aware sibling of sql_statements.tables
      -- (comma-joined, no namespace, kept untouched -- see that field's own
      -- consumers). One row per (statement, table) pair, extracted straight
      -- from the statement's table list (not derived from
      -- sql_statement_columns), so a column-less table touch (bare DELETE,
      -- SELECT COUNT(*)) still gets a table-level row.
      , "CREATE TABLE IF NOT EXISTS sql_statement_tables \
        \(file TEXT, object TEXT, proc_name TEXT, line INTEGER, \
        \operation TEXT, namespace TEXT, table_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_objects \
        \(file TEXT, object TEXT, style TEXT, layout_json TEXT, retrieve_sql TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_retrieve_tables \
        \(file TEXT, object TEXT, namespace TEXT, table_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_retrieve_columns \
        \(file TEXT, object TEXT, namespace TEXT, table_name TEXT, column_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_write_columns \
        \(file TEXT, object TEXT, namespace TEXT, table_name TEXT, column_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_where_columns \
        \(file TEXT, object TEXT, namespace TEXT, table_name TEXT, column_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_joins \
        \(file TEXT, object TEXT, left_ref TEXT, op TEXT, right_ref TEXT, \
        \outer1 TEXT, outer2 TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_retrieve_where \
        \(file TEXT, object TEXT, idx INTEGER, exp1 TEXT, op TEXT, exp2 TEXT, logic TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_arguments \
        \(file TEXT, object TEXT, arg_name TEXT, arg_type TEXT, ordinal INTEGER)"
      , "CREATE TABLE IF NOT EXISTS catalog_columns \
        \(namespace TEXT, table_name TEXT, column_name TEXT, ordinal INTEGER)"
      , "CREATE TABLE IF NOT EXISTS catalog_pks \
        \(namespace TEXT, table_name TEXT, column_name TEXT, ordinal INTEGER)"
      , "CREATE TABLE IF NOT EXISTS catalog_fks \
        \(constraint_name TEXT, from_namespace TEXT, from_table TEXT, from_column TEXT, \
        \to_namespace TEXT, to_table TEXT, to_column TEXT, ordinal INTEGER)"
      , "CREATE TABLE IF NOT EXISTS catalog_checks \
        \(constraint_name TEXT, namespace TEXT, table_name TEXT, predicate TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_controls \
        \(file TEXT, object TEXT, band TEXT, control_type TEXT, name TEXT, \
        \x INTEGER, y INTEGER, width INTEGER, height INTEGER, expression TEXT)"
      , "CREATE TABLE IF NOT EXISTS parse_errors \
        \(file TEXT, error TEXT, line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS source_files \
        \(file TEXT PRIMARY KEY, lines TEXT)"
      -- Plan 201 Phase 5a: one row per lexed token whose kind is
      -- identifier-shaped (mirrors PB.Grammar.Body.isSegmentName), the raw
      -- token-level denominator for type-resolution coverage measurement --
      -- a token position here with no matching resolved_var_refs/
      -- resolved_calls span is an identifier that never became a row at all
      -- (invisible to a row-based coverage percentage).
      , "CREATE TABLE IF NOT EXISTS identifier_tokens \
        \(file TEXT, text TEXT, kind TEXT, \
        \start_line INTEGER, start_col INTEGER, end_line INTEGER, end_col INTEGER)"
      -- Phase B tables
      , "CREATE TABLE IF NOT EXISTS resolved_types \
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \raw_type TEXT, kind TEXT, target TEXT, scope TEXT, scope_line INTEGER)"
      -- to_name_start_line/col, to_name_end_line/col carry the callee
      -- identifier token's own span, additive alongside line -- see
      -- call_sites above for why line itself must stay untouched.
      , "CREATE TABLE IF NOT EXISTS resolved_calls \
        \(file TEXT, object TEXT, proc_name TEXT, to_name TEXT, \
        \call_type TEXT, line INTEGER, \
        \target_object TEXT, target_proc TEXT, kind TEXT, confidence TEXT, \
        \to_name_start_line INTEGER, to_name_start_col INTEGER, \
        \to_name_end_line INTEGER, to_name_end_col INTEGER)"
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
        \(file TEXT, object TEXT, proc_name TEXT, var_name TEXT, \
        \target_file TEXT, target_object TEXT, target_proc TEXT, target_var TEXT, \
        \severity TEXT, category TEXT, steps_json TEXT)"
      , "CREATE TABLE IF NOT EXISTS taint_annotations \
        \(file TEXT, object TEXT, proc_name TEXT, block_id TEXT, \
        \is_taint_entry BOOLEAN, is_taint_sink BOOLEAN, tainted_vars TEXT)"
      , "CREATE TABLE IF NOT EXISTS dead_code \
        \(object TEXT, proc_name TEXT, proc_type TEXT, cyclomatic INTEGER, \
        \confidence TEXT, caller_count_naive INTEGER, caller_count_scoped INTEGER)"
      , "CREATE TABLE IF NOT EXISTS dead_vars \
        \(object TEXT, proc_name TEXT, var_name TEXT, line INTEGER, kind TEXT)"
      , "CREATE TABLE IF NOT EXISTS type_mismatches \
        \(object TEXT, proc_name TEXT, line INTEGER, target TEXT, \
        \lhs_type TEXT, rhs_desc TEXT, kind TEXT)"
      , "CREATE TABLE IF NOT EXISTS schema_objects \
        \(object_key TEXT, kind TEXT, namespace TEXT, table_name TEXT, column_name TEXT, \
        \stmt_file TEXT, stmt_object TEXT, stmt_proc TEXT, stmt_line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS schema_morphisms \
        \(from_key TEXT, to_key TEXT, leg_kind TEXT, leg_source TEXT)"
      , "CREATE TABLE IF NOT EXISTS decomposition_coslice \
        \(seed_key TEXT, target_key TEXT, direction TEXT, leg_ordinal INTEGER, \
        \leg_from TEXT, leg_to TEXT, leg_kind TEXT, leg_source TEXT, \
        \seed_kind TEXT, seed_namespace TEXT, seed_table_name TEXT, seed_column_name TEXT, \
        \seed_stmt_file TEXT, seed_stmt_object TEXT, seed_stmt_proc TEXT, seed_stmt_line INTEGER, \
        \target_kind TEXT, target_namespace TEXT, target_table_name TEXT, target_column_name TEXT, \
        \target_stmt_file TEXT, target_stmt_object TEXT, target_stmt_proc TEXT, target_stmt_line INTEGER, \
        \leg_from_kind TEXT, leg_from_namespace TEXT, leg_from_table_name TEXT, leg_from_column_name TEXT, \
        \leg_from_stmt_file TEXT, leg_from_stmt_object TEXT, leg_from_stmt_proc TEXT, leg_from_stmt_line INTEGER, \
        \leg_to_kind TEXT, leg_to_namespace TEXT, leg_to_table_name TEXT, leg_to_column_name TEXT, \
        \leg_to_stmt_file TEXT, leg_to_stmt_object TEXT, leg_to_stmt_proc TEXT, leg_to_stmt_line INTEGER)"
      , "CREATE TABLE IF NOT EXISTS implied_fk \
        \(from_namespace TEXT, from_table TEXT, from_column TEXT, \
        \to_namespace TEXT, to_table TEXT, to_column TEXT)"
      , "CREATE TABLE IF NOT EXISTS column_risk \
        \(namespace TEXT, table_name TEXT, column_name TEXT, downstream_count INTEGER)"
      -- Plan 157 Phase 4.5: reads from the namespace-carrying
      -- dw_retrieve_tables/sql_statement_tables directly -- no more
      -- CSV-split of sql_statements.tables (which has no namespace of its
      -- own; kept as-is for its other consumers).
      , "CREATE OR REPLACE VIEW all_sql_tables AS \
        \SELECT file, object, 'datawindow' AS source, \
        \'retrieve' AS operation, namespace, table_name, NULL AS proc_name, NULL::INT AS line \
        \FROM dw_retrieve_tables \
        \UNION ALL \
        \SELECT file, object, 'powerscript' AS source, operation, \
        \namespace, table_name, proc_name, line \
        \FROM sql_statement_tables"
      ]

-- ---------------------------------------------------------------------------
-- Generic input/derived relation bridge (dynamic-arity TEXT tables)
--
-- The materializers in 'PB.Pipeline.DuckDb.Materialize' need to read/write
-- relations whose column count is a runtime value, not fixed by a Haskell
-- type -- so no per-relation 'FromRow'/appender pair is possible.
-- These three are the dynamic-arity counterparts of the typed
-- query/appender pairs in the Phase A/B submodules, values passed through as
-- TEXT throughout (every input relation this project builds -- keys,
-- kinds, names -- is already string-shaped; a numeric column like 'stmt's
-- 'line' is CAST to VARCHAR at read time since no current rule inspects it
-- other than by equality/wildcard).

-- | A row of arbitrary width, all columns read via their 'FromField' Text
-- instance. Not exported -- only 'queryTextRows' constructs one.
newtype TextRow = TextRow { unTextRow :: [Text] }

instance FromRow TextRow where
  fromRow = TextRow <$> go
    where
      go = do
        n <- numFieldsRemaining
        if n <= 0 then pure [] else (:) <$> field <*> go

-- | Read every row of a table or view as TEXT columns, in the given column
-- order (CAST to VARCHAR at the SQL level, so this works regardless of the
-- underlying column type).
queryTextRows :: Handle -> Text -> [Text] -> IO [[Text]]
queryTextRows conn tblOrView cols = do
  rows <- query_ (hConn conn) (Query sql)
  pure (map unTextRow rows)
  where
    sql = "SELECT " <> T.intercalate ", "
            [ "CAST(" <> c <> " AS VARCHAR)" | c <- cols ]
            <> " FROM " <> tblOrView

-- | (Re)create a table with the given column names, all TEXT, dropping any
-- previous table of that name first -- the write-side counterpart of
-- 'queryTextRows', used to materialize a computed relation's result rows.
recreateTextTable :: Handle -> Text -> [Text] -> IO ()
recreateTextTable conn tbl cols = do
  void $ execute_ (hConn conn) (Query ("DROP TABLE IF EXISTS " <> tbl))
  void $ execute_ (hConn conn) (Query ("CREATE TABLE " <> tbl <> " ("
    <> T.intercalate ", " [ c <> " TEXT" | c <- cols ] <> ")"))

-- | Append rows of uniform (but runtime-known) arity as TEXT columns -- no
-- per-arity 'ToRow' instance needed.
appendTextRows :: Handle -> Text -> [[Text]] -> IO ()
appendTextRows _    _   []   = pure ()
appendTextRows conn tbl rows = withRaw conn tbl $ \app ->
  forEachRowRaw app rows $ \_ r -> for_ r (aText app)

-- ---------------------------------------------------------------------------
-- Internal helpers shared by the DuckDb.* submodules

jsonList :: ToJSON a => [a] -> Text
jsonList = TE.decodeUtf8 . BSL.toStrict . encode

withRaw :: Handle -> Text -> (DuckDBAppender -> IO ()) -> IO ()
withRaw conn tbl action =
  withConnectionHandle (hConn conn) $ \rawConn ->
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
          st <- c_duckdb_appender_flush app
          checkAppenderSt "appender_flush" app st
          pure result

-- | Local row-marshalling loop for 'appendTextRows' only, identical in
-- shape (and exception-safety) to
-- 'PB.Pipeline.DuckDb.Appender.forEachRow'. That shared helper lives in the
-- sibling 'Appender' module, which itself imports this core module for
-- 'checkAppenderSt' -- 'appendTextRows' can't import it back without a
-- module cycle, so this core module keeps its own copy of the same
-- bracketed finalization.
forEachRowRaw :: DuckDBAppender -> [row] -> (DuckDBAppender -> row -> IO ()) -> IO ()
forEachRowRaw app rows writeRow =
  for_ rows $ \r -> bracket_ (pure ()) (endRowRaw app) (writeRow app r)

endRowRaw :: DuckDBAppender -> IO ()
endRowRaw app = checkSt "appender_end_row" =<< c_duckdb_appender_end_row app

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

-- | Append a span as four nullable INTEGER columns, in @start_line,
-- start_col, end_line, end_col@ order -- all four NULL for 'Nothing'.
aMaybeSpan :: DuckDBAppender -> Maybe SourceSpan -> IO ()
aMaybeSpan app Nothing = do
  aMaybeInt app Nothing
  aMaybeInt app Nothing
  aMaybeInt app Nothing
  aMaybeInt app Nothing
aMaybeSpan app (Just sp) = do
  aInt app (ssStartLine sp)
  aInt app (ssStartCol  sp)
  aInt app (ssEndLine   sp)
  aInt app (ssEndCol    sp)

aBool :: DuckDBAppender -> Bool -> IO ()
aBool app b =
  checkSt "append_bool" =<< c_duckdb_append_bool app (if b then CBool 1 else CBool 0)

checkSt :: String -> DuckDBState -> IO ()
checkSt ctx (DuckDBState n)
  | n == 0    = pure ()
  | otherwise = error $ "DuckDB appender error in " <> ctx

-- | Appender-aware variant of 'checkSt': on a non-zero DuckDB status, pulls
-- the real libduckdb error string via 'c_duckdb_appender_error_data' (the
-- bare status code 'checkSt' reports is undiagnosable — e.g. a missing
-- 'PB.Pipeline.DuckDb.Appender.forEachRow' finalization leaves every
-- appended value in one un-finalized appender row, which only fails at
-- flush with a column-count mismatch and no table/row context). The error
-- data must be copied (via 'peekCString') before
-- 'c_duckdb_destroy_error_data' invalidates it. See compiler/AGENTS.md's
-- appender-pool note for the diagnosis playbook.
checkAppenderSt :: String -> DuckDBAppender -> DuckDBState -> IO ()
checkAppenderSt ctx app (DuckDBState n)
  | n == 0    = pure ()
  | otherwise = do
      errData <- c_duckdb_appender_error_data app
      msg <- if errData == nullPtr
               then pure "<no error data>"
               else do
                 msgPtr <- c_duckdb_error_data_message errData
                 m <- if msgPtr == nullPtr
                        then pure "<no error message>"
                        else peekCString msgPtr
                 alloca $ \edPtr -> poke edPtr errData >> c_duckdb_destroy_error_data edPtr
                 pure m
      error $ "DuckDB appender error in " <> ctx <> ": " <> msg
