{-# LANGUAGE StrictData #-}
{-# LANGUAGE RecordWildCards #-}
module PB.Pipeline.Passes
  ( runPhaseB
  , PhaseAData (..)
  , emptyPhaseAData
  ) where

import PB.Prelude
import PB.AST.Ident            (Ident, IdentMap, IdentSet, identSetFromList, mkIdent)
import PB.Analysis.Builtins    (builtinFnNames, builtinMethodNames)
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TaintEdges  qualified as TaintEdges
import PB.Analysis.TypeResolve
import PB.Analysis.TaintEdges (TaintIntraEdgeRow, TaintReturnRow)
import PB.Analysis.SchemaCategory
  ( SchemaInputs (..), SchGraph (..), buildSchema, CatFkRow
  , SchObject (..), SchMorphism (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..), CatColumnRow (..)
  )
import PB.Pipeline.DuckDb.Relations qualified as Relations
import PB.Pipeline.DuckDb.Relations (LegSourceFanout (..), SchemaInputRows (..))
import PB.Analysis.DeadCodeReachability qualified as DeadCodeReachability
import PB.Analysis.SchemaClosure qualified as SchemaClosure
import PB.Analysis.TaintClosure qualified as TaintClosure
import PB.Pipeline.Progress qualified as Progress
import PB.Pipeline.DuckDb (Handle)
import PB.Pipeline.DuckDb.PhaseB.Query
  ( queryObjInfo
  , queryCallableProcMap
  , ProcRows (..)
  , queryTaintInputs
  , querySqlCols
  , queryCatColumns, queryCatFks
  , DeadCodeClosureReady (..), SchemaClosureReady (..), CallGraphAndTaintReady (..)
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

-- | Accumulated Phase A data that Phase B would otherwise re-read from
-- DuckDB. One list per compiler-only table, concatenated across all
-- compiled files. Populated in 'PB.Pipeline.Runner.runModeDb' and threaded
-- into 'runPhaseB', replacing DuckDB query calls.
data PhaseAData = PhaseAData
  { padLocalVars         :: ![LocalVar]
  , padCatFootprintCols  :: ![SqlColRow]
  , padTaintIntraEdges   :: ![TaintIntraEdgeRow]
  , padTaintReturnRows   :: ![TaintReturnRow]
  , padDwWriteColumns    :: ![DwRetrieveColRow]
  , padDwWhereColumns    :: ![DwRetrieveColRow]
  , padProcDefs          :: ![Taint.DefRow]
  , padProcUses          :: ![Taint.UseRow]
  , padGlobalVars        :: ![GlobalVar]
  , padCallSites         :: ![CallSite]
  , padDwRetrieveColumns :: ![DwRetrieveColRow]
  , padDwJoinLegs        :: ![DwJoinLegRow]
  } deriving (Eq, Show)

-- | Empty initial 'PhaseAData'.
emptyPhaseAData :: PhaseAData
emptyPhaseAData = PhaseAData [] [] [] [] [] [] [] [] [] [] [] []

-- | Proof-of-completion token for 'resolveTypesAndCalls': minted once
-- @resolved_calls@ is populated, consumed by 'buildCallGraphAndTaint' and
-- 'initDeadCodeInput'. Constructor NOT exported from this module.
newtype ResolvedCallsReady = ResolvedCallsReady [ResolvedCall]

-- | All DuckDB rows 'resolveTypesAndCalls' fetches before its pure transform.
data ResolveInputs = ResolveInputs
  { riLocalVars       :: ![LocalVar]
  , riGlobalVars      :: ![GlobalVar]
  , riCallSites       :: ![CallSite]
  , riObjSet          :: !(Set.Set Text)
  , riUsrTypes        :: !(Set.Set Text)
  , riInherits        :: !(Map.Map Ident Ident)
  , riProcMap         :: !(IdentMap IdentSet)
  , riCallableProcMap :: !(IdentMap IdentSet)
  }

-- | The two row lists 'resolveTypesAndCalls' produces for its sink.
data ResolvedOutput = ResolvedOutput
  { roResolvedTypes :: ![ResolvedType]
  , roResolvedCalls :: ![ResolvedCall]
  }

-- | All DuckDB rows 'buildCallGraphAndTaint' fetches before its pure transform.
data CallGraphInputs = CallGraphInputs
  { cgiGlobalVars    :: ![GlobalVar]
  , cgiProcDefs      :: ![Taint.DefRow]
  , cgiProcUses      :: ![Taint.UseRow]
  , cgiResolvedCalls :: ![Taint.ResolvedCallRow]
  , cgiTaintInputs   :: ![Taint.TaintFileInputs]
  , cgiIntraEdges    :: ![TaintEdges.TaintIntraEdgeRow]
  , cgiReturnRows    :: ![TaintEdges.TaintReturnRow]
  }

-- | Everything 'buildCallGraphAndTaint' pushes back into DuckDB.
data CallGraphOutput = CallGraphOutput
  { coInterprocEdges :: ![Taint.InterprocEdge]
  , coProcSummaries  :: ![Taint.ProcedureSummary]
  , coTaintSources   :: ![Taint.TaintSource]
  , coTaintSinks     :: ![Taint.TaintSink]
  , coTaintClosure   :: !TaintClosure.TaintClosure
  }

-- | All DuckDB rows 'buildSchemaCategory' fetches before its pure transform.
data SchemaCategoryInputs = SchemaCategoryInputs
  { sciDwRetrieveColumns :: ![DwRetrieveColRow]
  , sciDwWriteColumns    :: ![DwRetrieveColRow]
  , sciDwWhereColumns    :: ![DwRetrieveColRow]
  , sciDwJoinLegs        :: ![DwJoinLegRow]
  , sciSqlCols           :: ![SqlColRow]
  , sciCatFootprintCols  :: ![SqlColRow]
  , sciCatColumns        :: ![CatColumnRow]
  }

-- | Everything 'buildSchemaCategory' pushes back into DuckDB.
data SchemaCategoryOutput = SchemaCategoryOutput
  { scoObjects :: ![SchObject]
  , scoLegs    :: ![SchMorphism]
  }

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
diagnoseLegSourceFanout :: Handle -> SchemaInputRows -> IO ()
diagnoseLegSourceFanout conn _schRows = do
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
runPhaseB :: Handle -> Maybe Text -> PhaseAData -> IO ()
runPhaseB conn mDefaultNamespace pad = do
  Progress.emitEvent (Progress.EvPhase "B")
  -- B1: prerequisite Haskell analyses + input relation materialization.
  (_inh, rcReady) <- resolveTypesAndCalls
    (fetchResolveInputs (padLocalVars pad) (padGlobalVars pad) (padCallSites pad) conn)
    (sinkResolvedOutput conn)
  -- Thread resolved_calls in-memory (Plan 208 Phase 2): extract from the
  -- proof token to avoid re-querying DuckDB for Phase B's own data.
  let ResolvedCallsReady rc = rcReady
      resolvedCallRows = map resolvedCallToRow rc
  (procRows, cgReady) <- buildCallGraphAndTaint rcReady
    (fetchCallGraphInputs conn (padGlobalVars pad) (padTaintIntraEdges pad) (padTaintReturnRows pad) resolvedCallRows (padProcDefs pad) (padProcUses pad))
    (sinkCallGraphOutput conn)
  catFks <- queryCatFks conn
  schGraph <- buildSchemaCategory mDefaultNamespace catFks
    (fetchSchemaCategoryInputs conn (padDwRetrieveColumns pad) (padDwJoinLegs pad) (padDwWriteColumns pad) (padDwWhereColumns pad) (padCatFootprintCols pad))
    (sinkSchemaCategoryOutput conn)
  dcRows  <- initDeadCodeInput conn rcReady
  dcReady <- computeDeadCodeClosure conn dcRows
  schRows <- initSchemaInput conn schGraph catFks
  scReady <- computeSchemaClosure conn schRows
  diagnoseTaintFanout conn
  diagnoseLegSourceFanout conn schRows
  -- B2: the SQL materializers run in dependency order.
  Progress.emitEvent (Progress.EvStep "Phase B analysis (SQL)" Nothing [] [] Nothing)
  fkPairsReady <- materializeImpliedFkPairs conn schRows
  riskReady    <- materializeRiskCount conn scReady
  materializeLiveProc conn dcReady schRows
  materializeDeadCode conn dcReady
  materializeDecompositionCoslice conn scReady schGraph
  materializeImpliedFk conn fkPairsReady schGraph
  materializeColumnRisk conn riskReady schGraph
  materializeTaintPaths conn cgReady
  materializeTaintAnnotations conn cgReady procRows

-- ---------------------------------------------------------------------------
-- Fetch/sink helpers for the shape-1 stages (constructed once in runPhaseB,
-- closed over a real Handle)

fetchResolveInputs :: [LocalVar] -> [GlobalVar] -> [CallSite] -> Handle -> IO ResolveInputs
fetchResolveInputs lvs gvs css conn = do
  (objSet, usrTypes, inh, procMap) <- queryObjInfo     conn
  callableProcMap                  <- queryCallableProcMap conn
  pure ResolveInputs
    { riLocalVars       = lvs
    , riGlobalVars      = gvs
    , riCallSites       = css
    , riObjSet          = objSet
    , riUsrTypes        = usrTypes
    , riInherits        = inh
    , riProcMap         = procMap
    , riCallableProcMap = callableProcMap
    }

sinkResolvedOutput :: Handle -> ResolvedOutput -> IO ()
sinkResolvedOutput conn ResolvedOutput{..} = do
  appendResolvedTypes conn roResolvedTypes
  appendResolvedCalls conn roResolvedCalls

fetchCallGraphInputs :: Handle -> [GlobalVar] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [Taint.ResolvedCallRow] -> [Taint.DefRow] -> [Taint.UseRow] -> IO CallGraphInputs
fetchCallGraphInputs conn globalVars intraEdges returnRows resolvedCallRows procDefs procUses =
  Progress.timedStep "Load taint inputs (1 query + 6 in-memory)" $ do
    tfis       <- timedQueryRows "  queryTaintInputs"       (queryTaintInputs     conn)
    pure CallGraphInputs
      { cgiGlobalVars    = globalVars
      , cgiProcDefs      = procDefs
      , cgiProcUses      = procUses
      , cgiResolvedCalls = resolvedCallRows
      , cgiTaintInputs   = tfis
      , cgiIntraEdges    = intraEdges
      , cgiReturnRows    = returnRows
      }

sinkCallGraphOutput :: Handle -> CallGraphOutput -> IO ()
sinkCallGraphOutput conn CallGraphOutput{..} = do
  Progress.timedStep "Build interproc edges + summaries + classify" $ do
    appendInterprocEdges conn coInterprocEdges
    appendProcSummaries  conn coProcSummaries
  Progress.timedStep "Taint classification" $ do
    appendTaintSources   conn coTaintSources
    appendTaintSinks     conn coTaintSinks
  Progress.timedStep "Taint closure" $
    TaintClosure.materializeTaintClosure coTaintClosure coTaintSources coTaintSinks conn
  Progress.timedStep "Taint witness paths" $
    TaintClosure.materializeTaintStepKind coTaintClosure coTaintSources coTaintSinks conn

fetchSchemaCategoryInputs :: Handle -> [DwRetrieveColRow] -> [DwJoinLegRow] -> [DwRetrieveColRow] -> [DwRetrieveColRow] -> [SqlColRow] -> IO SchemaCategoryInputs
fetchSchemaCategoryInputs conn dwRetrieveCols dwJoinLegs dwWriteCols dwWhereCols cfCols =
  Progress.timedStep "Load schema-category inputs (2 queries + 5 in-memory)" $ do
    sqlCols <- timedQueryRows "  querySqlCols"             (querySqlCols             conn)
    catCols <- timedQueryRows "  queryCatColumns"          (queryCatColumns          conn)
    pure SchemaCategoryInputs
      { sciDwRetrieveColumns = dwRetrieveCols
      , sciDwWriteColumns    = dwWriteCols
      , sciDwWhereColumns    = dwWhereCols
      , sciDwJoinLegs        = dwJoinLegs
      , sciSqlCols           = sqlCols
      , sciCatFootprintCols  = cfCols
      , sciCatColumns        = catCols
      }

sinkSchemaCategoryOutput :: Handle -> SchemaCategoryOutput -> IO ()
sinkSchemaCategoryOutput conn SchemaCategoryOutput{..} = do
  appendSchemaObjects   conn scoObjects
  appendSchemaMorphisms conn scoLegs
  Progress.emitEvent (Progress.EvStep
    ("Schema category built: " <> T.pack (show (length scoObjects))
      <> " objects, " <> T.pack (show (length scoLegs)) <> " legs")
    Nothing []
    [ ("schema_objects", length scoObjects)
    , ("schema_morphisms", length scoLegs)
    ]
    Nothing)

-- | Materialize the dead-code input relations view (@proc@\/@entry@\/
-- @inherits@\/@call_ref@\/@resolved_call_edge@\/@calls@\/@proc_meta@).
-- Idempotent (@CREATE OR REPLACE VIEW@). Must run after
-- 'resolveTypesAndCalls' (for @resolved_calls@).
initDeadCodeInput :: Handle -> ResolvedCallsReady -> IO Relations.DeadCodeInputRows
initDeadCodeInput conn _rcReady =
  Progress.timedStep "Dead-code relations materialized" $ Relations.initDeadCodeRelations conn

-- | Dead-code reachability closure over 'initDeadCodeInput''s rows, writing
-- @proc_dead@.
computeDeadCodeClosure :: Handle -> Relations.DeadCodeInputRows -> IO DeadCodeClosureReady
computeDeadCodeClosure conn dcRows =
  Progress.timedStep "Dead-code closure" (DeadCodeReachability.materializeDeadCodeClosure dcRows conn)
    >> pure (DeadCodeClosureReady ())

-- | Materialize the schema input relations view (@leg_source@\/@stmt@\/
-- @seed@\/@join_leg@\/@fk@). Idempotent (@CREATE OR REPLACE VIEW@). Must run
-- after 'buildSchemaCategory' (for @schema_objects@\/@schema_morphisms@).
--
-- @catFks@ is the same rows 'runPhaseB' already fetched for
-- 'buildSchemaCategory'; threaded here instead of re-querying @catalog_fks@
-- (Plan 187 §18 tier 2).
initSchemaInput :: Handle -> SchGraph -> [CatFkRow] -> IO Relations.SchemaInputRows
initSchemaInput conn _schGraph catFks =
  Progress.timedStep "Schema relations materialized" $ Relations.initSchemaRelations conn catFks

-- | Schema transitive closure + coslice paths (@reaches@\/@path_leg_fwd@\/
-- @path_leg_back@) over 'initSchemaInput''s rows.
computeSchemaClosure :: Handle -> Relations.SchemaInputRows -> IO SchemaClosureReady
computeSchemaClosure conn schRows =
  Progress.timedStep "Schema closure" (SchemaClosure.materializeSchemaClosure schRows conn)
    >> pure (SchemaClosureReady ())

-- | The relation materializers run as direct DuckDB SQL, invoked in
-- dependency order inside 'runPhaseB' (see 'PB.Pipeline.DuckDb.materializeImpliedFkPairs',
-- 'PB.Pipeline.DuckDb.materializeRiskCount', 'PB.Pipeline.DuckDb.materializeLiveProc',
-- 'PB.Pipeline.DuckDb.Materialize.materializeDeadCode').
-- The taint, dead-reach, and schema-coslice relations are produced
-- algebraically (Haskell or SQL); the schema/dead-code consumers read the
-- same pre-materialized input tables they always did.

resolveTypesAndCalls
  :: IO ResolveInputs
  -> (ResolvedOutput -> IO ())
  -> IO (Map.Map Ident Ident, ResolvedCallsReady)
resolveTypesAndCalls fetchInputs sinkOutput = Progress.timedStep "Resolving types" $ do
  ResolveInputs{..} <- fetchInputs
  let objIdents  = identSetFromList (map mkIdent (Set.toList riObjSet))
      userIdents = identSetFromList (map mkIdent (Set.toList riUsrTypes))
      rt  = resolveTypes riLocalVars objIdents userIdents
      rtG = resolveGlobalTypes riGlobalVars objIdents userIdents
      rc  = resolveCalls riCallSites riProcMap riCallableProcMap riInherits builtinFnNames builtinMethodNames
  sinkOutput ResolvedOutput
    { roResolvedTypes = rt <> rtG
    , roResolvedCalls = rc
    }
  pure (riInherits, ResolvedCallsReady rc)

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
buildCallGraphAndTaint
  :: ResolvedCallsReady
  -> IO CallGraphInputs
  -> (CallGraphOutput -> IO ())
  -> IO (ProcRows, CallGraphAndTaintReady)
buildCallGraphAndTaint _rcReady fetchInputs sinkOutput = Progress.timedStep "Building call graph" $ do
  CallGraphInputs{..} <- fetchInputs
  let globalVarNames = Set.fromList (map (mkIdent . gvName) cgiGlobalVars)
      allProcMetas   = concatMap Taint.tfiProcMetas cgiTaintInputs
      allSqlStmts    = concatMap Taint.tfiSqlStmts  cgiTaintInputs
      edges          = Taint.buildInterprocEdges cgiResolvedCalls cgiProcDefs cgiProcUses globalVarNames allProcMetas
      summaries      = Taint.buildProcedureSummaries edges cgiProcDefs cgiProcUses globalVarNames allProcMetas
      allSources     = Taint.classifySources allSqlStmts allProcMetas
      allSinks       = Taint.classifySinks   allSqlStmts
      taintClosure   = TaintClosure.buildTaintClosure cgiIntraEdges cgiReturnRows edges allSources
  sinkOutput CallGraphOutput
    { coInterprocEdges = edges
    , coProcSummaries  = summaries
    , coTaintSources   = allSources
    , coTaintSinks     = allSinks
    , coTaintClosure   = taintClosure
    }
  pure (ProcRows { prDefs = cgiProcDefs, prUses = cgiProcUses }, CallGraphAndTaintReady ())

-- | Convert 'ResolvedCall' (TypeResolve) to 'Taint.ResolvedCallRow' for
-- in-memory threading (Plan 208 Phase 2). The return type field is always
-- 'Nothing' (the DuckDB table has no such column).
resolvedCallToRow :: ResolvedCall -> Taint.ResolvedCallRow
resolvedCallToRow ResolvedCall{..} = Taint.ResolvedCallRow
  { Taint.rcrFile           = rcFile
  , Taint.rcrObject         = rcObject
  , Taint.rcrFromProc       = rcFromProc
  , Taint.rcrToName         = rcToName
  , Taint.rcrCallType       = rcCallType
  , Taint.rcrCallLine       = rcLine
  , Taint.rcrTargetObject   = rcTargetObject
  , Taint.rcrTargetProc     = rcTargetProc
  , Taint.rcrResolutionKind = rcKind
  , Taint.rcrConfidence     = rcConfidence
  , Taint.rcrReturnType     = Nothing
  , Taint.rcrSpan           = rcSpan
  }

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
buildSchemaCategory
  :: Maybe Text
  -> [CatFkRow]
  -> IO SchemaCategoryInputs
  -> (SchemaCategoryOutput -> IO ())
  -> IO SchGraph
buildSchemaCategory mDefaultNamespace catFks fetchInputs sinkOutput = Progress.timedStep "Building schema category" $ do
  SchemaCategoryInputs{..} <- fetchInputs
  let sch = buildSchema SchemaInputs
        { inDwRetrieveColumns   = sciDwRetrieveColumns
        , inDwJoins             = sciDwJoinLegs
        , inDwWriteColumns      = sciDwWriteColumns
        , inDwWhereColumns      = sciDwWhereColumns
        , inSqlColumns          = sciSqlCols
        , inCatFootprintColumns = sciCatFootprintCols
        , inCatalogColumns      = sciCatColumns
        , inCatalogFks          = catFks
        , inDefaultNamespace    = mDefaultNamespace
        }
  sinkOutput SchemaCategoryOutput
    { scoObjects = Set.toList (sgObjects sch)
    , scoLegs    = sgLegs sch
    }
  pure sch
