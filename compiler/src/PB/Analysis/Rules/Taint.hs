-- | Taint-flow EDB relations and Datalog rules, computed via Souffle.
--
-- The four edge relations (intra-proc def-use, arg, return, global-write)
-- are pure structural joins\/filters over @proc_defs@\/@proc_uses@\/
-- @interproc_edges@, unioned into @taint_edge@. The Datalog program
-- computes transitive reachability (@taint_reaches@, seeded from
-- @taint_source@) and source→sink confirmation (@taint_confirmed@).
-- Witness-path reconstruction (@taint_step_kind@) runs separately in
-- Haskell -- see 'reconstructTaintStepKind''s own doc comment.
module PB.Analysis.Rules.Taint
  ( initTaintEdbViews
  , initTaintEdbViewsWith
  , DefUseFanout (..)
  , defLineFanout
  , returnUseFanout
  , taintRules
  , materializeTaintClosure
  , reconstructTaintStepKind
  , taintEdgeIntraRows
  , taintEdgeArgRows
  , taintEdgeGlobalRows
  , taintEdgeReturnRows
  , taintKeyRows
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb
  ( DuckConn, queryTextRows, recreateTextTable, appendTextRows
  , queryProcDefs, queryProcUses
  , InterprocEdgeRow (..), queryInterprocEdges
  , TaintKeyRow (..), queryTaintSourceRows, queryTaintSinkRows
  )
import PB.Analysis.Taint qualified as Taint
import PB.Analysis.TaintEdges qualified as TaintEdges
import PB.Analysis.TaintAlgebra (taintReachesPairs, taintConfirmed)
import Database.DuckDB.Simple (Query (..), query_)
import Database.DuckDB.Simple.FromRow (FromRow (..), field)

import qualified Data.HashMap.Strict as HM
import qualified Data.List           as List
import qualified Data.Sequence       as Seq
import qualified Data.Set            as Set
import qualified Data.Text           as T

-- ---------------------------------------------------------------------------
-- EDB relations
-- ---------------------------------------------------------------------------

-- | (Re)materialize the taint EDB relations. Must run after
-- 'PB.Pipeline.Passes.runPass67' populates @proc_defs@\/@proc_uses@\/
-- @interproc_edges@\/@taint_sources@\/@taint_sinks@.
--
-- @taint_edge@ is the union of four edge shapes, each producing
-- @(from_key, to_key, kind)@ where a key is @object::proc::var@.
-- @taint_source@\/@taint_sink@ project the key from the classified
-- source\/sink tables. The four edge lists are combined in memory rather
-- than each materialized under its own name -- nothing reads them except
-- via this union.
initTaintEdbViews :: DuckConn -> IO ()
initTaintEdbViews = initTaintEdbViewsWith (\_ -> pure ())

-- | As 'initTaintEdbViews', but additionally invokes @onCounts@ with a
-- named checkpoint after every individual step: a cheap metadata-level
-- @COUNT(*)@ for all five source tables first (fast even if a later full
-- fetch hangs), then one checkpoint per full-row fetch, one after the four
-- edge shapes combine into @taint_edge@'s row list, and one after each of
-- the three DB writes -- lets a caller (e.g.
-- 'PB.Pipeline.Passes.runPhaseB') narrow a stall down to a specific query,
-- the in-memory join, or a specific write, without threading printing
-- logic into this module (mirrors 'PB.Pipeline.Souffle.runRuleSetWith'\'s
-- callback shape).
initTaintEdbViewsWith :: ([(Text, Int)] -> IO ()) -> DuckConn -> IO ()
initTaintEdbViewsWith onCounts conn = do
  fastCounts <- mapM (\t -> (t,) <$> tableRowCount conn t)
    ["proc_defs", "proc_uses", "interproc_edges", "taint_sources", "taint_sinks"]
  onCounts fastCounts
  defs  <- queryProcDefs conn
  onCounts [("proc_defs_fetched", length defs)]
  uses  <- queryProcUses conn
  onCounts [("proc_uses_fetched", length uses)]
  edges <- queryInterprocEdges conn
  onCounts [("interproc_edges_fetched", length edges)]
  srcs  <- queryTaintSourceRows conn
  onCounts [("taint_sources_fetched", length srcs)]
  snks  <- queryTaintSinkRows conn
  onCounts [("taint_sinks_fetched", length snks)]
  let edgeRows = taintEdgeIntraRows defs uses
              ++ taintEdgeArgRows edges
              ++ taintEdgeGlobalRows edges
              ++ taintEdgeReturnRows uses edges
  onCounts [("taint_edge_rows", length edgeRows)]
  materialize "taint_edge"   ["from_key", "to_key", "kind"] edgeRows
  onCounts [("taint_edge_written", 1)]
  materialize "taint_source" ["x"] (taintKeyRows srcs)
  onCounts [("taint_source_written", 1)]
  materialize "taint_sink"   ["x"] (taintKeyRows snks)
  onCounts [("taint_sink_written", 1)]
  where
    materialize name cols rows = do
      recreateTextTable conn name cols
      appendTextRows conn name rows

-- | Cheap metadata-level row count for a table -- lets a caller distinguish
-- "this table is merely large" (fast @COUNT(*)@) from "fetching every row
-- into Haskell via 'Database.DuckDB.Simple.FromRow' is itself slow".
newtype CountRow = CountRow Int

instance FromRow CountRow where
  fromRow = CountRow <$> field

tableRowCount :: DuckConn -> Text -> IO Int
tableRowCount conn tbl = do
  rows <- query_ conn (Query ("SELECT COUNT(*) FROM " <> tbl))
  pure $ case rows of
    [CountRow n] -> n
    _            -> 0

-- | Fan-in characterization for a grouped-join key, mirroring
-- 'PB.Analysis.Rules.Schema.LegSourceFanout' -- computed directly in
-- DuckDB SQL against the already-materialized @proc_defs@\/@proc_uses@
-- tables (not the in-memory Haskell lists), so it's cheap to run even when
-- the actual join ('taintEdgeIntraRows'\/'taintEdgeReturnRows') is the one
-- hanging.
data DefUseFanout = DefUseFanout
  { dufTotalRows    :: !Int
  , dufDistinctKeys :: !Int
  , dufMaxGroupSize :: !Int
  } deriving (Eq, Show)

newtype FanoutRow = FanoutRow DefUseFanout

instance FromRow FanoutRow where
  fromRow = (\t k m -> FanoutRow (DefUseFanout t k m)) <$> field <*> field <*> field

-- | Fan-in of @proc_defs@ rows sharing one (object, proc_name, line) key --
-- 'taintEdgeIntraRows' groups on this exact key via its internal
-- @defsByLine@.
defLineFanout :: DuckConn -> IO DefUseFanout
defLineFanout conn = do
  rows <- query_ conn
    "WITH g AS (SELECT object, proc_name, line, COUNT(*) AS cnt FROM proc_defs \
    \WHERE line IS NOT NULL GROUP BY object, proc_name, line) \
    \SELECT (SELECT COUNT(*) FROM proc_defs WHERE line IS NOT NULL), \
    \COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow f] -> f
    _             -> DefUseFanout 0 0 0

-- | Fan-in of @proc_uses@ rows tagged @kind = 'return'@ sharing one
-- (object, proc_name) key -- 'taintEdgeReturnRows' groups on this exact key
-- via its internal @returnUsesByCallee@.
returnUseFanout :: DuckConn -> IO DefUseFanout
returnUseFanout conn = do
  rows <- query_ conn
    "WITH g AS (SELECT object, proc_name, COUNT(*) AS cnt FROM proc_uses \
    \WHERE kind = 'return' GROUP BY object, proc_name) \
    \SELECT (SELECT COUNT(*) FROM proc_uses WHERE kind = 'return'), \
    \COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow f] -> f
    _             -> DefUseFanout 0 0 0

-- | The @object::proc::var@ key every taint EDB relation joins on.
taintKey :: Text -> Text -> Text -> Text
taintKey obj proc var = obj <> "::" <> proc <> "::" <> var

-- | Intra-proc def-use edge: a use of one var at line L and a def of a
-- DIFFERENT var at the same line L, in the same (object, proc). A def with
-- no recorded line can never join (its line can't equal any use's line); a
-- use and def sharing both line and var name are the same assignment, not
-- a flow, so that pair is excluded explicitly.
taintEdgeIntraRows :: [Taint.DefRow] -> [Taint.UseRow] -> [[Text]]
taintEdgeIntraRows defs uses =
  [ [ taintKey (Taint.urObject u) (Taint.urProcName u) (Taint.urVarName u)
    , taintKey (Taint.drObject d) (Taint.drProcName d) (Taint.drVarName d)
    , "def"
    ]
  | u <- uses
  , Just line <- [Taint.urLine u]
  , d <- HM.findWithDefault [] (Taint.urObject u, Taint.urProcName u, line) defsByLine
  , Taint.urVarName u /= Taint.drVarName d
  ]
  where
    defsByLine :: HM.HashMap (Text, Text, Int) [Taint.DefRow]
    defsByLine = HM.fromListWith (++)
      [ ((Taint.drObject d, Taint.drProcName d, line), [d])
      | d <- defs, Just line <- [Taint.drLine d]
      ]

-- | Arg edge: a straight projection of @interproc_edges@ rows tagged
-- @edge_kind = "arg"@.
taintEdgeArgRows :: [InterprocEdgeRow] -> [[Text]]
taintEdgeArgRows edges =
  [ [ taintKey (ierCallerObject e) (ierCallerProc e) (ierCallerContext e)
    , taintKey (ierCalleeObject e) (ierCalleeProc e) (ierCalleeContext e)
    , "arg"
    ]
  | e <- edges, ierEdgeKind e == "arg"
  ]

-- | Global write edge: same shape as 'taintEdgeArgRows', tagged
-- @edge_kind = "global_write"@ -- the caller side keys on the written
-- global's own name rather than a call-site context.
taintEdgeGlobalRows :: [InterprocEdgeRow] -> [[Text]]
taintEdgeGlobalRows edges =
  [ [ taintKey (ierCallerObject e) (ierCallerProc e) (ierVarName e)
    , taintKey (ierCalleeObject e) (ierCalleeProc e) (ierCalleeContext e)
    , "global"
    ]
  | e <- edges, ierEdgeKind e == "global_write"
  ]

-- | Return edge: an @interproc_edges@ row tagged @edge_kind = "return"@,
-- joined against a @proc_uses@ row tagged @kind = "return"@ in the callee.
-- The @interproc_edges@ row's own callee context is the literal string
-- "return", not a real variable -- the actual tainted-from node is
-- whichever var the callee itself uses with kind "return".
taintEdgeReturnRows :: [Taint.UseRow] -> [InterprocEdgeRow] -> [[Text]]
taintEdgeReturnRows uses edges =
  [ [ taintKey (Taint.urObject u) (Taint.urProcName u) (Taint.urVarName u)
    , taintKey (ierCallerObject e) (ierCallerProc e) (ierCallerContext e)
    , "return"
    ]
  | e <- edges, ierEdgeKind e == "return"
  , u <- HM.findWithDefault [] (ierCalleeObject e, ierCalleeProc e) returnUsesByCallee
  ]
  where
    returnUsesByCallee :: HM.HashMap (Text, Text) [Taint.UseRow]
    returnUsesByCallee = HM.fromListWith (++)
      [ ((Taint.urObject u, Taint.urProcName u), [u])
      | u <- uses, Taint.urKind u == "return"
      ]

-- | Distinct @object::proc::var@ keys from a @taint_sources@\/
-- @taint_sinks@ read -- shared by @taint_source@ and @taint_sink@, which
-- project the identical key shape from their own tables.
taintKeyRows :: [TaintKeyRow] -> [[Text]]
taintKeyRows rows = map (: []) . Set.toList . Set.fromList $
  [ taintKey (tkrObject r) (tkrProcName r) (tkrVarName r) | r <- rows ]

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

-- | The taint Datalog program: forward-only reachability (taint flows
-- source→sink, no backward half unlike cosliceRules) plus source→sink
-- confirmation. Witness-path reconstruction (@taint_step_kind@) is computed
-- separately, in Haskell -- see 'reconstructTaintStepKind'.
taintRules :: RuleSet
taintRules = RuleSet
  { rsRelations =
      [ taintReachesRel, taintConfirmedRel ]
  , rsRules =
      [ -- Seeded ONLY from taint_source, not every node with an outgoing
        -- edge: materializeTaintAnnotations (DuckDb.hs) is the sole other
        -- consumer of taint_reaches, and it already discards every (x, y)
        -- row where x isn't a taint_source via its own downstream
        -- Set.member filter -- so this seeding computes exactly the same
        -- final (x, y) pairs an unrestricted seed would, without rooting
        -- the closure at every other node too. An unrestricted seed is
        -- also strictly more expensive: every node along a chain becomes
        -- its own separate seed, so row count grows with the square of
        -- chain length rather than linearly.
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
-- Production closure materialization (Plan 182 cutover, 2026-07-18)
-- ---------------------------------------------------------------------------

-- | Materialize @taint_reaches@\/@taint_confirmed@ from the algebraic
-- closure ('PB.Analysis.TaintAlgebra') instead of running 'taintRules'
-- through Souffle -- production's source for those two tables since the
-- Plan 182 cutover. Takes the same already-computed inputs
-- 'PB.Pipeline.Passes.runPass67' builds for its interproc-edge\/
-- source\/sink classification, so no extra DB round-trip is needed.
-- 'taintRules' itself is unchanged and still runs on demand (the
-- oracle-diff test suite, the UI's SQL\/Datalog exploration surface).
materializeTaintClosure
  :: [Taint.TaintSource] -> [Taint.TaintSink] -> [TaintEdges.TaintIntraEdgeRow] -> [TaintEdges.TaintReturnRow]
  -> [Taint.DefRow] -> [Taint.UseRow] -> [Taint.InterprocEdge] -> DuckConn -> IO ()
materializeTaintClosure sources sinks intraEdges returnRows defs uses edges conn = do
  let reaches   = taintReachesPairs sources intraEdges returnRows defs uses edges
      confirmed = taintConfirmed sources sinks intraEdges returnRows defs uses edges
      reachRows =
        [ [taintKey ox px vx, taintKey oy py vy]
        | ((ox, px, vx), (oy, py, vy)) <- reaches
        ]
      confirmedRows =
        [ [ taintKey (Taint.tsObject s) (Taint.tsProcName s) (Taint.tsVarName s)
          , taintKey (Taint.tskObject k) (Taint.tskProcName k) (Taint.tskVarName k)
          ]
        | (s, k) <- confirmed
        ]
  recreateTextTable conn "taint_reaches" ["x", "y"]
  appendTextRows conn "taint_reaches" reachRows
  recreateTextTable conn "taint_confirmed" ["s", "t"]
  appendTextRows conn "taint_confirmed" confirmedRows

-- ---------------------------------------------------------------------------
-- Witness-path reconstruction
-- ---------------------------------------------------------------------------

-- | Rebuild @taint_step_kind@ via one BFS per live source, shared across
-- all of that source's confirmed sinks through a parent-pointer map, plus a
-- cheap backward walk per confirmed (source, sink) pair -- mirrors the
-- 'PB.Analysis.Taint.propagateTaint'\/'PB.Analysis.Taint.traceTaintPath'
-- split: one BFS per source (O(V+E) each, not a distance table to every
-- reachable node), then a cheap backward walk per confirmed pair.
-- Materializing a full (source, node) distance table for every live source
-- instead is inherently O(#live_sources x avg-reachable-set-size), which
-- dominates cost on a corpus whose taint graph has a shared-utility-layer
-- shape (many sources funnel through the same hub procedures) -- computing
-- @taint_reaches@\/@taint_confirmed@ alone (no witness reconstruction) is
-- orders of magnitude cheaper than adding that per-source distance table
-- would be.
--
-- Preserves full per-(source,sink) attribution rather than collapsing to
-- one path per sink -- every distinct attack vector is reported, a richer
-- security signal than a single representative path. When multiple edges
-- tie for the same BFS distance, this picks the lexicographically smallest
-- @(to, kind)@ pair at each step (adjacency pre-sorted) -- a deterministic
-- but arbitrary tie-break: the confirmed-pair set, path lengths, and
-- step_kind semantics are unaffected, only which equally-short diamond edge
-- is reported as the witness.
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
