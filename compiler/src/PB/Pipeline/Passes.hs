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
import PB.Analysis.Rules.Taint qualified as TaintRules
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
  , appendTaintSources, appendTaintSinks
  , appendSchemaObjects, appendSchemaMorphisms
  , materializeDecompositionCoslice
  , materializeDeadCode
  , materializeTaintPaths
  , materializeTaintAnnotations
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

-- | Shared per-relation progress callback for 'Souffle.runRuleSets' in
-- 'runPhaseB': one @step@ event per IDB relation just before it is
-- materialized. The Python reporter's Phase B view shows only the latest
-- step label (no sub-progress bar), so per-relation granularity keeps the
-- label current as each rule set's outputs land rather than stalling on a
-- single blanket label for the whole Datalog run.
souffleProgress :: Souffle.Relation -> IO ()
souffleProgress rel = emitProgress (object
  [ "tag" .= ("step" :: Text)
  , "label" .= ("Datalog: " <> Souffle.relName rel)
  ])

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Structured as two sub-phases:
--
-- * **B1 (Haskell + EDB materialization):** the analyses that can't be
--   expressed as Soufflé rules run here — type/call resolution
--   ('runPass5', populating @resolved_calls@), interproc-edge and taint
--   analysis ('runPass67'), and schema-category construction ('runPass9',
--   populating @schema_objects@\/@schema_morphisms@). Then
--   'materializeAllEdbViews' creates every SQL-view EDB relation the
--   Soufflé rule sets below assume: the dead-code EDBs
--   ('DeadCodeRules.initDeadReachEdbViews', over @procedures@\/
--   @resolved_calls@\/@objects@) and the schema EDBs
--   ('SchemaRules.initEdbViews', over @schema_morphisms@\/
--   @schema_objects@).
-- * **B2 (one Soufflé run):** every Phase B Datalog rule set runs in a
--   single 'Souffle.runRuleSets' call. 'Souffle.orderRuleSets' resolves
--   every Soufflé-internal dependency edge automatically —
--   @proc_dead@ (from 'DeadCodeRules.deadReachRules') before
--   'DeadCodeRules.deadCodeRowsRules' and 'DeadCodeRules.liveProcRules';
--   @leg@ (from 'SchemaRules.legRules') before 'SchemaRules.reachesRules';
--   @reaches@ (from 'SchemaRules.reachesRules') before
--   'SchemaRules.cosliceRules'. The only sequencing that remains manual is
--   the Phase A→B boundary enforced by B1 (the EDB views' source tables
--   must be populated before the views are created), which is a genuine
--   data dependency, not an on-demand coupling between rule sets. Finally
--   the two SQL materializers project IDB output tables into their
--   API-facing shapes (@dead_code_rows@→@dead_code@,
--   @path_leg_fwd@\/@path_leg_back@→@decomposition_coslice@).
runPhaseB :: DuckConn -> Maybe Text -> IO ()
runPhaseB conn mDefaultNamespace = do
  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("B" :: Text)])
  -- B1: prerequisite Haskell analyses + EDB materialization.
  _   <- runPass5  conn
  runPass67 conn
  _sch <- runPass9 conn mDefaultNamespace
  materializeAllEdbViews conn
  -- B2: all Soufflé rule sets in one dependency-ordered run.
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Datalog analysis" :: Text)])
  Souffle.runRuleSets souffleProgress conn allDatalogRuleSets
  materializeDeadCode conn
  materializeDecompositionCoslice conn
  materializeTaintPaths conn
  materializeTaintAnnotations conn

-- | Materialize every EDB view the Soufflé rule sets in 'allDatalogRuleSets'
-- assume already exist. Each 'init*EdbViews' is idempotent (@CREATE OR
-- REPLACE VIEW@); together they cover the dead-code and schema EDB layers.
-- Must run after 'runPass5' (for @resolved_calls@) and 'runPass9' (for
-- @schema_objects@\/@schema_morphisms@).
materializeAllEdbViews :: DuckConn -> IO ()
materializeAllEdbViews conn = do
  DeadCodeRules.initDeadReachEdbViews conn
  SchemaRules.initEdbViews conn
  TaintRules.initTaintEdbViews conn

-- | Every Soufflé rule set run in Phase B. 'Souffle.runRuleSets' topologically
-- orders these by their IDB-output ∩ EDB-input edges, so the order listed
-- here is the stable tie-break for independent rule sets only — the real
-- ordering is data-driven. See 'runPhaseB' for the edge inventory.
allDatalogRuleSets :: [Souffle.RuleSet]
allDatalogRuleSets =
  [ DeadCodeRules.deadReachRules
  , DeadCodeRules.callerCountRules
  , DeadCodeRules.deadCodeRowsRules
  , SchemaRules.legRules
  , SchemaRules.reachesRules
  , SchemaRules.cosliceRules
  , DeadCodeRules.liveProcRules
  , TaintRules.taintRules
  ]

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

-- | Pass 6+7: compute interproc edges and taint classification ONCE
-- corpus-wide.  The BFS propagation (propagateTaint) and path
-- reconstruction (buildTaintPaths/buildTaintAnnotations) are now
-- handled by the Datalog rule set (TaintRules.taintRules) — this
-- pass only produces the EDB tables those rules read from.
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
  appendInterprocEdges   conn edges
  appendProcSummaries    conn summaries
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Taint classification" :: Text)])
  appendTaintSources     conn allSources
  appendTaintSinks       conn allSinks
  pure ()

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
