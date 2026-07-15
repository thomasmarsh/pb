-- | Plan 161 Phase 2d: taint BFS reachability via Souffle.
--
-- Port of 'PB.Analysis.Taint.propagateTaint''s BFS and
-- 'traceTaintPath''s path reconstruction to Souffle Datalog,
-- following the cosliceRules path-witness pattern.
--
-- The four edge rules (intra-proc def-use, arg, return, global-write)
-- are pure structural joins over @proc_defs@\/@proc_uses@\/
-- @interproc_edges@, computed as SQL VIEWs.  The Datalog program
-- computes transitive reachability (@taint_reaches@), shortest
-- distance with choice-domain for cycle termination
-- (@taint_min_dist@), witness legs (@taint_path_leg@), and
-- source→sink confirmation (@taint_confirmed@).
module PB.Analysis.Rules.Taint
  ( initTaintEdbViews
  , taintRules
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb (DuckConn)
import Database.DuckDB.Simple (Query (..), execute_)

-- ---------------------------------------------------------------------------
-- EDB views
-- ---------------------------------------------------------------------------

-- | (Re)create the taint EDB views.  Must run after
-- 'PB.Pipeline.Passes.runPass67' populates @proc_defs@\/@proc_uses@\/
-- @interproc_edges@\/@taint_sources@\/@taint_sinks@.
--
-- @taint_edge@ is a UNION ALL of four views, each producing
-- @(from_key, to_key, kind)@ where a key is @object::proc::var@.
-- @taint_source@ and @taint_sink@ project the key from the
-- classified source\/sink tables.
initTaintEdbViews :: DuckConn -> IO ()
initTaintEdbViews conn = for_ views (void . execute_ conn)
  where
    views :: [Query]
    views =
      [ -- 1. Intra-proc def-use edge: a UseRow for var at line L,
        --    and a DefRow for a DIFFERENT var at the same line L,
        --    in the same (object, proc).  defsByLine only inserts
        --    rows with Just line (Taint.hs:689), so d.line IS NOT
        --    NULL is sufficient.  The uses side's NULL-line rows are
        --    implicitly excluded by the JOIN condition (u.line = d.line
        --    is false when either is NULL).
        "CREATE OR REPLACE VIEW taint_edge_intra AS \
        \SELECT \
        \  u.object || '::' || u.proc_name || '::' || u.var_name AS from_key, \
        \  d.object || '::' || d.proc_name || '::' || d.var_name AS to_key, \
        \  'def' AS kind \
        \FROM proc_uses u \
        \JOIN proc_defs d \
        \  ON u.object = d.object \
        \ AND u.proc_name = d.proc_name \
        \ AND u.line = d.line \
        \WHERE u.var_name <> d.var_name \
        \  AND d.line IS NOT NULL"

        -- 2. Arg edge: straight projection of interproc_edges
        --    WHERE edge_kind = 'arg'.
      , "CREATE OR REPLACE VIEW taint_edge_arg AS \
        \SELECT \
        \  caller_object || '::' || caller_proc || '::' || caller_context AS from_key, \
        \  callee_object || '::' || callee_proc || '::' || callee_context AS to_key, \
        \  'arg' AS kind \
        \FROM interproc_edges \
        \WHERE edge_kind = 'arg'"

        -- 3. Global write edge: same shape, WHERE edge_kind = 'global_write'.
      , "CREATE OR REPLACE VIEW taint_edge_global AS \
        \SELECT \
        \  caller_object || '::' || caller_proc || '::' || var_name AS from_key, \
        \  callee_object || '::' || callee_proc || '::' || callee_context AS to_key, \
        \  'global' AS kind \
        \FROM interproc_edges \
        \WHERE edge_kind = 'global_write'"

        -- 4. Return edge: interproc_edges WHERE kind='return' JOIN
        --    proc_uses WHERE kind='return'.  The interproc_edges row's
        --    callee_context is the literal "return", not a real var;
        --    the actual FROM-node var comes from the join against
        --    proc_uses — propagateOne's returnSeeds requires the
        --    CURRENTLY TAINTED var to itself have a kind='return' UseRow
        --    in that proc before firing.
      , "CREATE OR REPLACE VIEW taint_edge_return AS \
        \SELECT \
        \  u.object || '::' || u.proc_name || '::' || u.var_name AS from_key, \
        \  e.caller_object || '::' || e.caller_proc || '::' || e.caller_context AS to_key, \
        \  'return' AS kind \
        \FROM interproc_edges e \
        \JOIN proc_uses u \
        \  ON u.object = e.callee_object \
        \ AND u.proc_name = e.callee_proc \
        \ AND u.kind = 'return' \
        \WHERE e.edge_kind = 'return'"

        -- Union all four edge views into one.
      , "CREATE OR REPLACE VIEW taint_edge AS \
        \SELECT from_key, to_key, kind FROM taint_edge_intra \
        \UNION ALL \
        \SELECT from_key, to_key, kind FROM taint_edge_arg \
        \UNION ALL \
        \SELECT from_key, to_key, kind FROM taint_edge_global \
        \UNION ALL \
        \SELECT from_key, to_key, kind FROM taint_edge_return"

        -- Source view: key projection from taint_sources.
      , "CREATE OR REPLACE VIEW taint_source AS \
        \SELECT DISTINCT object || '::' || proc_name || '::' || var_name AS x \
        \FROM taint_sources"

        -- Sink view: key projection from taint_sinks.
      , "CREATE OR REPLACE VIEW taint_sink AS \
        \SELECT DISTINCT object || '::' || proc_name || '::' || var_name AS x \
        \FROM taint_sinks"
      ]

-- ---------------------------------------------------------------------------
-- Concrete program
-- ---------------------------------------------------------------------------

taintEdgeRel, taintSourceRel, taintSinkRel, taintReachesRel,
  taintMinDistRel, taintPathLegRel, taintConfirmedRel, taintStepKindRel :: Relation
taintEdgeRel     = symRelation "taint_edge"     ["from_key", "to_key", "kind"]
taintSourceRel   = symRelation "taint_source"   ["x"]
taintSinkRel     = symRelation "taint_sink"     ["x"]
taintReachesRel  = Relation "taint_reaches"
                     [("x", "symbol"), ("y", "symbol")]
taintMinDistRel  = Relation "taint_min_dist"
                     [("s", "symbol"), ("node", "symbol"), ("dist", "number")]
taintPathLegRel  = Relation "taint_path_leg"
                     [("s","symbol"),("target","symbol"),("leg_ord","number"),
                      ("lf","symbol"),("lt","symbol"),("kind","symbol")]
taintConfirmedRel = symRelation "taint_confirmed" ["s", "t"]
-- | Plan 171b (2026-07-15): the step_kind/description label for each
-- witness leg, derived via rule specialization instead of the SQL CASE
-- that used to live in materializeTaintPaths. Rule 1 tags the leg
-- starting at the source (leg_ord 0) as "source" regardless of its real
-- edge kind. Rule 2 passes the edge kind through unchanged for every
-- other leg. Rule 3 derives the terminal "arrived at sink" marker row one
-- ordinal past the last witness leg (max-aggregate, same idiom legRules
-- uses for priority and cosliceRules for min_dist), guarded s != t so it
-- only fires for a genuine multi-hop path. Rule 4 is the 0-hop
-- degenerate case (source == sink): a single "source-sink" row, no
-- witness legs exist for taint_path_leg to derive at all.
taintStepKindRel = Relation "taint_step_kind"
                     [("s","symbol"),("t","symbol"),("leg_ord","number"),
                      ("lf","symbol"),("lt","symbol"),("kind","symbol"),
                      ("step_kind","symbol"),("description","symbol")]

-- | The taint Datalog program.
--
-- Forward-only (taint flows source→sink, no backward half unlike
-- cosliceRules).  @taint_min_dist@ uses @choice-domain (s, node)@
-- for cycle termination — same mechanism as cosliceRules' min_dist.
-- @taint_path_leg@ emits witness legs bounded by the shortest-path
-- envelope.  @taint_confirmed@ identifies (source, sink) pairs with
-- any path.
taintRules :: RuleSet
taintRules = RuleSet
  { rsRelations =
      [ taintReachesRel, taintMinDistRel, taintPathLegRel, taintConfirmedRel
      , taintStepKindRel
      ]
  , rsRules =
      [ -- Transitive closure: exists so taint_path_leg can bound
        -- intermediate hops.
        Rule "taint_reaches(x, y) :- taint_edge(x, y, _)"
          [taintReachesRel, taintEdgeRel]
      , Rule "taint_reaches(x, z) :- taint_reaches(x, y), taint_edge(y, z, _)"
          [taintReachesRel, taintEdgeRel]

        -- Shortest distance per (source, node).
        -- choice-domain (s, node) ensures termination on cyclic
        -- graphs: Souffle locks each (s, node) key to the FIRST
        -- distance derived and drops later tuples.  n != s blocks
        -- the seed's own distance-0 tuple from being overwritten
        -- before choice-domain locks it in on iteration 0.
      , Rule "taint_min_dist(s, s, 0) :- taint_source(s)"
          [taintMinDistRel, taintSourceRel]
      , Rule "taint_min_dist(s, n, dprev + 1) :- taint_min_dist(s, p, dprev), taint_edge(p, n, _), n != s"
          [taintMinDistRel, taintEdgeRel]

        -- Path legs: two unioned rules express the disjunction
        -- (LT = T ; reaches(LT, T)).
        -- Rule 1: intermediate hop — leg lands at lt, lt reaches t,
        --          bounded strictly within t's shortest-path envelope.
        -- Rule 2: terminal hop — leg lands directly at t.
        --
        -- @taint_sink(t)@ guard (found on a 1763-file/300KLOC production
        -- corpus, alongside the legRules O(group_size^2) fix): every
        -- downstream consumer of taint_path_leg/taint_step_kind
        -- (materializeTaintPaths, DuckDb.hs) only ever reads rows whose
        -- (s, t) pair is in taint_confirmed, which already requires
        -- taint_sink(t) -- so without this guard, taint_path_leg/
        -- taint_step_kind were computed for EVERY node t reachable from a
        -- source (the shortest-path witness for every intermediate
        -- variable a taint value ever flows through), not just the small
        -- number of real sinks, then silently filtered down to the
        -- confirmed subset by materializeTaintPaths' own SQL JOIN. Adding
        -- the guard here prunes that provably-wasted work at the source
        -- instead of after the fact. Verified against the real souffle 2.5
        -- CLI on a synthetic 100-source/7,000-edge/20-sink fixture (each
        -- source fanning out to thousands of non-sink nodes, mirroring a
        -- real corpus' shared-utility-layer shape): 11.7s/121MB -> 0.75s/
        -- 28MB (15.6x/4.3x), taint_path_leg 405,000 -> 4,000 rows (101x),
        -- taint_step_kind 407,000 -> 6,000 rows (68x) -- and confirmed
        -- byte-identical final output: taint_confirmed unchanged, and
        -- taint_step_kind rows restricted to confirmed (s, t) pairs (the
        -- only ones materializeTaintPaths ever reads) are identical between
        -- guarded and unguarded versions. taint_min_dist/taint_reaches
        -- themselves are untouched by this guard (still computed to every
        -- reachable node -- they must be, since the BFS has to pass through
        -- non-sink intermediates en route to a distant sink) -- this only
        -- prunes witness-LEG reconstruction, not the underlying distance
        -- fixpoint.
      , Rule "taint_path_leg(s, t, o, lf, lt, kind) :- taint_sink(t), taint_min_dist(s, lf, o), taint_edge(lf, lt, kind), taint_min_dist(s, lt, o + 1), taint_min_dist(s, t, td), o + 1 < td, taint_reaches(lt, t)"
          [taintPathLegRel, taintSinkRel, taintMinDistRel, taintEdgeRel, taintReachesRel]
      , Rule "taint_path_leg(s, t, o, lf, t, kind) :- taint_sink(t), taint_min_dist(s, lf, o), taint_edge(lf, t, kind), taint_min_dist(s, t, o + 1)"
          [taintPathLegRel, taintSinkRel, taintMinDistRel, taintEdgeRel]

        -- Confirmed: source→sink pair with any path.
      , Rule "taint_confirmed(s, t) :- taint_source(s), taint_sink(t), taint_min_dist(s, t, _)"
          [taintConfirmedRel, taintSourceRel, taintSinkRel, taintMinDistRel]

        -- Plan 171b: step_kind/description labeling via rule
        -- specialization (replaces materializeTaintPaths' SQL CASE).
        -- Rule 1: the leg starting at the source is always "source",
        --          regardless of its real edge kind.
      , Rule "taint_step_kind(s, t, 0, lf, lt, kind, \"source\", \"taint source\") :- taint_path_leg(s, t, 0, lf, lt, kind)"
          [taintStepKindRel, taintPathLegRel]
        -- Rule 2: every other witness leg passes its edge kind through
        --          unchanged as both step_kind and (via cat) the
        --          description.
      , Rule "taint_step_kind(s, t, o, lf, lt, kind, kind, cat(\"taint propagation via \", kind)) :- taint_path_leg(s, t, o, lf, lt, kind), o != 0"
          [taintStepKindRel, taintPathLegRel]
        -- Rule 3: terminal "arrived at sink" marker, one ordinal past
        --          the last witness leg. Guarded s != t so it only
        --          fires for a genuine multi-hop path (the 0-hop case
        --          is Rule 4, below) — a confirmed pair always has at
        --          least one taint_path_leg row when s != t, so the max
        --          aggregate's domain is never empty here.
      , Rule "taint_step_kind(s, t, maxord + 1, t, t, \"sink\", \"sink\", \"taint propagation via sink\") :- taint_confirmed(s, t), s != t, maxord = max o : { taint_path_leg(s, t, o, _, _, _) }"
          [taintStepKindRel, taintConfirmedRel, taintPathLegRel]
        -- Rule 4: 0-hop degenerate case (source == sink) — a single
        --          "source-sink" row; taint_path_leg has no rows for
        --          this pair since there is no edge to traverse.
      , Rule "taint_step_kind(s, s, 0, s, s, \"sink\", \"source-sink\", \"taint source and sink (same variable)\") :- taint_confirmed(s, s)"
          [taintStepKindRel, taintConfirmedRel]
      ]
  , rsChoiceDomains =
      [ ("taint_min_dist", ["s", "node"])
      ]
  }
