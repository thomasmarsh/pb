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
  , reconstructTaintStepKind
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb (DuckConn, queryTextRows, recreateTextTable, appendTextRows)
import Database.DuckDB.Simple (Query (..), execute_)

import qualified Data.HashMap.Strict as HM
import qualified Data.List           as List
import qualified Data.Sequence       as Seq
import qualified Data.Set            as Set
import qualified Data.Text           as T

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
  taintConfirmedRel :: Relation
taintEdgeRel     = symRelation "taint_edge"     ["from_key", "to_key", "kind"]
taintSourceRel   = symRelation "taint_source"   ["x"]
taintSinkRel     = symRelation "taint_sink"     ["x"]
taintReachesRel  = Relation "taint_reaches"
                     [("x", "symbol"), ("y", "symbol")]
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
      [ taintReachesRel, taintConfirmedRel ]
  , rsRules =
      [ -- Transitive closure, seeded ONLY from taint_source (not every node
        -- with an outgoing edge): materializeTaintAnnotations (DuckDb.hs)
        -- is the sole other consumer of taint_reaches, and it already
        -- discards every (x, y) row where x isn't a taint_source via its
        -- own downstream Set.member filter -- so seeding only from
        -- taint_source computes exactly the same final (x, y) pairs, just
        -- without wastefully rooting the closure at every other node too.
        -- Verified byte-identical against the unrestricted version (with
        -- the old seed's output filtered to x ∈ taint_source) on two
        -- synthetic fixtures. This is the dominant cost on a real
        -- 1763-file/300KLOC corpus: on a synthetic 420-source/63,000-edge
        -- fixture shaped like real code (most tainted locals are dead ends
        -- that never reach a sink, a few chains do), the OLD unrestricted
        -- taint_reaches produced 4,756,500 rows (O(chain_length^2) per
        -- chain, since every node along a chain was ALSO its own separate
        -- seed) where the source-seeded version produces the 63,000 rows
        -- actually needed.
        Rule "taint_reaches(x, y) :- taint_source(x), taint_edge(x, y, _)"
          [taintReachesRel, taintSourceRel, taintEdgeRel]
      , Rule "taint_reaches(x, z) :- taint_reaches(x, y), taint_edge(y, z, _)"
          [taintReachesRel, taintEdgeRel]

        -- Confirmed: source→sink pair with any path.
        --
        -- Two rules, not one: taint_reaches only derives via 1+ REAL
        -- edges (no reflexive base case), so the 0-hop (source == sink,
        -- same variable) case needs its own rule. Caught by the existing
        -- "0-hop source-equals-sink pair" SouffleTaintTest.hs fixture.
        -- Rule 1 covers it explicitly (independent of any edge); rule 2
        -- is the general multi-hop case.
      , Rule "taint_confirmed(s, s) :- taint_source(s), taint_sink(s)"
          [taintConfirmedRel, taintSourceRel, taintSinkRel]
      , Rule "taint_confirmed(s, t) :- taint_source(s), taint_sink(t), taint_reaches(s, t)"
          [taintConfirmedRel, taintSourceRel, taintSinkRel, taintReachesRel]
      ]
  , rsChoiceDomains = []
  }

-- ---------------------------------------------------------------------------
-- Witness-path reconstruction (moved out of Souffle, 2026-07-16)
-- ---------------------------------------------------------------------------

-- | Rebuild @taint_step_kind@ in Haskell via one BFS per live source plus a
-- cheap backward walk per confirmed sink, instead of Souffle's
-- @taint_min_dist@\/@taint_path_leg@ per-source shortest-distance fixpoint
-- (PERFORMANCE FIX, 2026-07-16, same production incident as the four
-- @taintRules@ seed-restriction fixes above -- see
-- @doc\/plan\/171-datalog-decision-migration.md@'s Postscript). Materializing
-- a full (source, node) distance table for EVERY live source is inherently
-- O(#live_sources x avg-reachable-set-size), which explodes on a real
-- corpus' shared-utility-layer graph shape regardless of seed restriction: a
-- synthetic 1,800-source\/700-sink hub fixture with only ~11K edges (27x
-- FEWER than the real corpus' 301,754) took 190s\/4.66GB under the
-- fully-fixed Datalog rules, yet @taint_reaches@\/@taint_confirmed@ ALONE
-- (no witness reconstruction) computed the SAME fixture in 0.79s\/41MB --
-- essentially all the cost was witness-path reconstruction, not knowing
-- which (source, sink) pairs are confirmed. This mirrors the pre-Datalog
-- 'PB.Analysis.Taint.propagateTaint'\/'PB.Analysis.Taint.traceTaintPath'
-- split exactly: one BFS per source (O(V+E) each, not a distance table to
-- every reachable node), then a cheap backward walk per confirmed pair. A
-- naive unoptimized Python port of this same one-BFS-per-source-plus-
-- backward-walk shape reconstructed all 646,196 confirmed pairs on that
-- fixture in 31.3s (48us\/pair); this compiled Haskell version, sharing one
-- parent tree across all of a source's sinks (not recomputed per pair), is
-- expected to be faster still.
--
-- TIE-BREAK NOTE: preserves full per-(source,sink) attribution (kept over
-- collapsing to one path per SINK, per explicit user direction -- a real
-- security-tool product decision, not a perf shortcut) -- but when
-- multiple edges tie for the same BFS distance, this picks the
-- lexicographically smallest (to, kind) at each step (adjacency
-- pre-sorted), a deterministic but not necessarily identical choice to the
-- old Datalog+SQL @ranked_legs@ tie-break (which chose per (source,sink)
-- pair independently, not from one shared per-source tree). Documented
-- cosmetic shape delta, same category Plan 171b already accepted for
-- steps_json content: the confirmed-pair set, path lengths, and step_kind
-- semantics are unaffected -- only WHICH equally-short diamond edge wins
-- when the choice was already arbitrary.
reconstructTaintStepKind :: DuckConn -> IO ()
reconstructTaintStepKind conn = do
  edgeRows      <- queryTextRows conn "taint_edge" ["from_key", "to_key", "kind"]
  confirmedRows <- queryTextRows conn "taint_confirmed" ["s", "t"]
  let adjacency :: HM.HashMap Text [(Text, Text)]
      adjacency = HM.map (List.sortOn id) (HM.fromListWith (++)
        [ (from, [(to, kind)]) | [from, to, kind] <- edgeRows ])

      confirmedBySource :: HM.HashMap Text [Text]
      confirmedBySource = HM.fromListWith (++)
        [ (s, [t]) | [s, t] <- confirmedRows ]

      reconstructForSource :: (Text, [Text]) -> [[Text]]
      reconstructForSource (source, sinks) =
        let parents = bfsParents adjacency source
        in concatMap (legRowsFor source parents) sinks

      rows = concatMap reconstructForSource (HM.toList confirmedBySource)

  recreateTextTable conn "taint_step_kind"
    ["s", "t", "leg_ord", "lf", "lt", "kind", "step_kind", "description"]
  appendTextRows conn "taint_step_kind" rows

-- | One BFS from a single source over the taint graph, producing a
-- parent-pointer map: each discovered non-source node maps to (parent
-- node, edge kind used to reach it). Same worklist-BFS shape as
-- 'PB.Analysis.Taint.propagateTaint', but graph-structural only
-- (already-flattened @taint_edge@ triples, no def-use\/line bookkeeping)
-- and scoped to ONE source rather than a shared multi-source queue -- so
-- distinct sources reconstruct distinct witness paths (preserving
-- per-source attribution), unlike 'PB.Analysis.Taint.propagateTaint's
-- single global tree. Adjacency lists are pre-sorted ascending by
-- @(to, kind)@ (see 'reconstructTaintStepKind'), so ties among parallel
-- edges into the same node resolve deterministically to the
-- lexicographically smallest @(to, kind)@ pair.
bfsParents :: HM.HashMap Text [(Text, Text)] -> Text -> HM.HashMap Text (Text, Text)
bfsParents adjacency source = go (Set.singleton source) HM.empty (Seq.singleton source)
  where
    go :: Set.Set Text -> HM.HashMap Text (Text, Text) -> Seq.Seq Text
       -> HM.HashMap Text (Text, Text)
    go visited parents queue = case Seq.viewl queue of
      Seq.EmptyL -> parents
      cur Seq.:< rest ->
        let candidates = HM.findWithDefault [] cur adjacency
            fresh       = firstPerTarget
              [ (to, kind) | (to, kind) <- candidates, to `Set.notMember` visited ]
            visited'    = foldr (Set.insert . fst) visited fresh
            parents'    = foldr (\(to, kind) m -> HM.insert to (cur, kind) m) parents fresh
            queue'      = rest Seq.>< Seq.fromList (map fst fresh)
        in go visited' parents' queue'

-- | Keep only the first @(to, kind)@ pair per distinct @to@ -- parallel
-- edges into the same node at the same BFS layer collapse to one witness,
-- deterministically the smallest since the input is pre-sorted.
firstPerTarget :: [(Text, Text)] -> [(Text, Text)]
firstPerTarget = go' Set.empty
  where
    go' _ [] = []
    go' seen ((to, kind) : rest)
      | to `Set.member` seen = go' seen rest
      | otherwise            = (to, kind) : go' (Set.insert to seen) rest

-- | Backward-walk a source's BFS parent tree from one confirmed sink,
-- producing @taint_step_kind@-shaped rows for that (source, sink) pair --
-- mirrors 'PB.Analysis.Taint.traceTaintPath's backward provenance walk,
-- reading the (source,sink)-agnostic parent map 'bfsParents' builds once
-- per source. Row shape\/labeling matches the four Datalog rules this
-- function replaces exactly: leg_ord 0 is always \"source\" regardless of
-- its real edge kind; every other leg passes its edge kind through as both
-- step_kind and description; a terminal \"sink\" marker lands one ordinal
-- past the last leg; the 0-hop (source == sink) case is a single
-- \"source-sink\" row with no real edge.
legRowsFor :: Text -> HM.HashMap Text (Text, Text) -> Text -> [[Text]]
legRowsFor source parents sink
  | source == sink =
      [[source, source, "0", source, source, "sink", "source-sink",
        "taint source and sink (same variable)"]]
  | otherwise =
      let chain    = walkBack sink []
          legs     = [ legRow o lf lt kind | (o, (lf, lt, kind)) <- zip [0 :: Int ..] chain ]
          terminal = [source, sink, T.pack (show (length chain)), sink, sink,
                      "sink", "sink", "taint propagation via sink"]
      in legs ++ [terminal]
  where
    legRow :: Int -> Text -> Text -> Text -> [Text]
    legRow 0 lf lt kind = [source, sink, "0", lf, lt, kind, "source", "taint source"]
    legRow o lf lt kind = [source, sink, T.pack (show o), lf, lt, kind, kind,
                            "taint propagation via " <> kind]

    -- Walk backward from 'cur' to 'source' via 'parents', accumulating
    -- (from, to, kind) legs in source -> sink order (each step is
    -- prepended, so the hop closest to 'source' -- discovered LAST in the
    -- backward walk -- ends up FIRST in the result).
    walkBack :: Text -> [(Text, Text, Text)] -> [(Text, Text, Text)]
    walkBack cur acc
      | cur == source = acc
      | otherwise = case HM.lookup cur parents of
          Just (p, kind) -> walkBack p ((p, cur, kind) : acc)
          Nothing -> error
            ("PB.Analysis.Rules.Taint.legRowsFor: impossible: " <> T.unpack cur
              <> " has no BFS parent despite being taint_confirmed reachable from "
              <> T.unpack source)
