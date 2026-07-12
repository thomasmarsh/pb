{-# LANGUAGE StrictData #-}
module PB.Pipeline.Passes
  ( runPhaseB
  ) where

import PB.Prelude
import PB.Analysis.Builtins    (builtinFnNames, builtinMethodNames)
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TypeResolve
import PB.Analysis.SchemaCategory
  ( SchemaInputs (..), SchGraph (..), buildSchema )
import PB.Pipeline.Souffle qualified as Souffle
import PB.Analysis.Rules.Schema qualified as SchemaRules
import PB.Analysis.Rules.DeadCode qualified as DeadCodeRules
import PB.Pipeline.DuckDb
  ( DuckConn
  , queryLocalVars, queryCallSites, queryGlobalVars, queryObjInfo
  , queryProcDefs, queryProcUses, queryResolvedCalls
  , queryTaintInputs
  , queryDwRetrieveColumns, queryDwWriteColumns, queryDwWhereColumns
  , queryDwJoinLegs, querySqlCols
  , queryCatFootprintColumns
  , queryCatColumns, queryCatFks
  , appendResolvedTypes, appendResolvedCalls
  , appendInterprocEdges, appendProcSummaries
  , appendTaintSources, appendTaintSinks, appendTaintPaths
  , appendTaintAnnotations
  , appendSchemaObjects, appendSchemaMorphisms
  , materializeDecompositionCoslice
  , materializeDeadCode
  )

import Data.Aeson          (Value (..), encode, object, (.=))
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import System.IO           (hFlush, stderr)
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL

-- | Emit a single JSON progress event to stderr for the Python reporter.
emitProgress :: Value -> IO ()
emitProgress v = do
  BS.hPut stderr (BSL.toStrict (encode v) <> "\n")
  hFlush stderr

-- | Shared per-relation progress callback for 'Souffle.runRuleSetWith' calls
-- across passes 8 and 11 -- see 'runPass11'\'s doc comment for why one event
-- per relation, not one per pass.
souffleProgress :: Souffle.Relation -> IO ()
souffleProgress rel = emitProgress (object
  [ "tag" .= ("step" :: Text)
  , "label" .= ("Datalog: " <> Souffle.relName rel)
  ])

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Runs sequentially after Phase A is complete. Split into three functions so
-- each pass's bindings go out of scope (and are GC-eligible) before the next.
runPhaseB :: DuckConn -> Maybe Text -> IO ()
runPhaseB conn mDefaultNamespace = do
  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("B" :: Text)])
  _    <- runPass5  conn
  runPass67 conn
  runPass8 conn
  sch   <- runPass9 conn mDefaultNamespace
  runPass10 conn sch
  runPass11 conn

runPass5 :: DuckConn -> IO (Map.Map Text Text)
runPass5 conn = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Resolving types" :: Text)])
  lvs                              <- queryLocalVars  conn
  css                              <- queryCallSites  conn
  (objSet, usrTypes, inh, procMap) <- queryObjInfo   conn
  let rt = resolveTypes lvs objSet usrTypes
      rc = resolveCalls css procMap inh builtinFnNames builtinMethodNames
  appendResolvedTypes conn rt
  appendResolvedCalls conn rc
  pure inh

-- | Pass 6+7: compute interproc edges and taint ONCE corpus-wide (not once per file).
runPass67 :: DuckConn -> IO ()
runPass67 conn = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Building call graph" :: Text)])
  gvs  <- queryGlobalVars     conn
  defs <- queryProcDefs       conn
  uses <- queryProcUses       conn
  allRC <- queryResolvedCalls conn
  tfis  <- queryTaintInputs   conn
  let globalVarNames = Set.fromList (map gvName gvs)
      allProcMetas   = concatMap Taint.tfiProcMetas tfis
      allSqlStmts    = concatMap Taint.tfiSqlStmts  tfis
      edges          = Taint.buildInterprocEdges allRC defs uses globalVarNames allProcMetas
      summaries      = Taint.buildProcedureSummaries edges defs uses globalVarNames allProcMetas
      allSources     = Taint.classifySources allSqlStmts allProcMetas
      allSinks       = Taint.classifySinks   allSqlStmts
      (tainted, prov) = Taint.propagateTaint allSources defs uses edges
      allPaths       = Taint.buildTaintPaths allSources allSinks prov
      allAnnotations = Taint.buildTaintAnnotations tainted allSources allSinks defs uses
  appendInterprocEdges   conn edges
  appendProcSummaries    conn summaries
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Taint analysis" :: Text)])
  appendTaintSources     conn allSources
  appendTaintSinks       conn allSinks
  appendTaintPaths       conn allPaths
  appendTaintAnnotations conn allAnnotations
  pure ()

-- | Pass 8: dead-code detection, fully Datalog-materialized. Runs
-- 'DeadCodeRules.deadReachRules' (reachability -> @proc_dead@),
-- 'DeadCodeRules.callerCountRules' (caller-count aggregates + confidence),
-- and 'DeadCodeRules.deadCodeRowsRules' (the final per-procedure join) via
-- 'Souffle.runRuleSets', then 'materializeDeadCode' projects
-- @dead_code_rows@ into the @dead_code@ table (picking the
-- highest-@cyclomatic@ row per overloaded name). No Haskell classification
-- step remains.
runPass8 :: DuckConn -> IO ()
runPass8 conn = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Dead code detection" :: Text)])
  DeadCodeRules.initDeadReachEdbViews conn
  Souffle.runRuleSets souffleProgress conn
    [DeadCodeRules.deadReachRules, DeadCodeRules.callerCountRules, DeadCodeRules.deadCodeRowsRules]
  materializeDeadCode conn

-- | Pass 9 (Plan 148 Phase 1b; default-namespace resolution added Plan 157
-- Phase 1): materialize the schema category @Sch@ from Phase A's
-- DW-retrieve/DW-join/SQL-column/DDL-catalog tables. Returns the graph so
-- Pass 10 can traverse it without rebuilding from DB rows.
runPass9 :: DuckConn -> Maybe Text -> IO SchGraph
runPass9 conn mDefaultNamespace = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Building schema category" :: Text)])
  drCols  <- queryDwRetrieveColumns  conn
  dwCols  <- queryDwWriteColumns     conn
  dwhCols <- queryDwWhereColumns     conn
  djLegs  <- queryDwJoinLegs         conn
  sqlCols <- querySqlCols            conn
  cfCols  <- queryCatFootprintColumns conn
  catCols <- queryCatColumns         conn
  catFks  <- queryCatFks             conn
  let sch = buildSchema SchemaInputs
        { inDwRetrieveColumns   = drCols
        , inDwJoins             = djLegs
        , inDwWriteColumns      = dwCols
        , inDwWhereColumns      = dwhCols
        , inSqlColumns          = sqlCols
        , inCatFootprintColumns = cfCols
        , inCatalogColumns      = catCols
        , inCatalogFks          = catFks
        , inDefaultNamespace    = mDefaultNamespace
        }
  appendSchemaObjects   conn (Set.toList (sgObjects sch))
  appendSchemaMorphisms conn (sgLegs sch)
  pure sch

-- | Pass 11 (Plan 161 -- Souffle rewrite): materialize @live_proc@, the
-- stratified-negation demo wired into the Explorer API/UI (Plan 161
-- Phase 4). @liveProcRules@ reads @proc_dead@ (Pass 8) and @stmt@ (the
-- EDB view Pass 10's 'SchemaRules.initEdbViews' call created) directly --
-- both must already exist by the time this pass runs (they do; see
-- 'runPhaseB'). @reaches@ and the EDB views are now produced by Pass 10,
-- so this pass no longer calls 'SchemaRules.initEdbViews' or runs
-- @reachesRules@ itself.
--
-- Emits one "step" event per relation (via 'Souffle.runRuleSets''s
-- progress callback, threaded to 'Souffle.runRuleSetWith'), not one
-- blanket event for the whole pass: the Python reporter's Phase B
-- rendering shows only the latest step label with no sub-progress bar, so
-- a single silent step here would otherwise become a growing invisible
-- pause as Plan 161 Phase 3 adds more/larger rule sets to this pass.
runPass11 :: DuckConn -> IO ()
runPass11 conn = do
  Souffle.runRuleSets souffleProgress conn
    [ DeadCodeRules.liveProcRules ]

-- | Pass 10 (Plan 161 Phase 2c): materialize @decomposition_coslice@ via
-- the Souffle @cosliceRules@ substrate ('PB.Analysis.Rules.Schema').
-- 'SchemaRules.cosliceRules' runs after 'SchemaRules.reachesRules'
-- (cosliceRules consumes @reaches@ as EDB; 'Souffle.runRuleSets' orders
-- them by that dependency automatically), then
-- 'materializeDecompositionCoslice' projects the @path_leg_fwd@\/
-- @path_leg_back@ tables into the 8-column @decomposition_coslice@ shape
-- (tie-break via ROW_NUMBER, leg_source joined from schema_morphisms,
-- StmtObj-only target filter). No Haskell graph traversal remains.
runPass10 :: DuckConn -> SchGraph -> IO ()
runPass10 conn _sch = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Computing decomposition coslices" :: Text)])
  SchemaRules.initEdbViews conn
  Souffle.runRuleSets souffleProgress conn
    [ SchemaRules.reachesRules, SchemaRules.cosliceRules ]
  materializeDecompositionCoslice conn
