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
  taintMinDistRel, taintPathLegRel, taintConfirmedRel :: Relation
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
      , Rule "taint_path_leg(s, t, o, lf, lt, kind) :- taint_min_dist(s, lf, o), taint_edge(lf, lt, kind), taint_min_dist(s, lt, o + 1), taint_min_dist(s, t, td), o + 1 < td, taint_reaches(lt, t)"
          [taintPathLegRel, taintMinDistRel, taintEdgeRel, taintReachesRel]
      , Rule "taint_path_leg(s, t, o, lf, t, kind) :- taint_min_dist(s, lf, o), taint_edge(lf, t, kind), taint_min_dist(s, t, o + 1)"
          [taintPathLegRel, taintMinDistRel, taintEdgeRel]

        -- Confirmed: source→sink pair with any path.
      , Rule "taint_confirmed(s, t) :- taint_source(s), taint_sink(t), taint_min_dist(s, t, _)"
          [taintConfirmedRel, taintSourceRel, taintSinkRel, taintMinDistRel]
      ]
  , rsChoiceDomains =
      [ ("taint_min_dist", ["s", "node"])
      ]
  }
