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
import PB.Pipeline.Souffle qualified as Souffle
import PB.Analysis.Rules.Schema qualified as SchemaRules
import PB.Analysis.Rules.Schema (LegSourceFanout (..))
import PB.Analysis.Rules.DeadCode qualified as DeadCodeRules
import PB.Analysis.Rules.Taint qualified as TaintRules
import PB.Pipeline.Progress qualified as Progress
import PB.Pipeline.DuckDb
  ( DuckConn
  , queryLocalVars, queryCallSites, queryGlobalVars, queryObjInfo
  , queryProcDefs, queryProcUses, queryResolvedCalls
  , queryTaintInputs, queryTaintIntraEdges, queryTaintReturnRows
  , queryDwRetrieveColumns, queryDwWriteColumns, queryDwWhereColumns
  , queryDwJoinLegs, querySqlCols
  , queryCatFootprintColumns
  , queryCatColumns, queryCatFks
  , appendResolvedTypes, appendResolvedCalls
  , appendInterprocEdges, appendProcSummaries
  , appendTaintSources, appendTaintSinks
  , appendSchemaObjects, appendSchemaMorphisms
  , materializeDecompositionCoslice
  , materializeImpliedFk
  , materializeColumnRisk
  , materializeDeadCode
  , materializeTaintPaths
  , materializeTaintAnnotations
  )

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import Data.IORef             (IORef, newIORef, readIORef, writeIORef)
import Data.Time.Clock        (UTCTime, getCurrentTime)

-- | Shared per-relation progress hook for 'Souffle.runRuleSetsWithStart' in
-- 'runPhaseB': fires a @step@ event just before an IDB relation is
-- materialized, then a second one right after with its row count. The
-- Python reporter's Phase B view shows only the latest step label (no
-- sub-progress bar), so per-relation granularity keeps the label current as
-- each rule set's outputs land rather than stalling on a single blanket
-- label for the whole Datalog run.
--
-- CAVEAT (found in production, 2026-07-15): the "before" firing only
-- happens once a ruleset's single monolithic @souffle@ subprocess has
-- already exited -- while that subprocess is mid-flight (which can be
-- minutes on a large corpus, see 'souffleStart' below), the displayed label
-- is whatever the PREVIOUS ruleset in 'Souffle.orderRuleSets'\' resolved
-- order last emitted, not the ruleset actually running. Concretely:
-- 'allDatalogRuleSets' lists @taintRules@ last, but 'Souffle.orderRuleSets'
-- batches independent rulesets (no relation-name dependency edge between
-- them) into the same round in list order -- @taintRules@ has no dependency
-- on any other ruleset's output, so it lands in ROUND 1 immediately after
-- @legRules@ (verified via @cabal repl@: @orderRuleSets allDatalogRuleSets@
-- = @[ deadReachRules, callerCountRules, legRules, taintRules,
-- deadCodeRowsRules, reachesRules, liveProcRules, cosliceRules ]@). A live
-- run stuck on "Datalog: leg" for 13+ minutes was actually deep inside
-- @taintRules@ (301,754-row @taint_edge.facts@) the whole time -- only
-- confirmed via process\/temp-dir inspection, not this progress label. See
-- 'souffleStart' for the fix, and 'PB.Analysis.Rules.Taint.taintRules'\'
-- Code Index entry (compiler/CLAUDE.md) for the perf fix this incident
-- also produced.
-- | Label stays identical across both firings (unlike an earlier version
-- of this function, which appended @" materialized (N rows)"@ to the
-- second event's label only) -- the row count already flows through the
-- structured @idb_rows@ field below, so baking it into the label text too
-- just gave the two events different labels and defeated the Python
-- 'DiagnosticsCollector'\'s flush-on-label-change pairing (the same
-- mechanism 'souffleLabel' exists to keep 'souffleStart'\/'souffleFinish'
-- on). The bare start event (no row count yet) would otherwise show up as
-- its own all-dashes row in the report table instead of merging into its
-- end event's row.
souffleProgress :: Souffle.Relation -> Maybe (Int, Double) -> IO ()
souffleProgress rel Nothing =
  Progress.emitEvent (Progress.EvStep ("Datalog: " <> Souffle.relName rel) Nothing [] [] Nothing)
souffleProgress rel (Just (n, elapsedMs)) =
  Progress.emitEvent (Progress.EvStep
    ("Datalog: " <> Souffle.relName rel)
    (Just elapsedMs) [] [(Souffle.relName rel, n)] Nothing)

-- | Stable per-ruleset progress-event label, shared by 'souffleStart' and
-- 'souffleFinish' so the Python 'DiagnosticsCollector' (which flushes a
-- report row only when the @"step"@ event label changes) pairs the two into
-- one row carrying both the start event's @edb_rows@ and the finish event's
-- @elapsed_ms@ -- row counts live entirely in the structured fields, not
-- baked into the label text, so the label stays identical between the two
-- events regardless of what those counts are.
souffleLabel :: Souffle.RuleSet -> Text
souffleLabel rs = "Datalog: running ["
  <> T.intercalate ", " (map Souffle.relName (Souffle.rsRelations rs))
  <> "]"

-- | Fires at the TRUE start of a ruleset's processing -- before its EDB
-- facts are even queried (see 'Souffle.SouffleHooks.onRuleSetPrepStart').
-- Anchors the timeline bar's left edge correctly; 'souffleCounts' below
-- (fired later, once row counts are known) shares the same label and
-- merges into this same report row rather than opening a second one. A
-- real corpus timeline showed a ~2s unaccounted gap right before every
-- ruleset's bar until this hook existed -- the EDB-gathering loop was
-- genuinely running the whole time, just with no event marking when it
-- began.
souffleStart :: Souffle.RuleSet -> IO ()
souffleStart rs = Progress.emitEvent (Progress.EvStep (souffleLabel rs) Nothing [] [] Nothing)

-- | Fires once EDB facts are queried/written and their row counts are known
-- (see 'Souffle.SouffleHooks.onRuleSetStart's own doc comment for why this
-- is deliberately later than 'souffleStart') -- shares 'souffleLabel' with
-- 'souffleStart' so this just adds row counts to the same already-open
-- report row instead of anchoring a second one.
souffleCounts :: Souffle.RuleSet -> [(Souffle.Relation, Int)] -> IO ()
souffleCounts rs counts = Progress.emitEvent (Progress.EvStep
  (souffleLabel rs)
  Nothing
  [ (Souffle.relName rel, n) | (rel, n) <- counts ]
  []
  Nothing)

-- | Fires once the ruleset's @souffle@ subprocess has exited and every IDB
-- relation has been read back into DuckDB -- the actual cost of running
-- this ruleset's Datalog evaluation, previously untimed anywhere (see
-- 'Souffle.SouffleHooks'\' 'Souffle.onRuleSetFinish' doc comment). Shares
-- 'souffleLabel' with 'souffleStart' so the diagnostics report renders one
-- row per ruleset with a real duration instead of two disconnected,
-- undurated rows.
souffleFinish :: Souffle.RuleSet -> Double -> IO ()
souffleFinish rs elapsedMs = do
  mResidency <- Progress.residencySnapshot
  Progress.emitEvent (Progress.EvStep (souffleLabel rs) (Just elapsedMs) [] [] mResidency)

-- | Fires once per EDB relation, immediately after that relation's facts
-- are queried and written into its @.facts@ file -- the concrete fix for a
-- production incident where a stall inside this exact loop (suspected on an
-- oversized @reaches@ relation feeding @risk_count@) produced zero progress
-- events, since 'souffleCounts' below only fires once the whole loop has
-- already finished.
souffleEdbFact :: Souffle.Relation -> Int -> Double -> IO ()
souffleEdbFact rel n elapsedMs = do
  mResidency <- Progress.residencySnapshot
  Progress.emitEvent (Progress.EvStep
    ("Datalog: EDB " <> Souffle.relName rel <> " written (" <> T.pack (show n) <> " rows)")
    (Just elapsedMs) [(Souffle.relName rel, n)] [] mResidency)

-- | Fires periodically while a @souffle@ subprocess itself is running, so a
-- long in-Souffle evaluation doesn't go dark between 'souffleStart' and
-- 'souffleProgress'.
souffleHeartbeat :: Double -> IO ()
souffleHeartbeat elapsedSec = do
  mResidency <- Progress.residencySnapshot
  Progress.emitEvent (Progress.EvStep
    ("Datalog: souffle still running (" <> T.pack (show (round elapsedSec :: Int)) <> "s)")
    (Just (elapsedSec * 1000)) [] [] mResidency)

-- | The 'Souffle.SouffleHooks' value 'runPhaseB' wires into every Datalog
-- rule set run.
souffleHooks :: Souffle.SouffleHooks
souffleHooks = Souffle.noSouffleHooks
  { Souffle.onRuleSetPrepStart = souffleStart
  , Souffle.onRuleSetStart     = souffleCounts
  , Souffle.onEdbFact          = souffleEdbFact
  , Souffle.onIdbRelation      = souffleProgress
  , Souffle.onHeartbeat        = souffleHeartbeat
  , Souffle.onRuleSetFinish    = souffleFinish
  }

-- | Characterize @leg_source@'s (x, y) key fan-in before 'SchemaRules.legRules'
-- runs (see that ruleset's own doc comment for the O(group_size^2) Souffle
-- aggregate bug this was written to catch early). Always emits a one-line
-- summary; additionally emits a @warning@ event when the largest group looks
-- disproportionate -- 500 is a heuristic threshold, not a proven safe bound:
-- 'leg_source' has only ~3 distinct @kind@ buckets, so a group this size is
-- almost certainly duplicate/near-duplicate extraction on one schema edge
-- rather than legitimate diversity, and is worth an operator's attention
-- regardless of whether the current 'SchemaRules.legRules' handles it fast.
reportLegSourceFanout :: DuckConn -> IO ()
reportLegSourceFanout conn = do
  t0 <- getCurrentTime
  LegSourceFanout total keys maxGroup <- SchemaRules.legSourceFanout conn
  t1 <- getCurrentTime
  let n = T.pack . show
  Progress.emitEvent (Progress.EvStep
    ("Datalog: leg_source -- " <> n total <> " rows, "
      <> n keys <> " keys, max " <> n maxGroup <> " rows/key")
    (Just (Progress.msBetween t0 t1)) [("leg_source", total)] [] Nothing)
  when (maxGroup > 500) $ Progress.emitEvent (Progress.EvWarning
    ("leg_source has a key with " <> n maxGroup <> " duplicate rows \
     \(out of " <> n total <> " total, " <> n keys <> " distinct keys) \
     \-- unusually large fan-in on one schema edge, likely duplicate/\
     \near-duplicate extraction rather than legitimate diversity; \
     \worth investigating the source before trusting downstream leg/reaches results"))

-- | Characterize 'proc_defs'\/'proc_uses' key fan-in for the two joins
-- 'PB.Analysis.Rules.Taint.initTaintEdbViews' performs in memory
-- ('taintEdgeIntraRows'\/'taintEdgeReturnRows') before it runs -- mirrors
-- 'reportLegSourceFanout' above, since a duplicate-key fan-in blowup is the
-- established failure shape in this neighborhood (leg_source, taint_reaches
-- both hit it previously; see compiler/CLAUDE.md's Code Index).
reportTaintDefUseFanout :: DuckConn -> IO ()
reportTaintDefUseFanout conn = do
  t0 <- getCurrentTime
  defFo <- TaintRules.defLineFanout conn
  t1 <- getCurrentTime
  retFo <- TaintRules.returnUseFanout conn
  t2 <- getCurrentTime
  let n = T.pack . show
      report relName label elapsedMs (TaintRules.DefUseFanout total keys maxGroup) = do
        Progress.emitEvent (Progress.EvStep
          (label <> " -- " <> n total <> " rows, "
            <> n keys <> " keys, max " <> n maxGroup <> " rows/key")
          (Just elapsedMs) [(relName, total)] [] Nothing)
        when (maxGroup > 500) $ Progress.emitEvent (Progress.EvWarning
          (label <> " has a key with " <> n maxGroup
            <> " duplicate rows (out of " <> n total <> " total, " <> n keys
            <> " distinct keys) -- unusually large fan-in, likely duplicate/\
               \near-duplicate extraction rather than legitimate diversity"))
  report ("proc_defs" :: Text) ("Datalog: proc_defs (object,proc,line)" :: Text)
    (Progress.msBetween t0 t1) defFo
  report ("proc_uses_return" :: Text) ("Datalog: proc_uses return (object,proc)" :: Text)
    (Progress.msBetween t1 t2) retFo

-- | Report the raw 'PB.Analysis.Rules.Taint.initTaintEdbViewsWith' checkpoint
-- counts as a single progress event, with elapsed_ms measured since the
-- previous checkpoint (via 'lastT') -- narrows a stall down to the specific
-- query\/join\/write between two checkpoints, not just the whole
-- materialization step.
reportTaintCounts :: IORef UTCTime -> [(Text, Int)] -> IO ()
reportTaintCounts lastT counts = do
  t0 <- readIORef lastT
  t1 <- getCurrentTime
  writeIORef lastT t1
  Progress.emitEvent (Progress.EvStep
    ("Taint EDB counts: " <> T.intercalate ", " [ k <> "=" <> T.pack (show v) | (k, v) <- counts ])
    (Just (Progress.msBetween t0 t1)) [] counts Nothing)

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Structured as two sub-phases:
--
-- * **B1 (Haskell + EDB materialization):** the analyses that can't be
--   expressed as Soufflé rules run here — type/call resolution
--   ('runPass5', populating @resolved_calls@), interproc-edge and taint
--   analysis, including the taint closure itself
--   ('runPass67' — @taint_reaches@\/@taint_confirmed@ are algebraic, not
--   Soufflé, since the Plan 182 cutover), and schema-category construction
--   ('runPass9', populating @schema_objects@\/@schema_morphisms@). Then
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
  Progress.emitEvent (Progress.EvPhase "B")
  -- B1: prerequisite Haskell analyses + EDB materialization.
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
  materializeAllEdbViews conn
  -- B2: all Soufflé rule sets in one dependency-ordered run. Characterize
  -- leg_source's key fan-in first (see reportLegSourceFanout) -- cheap, and
  -- surfaces a pathological corpus shape before the Souffle run rather than
  -- only via its wall-clock/memory symptoms.
  reportLegSourceFanout conn
  Progress.emitEvent (Progress.EvStep "Datalog analysis" Nothing [] [] Nothing)
  Souffle.runRuleSetsWithStart souffleHooks conn allDatalogRuleSets
  TaintRules.reconstructTaintStepKind conn
  materializeDeadCode conn
  materializeDecompositionCoslice conn
  materializeImpliedFk conn
  materializeColumnRisk conn
  materializeTaintPaths conn
  materializeTaintAnnotations conn

-- | Materialize every EDB view the Soufflé rule sets in 'allDatalogRuleSets'
-- assume already exist. Each 'init*EdbViews' is idempotent (@CREATE OR
-- REPLACE VIEW@); together they cover the dead-code and schema EDB layers.
-- Must run after 'runPass5' (for @resolved_calls@) and 'runPass9' (for
-- @schema_objects@\/@schema_morphisms@).
materializeAllEdbViews :: DuckConn -> IO ()
materializeAllEdbViews conn = do
  Progress.timedStep "Dead-code EDB views materialized" $ DeadCodeRules.initDeadReachEdbViews conn
  Progress.timedStep "Schema EDB views materialized" $ SchemaRules.initEdbViews conn
  reportTaintDefUseFanout conn
  taintCheckpointT <- getCurrentTime >>= newIORef
  Progress.timedStep "Taint EDB views materialized" $
    TaintRules.initTaintEdbViewsWith (reportTaintCounts taintCheckpointT) conn

-- | Every Soufflé rule set run in Phase B. 'Souffle.runRuleSets' topologically
-- orders these by their IDB-output ∩ EDB-input edges, so the order listed
-- here is the stable tie-break for independent rule sets only — the real
-- ordering is data-driven. See 'runPhaseB' for the edge inventory.
--
-- 'TaintRules.taintRules' is deliberately NOT listed here (Plan 182
-- cutover, 2026-07-18): @taint_reaches@\/@taint_confirmed@ are now
-- produced by 'TaintRules.materializeTaintClosure' in 'runPass67', an
-- algebraic Kleene-star closure over the same EDB inputs. 'taintRules'
-- itself is unchanged and still callable on demand.
allDatalogRuleSets :: [Souffle.RuleSet]
allDatalogRuleSets =
  [ DeadCodeRules.deadReachRules
  , DeadCodeRules.callerCountRules
  , DeadCodeRules.deadCodeRowsRules
  , SchemaRules.legRules
  , SchemaRules.reachesRules
  , SchemaRules.cosliceRules
  , SchemaRules.impliedFkRules
  , SchemaRules.riskRules
  , DeadCodeRules.liveProcRules
  ]

runPass5 :: DuckConn -> IO (Map.Map Ident Ident)
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
-- @taint_confirmed@) via the algebraic Kleene-star closure
-- ('TaintRules.materializeTaintClosure', Plan 182 cutover) — production's
-- source for those two tables since 2026-07-18. Path reconstruction
-- (@taint_step_kind@, via 'TaintRules.reconstructTaintStepKind') still
-- runs later in 'runPhaseB', once @taint_confirmed@ is populated. The
-- Souffle 'TaintRules.taintRules' fixpoint this replaces is unchanged and
-- still available on demand (the oracle-diff test suite, the UI's
-- SQL\/Datalog exploration surface) — it just no longer runs in the hot
-- path.
runPass67 :: DuckConn -> IO ()
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
  Progress.timedStep "Taint closure (algebraic)" $
    TaintRules.materializeTaintClosure allSources allSinks intraEdges returnRows defs uses edges conn

-- | Pass 9 (Plan 148 Phase 1b; default-namespace resolution added Plan 157
-- Phase 1): materialize the schema category @Sch@ from Phase A's
-- DW-retrieve/DW-join/SQL-column/DDL-catalog tables. Returns the graph so
-- Pass 10 can traverse it without rebuilding from DB rows.
runPass9 :: DuckConn -> Maybe Text -> IO SchGraph
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
