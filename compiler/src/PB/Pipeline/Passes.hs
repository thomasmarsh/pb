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
  ( SchemaInputs (..), SchGraph (..), buildSchema, CatFkRow )
import PB.Pipeline.DuckDb.Relations qualified as Relations
import PB.Pipeline.DuckDb.Relations (LegSourceFanout (..))
import PB.Analysis.DeadCodeReachability qualified as DeadCodeReachability
import PB.Analysis.SchemaClosure qualified as SchemaClosure
import PB.Analysis.TaintClosure qualified as TaintClosure
import PB.Pipeline.Progress qualified as Progress
import PB.Pipeline.DuckDb (Handle)
import PB.Pipeline.DuckDb.PhaseB.Query
  ( queryLocalVars, queryCallSites, queryGlobalVars, queryObjInfo
  , queryCallableProcMap
  , queryProcDefs, queryProcUses, ProcRows (..), queryResolvedCalls
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
  , materializeTaintPaths
  , materializeTaintAnnotations
  )

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import Data.Time.Clock        (getCurrentTime)

-- | Phase B computes the relation materializers directly in DuckDB
-- (see 'PB.Pipeline.DuckDb.materializeImpliedFkPairs',
-- 'PB.Pipeline.DuckDb.materializeRiskCount',
-- 'PB.Pipeline.DuckDb.materializeLiveProc', 'PB.Pipeline.DuckDb.materializeDeadCode'),
-- invoked in 'runPhaseB' after
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
diagnoseLegSourceFanout :: Handle -> IO ()
diagnoseLegSourceFanout conn = do
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
-- runs -- mirrors 'diagnoseLegSourceFanout' above, since a duplicate-key
-- fan-in blowup is the established failure shape in this neighborhood
-- (leg_source, taint_reaches both hit it previously; see
-- compiler/CLAUDE.md's Code Index).
diagnoseTaintFanout :: Handle -> IO ()
diagnoseTaintFanout conn = do
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

-- | Time a single DB read and report its row count under 'label' -- splits
-- the "Load taint inputs (7 queries)" step (buildCallGraphAndTaint) so a private-corpus
-- run can attribute that step's cost to a specific query/table instead of
-- one opaque combined number (doc/plan/187-perf-hotspots.md §14).
timedQueryRows :: Text -> IO [a] -> IO [a]
timedQueryRows label action = Progress.timedStepRows label (do
  rows <- action
  pure (rows, [(label, length rows)]))

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Structured as two sub-phases:
--
-- * **B1 (Haskell + input relation materialization):** the analyses that can't be
--   expressed as pure SQL run here -- type/call resolution
--   ('resolveTypesAndCalls', populating @resolved_calls@), interproc-edge and taint
--   analysis, including the taint closure itself
--   ('buildCallGraphAndTaint' -- @taint_reaches@\/@taint_confirmed@ are materialized by 'TaintClosure.materializeTaintClosure'), and
--   schema-category construction
--   ('buildSchemaCategory', populating @schema_objects@\/@schema_morphisms@). Then
--   'initDeadCodeInput'\/'computeDeadCodeClosure'\/'initSchemaInput'\/'computeSchemaClosure'
--   create every input relation the downstream materializers assume: the
--   dead-code input relations
--   ('Relations.initDeadCodeRelations', over @procedures@\/
--   @resolved_calls@\/@objects@), @proc_dead@ itself
--   ('DeadCodeReachability.materializeDeadCodeClosure'), and the
--   schema input relations
--   ('Relations.initSchemaRelations', over @schema_morphisms@\/
--   @schema_objects@).
-- * **B2 (SQL materializers):** the relation materializers run as direct
--   DuckDB SQL, in dependency order after the input relation views exist:
--   'PB.Pipeline.DuckDb.materializeImpliedFkPairs' (consumed by
--   'materializeImpliedFk'), 'PB.Pipeline.DuckDb.materializeRiskCount'
--   (consumed by 'materializeColumnRisk'),
--   'PB.Pipeline.DuckDb.materializeLiveProc' (the @live_proc@ table the CLI
--   reads), and 'PB.Pipeline.DuckDb.materializeDeadCode' (a single CTE chain
--   straight from @proc_dead@\/@proc_meta@\/@call_ref@\/@resolved_call_edge@
--   to @dead_code@ -- Plan 198 Phase A collapsed the prior 8-table
--   intermediate chain). The only sequencing that remains
--   manual is the Phase A->B boundary enforced by B1 (the input relation views' source
--   tables must be populated before the views are created), which is a
--   genuine data dependency. Finally the schema materializer projects its
--   derived output table into its API-facing shape (@path_leg_fwd@\/
--   @path_leg_back@->@decomposition_coslice@).
runPhaseB :: Handle -> Maybe Text -> IO ()
runPhaseB conn mDefaultNamespace = do
  Progress.emitEvent (Progress.EvPhase "B")
  -- B1: prerequisite Haskell analyses + input relation materialization.
  _        <- resolveTypesAndCalls conn
  procRows <- buildCallGraphAndTaint conn
  -- catalog_fks is read once here and threaded into both buildSchemaCategory
  -- (which builds the schema category from it) and initSchemaInput (which
  -- builds the fk relation from it) -- the same
  -- rows, nothing writes to catalog_fks between the two uses (Plan 187 §18
  -- tier 2).
  catFks <- queryCatFks conn
  _   <- buildSchemaCategory conn mDefaultNamespace catFks
  dcRows <- initDeadCodeInput conn
  computeDeadCodeClosure dcRows conn
  schRows <- initSchemaInput conn catFks
  computeSchemaClosure schRows conn
  diagnoseTaintFanout conn
  -- B2: the five SQL materializers run in dependency order. Characterize
  -- leg_source's key
  -- fan-in first (see diagnoseLegSourceFanout) -- cheap, and surfaces a
  -- pathological corpus shape before the materialization rather than only
  -- via its wall-clock/memory symptoms.
  diagnoseLegSourceFanout conn
  Progress.emitEvent (Progress.EvStep "Phase B analysis (SQL)" Nothing [] [] Nothing)
  materializeImpliedFkPairs conn
  materializeRiskCount conn
  materializeLiveProc conn
  materializeDeadCode conn
  materializeDecompositionCoslice conn
  materializeImpliedFk conn
  materializeColumnRisk conn
  materializeTaintPaths conn
  materializeTaintAnnotations procRows conn

-- | Materialize the dead-code input relations view (@proc@\/@entry@\/
-- @inherits@\/@call_ref@\/@resolved_call_edge@\/@calls@\/@proc_meta@).
-- Idempotent (@CREATE OR REPLACE VIEW@). Must run after
-- 'resolveTypesAndCalls' (for @resolved_calls@).
initDeadCodeInput :: Handle -> IO Relations.DeadCodeInputRows
initDeadCodeInput conn =
  Progress.timedStep "Dead-code relations materialized" $ Relations.initDeadCodeRelations conn

-- | Dead-code reachability closure over 'initDeadCodeInput''s rows, writing
-- @proc_dead@.
computeDeadCodeClosure :: Relations.DeadCodeInputRows -> Handle -> IO ()
computeDeadCodeClosure dcRows conn =
  Progress.timedStep "Dead-code closure" $ DeadCodeReachability.materializeDeadCodeClosure dcRows conn

-- | Materialize the schema input relations view (@leg_source@\/@stmt@\/
-- @seed@\/@join_leg@\/@fk@). Idempotent (@CREATE OR REPLACE VIEW@). Must run
-- after 'buildSchemaCategory' (for @schema_objects@\/@schema_morphisms@).
--
-- @catFks@ is the same rows 'runPhaseB' already fetched for
-- 'buildSchemaCategory'; threaded here instead of re-querying @catalog_fks@
-- (Plan 187 §18 tier 2).
initSchemaInput :: Handle -> [CatFkRow] -> IO Relations.SchemaInputRows
initSchemaInput conn catFks =
  Progress.timedStep "Schema relations materialized" $ Relations.initSchemaRelations conn catFks

-- | Schema transitive closure + coslice paths (@reaches@\/@path_leg_fwd@\/
-- @path_leg_back@) over 'initSchemaInput''s rows.
computeSchemaClosure :: Relations.SchemaInputRows -> Handle -> IO ()
computeSchemaClosure schRows conn =
  Progress.timedStep "Schema closure" $ SchemaClosure.materializeSchemaClosure schRows conn

-- | The relation materializers run as direct DuckDB SQL, invoked in
-- dependency order inside 'runPhaseB' (see 'PB.Pipeline.DuckDb.materializeImpliedFkPairs',
-- 'PB.Pipeline.DuckDb.materializeRiskCount', 'PB.Pipeline.DuckDb.materializeLiveProc',
-- 'PB.Pipeline.DuckDb.Materialize.materializeDeadCode').
-- The taint, dead-reach, and schema-coslice relations are produced
-- algebraically (Haskell or SQL); the schema/dead-code consumers read the
-- same pre-materialized input tables they always did.

resolveTypesAndCalls :: Handle -> IO (Map.Map Ident Ident)
resolveTypesAndCalls conn = Progress.timedStep "Resolving types" $ do
  lvs                              <- queryLocalVars  conn
  gvs                              <- queryGlobalVars conn
  css                              <- queryCallSites  conn
  (objSet, usrTypes, inh, procMap) <- queryObjInfo   conn
  callableProcMap                  <- queryCallableProcMap conn
  let objIdents  = identSetFromList (map mkIdent (Set.toList objSet))
      userIdents = identSetFromList (map mkIdent (Set.toList usrTypes))
      rt  = resolveTypes lvs objIdents userIdents
      rtG = resolveGlobalTypes gvs objIdents userIdents
      rc  = resolveCalls css procMap callableProcMap inh builtinFnNames builtinMethodNames
  appendResolvedTypes conn (rt <> rtG)
  appendResolvedCalls conn rc
  pure inh

-- | Interproc edges and taint classification ONCE
-- corpus-wide, then the taint closure itself (@taint_reaches@\/
-- @taint_confirmed@) and the witness-path table (@taint_step_kind@) via
-- the algebraic closure ('TaintClosure.materializeTaintClosure'\/
-- 'TaintClosure.materializeTaintStepKind') -- production's source for all
-- three tables. Neither depends on a DB round-trip: both read straight off
-- the same in-memory rows this pass already built.
--
-- Returns the @proc_defs@\/@proc_uses@ rows fetched here as 'ProcRows',
-- threaded by 'runPhaseB' into 'PB.Pipeline.DuckDb.materializeTaintAnnotations'
-- (run much later in Phase B2) instead of it re-querying the same two
-- tables (Plan 187 §18 tier 3).
buildCallGraphAndTaint :: Handle -> IO ProcRows
buildCallGraphAndTaint conn = Progress.timedStep "Building call graph" $ do
  (gvs, defs, uses, allRC, tfis, intraEdges, returnRows) <-
    Progress.timedStep "Load taint inputs (7 queries)" $ do
      gvs  <- timedQueryRows "  queryGlobalVars"       (queryGlobalVars     conn)
      defs <- timedQueryRows "  queryProcDefs"         (queryProcDefs       conn)
      uses <- timedQueryRows "  queryProcUses"         (queryProcUses       conn)
      allRC <- timedQueryRows "  queryResolvedCalls"   (queryResolvedCalls  conn)
      tfis  <- timedQueryRows "  queryTaintInputs"     (queryTaintInputs    conn)
      intraEdges <- timedQueryRows "  queryTaintIntraEdges" (queryTaintIntraEdges conn)
      returnRows <- timedQueryRows "  queryTaintReturnRows" (queryTaintReturnRows conn)
      pure (gvs, defs, uses, allRC, tfis, intraEdges, returnRows)
  (allSources, allSinks, edges) <-
    Progress.timedStep "Build interproc edges + summaries + classify" $ do
      let globalVarNames = Set.fromList (map (mkIdent . gvName) gvs)
          allProcMetas   = concatMap Taint.tfiProcMetas tfis
          allSqlStmts    = concatMap Taint.tfiSqlStmts  tfis
          edges          = Taint.buildInterprocEdges allRC defs uses globalVarNames allProcMetas
          summaries      = Taint.buildProcedureSummaries edges defs uses globalVarNames allProcMetas
          allSources     = Taint.classifySources allSqlStmts allProcMetas
          allSinks       = Taint.classifySinks   allSqlStmts
      appendInterprocEdges   conn edges
      appendProcSummaries    conn summaries
      pure (allSources, allSinks, edges)
  Progress.timedStep "Taint classification" $ do
    appendTaintSources     conn allSources
    appendTaintSinks       conn allSinks
  let taintClosure = TaintClosure.buildTaintClosure intraEdges returnRows edges allSources
  Progress.timedStep "Taint closure" $
    TaintClosure.materializeTaintClosure taintClosure allSources allSinks conn
  Progress.timedStep "Taint witness paths" $
    TaintClosure.materializeTaintStepKind taintClosure allSources allSinks conn
  pure ProcRows { prDefs = defs, prUses = uses }

-- | Pass 9 (Plan 148 Phase 1b; default-namespace resolution added Plan 157
-- Phase 1): materialize the schema category @Sch@ from Phase A's
-- DW-retrieve/DW-join/SQL-column/DDL-catalog tables. Returns the graph so
-- Pass 10 can traverse it without rebuilding from DB rows.
--
-- @catFks@ is taken as a parameter rather than queried here: 'runPhaseB'
-- fetches it once and passes the same rows to both this function and
-- 'PB.Pipeline.DuckDb.Relations.initSchemaRelations', which independently
-- needs it to build the @fk@ relation (Plan 187 §18 tier 2 -- no re-query of
-- @catalog_fks@).
buildSchemaCategory :: Handle -> Maybe Text -> [CatFkRow] -> IO SchGraph
buildSchemaCategory conn mDefaultNamespace catFks = Progress.timedStep "Building schema category" $ do
  drCols  <- queryDwRetrieveColumns  conn
  dwCols  <- queryDwWriteColumns     conn
  dwhCols <- queryDwWhereColumns     conn
  djLegs  <- queryDwJoinLegs         conn
  sqlCols <- querySqlCols            conn
  cfCols  <- queryCatFootprintColumns conn
  catCols <- queryCatColumns         conn
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
  Progress.emitEvent (Progress.EvStep
    ("Schema category built: " <> T.pack (show (Set.size (sgObjects sch)))
      <> " objects, " <> T.pack (show (length (sgLegs sch))) <> " legs")
    Nothing []
    [ ("schema_objects", Set.size (sgObjects sch))
    , ("schema_morphisms", length (sgLegs sch))
    ]
    Nothing)
  pure sch
