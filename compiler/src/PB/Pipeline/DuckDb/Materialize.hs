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
  , materializeCallerCounts
  , materializeDeadCodeRows
  ) where

import PB.Prelude
import PB.Analysis.Taint       qualified as Taint
import PB.Pipeline.DuckDb
  ( Handle, executeHandle, recreateTextTable, queryTextRows )
import PB.Pipeline.DuckDb.PhaseB.Query  (ProcRows (..))
import PB.Pipeline.DuckDb.PhaseB.Append (appendTaintAnnotations)

import Database.DuckDB.Simple  (Query (..))

import qualified Data.Set  as Set
import qualified Data.Text as T

-- | Run a list of single-statement SQL commands, one 'executeHandle' each.
-- Kept separate (not a single multi-statement string) because the
-- duckdb-simple 'execute_' contract in this codebase is single-statement
-- per call (see 'PB.Pipeline.DuckDb.initSchema').
runStatements :: Handle -> [Text] -> IO ()
runStatements conn = mapM_ (\s -> void $ executeHandle conn (Query s))

-- | Materialize @implied_fk_pairs@ directly in DuckDB: a DataWindow join edge
-- with no declared foreign key in EITHER direction.
materializeImpliedFkPairs :: Handle -> IO ()
materializeImpliedFkPairs conn = do
  recreateTextTable conn "implied_fk_pairs" ["x", "y"]
  runStatements conn
    [ "INSERT INTO implied_fk_pairs (x, y) "
      <> "SELECT j.x, j.y FROM join_leg j "
      <> "WHERE NOT EXISTS (SELECT 1 FROM fk f WHERE f.x = j.x AND f.y = j.y) "
      <> "AND NOT EXISTS (SELECT 1 FROM fk f2 WHERE f2.x = j.y AND f2.y = j.x)"
    ]

-- | Materialize @risk_count@ directly in DuckDB: each node's downstream
-- footprint over the @reaches@ table — the same aggregate
-- 'materializeCallerCounts' uses for caller fan-in.
materializeRiskCount :: Handle -> IO ()
materializeRiskCount conn = do
  recreateTextTable conn "risk_count" ["x", "n"]
  runStatements conn
    [ "INSERT INTO risk_count (x, n) "
      <> "SELECT x, CAST(COUNT(*) AS VARCHAR) FROM reaches GROUP BY x"
    ]

-- | Materialize @live_proc@ directly in DuckDB:
-- @live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !proc_dead(Object,Proc)@.
-- Consumed by the CLI's @/api/analysis/live-procedures@ endpoint
-- ('cli/api/src/pb/api/services/analysis.py').
materializeLiveProc :: Handle -> IO ()
materializeLiveProc conn = do
  recreateTextTable conn "live_proc" ["object", "proc"]
  runStatements conn
    [ "INSERT INTO live_proc (object, proc) "
      <> "SELECT s.object, s.proc FROM stmt s "
      <> "WHERE NOT EXISTS ("
      <> "SELECT 1 FROM proc_dead pd "
      <> "WHERE pd.object = s.object AND pd.proc = s.proc)"
    ]

-- | Materialize the caller-count and confidence relations directly in
-- DuckDB. Produces @has_naive_caller@, @has_scoped_caller@,
-- @caller_count_naive@, @caller_count_scoped@, and @confidence@ — the same
-- intermediate tables 'materializeDeadCodeRows' joins.
materializeCallerCounts :: Handle -> IO ()
materializeCallerCounts conn = do
  recreateTextTable conn "has_naive_caller" ["callee_name"]
  recreateTextTable conn "has_scoped_caller" ["callee_obj", "callee_proc"]
  recreateTextTable conn "caller_count_naive" ["callee_name", "n"]
  recreateTextTable conn "caller_count_scoped" ["callee_obj", "callee_proc", "n"]
  recreateTextTable conn "confidence" ["object", "proc", "level"]
  runStatements conn
    [ "INSERT INTO has_naive_caller (callee_name) SELECT DISTINCT callee_name FROM call_ref"
    , "INSERT INTO has_scoped_caller (callee_obj, callee_proc) "
        <> "SELECT DISTINCT callee_obj, callee_proc FROM resolved_call_edge"
    , "INSERT INTO caller_count_naive (callee_name, n) "
        <> "SELECT callee_name, CAST(COUNT(*) AS VARCHAR) FROM call_ref GROUP BY callee_name"
    , "INSERT INTO caller_count_scoped (callee_obj, callee_proc, n) "
        <> "SELECT callee_obj, callee_proc, CAST(COUNT(*) AS VARCHAR) "
        <> "FROM resolved_call_edge GROUP BY callee_obj, callee_proc"
    , "INSERT INTO confidence (object, proc, level) "
        <> "SELECT pm.object, pm.proc, 'high' FROM proc_meta pm "
        <> "WHERE NOT EXISTS (SELECT 1 FROM has_naive_caller h WHERE h.callee_name = pm.proc_lower) "
        <> "UNION ALL "
        <> "SELECT pm.object, pm.proc, 'medium' FROM proc_meta pm "
        <> "WHERE EXISTS (SELECT 1 FROM has_naive_caller h WHERE h.callee_name = pm.proc_lower) "
        <> "AND NOT EXISTS (SELECT 1 FROM has_scoped_caller s WHERE s.callee_obj = pm.object AND s.callee_proc = pm.proc) "
        <> "UNION ALL "
        <> "SELECT pm.object, pm.proc, 'low' FROM proc_meta pm "
        <> "WHERE EXISTS (SELECT 1 FROM has_naive_caller h WHERE h.callee_name = pm.proc_lower) "
        <> "AND EXISTS (SELECT 1 FROM has_scoped_caller s WHERE s.callee_obj = pm.object AND s.callee_proc = pm.proc)"
    ]

-- | Materialize @dead_code_rows@ (and its @caller_count_naive_final@ /
-- @caller_count_scoped_final@ intermediates) directly in DuckDB.
-- Must run AFTER 'materializeCallerCounts' (which produces @confidence@ and
-- the caller-count relations it joins).
materializeDeadCodeRows :: Handle -> IO ()
materializeDeadCodeRows conn = do
  recreateTextTable conn "caller_count_naive_final" ["proc_lower", "n"]
  recreateTextTable conn "caller_count_scoped_final" ["object", "proc", "n"]
  recreateTextTable conn "dead_code_rows"
    ["object", "proc", "proc_type", "cyclomatic", "level", "naive_n", "scoped_n"]
  runStatements conn
    [ "INSERT INTO caller_count_naive_final (proc_lower, n) "
        <> "SELECT callee_name, n FROM caller_count_naive "
        <> "UNION ALL "
        <> "SELECT pm.proc_lower, '0' FROM proc_meta pm "
        <> "WHERE NOT EXISTS (SELECT 1 FROM has_naive_caller h WHERE h.callee_name = pm.proc_lower)"
    , "INSERT INTO caller_count_scoped_final (object, proc, n) "
        <> "SELECT callee_obj, callee_proc, n FROM caller_count_scoped "
        <> "UNION ALL "
        <> "SELECT p.object, p.proc, '0' FROM proc p "
        <> "WHERE NOT EXISTS (SELECT 1 FROM has_scoped_caller s WHERE s.callee_obj = p.object AND s.callee_proc = p.proc)"
    , "INSERT INTO dead_code_rows (object, proc, proc_type, cyclomatic, level, naive_n, scoped_n) "
        <> "SELECT pd.object, pd.proc, pm.proc_type, pm.cyclomatic, c.level, cnf.n, csf.n "
        <> "FROM proc_dead pd "
        <> "JOIN proc_meta pm ON pm.object = pd.object AND pm.proc = pd.proc "
        <> "JOIN confidence c ON c.object = pd.object AND c.proc = pd.proc "
        <> "JOIN caller_count_naive_final cnf ON cnf.proc_lower = pm.proc_lower "
        <> "JOIN caller_count_scoped_final csf ON csf.object = pd.object AND csf.proc = pd.proc"
    ]

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
-- (Regression test: 'RulesTest.hs'\'s "overloaded procedure with
-- one unknown cyclomatic" case.) The pre-Stage-6 Haskell 'classifyDeadProcedures' used
-- 'Map.fromListWith (\a _b -> a)', which kept whichever row DuckDB's
-- unordered table scan happened to return first -- not a rule, an
-- accident with no rationale and no run-to-run reproducibility guarantee.
-- Confirmed via real corpus diff (2026-07-11): every one of the 7 rows
-- this changes vs. the old behavior differs ONLY in cyclomatic -- object,
-- proc, proc_type, confidence, and both caller counts are unchanged.
materializeDeadCode :: Handle -> IO ()
materializeDeadCode conn = do
  _ <- executeHandle conn "DELETE FROM dead_code"
  _ <- executeHandle conn
    "INSERT INTO dead_code \
    \SELECT object, proc, proc_type, TRY_CAST(cyclomatic AS INTEGER), \
    \level, TRY_CAST(naive_n AS INTEGER), TRY_CAST(scoped_n AS INTEGER) \
    \FROM ( \
    \  SELECT *, ROW_NUMBER() OVER (PARTITION BY object, proc ORDER BY TRY_CAST(cyclomatic AS INTEGER) DESC NULLS LAST) AS rn \
    \  FROM dead_code_rows \
    \) WHERE rn = 1"
  pure ()

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
materializeDecompositionCoslice :: Handle -> IO ()
materializeDecompositionCoslice conn =
  void $ executeHandle conn (Query sql)
  where
    sql = T.unlines
      [ "INSERT INTO decomposition_coslice"
      , "  (seed_key, target_key, direction, leg_ordinal, leg_from, leg_to, leg_kind, leg_source)"
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
      , "SELECT seed_key, target_key, direction, leg_ordinal, leg_from, leg_to, leg_kind,"
      , "       COALESCE(leg_source, '') AS leg_source"
      , "  FROM ranked WHERE rn = 1"
      ]

-- | Materialize @implied_fk@ from the @implied_fk_pairs@ table, decoding each
-- ColKey pair back to human-readable (namespace, table, column) via a
-- join-back on @schema_objects.object_key@ -- the same decoding
-- 'materializeDecompositionCoslice' uses, since 'schObjectKey' has no inverse
-- parser in this codebase. A pure rename\/join projection, no decision logic.
materializeImpliedFk :: Handle -> IO ()
materializeImpliedFk conn =
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
materializeColumnRisk :: Handle -> IO ()
materializeColumnRisk conn =
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
materializeTaintPaths :: Handle -> IO ()
materializeTaintPaths conn =
  void $ executeHandle conn (Query sql)
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
-- (which needs @block_id@ from proc_defs/proc_uses — passed in as
-- 'ProcRows', already fetched by 'PB.Pipeline.Passes.runPass67' and threaded
-- through 'PB.Pipeline.Passes.runPhaseB' instead of re-querying the same two
-- tables here; Plan 187 §18 tier 3).
materializeTaintAnnotations :: ProcRows -> Handle -> IO ()
materializeTaintAnnotations ProcRows{prDefs, prUses} conn = do
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
