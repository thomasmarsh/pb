module PB.Pipeline.DuckDb.Materialize
  ( materializeDeadCode
  , materializeTaintPaths
  , materializeTaintAnnotations
  , materializeDecompositionCoslice
  , materializeImpliedFk
  , materializeColumnRisk
  , materializeImpliedFkPairs
  , materializeRiskCount
  , materializeLiveProc
  , ImpliedFkPairsReady (..)
  , RiskCountReady (..)
  ) where

import PB.Prelude
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.SchemaCategory (SchGraph)
import PB.Pipeline.DuckDb
  ( Handle, executeHandle, recreateTextTable, queryTextRows )
import PB.Pipeline.DuckDb.PhaseB.Query
  ( ProcRows (..), DeadCodeClosureReady, SchemaClosureReady, CallGraphAndTaintReady )
import PB.Pipeline.DuckDb.PhaseB.Append (appendTaintAnnotations)
import PB.Pipeline.DuckDb.Relations (SchemaInputRows)

import Database.DuckDB.Simple  (Query (..))

import qualified Data.Set  as Set
import qualified Data.Text as T

-- | Proof-of-completion token for 'materializeImpliedFkPairs': minted once
-- @implied_fk_pairs@ is populated, consumed by 'materializeImpliedFk'.
newtype ImpliedFkPairsReady = ImpliedFkPairsReady ()

-- | Proof-of-completion token for 'materializeRiskCount': minted once
-- @risk_count@ is populated, consumed by 'materializeColumnRisk'.
newtype RiskCountReady = RiskCountReady ()

-- | Run a list of single-statement SQL commands, one 'executeHandle' each.
-- Kept separate (not a single multi-statement string) because the
-- duckdb-simple 'execute_' contract in this codebase is single-statement
-- per call (see 'PB.Pipeline.DuckDb.initSchema').
runStatements :: Handle -> [Text] -> IO ()
runStatements conn = mapM_ (\s -> void $ executeHandle conn (Query s))

-- | Materialize @implied_fk_pairs@ directly in DuckDB: a DataWindow join edge
-- with no declared foreign key in EITHER direction.
materializeImpliedFkPairs :: Handle -> SchemaInputRows -> IO ImpliedFkPairsReady
materializeImpliedFkPairs conn _schRows = do
  recreateTextTable conn "implied_fk_pairs" ["x", "y"]
  runStatements conn
    [ "INSERT INTO implied_fk_pairs (x, y) "
      <> "SELECT j.x, j.y FROM join_leg j "
      <> "WHERE NOT EXISTS (SELECT 1 FROM fk f WHERE f.x = j.x AND f.y = j.y) "
      <> "AND NOT EXISTS (SELECT 1 FROM fk f2 WHERE f2.x = j.y AND f2.y = j.x)"
    ]
  pure (ImpliedFkPairsReady ())

-- | Materialize @risk_count@ directly in DuckDB: each node's downstream
-- footprint over the @reaches@ table — the same aggregate
-- 'materializeDeadCode' uses for caller fan-in.
materializeRiskCount :: Handle -> SchemaClosureReady -> IO RiskCountReady
materializeRiskCount conn _scReady = do
  recreateTextTable conn "risk_count" ["x", "n"]
  runStatements conn
    [ "INSERT INTO risk_count (x, n) "
      <> "SELECT x, CAST(COUNT(*) AS VARCHAR) FROM reaches GROUP BY x"
    ]
  pure (RiskCountReady ())

-- | Materialize @live_proc@ directly in DuckDB:
-- @live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !proc_dead(Object,Proc)@.
-- Consumed by the CLI's @/api/analysis/live-procedures@ endpoint
-- ('cli/api/src/pb/api/services/analysis.py').
materializeLiveProc :: Handle -> DeadCodeClosureReady -> SchemaInputRows -> IO ()
materializeLiveProc conn _dcReady _schRows = do
  recreateTextTable conn "live_proc" ["object", "proc"]
  runStatements conn
    [ "INSERT INTO live_proc (object, proc) "
      <> "SELECT s.object, s.proc FROM stmt s "
      <> "WHERE NOT EXISTS ("
      <> "SELECT 1 FROM proc_dead pd "
      <> "WHERE pd.object = s.object AND pd.proc = s.proc)"
    ]

-- | Materialize @dead_code@ directly from the four pre-existing input
-- relations (@proc_dead@, @proc_meta@, @call_ref@, @resolved_call_edge@) in
-- a single CTE chain -- no intermediate tables (Plan 198 Phase A collapsed
-- the prior 8-table @has_naive_caller@\/@has_scoped_caller@\/
-- @caller_count_naive@\/@caller_count_scoped@\/@confidence@\/
-- @caller_count_naive_final@\/@caller_count_scoped_final@\/@dead_code_rows@
-- chain into this one materializer). Counts are INTEGER throughout -- no
-- CAST-to-VARCHAR-then-TRY_CAST-back round-trip.
--
-- The confidence classification (@high@\/@medium@\/@low@) and the caller
-- counts are computed the same way the old chain did:
--
--   * Naive caller count: @COUNT@ over @call_ref@ grouped by
--     @callee_name@, joined to @proc_meta@ by the lowercased @proc_lower@
--     (PowerBuilder identifiers are case-insensitive; @call_ref@'s
--     @callee_name@ is always lowercased already).
--   * Scoped caller count: @COUNT@ over @resolved_call_edge@ grouped by
--     @(callee_obj, callee_proc)@.
--   * Zero-fill: a @LEFT JOIN@ + @COALESCE(.., 0)@ against @proc_meta@\/
--     @proc@ gives every proc a count even with no callers, replacing the
--     old chain's @UNION ALL@-with-@NOT EXISTS@ zero-fill rows.
--   * Confidence: no naive caller -> @high@; a naive caller but no scoped
--     (fully-resolved) caller -> @medium@; both -> @low@.
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
-- (Regression test: 'RelationsTest.hs'\'s "overloaded procedure with
-- one unknown cyclomatic" case.)
materializeDeadCode :: Handle -> DeadCodeClosureReady -> IO ()
materializeDeadCode conn _dcReady = do
  -- Drop the 8 intermediate tables the pre-Plan-198 chain used to
  -- materialize, in case this run is against a DB file written by an
  -- older binary -- initSchema's CREATE TABLE IF NOT EXISTS means an
  -- existing file's tables otherwise persist untouched across runs.
  for_ deadTables $ \tbl ->
    executeHandle conn (Query ("DROP TABLE IF EXISTS " <> tbl))
  _ <- executeHandle conn "DELETE FROM dead_code"
  _ <- executeHandle conn (Query sql)
  pure ()
  where
    deadTables =
      [ "has_naive_caller", "has_scoped_caller"
      , "caller_count_naive", "caller_count_scoped"
      , "confidence", "caller_count_naive_final", "caller_count_scoped_final"
      , "dead_code_rows"
      ]
    sql = T.unlines
      [ "INSERT INTO dead_code"
      , "  (object, proc_name, proc_type, cyclomatic, confidence,"
      , "   caller_count_naive, caller_count_scoped)"
      , "WITH caller_count_naive AS ("
      , "  SELECT callee_name, COUNT(*) AS n FROM call_ref GROUP BY callee_name"
      , "),"
      , "caller_count_scoped AS ("
      , "  SELECT callee_obj, callee_proc, COUNT(*) AS n"
      , "    FROM resolved_call_edge GROUP BY callee_obj, callee_proc"
      , "),"
      , "confidence AS ("
      , "  SELECT pm.object, pm.proc,"
      , "    CASE"
      , "      WHEN cn.n IS NULL THEN 'high'"
      , "      WHEN cs.n IS NULL THEN 'medium'"
      , "      ELSE 'low'"
      , "    END AS level,"
      , "    COALESCE(cn.n, 0) AS naive_n, COALESCE(cs.n, 0) AS scoped_n"
      , "  FROM proc_meta pm"
      , "  LEFT JOIN caller_count_naive cn ON cn.callee_name = pm.proc_lower"
      , "  LEFT JOIN caller_count_scoped cs"
      , "    ON cs.callee_obj = pm.object AND cs.callee_proc = pm.proc"
      , "),"
      , "ranked AS ("
      , "  SELECT pd.object, pd.proc, pm.proc_type,"
      , "         TRY_CAST(pm.cyclomatic AS INTEGER) AS cyclomatic,"
      , "         c.level, c.naive_n, c.scoped_n,"
      , "         ROW_NUMBER() OVER ("
      , "           PARTITION BY pd.object, pd.proc"
      , "           ORDER BY TRY_CAST(pm.cyclomatic AS INTEGER) DESC NULLS LAST"
      , "         ) AS rn"
      , "  FROM proc_dead pd"
      , "  JOIN proc_meta pm ON pm.object = pd.object AND pm.proc = pd.proc"
      , "  JOIN confidence c ON c.object = pd.object AND c.proc = pd.proc"
      , ")"
      , "SELECT object, proc, proc_type, cyclomatic, level, naive_n, scoped_n"
      , "  FROM ranked WHERE rn = 1"
      ]

-- | Materialize @decomposition_coslice@ from the @path_leg_fwd@\/@path_leg_back@
-- tables (produced by 'PB.Analysis.SchemaClosure.cosliceClosure'). A pure SQL
-- projection -- no traversal, no Haskell graph walk -- satisfying the
-- relation-discipline functor property (the @path_leg@ tables are the reasoning;
-- this is a rename\/join into the 8-column consumer shape).
--
-- Three things happen here that a plain rename/join projection can't express:
--
-- 1. __Tie-break.__ Set semantics emit every shortest leg through a
--    diamond (a bounded 2x, not exponential -- verified on a 15-diamond
--    stress fixture). @ROW_NUMBER() OVER (PARTITION BY seed, target,
--    leg_ord ORDER BY leg_from, leg_to)@ picks one deterministic witness
--    per ordinal, so Python's @_coslice_paths@ chain-rebuilder (which
--    groups by @(seed, target)@ and orders by @leg_ordinal@) sees exactly
--    one contiguous leg chain per path.
--
-- 2. __leg_source recovery.@ The @path_leg@ tables carry
--    @leg_from@\/@leg_to@\/@leg_kind@ but not @leg_source@ (the
--    provenance column 'PB.Pipeline.DuckDb.PhaseB.Append.appendSchemaMorphisms'
--    writes). Joined back from @schema_morphisms@ on the three keys it
--    shares with @path_leg@.
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
materializeDecompositionCoslice :: Handle -> SchemaClosureReady -> SchGraph -> IO ()
materializeDecompositionCoslice conn _scReady _schGraph =
  void $ executeHandle conn (Query sql)
  where
    sql = T.unlines
      [ "INSERT INTO decomposition_coslice"
      , "  (seed_key, target_key, direction, leg_ordinal, leg_from, leg_to, leg_kind, leg_source,"
      , "   seed_kind, seed_namespace, seed_table_name, seed_column_name,"
      , "   seed_stmt_file, seed_stmt_object, seed_stmt_proc, seed_stmt_line,"
      , "   target_kind, target_namespace, target_table_name, target_column_name,"
      , "   target_stmt_file, target_stmt_object, target_stmt_proc, target_stmt_line,"
      , "   leg_from_kind, leg_from_namespace, leg_from_table_name, leg_from_column_name,"
      , "   leg_from_stmt_file, leg_from_stmt_object, leg_from_stmt_proc, leg_from_stmt_line,"
      , "   leg_to_kind, leg_to_namespace, leg_to_table_name, leg_to_column_name,"
      , "   leg_to_stmt_file, leg_to_stmt_object, leg_to_stmt_proc, leg_to_stmt_line)"
      , "WITH candidates AS ("
      , "  SELECT s AS seed_key, target AS target_key, 'forward' AS direction,"
      , "         CAST(leg_ord AS INTEGER) AS leg_ordinal, lf AS leg_from, lt AS leg_to, kind AS leg_kind"
      , "    FROM path_leg_fwd"
      , "  UNION ALL"
      -- Backward legs are reversed to target->seed ordering: the
      -- `path_leg_back` table (ascending ordinal, seed=0 outward) reads
      -- seed->target, but the walk-back reconstruction prepends each
      -- walked-back leg, so its legs read target->seed -- the convention
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
      , "SELECT r.seed_key, r.target_key, r.direction, r.leg_ordinal, r.leg_from, r.leg_to, r.leg_kind,"
      , "       COALESCE(r.leg_source, '') AS leg_source,"
      , "       so_seed.kind, so_seed.namespace, so_seed.table_name, so_seed.column_name,"
      , "       so_seed.stmt_file, so_seed.stmt_object, so_seed.stmt_proc, so_seed.stmt_line,"
      , "       so_target.kind, so_target.namespace, so_target.table_name, so_target.column_name,"
      , "       so_target.stmt_file, so_target.stmt_object, so_target.stmt_proc, so_target.stmt_line,"
      , "       so_leg_from.kind, so_leg_from.namespace, so_leg_from.table_name, so_leg_from.column_name,"
      , "       so_leg_from.stmt_file, so_leg_from.stmt_object, so_leg_from.stmt_proc, so_leg_from.stmt_line,"
      , "       so_leg_to.kind, so_leg_to.namespace, so_leg_to.table_name, so_leg_to.column_name,"
      , "       so_leg_to.stmt_file, so_leg_to.stmt_object, so_leg_to.stmt_proc, so_leg_to.stmt_line"
      , "  FROM (SELECT * FROM ranked WHERE rn = 1) r"
      , "  LEFT JOIN schema_objects so_seed     ON so_seed.object_key     = r.seed_key"
      , "  LEFT JOIN schema_objects so_target   ON so_target.object_key   = r.target_key"
      , "  LEFT JOIN schema_objects so_leg_from ON so_leg_from.object_key = r.leg_from"
      , "  LEFT JOIN schema_objects so_leg_to   ON so_leg_to.object_key   = r.leg_to"
      ]

-- | Materialize @implied_fk@ from the @implied_fk_pairs@ table, decoding each
-- ColKey pair back to human-readable (namespace, table, column) via a
-- join-back on @schema_objects.object_key@ -- the same decoding
-- 'materializeDecompositionCoslice' uses, since 'schObjectKey' has no inverse
-- parser in this codebase. A pure rename\/join projection, no decision logic.
materializeImpliedFk :: Handle -> ImpliedFkPairsReady -> SchGraph -> IO ()
materializeImpliedFk conn _fkPairsReady _schGraph =
  void $ executeHandle conn (Query sql)
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

-- | Materialize @column_risk@ from the @risk_count@ table, same
-- join-back-on-@object_key@ decoding as 'materializeImpliedFk'. @risk_count@
-- scores every 'reaches' node, including 'StmtObj' ones ('stmt'\/
-- @dw_retrieve@ kinds), which carry no @namespace@\/@table_name@\/
-- @column_name@ in @schema_objects@ (only @stmt_*@ fields) -- confirmed on
-- the real openpay corpus, where 115 such rows materialized as opaque
-- all-NULL triples. Migration risk scoring is inherently a per-COLUMN
-- question (what breaks if this column changes), so this filters to
-- @kind = 'column'@ only, the same restriction 'seedRows' already applies
-- to the coslice walk's own starting points.
materializeColumnRisk :: Handle -> RiskCountReady -> SchGraph -> IO ()
materializeColumnRisk conn _riskReady _schGraph =
  void $ executeHandle conn (Query sql)
  where
    sql = T.unlines
      [ "INSERT INTO column_risk (namespace, table_name, column_name, downstream_count)"
      , "SELECT so.namespace, so.table_name, so.column_name, CAST(rc.n AS INTEGER)"
      , "  FROM risk_count rc"
      , "  JOIN schema_objects so ON so.object_key = rc.x AND so.kind = 'column'"
      ]

-- | Materialize @taint_paths@ from the taint closure tables (@taint_step_kind@
-- and @taint_confirmed@).  Reads
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
-- SQL CASE here — they are derived by 'PB.Analysis.TaintClosure.materializeTaintStepKind'
-- (a house-rule violation this migration closes).
-- taint_step_kind already includes the terminal "arrived at sink"
-- marker row (and the 0-hop source==sink degenerate row), so the old
-- legs_with_sink UNION ALL that synthesized it here is gone too — this
-- materializer is now a pure rename/dedup/reshape of taint_step_kind.
--
-- PERFORMANCE FIX: @taint_step_kind@ is written directly into a plain DuckDB
-- table by 'PB.Analysis.TaintClosure.materializeTaintStepKind', a Haskell
-- BFS-based reconstruction. This materializer reads that table.
materializeTaintPaths :: Handle -> CallGraphAndTaintReady -> IO ()
materializeTaintPaths conn _cgReady =
  void $ executeHandle conn (Query sql)
  where
    sql = T.unlines
      [ "DELETE FROM taint_paths"
      , ";"
      , "INSERT INTO taint_paths"
      , "  (file, object, proc_name, var_name,"
      , "   target_file, target_object, target_proc, target_var,"
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
      , "  si.file AS file,"
      , "  si.object AS object,"
      , "  si.proc_name AS proc_name,"
      , "  si.var_name AS var_name,"
      , "  sk.file AS target_file,"
      , "  sk.object AS target_object,"
      , "  sk.proc_name AS target_proc,"
      , "  sk.var_name AS target_var,"
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
-- (which needs @block_id@ from proc_defs/proc_uses — passed in as
-- 'ProcRows', already fetched by 'PB.Pipeline.Passes.buildCallGraphAndTaint' and threaded
-- through 'PB.Pipeline.Passes.runPhaseB' instead of re-querying the same two
-- tables here; Plan 187 §18 tier 3).
materializeTaintAnnotations :: Handle -> CallGraphAndTaintReady -> ProcRows -> IO ()
materializeTaintAnnotations conn _cgReady ProcRows{prDefs, prUses} = do
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
  let annotations = Taint.buildTaintAnnotations taintedSet allSources allSinks prDefs prUses
  appendTaintAnnotations conn annotations
