{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.DuckDb
  ( DuckConn
  , withWriteConn
  , initSchema
  -- Appender pool
  , AppenderPool
  , withAppenderPool
  , withAppenderPoolTimed
  , appendRow
  -- Row types
  , ObjectRow (..)
  , ProcRow (..)
  , DwObjectRow (..)
  , DwControlRow (..)
  , DwRetrieveTableRow (..)
  , DwRetrieveColumnRow (..)
  , DwJoinRow (..)
  , DwRetrieveWhereRow (..)
  , SqlStmtRow (..)
  , SqlStmtColumnRow (..)
  , SqlStmtFilterRow (..)
  , SqlStmtTableRow (..)
  , CatalogColumnRow (..)
  , CatalogPkRow (..)
  , CatalogFkRow (..)
  , CatalogCheckRow (..)
  , SourceFileRow (..)
  -- Phase A appenders
  , appendObjects
  , appendProcedures
  , appendDwObjects
  , appendDwControls
  , appendDwRetrieveTables
  , appendDwRetrieveColumns
  , appendDwWriteColumns
  , appendDwWhereColumns
  , appendDwJoins
  , appendDwRetrieveWhere
  , appendLocalVars
  , appendDeadVars
  , appendTypeMismatches
  , appendCallSites
  , appendGlobalVars
  , appendProcDefs
  , appendProcUses
  , appendSqlStmts
  , appendSqlStmtColumns
  , appendSqlStmtFilters
  , appendSqlStmtTables
  , appendCatFootprintColumns
  , appendTaintIntraEdges
  , queryTaintIntraEdges
  , appendTaintReturnRows
  , queryTaintReturnRows
  , appendCatalogColumns
  , appendCatalogPks
  , appendCatalogFks
  , appendCatalogChecks
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
  , queryDwRetrieveColumns
  , queryDwWriteColumns
  , queryDwWhereColumns
  , queryDwJoinLegs
  , querySqlCols
  , queryCatFootprintColumns
  , queryCatColumns
  , queryCatFks
  -- Plan 175 Phase 1: typed EDB-reshaping-layer readers
  , SchMorphismRow (..)
  , querySchemaObjects
  , querySchemaMorphismRows
  -- Plan 175 Phase 2: typed EDB-reshaping-layer readers (DeadCode.hs)
  , ProcSummaryRow (..)
  , queryObjectAncestors
  , queryProcedures
  , queryDwObjects
  -- Phase B appenders
  , appendResolvedTypes
  , appendResolvedCalls
  , appendInterprocEdges
  , appendProcSummaries
  , appendTaintSources
  , appendTaintSinks
  , appendTaintAnnotations
  , materializeDeadCode
  , materializeTaintPaths
  , materializeTaintAnnotations
  , appendSchemaObjects
  , appendSchemaMorphisms
  , materializeDecompositionCoslice
  , materializeImpliedFk
  , materializeColumnRisk
  -- Generic EDB/IDB bridge (Plan 161 -- Souffle)
  , queryTextRows
  , recreateTextTable
  , appendTextRows
  ) where

import PB.Prelude
import PB.AST.Ident             (Ident, IdentMap, IdentSet, identMapFromListWith, identOrig, identSetSingleton, identSetUnion, mkIdent)
import PB.AST.Type             (parseTypeText)
import PB.Analysis.TypeResolve
  ( LocalVar (..), CallSite (..), GlobalVar (..)
  , ResolvedType (..), ResolvedCall (..)
  )
import PB.Analysis.Dataflow    qualified as Dataflow
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TaintEdges  qualified as TaintEdges
import PB.Analysis.DeadVars    (DeadVarFinding (..), deadVarKindText)
import PB.Analysis.TypeFamily (TypeMismatchFinding (..), mismatchKindText)
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), renderLegSource
  , SchMorphism (..)
  , schObjectKey
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  )
import PB.Pipeline.SqlParse    (TableRef (..))
import PB.Pipeline.Serialise   ()
import PB.Pipeline.Progress    qualified as Progress

import Database.DuckDB.Simple
  (Connection, Query (..), execute_, withConnection, query_)
import Database.DuckDB.Simple.Internal (withConnectionHandle)
import Database.DuckDB.Simple.FromRow  (FromRow (..), field, numFieldsRemaining)
import Database.DuckDB.FFI
  ( c_duckdb_appender_create
  , c_duckdb_appender_flush
  , c_duckdb_appender_destroy
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
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Lazy    as BSL
import qualified Data.Map.Strict         as Map
import qualified Data.Set                as Set
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as TE
import           Control.Exception       (bracket, bracket_)
import           Data.Int                (Int32)
import           Foreign                 (alloca, nullPtr, peek, poke)
import           Foreign.C.Types         (CBool (..))
import           Foreign.C.String        (peekCString)

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
        \cfg_json TEXT, instr_graph_json TEXT, wiring_json TEXT, \
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
      -- and consumed by PB.Analysis.TaintAlgebra.buildTaintIndex in Phase B.
      , "CREATE TABLE IF NOT EXISTS taint_intra_edges \
        \(object TEXT, proc_name TEXT, use_var TEXT, def_var TEXT)"
      -- Plan 182b (2026-07-18): one row per var used in a procedure's
      -- 'PB.Compile.IR.EReturn' payload, populated in Phase A alongside
      -- taint_intra_edges and consumed by
      -- PB.Analysis.TaintAlgebra.buildTaintIndex's tiReturnUseTriples in
      -- Phase B -- replaces that index's prior dependency on proc_uses'
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
        \(file TEXT, dw_name TEXT, namespace TEXT, table_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_retrieve_columns \
        \(file TEXT, dw_name TEXT, namespace TEXT, table_name TEXT, column_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_write_columns \
        \(file TEXT, dw_name TEXT, namespace TEXT, table_name TEXT, column_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_where_columns \
        \(file TEXT, dw_name TEXT, namespace TEXT, table_name TEXT, column_name TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_joins \
        \(file TEXT, dw_name TEXT, left_ref TEXT, op TEXT, right_ref TEXT, \
        \outer1 TEXT, outer2 TEXT)"
      , "CREATE TABLE IF NOT EXISTS dw_retrieve_where \
        \(file TEXT, dw_name TEXT, idx INTEGER, exp1 TEXT, op TEXT, exp2 TEXT, logic TEXT)"
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
        \leg_from TEXT, leg_to TEXT, leg_kind TEXT, leg_source TEXT)"
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
        \SELECT file, dw_name AS object, 'datawindow' AS source, \
        \'retrieve' AS operation, namespace, table_name, NULL AS proc_name, NULL::INT AS line \
        \FROM dw_retrieve_tables \
        \UNION ALL \
        \SELECT file, object, 'powerscript' AS source, operation, \
        \namespace, table_name, proc_name, line \
        \FROM sql_statement_tables"
      ]

-- ---------------------------------------------------------------------------
-- Appender pool

-- | A set of long-lived DuckDB appenders, one per table. Created once after
-- 'initSchema' and destroyed (flush + destroy) once at the Phase A/B
-- boundary. This avoids the ~13K create/flush/destroy FFI cycles that
-- per-file appenders would otherwise require (Plan 169 Finding 1+2).
newtype AppenderPool = AppenderPool (Map.Map Text DuckDBAppender)

-- | Create one appender per table name, then run @action@. All appenders are
-- flushed and destroyed when the scope exits (even on exception).
withAppenderPool :: DuckConn -> [Text] -> (AppenderPool -> IO a) -> IO a
withAppenderPool = withAppenderPoolTimed (\_ -> pure ())

-- | Like 'withAppenderPool', but times the flush+destroy teardown via
-- @sink@ (typically 'Progress.emitEvent') -- the only potentially slow part
-- of this scope's exit (on a large corpus, flushing every buffered
-- appender is real I/O), and a span a 'bracket' cleanup can't otherwise be
-- timed from outside its own scope: by the time control returns to the
-- caller of 'withAppenderPool', the flush has already silently happened.
withAppenderPoolTimed
  :: (Progress.ProgressEvent -> IO ()) -> DuckConn -> [Text] -> (AppenderPool -> IO a) -> IO a
withAppenderPoolTimed sink conn tables action =
  withConnectionHandle conn $ \rawConn ->
    bracket
      (createAll rawConn tables)
      (\pool -> Progress.timedStepTo sink "Flushing Phase A appender pool" (destroyAll pool))
      (\pool -> action (AppenderPool pool))
  where
    createAll _ [] = pure Map.empty
    createAll rawConn (t:ts) = do
      app <- alloca $ \appPtr -> do
        checkSt "appender_create" =<<
          BS.useAsCString (TE.encodeUtf8 t) (\tn ->
            c_duckdb_appender_create rawConn nullPtr tn appPtr)
        peek appPtr
      rest <- createAll rawConn ts
      pure (Map.insert t app rest)

    destroyAll pool = for_ (Map.toList pool) $ \(tbl, app) -> do
      st <- c_duckdb_appender_flush app
      checkAppenderSt ("appender_flush:" <> T.unpack tbl) app st
      alloca $ \appPtrPtr -> do
        poke appPtrPtr app
        void $ c_duckdb_appender_destroy appPtrPtr

-- | Append rows to a pooled table. Errors if the table is not in the pool
-- (programmer error — all table names are compile-time literals).
-- Flush happens once in 'withAppenderPool' teardown, not per call.
appendRow :: AppenderPool -> Text -> (DuckDBAppender -> IO ()) -> IO ()
appendRow (AppenderPool pool) tbl action =
  case Map.lookup tbl pool of
    Nothing -> error ("impossible: appender pool missing table " <> T.unpack tbl)
    Just app -> action app

-- | Write each row via @writeRow app row@, guaranteeing 'endRow' is called
-- exactly once after each row (bracketed). A forgotten 'endRow' can never
-- leave an un-finalized appender row — this is what made the 182b
-- 'appender_flush' bug impossible to repeat. Every 'append*' function routes
-- its per-row column marshalling through this helper instead of calling
-- 'endRow' directly. See compiler/CLAUDE.md's "Appender-pool failure modes"
-- subsection.
forEachRow :: DuckDBAppender -> [row] -> (DuckDBAppender -> row -> IO ()) -> IO ()
forEachRow app rows writeRow = for_ rows $ \r -> bracket_ (pure ()) (endRow app) (writeRow app r)

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
  , prInstrJson    :: Text
  , prWiringJson :: Text
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
  , drtrNamespace :: Maybe Text
  , drtrTableName :: Text
  }

data DwRetrieveColumnRow = DwRetrieveColumnRow
  { drcrFile       :: Text
  , drcrDwName     :: Text
  , drcrNamespace  :: Maybe Text
  , drcrTableName  :: Text
  , drcrColumnName :: Text
  }

data DwJoinRow = DwJoinRow
  { djrFile     :: Text
  , djrDwName   :: Text
  , djrLeftRef  :: Text
  , djrOp       :: Text
  , djrRightRef :: Text
  , djrOuter1   :: Maybe Text
  , djrOuter2   :: Maybe Text
  }

data DwRetrieveWhereRow = DwRetrieveWhereRow
  { drwrFile   :: Text
  , drwrDwName :: Text
  , drwrIdx    :: Int
  , drwrExp1   :: Text
  , drwrOp     :: Text
  , drwrExp2   :: Text
  , drwrLogic  :: Maybe Text
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

data SqlStmtColumnRow = SqlStmtColumnRow
  { sscrFile       :: Text
  , sscrObject     :: Text
  , sscrProcName   :: Text
  , sscrLine       :: Int
  , sscrNamespace  :: Maybe Text
  , sscrTableName  :: Maybe Text
  , sscrColumnName :: Text
  , sscrIsWrite    :: Bool
  }

data SqlStmtFilterRow = SqlStmtFilterRow
  { ssfrFile       :: Text
  , ssfrObject     :: Text
  , ssfrProcName   :: Text
  , ssfrLine       :: Int
  , ssfrNamespace  :: Maybe Text
  , ssfrTableName  :: Maybe Text
  , ssfrColumnName :: Text
  , ssfrOp         :: Text
  , ssfrValuesJson :: Text
  }

-- | One row of sql_statement_tables (Plan 157 Phase 4.5): a namespace-aware
-- sibling of sql_statements.tables, one row per (statement, table) pair.
data SqlStmtTableRow = SqlStmtTableRow
  { sstrFile      :: Text
  , sstrObject    :: Text
  , sstrProcName  :: Text
  , sstrLine      :: Int
  , sstrOperation :: Maybe Text
  , sstrNamespace :: Maybe Text
  , sstrTableName :: Text
  }

data CatalogColumnRow = CatalogColumnRow
  { cclrNamespace  :: Maybe Text
  , cclrTableName  :: Text
  , cclrColumnName :: Text
  , cclrOrdinal    :: Int
  }

data CatalogPkRow = CatalogPkRow
  { cpkrNamespace  :: Maybe Text
  , cpkrTableName  :: Text
  , cpkrColumnName :: Text
  , cpkrOrdinal    :: Int
  }

data CatalogFkRow = CatalogFkRow
  { cfkrConstraintName :: Maybe Text
  , cfkrFromNamespace  :: Maybe Text
  , cfkrFromTable      :: Text
  , cfkrFromColumn     :: Text
  , cfkrToNamespace    :: Maybe Text
  , cfkrToTable        :: Text
  , cfkrToColumn       :: Text
  , cfkrOrdinal        :: Int
  }

data CatalogCheckRow = CatalogCheckRow
  { cckrConstraintName :: Maybe Text
  , cckrNamespace      :: Maybe Text
  , cckrTableName      :: Text
  , cckrPredicate      :: Text
  }

data SourceFileRow = SourceFileRow
  { sfrFile :: Text
  , sfrLines :: Text
  }

-- ---------------------------------------------------------------------------
-- Phase A appenders

appendObjects :: AppenderPool -> [ObjectRow] -> IO ()
appendObjects _    [] = pure ()
appendObjects pool rows = appendRow pool "objects" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (orFile           r)
    aText      app (orKind           r)
    aText      app (orObject         r)
    aMaybeText app (orAncestor       r)
    aMaybeText app (orLayoutJson     r)
    aMaybeText app (orTypeBlocksJson r)
    aText      app (orConfidence     r)

appendProcedures :: AppenderPool -> [ProcRow] -> IO ()
appendProcedures _    [] = pure ()
appendProcedures pool rows = appendRow pool "procedures" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText     app (prFile       r)
    aText     app (prObject     r)
    aText     app (prProcName   r)
    aText     app (prProcType   r)
    aInt      app (prStartLine  r)
    aInt      app (prEndLine    r)
    aText     app (prCfgJson    r)
    aText     app (prInstrJson    r)
    aText     app (prWiringJson r)
    aText     app (prParams     r)
    aText     app (prReturnType r)
    aMaybeInt app (prCyclomatic r)
    aText     app (prConfidence r)

appendDwObjects :: AppenderPool -> [DwObjectRow] -> IO ()
appendDwObjects _    [] = pure ()
appendDwObjects pool rows = appendRow pool "dw_objects" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText     app (dorFile        r)
    aText     app (dorObject      r)
    aText     app (dorStyle       r)
    aText     app (dorLayoutJson  r)
    aMaybeText app (dorRetrieveSql r)

appendDwControls :: AppenderPool -> [DwControlRow] -> IO ()
appendDwControls _    [] = pure ()
appendDwControls pool rows = appendRow pool "dw_controls" $ \app ->
  forEachRow app rows $ \_ r -> do
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

appendDwRetrieveTables :: AppenderPool -> [DwRetrieveTableRow] -> IO ()
appendDwRetrieveTables _    [] = pure ()
appendDwRetrieveTables pool rows = appendRow pool "dw_retrieve_tables" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (drtrFile r)
    aText app (drtrDwName r)
    aMaybeText app (drtrNamespace r)
    aText app (drtrTableName r)

appendDwRetrieveColumns :: AppenderPool -> [DwRetrieveColumnRow] -> IO ()
appendDwRetrieveColumns _    [] = pure ()
appendDwRetrieveColumns pool rows = appendRow pool "dw_retrieve_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (drcrFile r)
    aText      app (drcrDwName r)
    aMaybeText app (drcrNamespace r)
    aText      app (drcrTableName r)
    aText      app (drcrColumnName r)

-- | Plan 163 Phase 6: a DW's update-table columns (@DwColumn@'s @dcUpdate@),
-- computed via 'PB.Analysis.DwFootprint.dwRetrieveFootprint' at compile
-- time -- same row shape as 'appendDwRetrieveColumns', a separate table so
-- the leg_kind (LegWrites, not LegRetrieve) stays evident from which table
-- a row came from, matching 'appendCatFootprintColumns's own precedent.
appendDwWriteColumns :: AppenderPool -> [DwRetrieveColumnRow] -> IO ()
appendDwWriteColumns _    [] = pure ()
appendDwWriteColumns pool rows = appendRow pool "dw_write_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (drcrFile r)
    aText      app (drcrDwName r)
    aMaybeText app (drcrNamespace r)
    aText      app (drcrTableName r)
    aText      app (drcrColumnName r)

-- | Plan 163 Phase 6: a DW retrieve's WHERE-operand columns (catalog-gated
-- by 'PB.Analysis.DwFootprint.dwRetrieveFootprint' itself), same shape
-- as 'appendDwWriteColumns'.
appendDwWhereColumns :: AppenderPool -> [DwRetrieveColumnRow] -> IO ()
appendDwWhereColumns _    [] = pure ()
appendDwWhereColumns pool rows = appendRow pool "dw_where_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (drcrFile r)
    aText      app (drcrDwName r)
    aMaybeText app (drcrNamespace r)
    aText      app (drcrTableName r)
    aText      app (drcrColumnName r)

appendDwJoins :: AppenderPool -> [DwJoinRow] -> IO ()
appendDwJoins _    [] = pure ()
appendDwJoins pool rows = appendRow pool "dw_joins" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (djrFile r)
    aText      app (djrDwName r)
    aText      app (djrLeftRef r)
    aText      app (djrOp r)
    aText      app (djrRightRef r)
    aMaybeText app (djrOuter1 r)
    aMaybeText app (djrOuter2 r)

appendDwRetrieveWhere :: AppenderPool -> [DwRetrieveWhereRow] -> IO ()
appendDwRetrieveWhere _    [] = pure ()
appendDwRetrieveWhere pool rows = appendRow pool "dw_retrieve_where" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (drwrFile r)
    aText      app (drwrDwName r)
    aInt       app (drwrIdx r)
    aText      app (drwrExp1 r)
    aText      app (drwrOp r)
    aText      app (drwrExp2 r)
    aMaybeText app (drwrLogic r)

appendLocalVars :: AppenderPool -> [LocalVar] -> IO ()
appendLocalVars _    [] = pure ()
appendLocalVars pool lvs = appendRow pool "local_vars" $ \app ->
  forEachRow app lvs $ \_ lv -> do
    aText app (lvFile lv)
    aText app (lvObject lv)
    aText app (lvProcName lv)
    aText app (lvVarName lv)
    aText app (lvRawType lv)
    aBool app (lvIsParam lv)
    aInt  app (lvScopeLine lv)

appendDeadVars :: AppenderPool -> [DeadVarFinding] -> IO ()
appendDeadVars _    [] = pure ()
appendDeadVars pool rows = appendRow pool "dead_vars" $ \app ->
  forEachRow app rows $ \_ f -> do
    aText     app (dvfObject f)
    aText     app (dvfProc f)
    aText     app (dvfVar f)
    aMaybeInt app (dvfLine f)
    aText     app (deadVarKindText (dvfKind f))

appendTypeMismatches :: AppenderPool -> [TypeMismatchFinding] -> IO ()
appendTypeMismatches _    [] = pure ()
appendTypeMismatches pool rows = appendRow pool "type_mismatches" $ \app ->
  forEachRow app rows $ \_ f -> do
    aText app (tmfObject f)
    aText app (tmfProc f)
    aInt  app (tmfLine f)
    aText app (tmfTarget f)
    aText app (tmfLhsType f)
    aText app (tmfRhsDesc f)
    aText app (mismatchKindText (tmfKind f))

appendCallSites :: AppenderPool -> [CallSite] -> IO ()
appendCallSites _    [] = pure ()
appendCallSites pool css = appendRow pool "call_sites" $ \app ->
  forEachRow app css $ \_ cs -> do
    aText     app (csFile cs)
    aText     app (csObject cs)
    aText     app (csFromProc cs)
    aText     app (csToName cs)
    aText     app (csCallType cs)
    aMaybeInt app (csLine cs)

appendGlobalVars :: AppenderPool -> [GlobalVar] -> IO ()
appendGlobalVars _    [] = pure ()
appendGlobalVars pool gvs = appendRow pool "global_vars" $ \app ->
  forEachRow app gvs $ \_ gv -> do
    aText app (gvFile gv)
    aText app (gvObject gv)
    aText app (gvName gv)
    aText app (gvType gv)
    aText app (T.intercalate "|" (gvMods gv))

appendProcDefs :: AppenderPool -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
appendProcDefs _    [] = pure ()
appendProcDefs pool flows = appendRow pool "proc_defs" $ \app ->
  for_ flows $ \(file, obj, proc_, pf) ->
    forEachRow app (concatMap Dataflow.bfDefs (Map.elems (Dataflow.pfBlocks pf))) $ \_ d -> do
      aText     app file
      aText     app obj
      aText     app proc_
      aText     app (identOrig (Dataflow.dsVar d))
      aText     app (Dataflow.dsBlock d)
      aInt      app (Dataflow.dsStmtIdx d)
      aMaybeInt app (Dataflow.dsLine d)
      aText     app (Dataflow.dsKind d)

appendProcUses :: AppenderPool -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
appendProcUses _    [] = pure ()
appendProcUses pool flows = appendRow pool "proc_uses" $ \app ->
  for_ flows $ \(file, obj, proc_, pf) ->
    forEachRow app (concatMap Dataflow.bfUses (Map.elems (Dataflow.pfBlocks pf))) $ \_ u -> do
      aText     app file
      aText     app obj
      aText     app proc_
      aText     app (identOrig (Dataflow.usVar u))
      aText     app (Dataflow.usBlock u)
      aInt      app (Dataflow.usStmtIdx u)
      aMaybeInt app (Dataflow.usLine u)
      aText     app (Dataflow.usKind u)

appendSqlStmts :: AppenderPool -> [SqlStmtRow] -> IO ()
appendSqlStmts _    [] = pure ()
appendSqlStmts pool rows = appendRow pool "sql_statements" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (ssrFile r)
    aText      app (ssrObject r)
    aText      app (ssrProcName r)
    aInt       app (ssrLine r)
    aMaybeText app (ssrOperation r)
    aText      app (ssrTables r)
    aText      app (ssrColumns r)
    aText      app (ssrRawSql r)
    aBool      app (ssrParseOk r)

appendSqlStmtColumns :: AppenderPool -> [SqlStmtColumnRow] -> IO ()
appendSqlStmtColumns _    [] = pure ()
appendSqlStmtColumns pool rows = appendRow pool "sql_statement_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (sscrFile r)
    aText      app (sscrObject r)
    aText      app (sscrProcName r)
    aInt       app (sscrLine r)
    aMaybeText app (sscrNamespace r)
    aMaybeText app (sscrTableName r)
    aText      app (sscrColumnName r)
    aBool      app (sscrIsWrite r)

-- | Plan 163 Phase 3: same row shape/append pattern as
-- 'appendSqlStmtColumns' (reuses 'SqlStmtColumnRow' rather than a bespoke
-- type), writing to 'cat_footprint_columns' instead.
appendCatFootprintColumns :: AppenderPool -> [SqlStmtColumnRow] -> IO ()
appendCatFootprintColumns _    [] = pure ()
appendCatFootprintColumns pool rows = appendRow pool "cat_footprint_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (sscrFile r)
    aText      app (sscrObject r)
    aText      app (sscrProcName r)
    aInt       app (sscrLine r)
    aMaybeText app (sscrNamespace r)
    aMaybeText app (sscrTableName r)
    aText      app (sscrColumnName r)
    aBool      app (sscrIsWrite r)

-- | Plan 182 Move 2: writes 'PB.Analysis.TaintEdges.foldTaintEdgesEff'
-- output, one row per intra-proc @(useVar, defVar)@ edge.
appendTaintIntraEdges :: AppenderPool -> [TaintEdges.TaintIntraEdgeRow] -> IO ()
appendTaintIntraEdges _    [] = pure ()
appendTaintIntraEdges pool rows = appendRow pool "taint_intra_edges" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (TaintEdges.tierObject r)
    aText app (TaintEdges.tierProcName r)
    aText app (TaintEdges.tierUseVar r)
    aText app (TaintEdges.tierDefVar r)

-- | Plan 182b: writes 'PB.Analysis.TaintEdges.foldTaintEdgesEff' output,
-- one row per var used in a procedure's @return@ payload.
appendTaintReturnRows :: AppenderPool -> [TaintEdges.TaintReturnRow] -> IO ()
appendTaintReturnRows _    [] = pure ()
appendTaintReturnRows pool rows = appendRow pool "taint_return_rows" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (TaintEdges.trrObject r)
    aText app (TaintEdges.trrProcName r)
    aText app (TaintEdges.trrVarName r)

appendSqlStmtFilters :: AppenderPool -> [SqlStmtFilterRow] -> IO ()
appendSqlStmtFilters _    [] = pure ()
appendSqlStmtFilters pool rows = appendRow pool "sql_statement_filters" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (ssfrFile r)
    aText      app (ssfrObject r)
    aText      app (ssfrProcName r)
    aInt       app (ssfrLine r)
    aMaybeText app (ssfrNamespace r)
    aMaybeText app (ssfrTableName r)
    aText      app (ssfrColumnName r)
    aText      app (ssfrOp r)
    aText      app (ssfrValuesJson r)

appendSqlStmtTables :: AppenderPool -> [SqlStmtTableRow] -> IO ()
appendSqlStmtTables _    [] = pure ()
appendSqlStmtTables pool rows = appendRow pool "sql_statement_tables" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (sstrFile r)
    aText      app (sstrObject r)
    aText      app (sstrProcName r)
    aInt       app (sstrLine r)
    aMaybeText app (sstrOperation r)
    aMaybeText app (sstrNamespace r)
    aText      app (sstrTableName r)

appendCatalogColumns :: AppenderPool -> [CatalogColumnRow] -> IO ()
appendCatalogColumns _    [] = pure ()
appendCatalogColumns pool rows = appendRow pool "catalog_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cclrNamespace  r)
    aText      app (cclrTableName  r)
    aText      app (cclrColumnName r)
    aInt       app (cclrOrdinal    r)

appendCatalogPks :: AppenderPool -> [CatalogPkRow] -> IO ()
appendCatalogPks _    [] = pure ()
appendCatalogPks pool rows = appendRow pool "catalog_pks" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cpkrNamespace  r)
    aText      app (cpkrTableName  r)
    aText      app (cpkrColumnName r)
    aInt       app (cpkrOrdinal    r)

appendCatalogFks :: AppenderPool -> [CatalogFkRow] -> IO ()
appendCatalogFks _    [] = pure ()
appendCatalogFks pool rows = appendRow pool "catalog_fks" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cfkrConstraintName r)
    aMaybeText app (cfkrFromNamespace  r)
    aText      app (cfkrFromTable      r)
    aText      app (cfkrFromColumn     r)
    aMaybeText app (cfkrToNamespace    r)
    aText      app (cfkrToTable        r)
    aText      app (cfkrToColumn       r)
    aInt       app (cfkrOrdinal        r)

appendCatalogChecks :: AppenderPool -> [CatalogCheckRow] -> IO ()
appendCatalogChecks _    [] = pure ()
appendCatalogChecks pool rows = appendRow pool "catalog_checks" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cckrConstraintName r)
    aMaybeText app (cckrNamespace      r)
    aText      app (cckrTableName      r)
    aText      app (cckrPredicate      r)

appendParseErrors :: AppenderPool -> [(FilePath, Text)] -> IO ()
appendParseErrors _    [] = pure ()
appendParseErrors pool errs = appendRow pool "parse_errors" $ \app ->
  forEachRow app errs $ \_ (path, msg) -> do
    aText app (T.pack path)
    aText app msg

appendSourceFiles :: AppenderPool -> [SourceFileRow] -> IO ()
appendSourceFiles _    [] = pure ()
appendSourceFiles pool rows = appendRow pool "source_files" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (sfrFile r)
    aText app (sfrLines r)

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
  :: DuckConn
  -> IO (Set.Set Text, Set.Set Text, Map.Map Ident Ident, IdentMap IdentSet)
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
    , Map.fromList [(mkIdent o, mkIdent a) | TwoText o a <- inhRows]
    , identMapFromListWith identSetUnion
        [(mkIdent o, identSetSingleton (mkIdent p)) | TwoText o p <- procRows]
    )

queryProcDefs :: DuckConn -> IO [Taint.DefRow]
queryProcDefs conn = query_ conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind \
  \FROM proc_defs"

queryProcUses :: DuckConn -> IO [Taint.UseRow]
queryProcUses conn = query_ conn
  "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind \
  \FROM proc_uses"

-- | Plan 182 Move 2: reads back 'appendTaintIntraEdges''s output.
queryTaintIntraEdges :: DuckConn -> IO [TaintEdges.TaintIntraEdgeRow]
queryTaintIntraEdges conn = query_ conn
  "SELECT object, proc_name, use_var, def_var FROM taint_intra_edges"

-- | Plan 182b: reads back 'appendTaintReturnRows''s output.
queryTaintReturnRows :: DuckConn -> IO [TaintEdges.TaintReturnRow]
queryTaintReturnRows conn = query_ conn
  "SELECT object, proc_name, var_name FROM taint_return_rows"

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

-- | Plan 148 Phase 1b: SchemaCategory read-side queries.
queryDwRetrieveColumns :: DuckConn -> IO [DwRetrieveColRow]
queryDwRetrieveColumns conn = query_ conn
  "SELECT file, dw_name, namespace, table_name, column_name FROM dw_retrieve_columns"

-- | Plan 163 Phase 6. Same 'DwRetrieveColRow' 'FromRow' shape as
-- 'queryDwRetrieveColumns' -- only the source table differs.
queryDwWriteColumns :: DuckConn -> IO [DwRetrieveColRow]
queryDwWriteColumns conn = query_ conn
  "SELECT file, dw_name, namespace, table_name, column_name FROM dw_write_columns"

queryDwWhereColumns :: DuckConn -> IO [DwRetrieveColRow]
queryDwWhereColumns conn = query_ conn
  "SELECT file, dw_name, namespace, table_name, column_name FROM dw_where_columns"

queryDwJoinLegs :: DuckConn -> IO [DwJoinLegRow]
queryDwJoinLegs conn = query_ conn
  "SELECT file, dw_name, left_ref, right_ref FROM dw_joins"

querySqlCols :: DuckConn -> IO [SqlColRow]
querySqlCols conn = query_ conn
  "SELECT file, object, proc_name, line, namespace, table_name, column_name, is_write \
  \FROM sql_statement_columns"

-- | Plan 175 Phase 1: typed reader over 'schema_objects', the inverse of
-- 'appendSchemaObjects'. object_key is not selected -- 'schObjectKey' is a
-- pure function of the other columns, so it is cheaper to recompute than to
-- read back and never check for drift against the stored value.
data SchObjectRow = SchObjectRow
  !Text !(Maybe Text) !(Maybe Text) !(Maybe Text)
  !(Maybe Text) !(Maybe Text) !(Maybe Text) !(Maybe Int)

instance FromRow SchObjectRow where
  fromRow = SchObjectRow
    <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

querySchemaObjects :: DuckConn -> IO [SchObject]
querySchemaObjects conn = do
  rows <- query_ conn
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

querySchemaMorphismRows :: DuckConn -> IO [SchMorphismRow]
querySchemaMorphismRows conn = query_ conn
  "SELECT from_key, to_key, leg_kind, leg_source FROM schema_morphisms"

-- | Plan 175 Phase 2: typed reader over 'objects', feeding
-- 'PB.Analysis.Rules.DeadCode.inheritsRows'. Deliberately not the write-side
-- 'ObjectRow' -- that type carries 'orLayoutJson'\/'orTypeBlocksJson', which
-- @inherits@ never reads; selecting only the two columns actually needed
-- avoids transferring that JSON for every object row. The @ancestor IS NOT
-- NULL@ filter is the same one 'queryObjInfo' already applies for its own
-- @inhRows@.
queryObjectAncestors :: DuckConn -> IO [(Text, Text)]
queryObjectAncestors conn = do
  rows <- query_ conn
    "SELECT object, ancestor FROM objects WHERE ancestor IS NOT NULL" :: IO [TwoText]
  pure [(o, a) | TwoText o a <- rows]

-- | Plan 175 Phase 2: typed reader over 'procedures', feeding
-- 'PB.Analysis.Rules.DeadCode.procRows'\/'procMetaRows'\/'entryRows'\/
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

queryProcedures :: DuckConn -> IO [ProcSummaryRow]
queryProcedures conn = query_ conn
  "SELECT object, proc_name, proc_type, cyclomatic, confidence FROM procedures"

-- | Plan 175 Phase 2: typed reader over 'dw_objects', feeding
-- 'PB.Analysis.Rules.DeadCode.entryRows''s DW-object membership check.
queryDwObjects :: DuckConn -> IO [Text]
queryDwObjects conn = do
  rows <- query_ conn "SELECT DISTINCT object FROM dw_objects" :: IO [OneText]
  pure [o | OneText o <- rows]

-- | Plan 163 Phase 3: same shape/query as 'querySqlCols', reading
-- 'cat_footprint_columns' instead -- the existing 'FromRow' 'SqlColRow'
-- instance is reused verbatim.
queryCatFootprintColumns :: DuckConn -> IO [SqlColRow]
queryCatFootprintColumns conn = query_ conn
  "SELECT file, object, proc_name, line, namespace, table_name, column_name, is_write \
  \FROM cat_footprint_columns"

queryCatColumns :: DuckConn -> IO [CatColumnRow]
queryCatColumns conn = query_ conn
  "SELECT namespace, table_name, column_name FROM catalog_columns"

queryCatFks :: DuckConn -> IO [CatFkRow]
queryCatFks conn = query_ conn
  "SELECT from_namespace, from_table, from_column, to_namespace, to_table, to_column \
  \FROM catalog_fks"

-- ---------------------------------------------------------------------------
-- Phase B appenders

appendResolvedTypes :: DuckConn -> [ResolvedType] -> IO ()
appendResolvedTypes _    [] = pure ()
appendResolvedTypes conn rows = withRaw conn "resolved_types" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (rtFile      r)
    aText      app (rtObject    r)
    aText      app (rtProcName  r)
    aText      app (rtVarName   r)
    aText      app (rtRawType   r)
    aText      app (rtKind      r)
    aMaybeText app (rtTarget    r)
    aBool      app (rtIsParam   r)
    aInt       app (rtScopeLine r)

appendResolvedCalls :: DuckConn -> [ResolvedCall] -> IO ()
appendResolvedCalls _    [] = pure ()
appendResolvedCalls conn rows = withRaw conn "resolved_calls" $ \app ->
  forEachRow app rows $ \_ r -> do
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

appendInterprocEdges :: DuckConn -> [Taint.InterprocEdge] -> IO ()
appendInterprocEdges _    [] = pure ()
appendInterprocEdges conn rows = withRaw conn "interproc_edges" $ \app ->
  forEachRow app rows $ \_ e -> do
    aText     app (Taint.ieCallerObject  e)
    aText     app (Taint.ieCallerProc    e)
    aMaybeInt app (Taint.ieCallerLine    e)
    aText     app (Taint.ieCalleeObject  e)
    aText     app (Taint.ieCalleeProc    e)
    aText     app (Taint.ieEdgeKind      e)
    aText     app (Taint.ieVarName       e)
    aText     app (Taint.ieCallerContext e)
    aText     app (Taint.ieCalleeContext e)

appendProcSummaries :: DuckConn -> [Taint.ProcedureSummary] -> IO ()
appendProcSummaries _    [] = pure ()
appendProcSummaries conn rows = withRaw conn "procedure_summaries" $ \app ->
  forEachRow app rows $ \_ s -> do
    aText app (Taint.psFile              s)
    aText app (Taint.psObject            s)
    aText app (Taint.psProcName          s)
    aText app (jsonList (Taint.psParamsIn       s))
    aText app (jsonList (Taint.psGlobalsRead    s))
    aText app (jsonList (Taint.psGlobalsWritten s))
    aText app (jsonList (Taint.psReturnFlowsTo  s))

appendTaintSources :: DuckConn -> [Taint.TaintSource] -> IO ()
appendTaintSources _    [] = pure ()
appendTaintSources conn rows = withRaw conn "taint_sources" $ \app ->
  forEachRow app rows $ \_ s -> do
    aText     app (Taint.tsFile       s)
    aText     app (Taint.tsObject     s)
    aText     app (Taint.tsProcName   s)
    aText     app (Taint.tsVarName    s)
    aText     app (Taint.tsSourceType s)
    aMaybeInt app (Taint.tsLine       s)

appendTaintSinks :: DuckConn -> [Taint.TaintSink] -> IO ()
appendTaintSinks _    [] = pure ()
appendTaintSinks conn rows = withRaw conn "taint_sinks" $ \app ->
  forEachRow app rows $ \_ s -> do
    aText     app (Taint.tskFile     s)
    aText     app (Taint.tskObject   s)
    aText     app (Taint.tskProcName s)
    aText     app (Taint.tskVarName  s)
    aText     app (Taint.tskSinkType s)
    aText     app (Taint.tskSeverity s)
    aMaybeInt app (Taint.tskLine     s)

appendTaintAnnotations :: DuckConn -> [Taint.TaintAnnotation] -> IO ()
appendTaintAnnotations _    [] = pure ()
appendTaintAnnotations conn rows = withRaw conn "taint_annotations" $ \app ->
  forEachRow app rows $ \_ a -> do
    aText app (Taint.taFile         a)
    aText app (Taint.taObject       a)
    aText app (Taint.taProcName     a)
    aText app (Taint.taBlockId      a)
    aBool app (Taint.taIsTaintEntry a)
    aBool app (Taint.taIsTaintSink  a)
    aText app (T.intercalate "|" (Taint.taTaintedVars a))

-- | Plan 166 Stage 6: dead_code is now populated entirely from the
-- Soufflé-materialized dead_code_rows relation via a mechanical cast
-- (every Soufflé column is TEXT; this restores the typed schema
-- Python's get_dead_code reads) -- no Haskell classification left.
--
-- The ROW_NUMBER() dedup handles PowerBuilder function overloading: proc
-- reachability is already computed at (object, proc_name) granularity --
-- the call graph can't distinguish overloads by parameter list, so a dead
-- name with multiple overloads was always going to collapse to one
-- dead_code row. The only question is which overload's @cyclomatic@ to
-- surface (proc_type/confidence/counts are identical across a name's
-- overloads regardless, since they're derived from the same proc-name-
-- level joins). This picks the HIGHEST cyclomatic deterministically --
-- a deliberate choice, not an arbitrary tie-break: it surfaces the most
-- complex variant behind a dead name, the more conservative/useful signal
-- if someone is deciding whether it's worth double-checking before
-- deleting. @NULLS LAST@ on the @DESC@ order is written explicitly rather
-- than relied on implicitly: DuckDB's current default for @DESC@ already
-- puts @NULL@ last (verified empirically -- an overload with an unknown
-- cyclomatic does NOT win the tie-break over a real value), but that
-- default is an engine behavior, not a documented guarantee this module
-- depends on elsewhere, so it's spelled out here rather than left implicit.
-- (Regression test: 'SouffleDeadCodeTest.hs'\'s "overloaded procedure with
-- one unknown cyclomatic" case.) The pre-Stage-6 Haskell 'classifyDeadProcedures' used
-- 'Map.fromListWith (\a _b -> a)', which kept whichever row DuckDB's
-- unordered table scan happened to return first -- not a rule, an
-- accident with no rationale and no run-to-run reproducibility guarantee.
-- Confirmed via real corpus diff (2026-07-11): every one of the 7 rows
-- this changes vs. the old behavior differs ONLY in cyclomatic -- object,
-- proc, proc_type, confidence, and both caller counts are unchanged.
materializeDeadCode :: DuckConn -> IO ()
materializeDeadCode conn = do
  _ <- execute_ conn "DELETE FROM dead_code"
  _ <- execute_ conn
    "INSERT INTO dead_code \
    \SELECT object, proc, proc_type, TRY_CAST(cyclomatic AS INTEGER), \
    \level, TRY_CAST(naive_n AS INTEGER), TRY_CAST(scoped_n AS INTEGER) \
    \FROM ( \
    \  SELECT *, ROW_NUMBER() OVER (PARTITION BY object, proc ORDER BY TRY_CAST(cyclomatic AS INTEGER) DESC NULLS LAST) AS rn \
    \  FROM dead_code_rows \
    \) WHERE rn = 1"
  pure ()

-- | Kind text for a 'LegKind'. Provenance (formerly a second, FK-only
-- @fk_source@ column derived here) is now the general 'legSource' field on
-- every 'SchMorphism' row -- see 'renderLegSource' (Plan 163 Phase 4, D3).
renderLegKind :: LegKind -> Text
renderLegKind LegReads    = "reads"
renderLegKind LegWrites   = "writes"
renderLegKind LegRetrieve = "retrieve"
renderLegKind LegFk       = "fk"

appendSchemaObjects :: DuckConn -> [SchObject] -> IO ()
appendSchemaObjects _    [] = pure ()
appendSchemaObjects conn objs = withRaw conn "schema_objects" $ \app ->
  forEachRow app objs $ \_ o -> do
    aText app (schObjectKey o)
    case o of
      ColumnObj (TableRef ns tbl) col -> do
        aText      app "column"
        aMaybeText app ns
        aMaybeText app (Just tbl)
        aMaybeText app (Just col)
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeInt  app Nothing
      StmtObj (SqlStmtId f obj_ p l) -> do
        aText      app "stmt"
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app (Just f)
        aMaybeText app (Just obj_)
        aMaybeText app (Just p)
        aMaybeInt  app (Just l)
      StmtObj (DwRetrieveId f dw) -> do
        aText      app "dw_retrieve"
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app (Just f)
        aMaybeText app (Just dw)
        aMaybeText app Nothing
        aMaybeInt  app Nothing

appendSchemaMorphisms :: DuckConn -> [SchMorphism] -> IO ()
appendSchemaMorphisms _    [] = pure ()
appendSchemaMorphisms conn ms = withRaw conn "schema_morphisms" $ \app ->
  forEachRow app ms $ \_ m -> do
    aText      app (schObjectKey (legFrom m))
    aText      app (schObjectKey (legTo m))
    aText      app (renderLegKind (legKind m))
    aText      app (renderLegSource (legSource m))

-- | Plan 161 Phase 2c: materialize @decomposition_coslice@ from the Souffle
-- @path_leg_fwd@\/@path_leg_back@ tables (produced by
-- 'PB.Analysis.Rules.Schema.cosliceRules'), replacing the old
-- Haskell-walked 'appendDecompositionCoslice'. A pure SQL projection -- no
-- traversal, no Haskell graph walk -- satisfying the Plan 166 EDB-discipline
-- functor property (the @path_leg@ tables are the reasoning; this is a
-- rename\/join into the 8-column consumer shape).
--
-- Three things happen here that the Datalog layer can't express:
--
-- 1. __Tie-break.__ Souffle set semantics emit every shortest leg through a
--    diamond (a bounded 2x, not exponential -- verified on a 15-diamond
--    stress fixture). @ROW_NUMBER() OVER (PARTITION BY seed, target,
--    leg_ord ORDER BY leg_from, leg_to)@ picks one deterministic witness
--    per ordinal, so Python's @_coslice_paths@ chain-rebuilder (which
--    groups by @(seed, target)@ and orders by @leg_ordinal@) sees exactly
--    one contiguous leg chain per path.
--
-- 2. __leg_source recovery.@ The Souffle @path_leg@ tables carry
--    @leg_from@\/@leg_to@\/@leg_kind@ but not @leg_source@ (the
--    provenance column 'appendSchemaMorphisms' writes). Joined back from
--    @schema_morphisms@ on the three keys it shares with @path_leg@.
--
-- 3. __Target filtering.__ 'columnCoslice' keeps only @StmtObj@ targets
--    (statements and DW retrieves) -- column intermediates appear in
--    @path_leg@ as traversal hops but are not rewrite-cost endpoints.
--    Filtered via @schema_objects.kind IN ('stmt', 'dw_retrieve')@.
-- | ROW_NUMBER's PARTITION BY includes 'direction': a forward path and a
-- backward path from the same seed to the same target are independently
-- derived (path_leg_fwd/path_leg_back) and their leg_ordinal sequences are
-- unrelated -- without 'direction' in the partition key, a forward leg and
-- a backward leg sharing an ordinal number compete for the same witness
-- slot, scrambling both into one row set with non-contiguous, mixed-origin
-- ordinals (found via a real-corpus regression: a target's surviving rows
-- had ordinals 0,4,5,6,7 from 'backward' interleaved with 1,2,3 from
-- 'forward' -- neither a valid forward nor backward path).
materializeDecompositionCoslice :: DuckConn -> IO ()
materializeDecompositionCoslice conn =
  void $ execute_ conn (Query sql)
  where
    sql = T.unlines
      [ "INSERT INTO decomposition_coslice"
      , "  (seed_key, target_key, direction, leg_ordinal, leg_from, leg_to, leg_kind, leg_source)"
      , "WITH candidates AS ("
      , "  SELECT s AS seed_key, target AS target_key, 'forward' AS direction,"
      , "         CAST(leg_ord AS INTEGER) AS leg_ordinal, lf AS leg_from, lt AS leg_to, kind AS leg_kind"
      , "    FROM path_leg_fwd"
      , "  UNION ALL"
      -- Backward legs are reversed to target->seed ordering: the Datalog
      -- `path_leg_back` emit (ascending ordinal, seed=0 outward) reads
      -- seed->target, but the deleted Haskell `validationWalkBack`'s
      -- `extendBackward (leg : spLegs path)` prepended each walked-back leg,
      -- so its `spLegs` read target->seed -- the convention
      -- `PB.Analysis.SchemaCategory.columnCoslice` shipped and every Python/UI
      -- consumer (incl. `seedRootedChain` in `DecompositionCandidatesCore.tsx`,
      -- which expects the path's non-seed end to be the target) inherits.
      -- Renumbering per (seed, target) as `max_ord - leg_ord` inverts the
      -- ordering while keeping ordinals contiguous and 0-based; the per-path
      -- JOIN is essential so a forward path's ordinals are left untouched.
      , "  SELECT pb.s AS seed_key, pb.target AS target_key, 'backward' AS direction,"
      , "         CAST(mo.max_ord AS INTEGER) - CAST(pb.leg_ord AS INTEGER) AS leg_ordinal,"
      , "         pb.lf AS leg_from, pb.lt AS leg_to, pb.kind AS leg_kind"
      , "    FROM path_leg_back pb"
      , "    JOIN (SELECT s, target, MAX(CAST(leg_ord AS INTEGER)) AS max_ord"
      , "            FROM path_leg_back GROUP BY s, target) mo"
      , "      ON mo.s = pb.s AND mo.target = pb.target"
      , "), ranked AS ("
      , "  SELECT c.seed_key, c.target_key, c.direction, c.leg_ordinal, c.leg_from, c.leg_to, c.leg_kind,"
      , "         sm.leg_source,"
      , "         ROW_NUMBER() OVER (PARTITION BY c.seed_key, c.target_key, c.direction, c.leg_ordinal"
      , "                           ORDER BY c.leg_from, c.leg_to) AS rn"
      , "    FROM candidates c"
      , "    JOIN schema_objects so ON so.object_key = c.target_key"
      , "                       AND so.kind IN ('stmt', 'dw_retrieve')"
      , "    LEFT JOIN schema_morphisms sm ON sm.from_key = c.leg_from"
      , "                                AND sm.to_key   = c.leg_to"
      , "                                AND sm.leg_kind = c.leg_kind"
      , ")"
      , "SELECT seed_key, target_key, direction, leg_ordinal, leg_from, leg_to, leg_kind,"
      , "       COALESCE(leg_source, '') AS leg_source"
      , "  FROM ranked WHERE rn = 1"
      ]

-- | Plan 161 Phase 3a: materialize @implied_fk@ from Souffle's
-- @implied_fk_pairs@ (produced by 'PB.Analysis.Rules.Schema.impliedFkRules'),
-- decoding each ColKey pair back to human-readable (namespace, table,
-- column) via a join-back on @schema_objects.object_key@ -- the same
-- decoding 'materializeDecompositionCoslice' uses, since 'schObjectKey' has
-- no inverse parser in this codebase. A pure rename\/join projection, no
-- decision logic.
materializeImpliedFk :: DuckConn -> IO ()
materializeImpliedFk conn =
  void $ execute_ conn (Query sql)
  where
    sql = T.unlines
      [ "INSERT INTO implied_fk"
      , "  (from_namespace, from_table, from_column, to_namespace, to_table, to_column)"
      , "SELECT so1.namespace, so1.table_name, so1.column_name,"
      , "       so2.namespace, so2.table_name, so2.column_name"
      , "  FROM implied_fk_pairs ifk"
      , "  JOIN schema_objects so1 ON so1.object_key = ifk.x"
      , "  JOIN schema_objects so2 ON so2.object_key = ifk.y"
      ]

-- | Plan 161 Phase 3a: materialize @column_risk@ from Souffle's
-- @risk_count@ (produced by 'PB.Analysis.Rules.Schema.riskRules'), same
-- join-back-on-@object_key@ decoding as 'materializeImpliedFk'. @risk_count@
-- scores every 'reaches' node, including 'StmtObj' ones ('stmt'\/
-- @dw_retrieve@ kinds), which carry no @namespace@\/@table_name@\/
-- @column_name@ in @schema_objects@ (only @stmt_*@ fields) -- confirmed on
-- the real openpay corpus, where 115 such rows materialized as opaque
-- all-NULL triples. Migration risk scoring is inherently a per-COLUMN
-- question (what breaks if this column changes), so this filters to
-- @kind = 'column'@ only, the same restriction 'seedRows' already applies
-- to the coslice walk's own starting points.
materializeColumnRisk :: DuckConn -> IO ()
materializeColumnRisk conn =
  void $ execute_ conn (Query sql)
  where
    sql = T.unlines
      [ "INSERT INTO column_risk (namespace, table_name, column_name, downstream_count)"
      , "SELECT so.namespace, so.table_name, so.column_name, CAST(rc.n AS INTEGER)"
      , "  FROM risk_count rc"
      , "  JOIN schema_objects so ON so.object_key = rc.x AND so.kind = 'column'"
      ]

-- ---------------------------------------------------------------------------
-- Plan 161 Phase 2d: taint path materialization
-- ---------------------------------------------------------------------------

-- | Materialize @taint_paths@ from Datalog\/Haskell output.  Reads
-- @taint_step_kind@ (witness legs) and @taint_confirmed@
-- (source→sink reachability), joins back to @taint_sources@\/
-- @taint_sinks@ for file info, and reproduces the existing
-- 11-column table shape.
--
-- Design decisions (pre-stated in doc/plan/161-phase-2d-taint.md):
--
--   * Deterministic diamond tie-break via ROW_NUMBER (same pattern
--     as materializeDecompositionCoslice).
--   * ORDER BY inside string_agg guarantees ordinal ordering.
--
-- Plan 171b (2026-07-15): step_kind/description no longer come from a
-- SQL CASE here — PB.Analysis.Rules.Taint derives them via rule
-- specialization (a house-rule violation this migration closes; see
-- compiler/CLAUDE.md's Datalog Rule Placement Discipline).
-- taint_step_kind already includes the terminal "arrived at sink"
-- marker row (and the 0-hop source==sink degenerate row), so the old
-- legs_with_sink UNION ALL that synthesized it here is gone too — this
-- materializer is now a pure rename/dedup/reshape of taint_step_kind.
--
-- PERFORMANCE FIX (2026-07-16): @taint_step_kind@ itself is no longer
-- Souffle-derived (the per-source shortest-distance fixpoint that used to
-- produce it, @taint_min_dist@\/@taint_path_leg@, is gone) — it is now
-- written directly into a plain DuckDB table by
-- 'PB.Analysis.Rules.Taint.reconstructTaintStepKind', a Haskell BFS-based
-- reconstruction. This materializer's SQL is unchanged; it just reads a
-- table populated a different way. See that function's own doc comment
-- for the full rationale.
materializeTaintPaths :: DuckConn -> IO ()
materializeTaintPaths conn =
  void $ execute_ conn (Query sql)
  where
    sql = T.unlines
      [ "DELETE FROM taint_paths"
      , ";"
      , "INSERT INTO taint_paths"
      , "  (source_file, source_object, source_proc, source_var,"
      , "   sink_file, sink_object, sink_proc, sink_var,"
      , "   severity, category, steps_json)"
      , "WITH confirmed AS ("
      , "  SELECT tc.s AS source_key, tc.t AS sink_key"
      , "  FROM taint_confirmed tc"
      , "),"
      , "source_info AS ("
      , "  SELECT ts.object || '::' || ts.proc_name || '::' || ts.var_name AS key,"
      , "         ts.file, ts.object, ts.proc_name, ts.var_name"
      , "  FROM taint_sources ts"
      , "),"
      , "sink_info AS ("
      , "  SELECT tsk.object || '::' || tsk.proc_name || '::' || tsk.var_name AS key,"
      , "         tsk.file, tsk.object, tsk.proc_name, tsk.var_name,"
      , "         tsk.severity, tsk.sink_type"
      , "  FROM taint_sinks tsk"
      , "),"
      , "ranked_legs AS ("
      , "  SELECT tsk.s AS source_key, tsk.t AS sink_key,"
      , "         CAST(tsk.leg_ord AS INTEGER) AS leg_ord,"
      , "         tsk.lf AS leg_from, tsk.lt AS leg_to,"
      , "         tsk.step_kind AS step_kind, tsk.description AS description,"
      , "         ROW_NUMBER() OVER ("
      , "           PARTITION BY tsk.s, tsk.t, CAST(tsk.leg_ord AS INTEGER)"
      , "           ORDER BY tsk.lf, tsk.lt"
      , "         ) AS rn"
      , "  FROM taint_step_kind tsk"
      , "),"
      , "chains AS ("
      , "  SELECT l.source_key, l.sink_key,"
      , "         '[' ||"
      , "           string_agg("
      , "             '{\"object\":\"' || split_part(l.leg_from, '::', 1) ||"
      , "             '\",\"proc_name\":\"' || split_part(l.leg_from, '::', 2) ||"
      , "             '\",\"var_name\":\"' || split_part(l.leg_from, '::', 3) ||"
      , "             '\",\"line\":null'"
      , "             ',\"step_kind\":\"' || l.step_kind || '\"'"
      , "             ',\"description\":\"' || l.description || '\"}',"
      , "             ',' ORDER BY l.leg_ord"
      , "           )"
      , "         || ']' AS steps_json"
      , "  FROM ranked_legs l WHERE l.rn = 1"
      , "  GROUP BY l.source_key, l.sink_key"
      , ")"
      , "SELECT"
      , "  si.file AS source_file,"
      , "  si.object AS source_object,"
      , "  si.proc_name AS source_proc,"
      , "  si.var_name AS source_var,"
      , "  sk.file AS sink_file,"
      , "  sk.object AS sink_object,"
      , "  sk.proc_name AS sink_proc,"
      , "  sk.var_name AS sink_var,"
      , "  sk.severity AS severity,"
      , "  COALESCE("
      , "    CASE WHEN sk.sink_type = 'db_write' THEN 'sql_injection'"
      , "         WHEN sk.sink_type = 'exec_immediate' THEN 'exec_immediate'"
      , "         ELSE 'general' END,"
      , "    'general'"
      , "  ) AS category,"
      , "  COALESCE(ch.steps_json, '[]') AS steps_json"
      , "FROM confirmed c"
      , "JOIN source_info si ON si.key = c.source_key"
      , "JOIN sink_info sk ON sk.key = c.sink_key"
      , "LEFT JOIN chains ch ON ch.source_key = c.source_key AND ch.sink_key = c.sink_key"
      ]

-- | Materialize @taint_annotations@ from the algebraic closure's output.
-- Reads @taint_sources@ and @taint_reaches@ (transitive closure) to
-- rebuild the tainted set, then calls 'Taint.buildTaintAnnotations'
-- (which needs @block_id@ from proc_defs/proc_uses).
materializeTaintAnnotations :: DuckConn -> IO ()
materializeTaintAnnotations conn = do
  -- 1. Read sources/sinks as Haskell types for buildTaintAnnotations.
  srcRows <- queryTextRows conn "taint_sources"
               ["file","object","proc_name","var_name","source_type"]
  snkRows <- queryTextRows conn "taint_sinks"
               ["file","object","proc_name","var_name","sink_type","severity"]
  let allSources = mapMaybe mkSource srcRows
      allSinks   = mapMaybe mkSink   snkRows
      mkSource [f,o,p,v,st] = Just Taint.TaintSource
        { Taint.tsFile = f, Taint.tsObject = o, Taint.tsProcName = p
        , Taint.tsVarName = v, Taint.tsSourceType = st, Taint.tsLine = Nothing }
      mkSource _ = Nothing
      mkSink [f,o,p,v,st,sev] = Just Taint.TaintSink
        { Taint.tskFile = f, Taint.tskObject = o, Taint.tskProcName = p
        , Taint.tskVarName = v, Taint.tskSinkType = st
        , Taint.tskSeverity = sev, Taint.tskLine = Nothing }
      mkSink _ = Nothing
  -- 2. Read taint_reaches (all reachable pairs)
  reachesRows <- queryTextRows conn "taint_reaches" ["x", "y"]
  -- 3. Build the tainted set: sources ∪ {y | ∃x. taint_source(x) ∧ taint_reaches(x, y)}
  --    Only targets reachable FROM a source are tainted — not all targets
  --    in taint_reaches (which includes nodes reachable from non-source nodes).
  let taintKey o p v = o <> "::" <> p <> "::" <> v
      sourceKeys = Set.fromList
        [ taintKey (Taint.tsObject s) (Taint.tsProcName s) (Taint.tsVarName s) | s <- allSources ]
      reachableFromSource = Set.fromList
        [ toKey
        | [fromKey, toKey] <- reachesRows
        , fromKey `Set.member` sourceKeys
        , case T.splitOn "::" toKey of { [_,_,_] -> True; _ -> False }
        ]
      parseTriple t = case T.splitOn "::" t of
        [a, b, c] -> Just (a, b, c)
        _         -> Nothing
      taintedSet = Set.fromList
        [ t | key <- Set.toList (sourceKeys <> reachableFromSource)
            , Just t <- [parseTriple key]
        ]
  -- 4. Read proc_defs + proc_uses for block_id context
  defs <- queryProcDefs conn
  uses <- queryProcUses conn
  let annotations = Taint.buildTaintAnnotations taintedSet allSources allSinks defs uses
  appendTaintAnnotations conn annotations

-- ---------------------------------------------------------------------------
-- Generic EDB/IDB bridge (Plan 161 -- Souffle rewrite)
--
-- 'PB.Pipeline.Souffle' needs to read/write relations whose column count is
-- a runtime value ('PB.Pipeline.Souffle.Relation''s 'relCols'), not fixed by
-- a Haskell type -- so no per-relation 'FromRow'/appender pair is possible.
-- These three are the dynamic-arity counterparts of the typed
-- query/appender pairs above, values passed through as TEXT throughout
-- (every EDB relation this project currently feeds Datalog/Souffle -- keys,
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
queryTextRows :: DuckConn -> Text -> [Text] -> IO [[Text]]
queryTextRows conn tblOrView cols = do
  rows <- query_ conn (Query sql)
  pure (map unTextRow rows)
  where
    sql = "SELECT " <> T.intercalate ", "
            [ "CAST(" <> c <> " AS VARCHAR)" | c <- cols ]
            <> " FROM " <> tblOrView

-- | (Re)create a table with the given column names, all TEXT, dropping any
-- previous table of that name first -- the write-side counterpart of
-- 'queryTextRows', used to materialize a computed relation's result rows.
recreateTextTable :: DuckConn -> Text -> [Text] -> IO ()
recreateTextTable conn tbl cols = do
  void $ execute_ conn (Query ("DROP TABLE IF EXISTS " <> tbl))
  void $ execute_ conn (Query ("CREATE TABLE " <> tbl <> " ("
    <> T.intercalate ", " [ c <> " TEXT" | c <- cols ] <> ")"))

-- | Append rows of uniform (but runtime-known) arity as TEXT columns -- no
-- per-arity 'ToRow' instance needed.
appendTextRows :: DuckConn -> Text -> [[Text]] -> IO ()
appendTextRows _    _   []   = pure ()
appendTextRows conn tbl rows = withRaw conn tbl $ \app ->
  forEachRow app rows $ \_ r -> for_ r (aText app)

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
          st <- c_duckdb_appender_flush app
          checkAppenderSt "appender_flush" app st
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

-- | Appender-aware variant of 'checkSt': on a non-zero DuckDB status, pulls
-- the real libduckdb error string via 'c_duckdb_appender_error_data' (the
-- bare status code 'checkSt' reports is undiagnosable — e.g. a missing
-- 'endRow' leaves every appended value in one un-finalized appender row,
-- which only fails at flush with a column-count mismatch and no table/row
-- context). The error data must be copied (via 'peekCString') before
-- 'c_duckdb_destroy_error_data' invalidates it. See compiler/CLAUDE.md's
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
