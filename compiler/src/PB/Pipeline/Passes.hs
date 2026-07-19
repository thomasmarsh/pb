{-# LANGUAGE StrictData #-}
module PB.Pipeline.Passes
  ( runPhaseB
  ) where

import PB.Prelude
import PB.AST.Ident            (Ident, identSetFromList, mkIdent)
import PB.Analysis.Builtins    (builtinFnNames, builtinMethodNames)
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TypeResolve
import PB.Analysis.SchemaCategory
  ( SchemaInputs (..), SchGraph (..), buildSchema )
import PB.Pipeline.DuckDb.Relations qualified as Relations
import PB.Pipeline.DuckDb.Relations (LegSourceFanout (..))
import PB.Analysis.DeadCodeReachability qualified as DeadCodeReachability
import PB.Analysis.SchemaClosure qualified as SchemaClosure
import PB.Analysis.TaintClosure qualified as TaintClosure
import PB.Pipeline.Progress qualified as Progress
import PB.Pipeline.DuckDb (Handle)
import PB.Pipeline.DuckDb.PhaseB.Query
  ( queryLocalVars, queryCallSites, queryGlobalVars, queryObjInfo
  , queryProcDefs, queryProcUses, queryResolvedCalls
  , queryTaintInputs, queryTaintIntraEdges, queryTaintReturnRows
  , queryDwRetrieveColumns, queryDwWriteColumns, queryDwWhereColumns
  , queryDwJoinLegs, querySqlCols
  , queryCatFootprintColumns
  , queryCatColumns, queryCatFks
  )
import PB.Pipeline.DuckDb.PhaseB.Append
  ( appendResolvedTypes, appendResolvedCalls
  , appendInterprocEdges, appendProcSummaries
  , appendTaintSources, appendTaintSinks
  , appendSchemaObjects, appendSchemaMorphisms
  )
import PB.Pipeline.DuckDb.Materialize
  ( materializeDecompositionCoslice
  , materializeImpliedFk
  , materializeImpliedFkPairs
  , materializeColumnRisk
  , materializeRiskCount
  , materializeDeadCode
  , materializeLiveProc
  , materializeCallerCounts
  , materializeDeadCodeRows
  , materializeTaintPaths
  , materializeTaintAnnotations
  )

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import Data.Time.Clock        (getCurrentTime)

-- | Phase B computes the five relation materializers directly in DuckDB
-- (see 'PB.Pipeline.DuckDb.materializeImpliedFkPairs',
-- 'PB.Pipeline.DuckDb.materializeRiskCount',
-- 'PB.Pipeline.DuckDb.materializeLiveProc',
-- 'PB.Pipeline.DuckDb.materializeCallerCounts',
-- 'PB.Pipeline.DuckDb.materializeDeadCodeRows'), invoked in 'runPhaseB' after
-- the input relation views are built. Per-relation progress is folded into the ordinary
-- 'Progress.timedStep' events.

-- | Characterize @leg_source@'s (x, y) key fan-in (see
-- 'PB.Pipeline.DuckDb.Relations.legSourceFanout' for the O(group_size^2)
-- aggregate blow-up this guards against). Always emits a one-line summary;
-- additionally emits a @warning@ event when the largest group looks
-- disproportionate -- 500 is a heuristic threshold, not a proven safe bound:
-- 'leg_source' has only ~3 distinct @kind@ buckets, so a group this size is
-- almost certainly duplicate/near-duplicate extraction on one schema edge
-- rather than legitimate diversity, and is worth an operator's attention.
reportLegSourceFanout :: Handle -> IO ()
reportLegSourceFanout conn = do
  t0 <- getCurrentTime
  LegSourceFanout total keys maxGroup <- Relations.legSourceFanout conn
  t1 <- getCurrentTime
  let n = T.pack . show
  Progress.emitEvent (Progress.EvStep
    ("leg_source -- " <> n total <> " rows, "
      <> n keys <> " keys, max " <> n maxGroup <> " rows/key")
    (Just (Progress.msBetween t0 t1)) [("leg_source", total)] [] Nothing)
  when (maxGroup > 500) $ Progress.emitEvent (Progress.EvWarning
    ("leg_source has a key with " <> n maxGroup <> " duplicate rows \
     \(out of " <> n total <> " total, " <> n keys <> " distinct keys) \
     \-- unusually large fan-in on one schema edge, likely duplicate/\
     \near-duplicate extraction rather than legitimate diversity; \
     \worth investigating the source before trusting downstream leg/reaches results"))

-- | Characterize @proc_defs@\/@proc_uses@ key fan-in (by (object, proc_name,
-- line) and (object, proc_name) respectively) before the taint closure
-- runs -- mirrors 'reportLegSourceFanout' above, since a duplicate-key
-- fan-in blowup is the established failure shape in this neighborhood
-- (leg_source, taint_reaches both hit it previously; see
-- compiler/CLAUDE.md's Code Index).
reportTaintDefUseFanout :: Handle -> IO ()
reportTaintDefUseFanout conn = do
  t0 <- getCurrentTime
  defFo <- Relations.defLineFanout conn
  t1 <- getCurrentTime
  retFo <- Relations.returnUseFanout conn
  t2 <- getCurrentTime
  let n = T.pack . show
      report relName label elapsedMs (Relations.DefUseFanout total keys maxGroup) = do
        Progress.emitEvent (Progress.EvStep
          (label <> " -- " <> n total <> " rows, "
            <> n keys <> " keys, max " <> n maxGroup <> " rows/key")
          (Just elapsedMs) [(relName, total)] [] Nothing)
        when (maxGroup > 500) $ Progress.emitEvent (Progress.EvWarning
          (label <> " has a key with " <> n maxGroup
            <> " duplicate rows (out of " <> n total <> " total, " <> n keys
            <> " distinct keys) -- unusually large fan-in, likely duplicate/\
               \near-duplicate extraction rather than legitimate diversity"))
  report ("proc_defs" :: Text) ("proc_defs (object,proc,line)" :: Text)
    (Progress.msBetween t0 t1) defFo
  report ("proc_uses_return" :: Text) ("proc_uses return (object,proc)" :: Text)
    (Progress.msBetween t1 t2) retFo

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Structured as two sub-phases:
--
-- * **B1 (Haskell + input relation materialization):** the analyses that can't be
--   expressed as pure SQL run here — type/call resolution
--   ('runPass5', populating @resolved_calls@), interproc-edge and taint
--   analysis, including the taint closure itself
--   ('runPass67' — @taint_reaches@\/@taint_confirmed@ are materialized by 'TaintClosure.materializeTaintClosure'), and
--   schema-category construction
--   ('runPass9', populating @schema_objects@\/@schema_morphisms@). Then
--   'materializeAllRelationsViews' creates every input relation the
--   downstream materializers assume: the dead-code input relations
--   ('Relations.initDeadCodeRelations', over @procedures@\/
--   @resolved_calls@\/@objects@), @proc_dead@ itself
--   ('DeadCodeReachability.materializeDeadCodeClosure'), and the
--   schema input relations
--   ('Relations.initSchemaRelations', over @schema_morphisms@\/
--   @schema_objects@).
-- * **B2 (SQL materializers):** the five relation materializers run as direct
--   DuckDB SQL, in dependency order after the input relation views exist:
--   'PB.Pipeline.DuckDb.materializeImpliedFkPairs' (consumed by
--   'materializeImpliedFk'), 'PB.Pipeline.DuckDb.materializeRiskCount'
--   (consumed by 'materializeColumnRisk'),
--   'PB.Pipeline.DuckDb.materializeLiveProc' (the @live_proc@ table the CLI
--   reads), 'PB.Pipeline.DuckDb.materializeCallerCounts', and finally
--   'PB.Pipeline.DuckDb.materializeDeadCodeRows' (which depends on the
--   @confidence@\/@caller_count_*@ tables the previous step built, and is
--   consumed by 'materializeDeadCode'). The only sequencing that remains
--   manual is the Phase A→B boundary enforced by B1 (the input relation views' source
--   tables must be populated before the views are created), which is a
--   genuine data dependency. Finally the two SQL materializers project derived
--   output tables into their API-facing shapes (@dead_code_rows@→@dead_code@,
--   @path_leg_fwd@\/@path_leg_back@→@decomposition_coslice@).
runPhaseB :: Handle -> Maybe Text -> IO ()
runPhaseB conn mDefaultNamespace = do
  Progress.emitEvent (Progress.EvPhase "B")
  -- B1: prerequisite Haskell analyses + input relation materialization.
  _   <- runPass5  conn
  runPass67 conn
  sch <- runPass9 conn mDefaultNamespace
  Progress.emitEvent (Progress.EvStep
    ("Schema category built: " <> T.pack (show (Set.size (sgObjects sch)))
      <> " objects, " <> T.pack (show (length (sgLegs sch))) <> " legs")
    Nothing []
    [ ("schema_objects", Set.size (sgObjects sch))
    , ("schema_morphisms", length (sgLegs sch))
    ]
    Nothing)
  materializeAllRelationsViews conn
  -- B2: the five SQL materializers run in dependency order. Characterize
  -- leg_source's key
  -- fan-in first (see reportLegSourceFanout) -- cheap, and surfaces a
  -- pathological corpus shape before the materialization rather than only
  -- via its wall-clock/memory symptoms.
  reportLegSourceFanout conn
  Progress.emitEvent (Progress.EvStep "Phase B analysis (SQL)" Nothing [] [] Nothing)
  materializeImpliedFkPairs conn
  materializeRiskCount conn
  materializeLiveProc conn
  materializeCallerCounts conn
  materializeDeadCodeRows conn
  materializeDeadCode conn
  materializeDecompositionCoslice conn
  materializeImpliedFk conn
  materializeColumnRisk conn
  materializeTaintPaths conn
  materializeTaintAnnotations conn

-- | Materialize every input relation view the downstream SQL materializers assume
-- already exist. Each 'initXRelations' is idempotent (@CREATE OR
-- REPLACE VIEW@); together they cover the dead-code and schema input relation layers.
-- Must run after 'runPass5' (for @resolved_calls@) and 'runPass9' (for
-- @schema_objects@\/@schema_morphisms@).
materializeAllRelationsViews :: Handle -> IO ()
materializeAllRelationsViews conn = do
  Progress.timedStep "Dead-code relations materialized" $ Relations.initDeadCodeRelations conn
  Progress.timedStep "Dead-code closure" $ DeadCodeReachability.materializeDeadCodeClosure conn
  Progress.timedStep "Schema relations materialized" $ Relations.initSchemaRelations conn
  Progress.timedStep "Schema closure" $ SchemaClosure.materializeSchemaClosure conn
  reportTaintDefUseFanout conn

-- | The five relation materializers run as direct DuckDB SQL, invoked in
-- dependency order inside 'runPhaseB' (see 'PB.Pipeline.DuckDb.materializeImpliedFkPairs',
-- 'PB.Pipeline.DuckDb.materializeRiskCount', 'PB.Pipeline.DuckDb.materializeLiveProc',
-- 'PB.Pipeline.DuckDb.materializeCallerCounts', 'PB.Pipeline.DuckDb.materializeDeadCodeRows').
-- The taint, dead-reach, and schema-coslice relations are produced
-- algebraically (Haskell or SQL); the schema/dead-code consumers read the
-- same pre-materialized input tables they always did.

runPass5 :: Handle -> IO (Map.Map Ident Ident)
runPass5 conn = Progress.timedStep "Resolving types" $ do
  lvs                              <- queryLocalVars  conn
  css                              <- queryCallSites  conn
  (objSet, usrTypes, inh, procMap) <- queryObjInfo   conn
  let rt = resolveTypes lvs (identSetFromList (map mkIdent (Set.toList objSet)))
                             (identSetFromList (map mkIdent (Set.toList usrTypes)))
      rc = resolveCalls css procMap inh builtinFnNames builtinMethodNames
  appendResolvedTypes conn rt
  appendResolvedCalls conn rc
  pure inh

-- | Pass 6+7: compute interproc edges and taint classification ONCE
-- corpus-wide, then the taint closure itself (@taint_reaches@\/
-- @taint_confirmed@) and the witness-path table (@taint_step_kind@) via
-- the algebraic Kleene-star closure ('TaintClosure.materializeTaintClosure'\/
-- 'TaintClosure.materializeTaintStepKind') — production's source for all
-- three tables. Neither depends on a DB round-trip: both read straight off
-- the same in-memory rows this pass already built.
runPass67 :: Handle -> IO ()
runPass67 conn = Progress.timedStep "Building call graph" $ do
  gvs  <- queryGlobalVars     conn
  defs <- queryProcDefs       conn
  uses <- queryProcUses       conn
  allRC <- queryResolvedCalls conn
  tfis  <- queryTaintInputs   conn
  intraEdges <- queryTaintIntraEdges conn
  returnRows <- queryTaintReturnRows conn
  let globalVarNames = Set.fromList (map (mkIdent . gvName) gvs)
      allProcMetas   = concatMap Taint.tfiProcMetas tfis
      allSqlStmts    = concatMap Taint.tfiSqlStmts  tfis
      edges          = Taint.buildInterprocEdges allRC defs uses globalVarNames allProcMetas
      summaries      = Taint.buildProcedureSummaries edges defs uses globalVarNames allProcMetas
      allSources     = Taint.classifySources allSqlStmts allProcMetas
      allSinks       = Taint.classifySinks   allSqlStmts
  appendInterprocEdges   conn edges
  appendProcSummaries    conn summaries
  Progress.timedStep "Taint classification" $ do
    appendTaintSources     conn allSources
    appendTaintSinks       conn allSinks
  Progress.timedStep "Taint closure" $
    TaintClosure.materializeTaintClosure allSources allSinks intraEdges returnRows edges conn
  Progress.timedStep "Taint witness paths" $
    TaintClosure.materializeTaintStepKind allSources allSinks intraEdges returnRows edges conn

-- | Pass 9 (Plan 148 Phase 1b; default-namespace resolution added Plan 157
-- Phase 1): materialize the schema category @Sch@ from Phase A's
-- DW-retrieve/DW-join/SQL-column/DDL-catalog tables. Returns the graph so
-- Pass 10 can traverse it without rebuilding from DB rows.
runPass9 :: Handle -> Maybe Text -> IO SchGraph
runPass9 conn mDefaultNamespace = Progress.timedStep "Building schema category" $ do
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
