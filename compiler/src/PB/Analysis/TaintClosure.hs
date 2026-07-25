{-# LANGUAGE StrictData #-}
{-# LANGUAGE RecordWildCards #-}
-- | Algebraic taint closure: a semiring-weighted reachability computation
-- over an interned relation, replacing 'PB.Analysis.Taint.propagateTaint''s
-- BFS (and the separate backward walk) with
-- 'PB.Algebra.Closure.reachFrom' — a sparse worklist relaxation from the
-- taint sources, not an all-pairs closure (which
-- is asymptotically wrong for a large sparse graph with a small seed set;
-- see doc/plan/182-algebraic-analysis.md Section 11 for the real-corpus
-- evidence: an all-pairs closure was >15,000x slower than the BFS oracle).
--
-- The edge relation is *identical* to the one 'propagateTaint' walks: the
-- four rules (intra-proc same-line def-use, arg, return, global-hub)
-- are re-stated as a pure successor function so the BFS and the algebraic
-- closure consume the same arcs — the A/B test in 'TaintClosureTest'
-- proves they agree.
--
-- See doc/plan/182-algebraic-analysis.md.
module PB.Analysis.TaintClosure
  ( TaintTriple
  , TaintClosure
  , buildTaintClosure
  , taintPathRelation
  , taintReachable
  , taintReachesPairs
  , taintConfirmed
  , taintWitnesses
  , taintWitnessLegs
  , materializeTaintClosure
  , materializeTaintStepKind
  ) where

import PB.Prelude
import PB.Analysis.Taint
  ( InterprocEdge (..)
  , TaintSource (..)
  , TaintSink (..)
  )
import PB.Analysis.Taint qualified as Taint
import PB.Analysis.TaintEdges (TaintIntraEdgeRow (..), TaintReturnRow (..))
import PB.Algebra.Semiring (PathValue (..))
import PB.Algebra.Closure
  ( Interner (..)
  , emptyInterner
  , intern
  , unintern
  , internByVal
  , Relation
  , fromEdges
  , reachFrom
  , reachableSet
  , reconstructPathNodes
  )

import PB.Pipeline.DuckDb (Handle, recreateTextTable, appendTextRows)
import qualified Data.Text as T

import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet        as HS
import qualified Data.IntMap.Strict as IM
import qualified Data.List         as L
import qualified Data.Map.Strict   as Map
import qualified Data.Set          as Set
import           Data.Set          (Set)

-- | A taint graph node: (object, procedure, variable).
type TaintTriple = (Text, Text, Text)

-- | All taint-propagation successor arcs out of a triple, as a list of
-- (dst, stepKind, desc). Mirrors 'propagateTaint''s internal
-- 'propagateOne' exactly, minus the BFS-only 'notMember tainted'
-- pruning (which does not affect the edge *set*).
--
-- This is the successor function the algebraic closure folds over. It is
-- built ONCE from the already-folded 'TaintEdges' output (the
-- 'TaintIntraEdgeRow'/'TaintReturnRow' tables written in Phase A) plus the
-- cross-procedure 'InterprocEdge's, and returned as a plain function so the
-- per-seed relaxation in 'taintPathRelation' never rebuilds
-- the HashMaps. (The old 'TaintIndex'/'taintSuccessorsIx' shape relied on
-- GHC full-laziness to float those builds out of a curried lambda and did
-- not reliably share on the real corpus -- see
-- doc/plan/182-algebraic-analysis.md Section 11.)
buildTaintSuccessors
  :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> (TaintTriple -> [(TaintTriple, Text, Text)])
buildTaintSuccessors intraEdges returnRows edges = \triple -> successorsOf triple
  where
    !intraSucc = HM.fromListWith (++)
      [ ((tierObject r, tierProcName r, tierUseVar r), [tierDefVar r])
      | r <- intraEdges ]
    !returnTriples = HS.fromList
      [ (trrObject r, trrProcName r, trrVarName r) | r <- returnRows ]
    !argEdges = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "arg" ]
    !retEdges = HM.fromListWith (++)
      [ ((ieCalleeObject e, ieCalleeProc e), [e])
      | e <- edges, ieEdgeKind e == "return" ]
    !globalEdges = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "global_write" ]
    successorsOf (obj, proc, var) =
      intraProc <> arg <> ret <> global
      where
        -- The 'newVar /= var' self-loop exclusion the old same-line join
        -- needed is already applied by 'PB.Analysis.TaintEdges''s
        -- 'assignWithRhs' (it never emits a (var, var) pair), so no filter
        -- is needed here.
        intraProc =
          [ ((obj, proc, newVar), "def", var <> " used in expression that defines " <> newVar)
          | newVar <- HM.findWithDefault [] (obj, proc, var) intraSucc
          ]
        arg =
          [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "arg", "passed as argument from " <> obj <> "." <> proc)
          | e <- HM.findWithDefault [] (obj, proc, var) argEdges
          ]
        ret =
          [ ((ieCallerObject e, ieCallerProc e, ieCallerContext e), "return", "return value of " <> obj <> "." <> proc <> " received by caller")
          | HS.member (obj, proc, var) returnTriples
          , e <- HM.findWithDefault [] (obj, proc) retEdges
          ]
        global =
          [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "global", "global variable " <> var <> " written in " <> obj <> "." <> proc)
          | e <- HM.findWithDefault [] (obj, proc, var) globalEdges
          ]

-- | The shared taint closure: a single PathValue relation built once, plus
-- the interner and the starred reachability relation the derived outputs
-- need. All three production outputs (@taint_reaches@ \/
-- @taint_confirmed@ \/ @taint_step_kind@) are derived from this one
-- structure (doc/plan/187-perf-hotspots.md §11.3), replacing the previous
-- 3×-redundant Boolean 'taintRelation' builds. The PathValue relation
-- carries the same arcs as the old Boolean relation, so every derived
-- reachable set is unchanged.
--
-- Fields: (1) interner, (2) base PathValue relation (for direct-successor
-- lookup), (3) source ids, (4) 'reachFrom' starred relation seeded from
-- the sources directly (so a source that is also a sink keeps its 0-hop
-- membership; a node's @pvHops@ in this relation distinguishes the trivial
-- 0-hop self-membership from a real >= 1-hop path).
data TaintClosure = TaintClosure
  (Interner TaintTriple)
  (Relation (PathValue (Text, Text, Text)))
  [Int]
  (Relation (PathValue (Text, Text, Text)))

-- | Build the shared 'TaintClosure' once: intern the PathValue relation and
-- precompute the 'reachFrom' fixpoint the derived outputs consume.
buildTaintClosure
  :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge] -> [TaintSource]
  -> TaintClosure
buildTaintClosure intraEdges returnRows edges sources =
  let (interner, rel) = taintPathRelation intraEdges returnRows edges sources
      idByVal = internByVal interner
      srcIds = Set.toList (Set.fromList
                 [ i | s <- sources
                     , let t = (tsObject s, tsProcName s, tsVarName s)
                     , Just i <- [HM.lookup t idByVal] ])
      reachSrc  = reachFrom rel srcIds
  in TaintClosure interner rel srcIds reachSrc

-- | Build the interned PathValue relation (carrying a witness label per
-- edge) for the same taint problem — used for witness reconstruction
-- via 'PB.Algebra.Closure.reconstructPath'.
taintPathRelation
  :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge] -> [TaintSource]
  -> (Interner TaintTriple, Relation (PathValue (Text, Text, Text)))
taintPathRelation intraEdges returnRows edges sources =
  let successors = buildTaintSuccessors intraEdges returnRows edges
      seeds  = sourceTriples sources
                 ++ [ (tierObject r, tierProcName r, tierUseVar r) | r <- intraEdges ]
                 ++ [ (tierObject r, tierProcName r, tierDefVar r) | r <- intraEdges ]
                 ++ [ (trrObject r, trrProcName r, trrVarName r) | r <- returnRows ]
                 ++ [ (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) | e <- edges ]
                 ++ [ (ieCallerObject e, ieCallerProc e, ieCallerContext e) | e <- edges ]
      labeled = [ (cur, dst, kind, desc)
                   | cur <- seeds, (dst, kind, desc) <- successors cur ]
      -- Same interner-seeding fix as 'buildTaintClosure' above -- see its
      -- comment.
      allTriples = dedup (seeds
                     ++ concatMap (\(a, _, _, _) -> [a]) labeled
                     ++ concatMap (\(_, b, _, _) -> [b]) labeled)
      interner = L.foldl' (\acc t -> snd (intern t acc)) emptyInterner allTriples
      idOf t = HM.lookup t (internByVal interner)
      rawArcs = [ (iCur, iDst, Reachable 1 (Just (kind, desc, snd3 b)) iCur)
                   | (a, b, kind, desc) <- labeled
                   , Just iCur <- [idOf a]
                   , Just iDst <- [idOf b] ]
  in (interner, fromEdges rawArcs)
  where
    sourceTriples ss = [ (tsObject s, tsProcName s, tsVarName s) | s <- ss ]
    dedup :: Ord a => [a] -> [a]
    dedup = Set.toList . Set.fromList
    snd3 (_, _, z) = z

-- | Tainted triples: the reachability set from all sources, as a 'Set'
-- of triples. Equals the first component of 'propagateTaint'. Derived from
-- the single PathValue relation (same arc set as the old Boolean relation).
taintReachable
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> Set TaintTriple
taintReachable sources intraEdges returnRows edges =
  let (interner, rel) = taintPathRelation intraEdges returnRows edges sources
      idOf t = HM.lookup t (internByVal interner)
      srcIds = [ i | s <- sources
               , let t = (tsObject s, tsProcName s, tsVarName s)
               , Just i <- [idOf t] ]
      reachRel = reachFrom rel srcIds
  in Set.fromList
       [ t | srcId <- srcIds
           , dstId <- Set.toList (reachableSet reachRel srcId)
           , Just t <- [unintern dstId interner]
       ]

-- | Per-source (source, node reachable via >=1 real edge) pairs, matching the
-- @taint_reaches(x, y)@ relation -- @x@ stays pinned to the literal source
-- (unlike 'taintReachable', which flattens per-source structure into one
-- global tainted set), and a source only re-appears as its own target when a
-- REAL cycle leads back to it.
--
-- 'reachFrom'/'reachableSet' always include a seed's own trivial 0-hop
-- membership (needed for 'taintReachable''s "isolated source is still
-- tainted" contract) -- the base relation has no such case, requiring >=1
-- real @taint_edge@ hop. Seeding 'reachFrom' from each source's *direct
-- successors* rather than the source itself sidesteps this: a successor's
-- own trivial membership genuinely IS one real hop from the source, so it is
-- never spurious, while a source only regains membership in its own
-- reachable set by a real path back through a successor.
taintReachesPairs
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple)]
taintReachesPairs sources intraEdges returnRows edges =
  taintReachesPairsClosure (buildTaintClosure intraEdges returnRows edges sources)

-- | 'taintReachesPairs' over a prebuilt 'TaintClosure' (no relation rebuild).
-- A node y /= source counts as reached iff it has 'pvHops' >= 1 in the
-- source's row of 'reachSrc' -- 'reachSrc' tracks the *shortest* path to
-- every node, and for every node other than the source itself this
-- correctly distinguishes "reached by a real edge" from "unreached".
--
-- The source itself is the one node this can't decide by hop-count alone:
-- 'reachFrom' seeds every node with a 0-hop identity membership, and the
-- shortest-path semiring's tie-break always keeps the lower hop count, so
-- 'reachSrc'\'s entry for the source stays pinned at 0 hops forever even
-- when a real cycle leads back to it -- @pvHops >= 1@ can never see that
-- cycle. Recovered separately via 'predIndex': a real cycle source -> ...
-- -> p -> source exists iff some direct predecessor p of the source (an
-- edge p -> source in the base relation) is itself present in the
-- source's own 'reachSrc' row (reached in >= 0 hops, i.e. p == source for
-- a direct self-loop edge, or p reached via a real path otherwise) --
-- composing that with the p -> source edge gives a real path back to the
-- source. This reproduces the old reachSucc-seeded-at-direct-successors
-- formulation's self-membership behavior exactly, without its second
-- per-successor 'reachFrom' fixpoint: 'predIndex' is a single O(E) reverse
-- pass over the already-built relation, not a BFS per successor.
taintReachesPairsClosure :: TaintClosure -> [(TaintTriple, TaintTriple)]
taintReachesPairsClosure (TaintClosure interner rel srcIds reachSrc) =
  let decode i = unintern i interner
      predIndex = IM.fromListWith (++)
        [ (dst, [srcNode]) | (srcNode, outs) <- IM.toList rel, dst <- IM.keys outs ]
      rowOf srcId = IM.findWithDefault IM.empty srcId reachSrc
      selfCycle srcId =
        any (\p -> IM.member p (rowOf srcId)) (IM.findWithDefault [] srcId predIndex)
      reachedIds srcId =
        [ yId | (yId, pv) <- IM.toList (rowOf srcId), pvHops pv >= 1 ]
          ++ [ srcId | selfCycle srcId ]
  in [ (s, y)
     | srcId <- srcIds
     , Just s <- [decode srcId]
     , yId <- reachedIds srcId
     , Just y <- [decode yId]
     ]

-- | Confirmed (source, sink) pairs: a sink reachable from a *specific*
-- source (cf. 'taint_confirmed'). Deduplicated by (source key, sink key)
-- -- @taint_confirmed@ is a SET keyed on the STRING
-- object::proc::var key, so two 'TaintSource'\/'TaintSink' records that
-- differ only in metadata (line, file) but share a key must collapse to
-- one row, same as they would there. Real-corpus finding (Plan 182
-- cutover, 2026-07-18): the same var is legitimately classified as a
-- source\/sink more than once (e.g. two @SELECT INTO@ occurrences of the
-- same :host_var in one proc) -- 15\/19 duplicate-key groups on the real
-- openpay corpus, which inflated this function's un-deduplicated output
-- 26 -> 41 rows before this fix.
taintConfirmed
  :: [TaintSource] -> [TaintSink] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> [(TaintSource, TaintSink)]
taintConfirmed sources sinks intraEdges returnRows edges =
  taintConfirmedClosure (buildTaintClosure intraEdges returnRows edges sources) sources sinks

-- | 'taintConfirmed' over a prebuilt 'TaintClosure' (no relation rebuild).
taintConfirmedClosure
  :: TaintClosure -> [TaintSource] -> [TaintSink] -> [(TaintSource, TaintSink)]
taintConfirmedClosure (TaintClosure interner _rel _srcIds reachSrc) sources sinks =
  let idByVal = internByVal interner
      sinkTriple snk = (tskObject snk, tskProcName snk, tskVarName snk)
      allPairs =
        [ (src, snk)
        | src <- sources
        , let srcT = (tsObject src, tsProcName src, tsVarName src)
        , Just srcId <- [HM.lookup srcT idByVal]
        , snk <- sinks
        , let snkT = sinkTriple snk
        , Just sinkId <- [HM.lookup snkT idByVal]
        , sinkId `Set.member` reachableSet reachSrc srcId
        ]
      keyOf (src, snk) =
        ((tsObject src, tsProcName src, tsVarName src), sinkTriple snk)
  in Map.elems (Map.fromList [ (keyOf p, p) | p <- allPairs ])

-- | Convenience: decode a starred PathValue relation back to a list of
-- (srcTriple, dstTriple, edgeLabel) reachable pairs. Useful for tests.
taintWitnesses
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple, (Text, Text, Text))]
taintWitnesses sources intraEdges returnRows edges =
  let (interner, rel) = taintPathRelation intraEdges returnRows edges sources
      idByVal = internByVal interner
      decode i = unintern i interner
      srcPairs = [ (s, i) | s <- sources
                  , let t = (tsObject s, tsProcName s, tsVarName s)
                  , Just i <- [HM.lookup t idByVal] ]
      reachRel = reachFrom rel (map snd srcPairs)
  in [ (srcT, dstT, lbl)
     | (_, srcId) <- srcPairs
     , Just srcT <- [decode srcId]
     , dstId <- Set.toList (reachableSet reachRel srcId)
     , Just dstT <- [decode dstId]
     , Just (Reachable _ (Just lbl) _) <- [IM.lookup srcId reachRel >>= IM.lookup dstId]
     ]

-- | Full leg-by-leg decomposition of a taint witness path: for each
-- reachable (source, node) pair, the ordered sequence of (fromTriple,
-- toTriple, kind, description) legs on a shortest src->dst path, decoded
-- back to 'TaintTriple's via the interner ('taintWitnesses' only keeps the
-- final hop's label; this walks the full chain via
-- 'PB.Algebra.Closure.reconstructPathNodes'). Reconciles against
-- @taint_step_kind@'s per-hop rows -- see
-- doc/plan/182-algebraic-analysis.md Section 12 item 4.
taintWitnessLegs
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple, [(TaintTriple, TaintTriple, Text, Text)])]
taintWitnessLegs sources intraEdges returnRows edges =
  taintWitnessLegsClosure (buildTaintClosure intraEdges returnRows edges sources)

-- | 'taintWitnessLegs' over a prebuilt 'TaintClosure' (no relation rebuild).
taintWitnessLegsClosure
  :: TaintClosure
  -> [(TaintTriple, TaintTriple, [(TaintTriple, TaintTriple, Text, Text)])]
taintWitnessLegsClosure (TaintClosure interner _rel srcIds reachSrc) =
  let decode i = unintern i interner
      reachRel = reachSrc
      decodeLeg (fromId, toId, (kind, desc, _)) = do
        fromT <- decode fromId
        toT   <- decode toId
        pure (fromT, toT, kind, desc)
  in [ (srcT, dstT, legs)
     | srcId <- srcIds
     , Just srcT <- [decode srcId]
     , dstId <- Set.toList (reachableSet reachRel srcId)
     , Just dstT <- [decode dstId]
     , Just rawLegs <- [reconstructPathNodes reachRel srcId dstId]
     , Just legs <- [traverse decodeLeg rawLegs]
     ]

-- | Materialize @taint_reaches@\/@taint_confirmed@ from the shared closure
-- ('taintReachesPairsClosure' / 'taintConfirmedClosure'). Takes the
-- prebuilt 'TaintClosure' 'PB.Pipeline.Passes.buildCallGraphAndTaint' constructs once,
-- so no relation is rebuilt and no extra DB round-trip is needed.
materializeTaintClosure
  :: TaintClosure -> [Taint.TaintSource] -> [Taint.TaintSink] -> Handle -> IO ()
materializeTaintClosure closure sources sinks conn = do
  let reaches   = taintReachesPairsClosure closure
      confirmed = taintConfirmedClosure closure sources sinks
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

-- | Materialize @taint_step_kind@ from the witness
-- ('taintWitnessLegsClosure'), restricted to CONFIRMED (source,
-- sink) pairs -- 'taintWitnessLegsClosure' is per-reachable-node, a strict
-- superset of the confirmed pairs this table reports one row per hop
-- for. Row shape and @step_kind@\/@description@ conventions: leg_ord 0 is
-- always "source", every other leg's @step_kind@\/@description@ echo its
-- real edge kind, a terminal "sink" marker lands one ordinal past the
-- last real leg, and the 0-hop (source == sink) case is a single
-- "source-sink" row with no real edge -- 'PB.Pipeline.DuckDb.materializeTaintPaths'
-- embeds these verbatim into @taint_paths.steps_json@, so the shape is
-- load-bearing, not incidental formatting.
materializeTaintStepKind
  :: TaintClosure -> [Taint.TaintSource] -> [Taint.TaintSink] -> Handle -> IO ()
materializeTaintStepKind closure sources sinks conn = do
  let confirmed   = taintConfirmedClosure closure sources sinks
      witnessLegs = taintWitnessLegsClosure closure
      legsByPair  = HM.fromList [ ((srcT, dstT), legList) | (srcT, dstT, legList) <- witnessLegs ]
      rows        = concatMap (rowsForPair legsByPair) confirmed
  recreateTextTable conn "taint_step_kind"
    ["s", "t", "leg_ord", "lf", "lt", "kind", "step_kind", "description"]
  appendTextRows conn "taint_step_kind" rows
  where
    taintKey3 (o, p, v) = taintKey o p v
    rowsForPair legsByPair (src, snk) =
      let srcT      = (Taint.tsObject src, Taint.tsProcName src, Taint.tsVarName src)
          snkT      = (Taint.tskObject snk, Taint.tskProcName snk, Taint.tskVarName snk)
          sourceKey = taintKey3 srcT
          sinkKey   = taintKey3 snkT
      in if srcT == snkT
           then [[sourceKey, sourceKey, "0", sourceKey, sourceKey, "sink", "source-sink",
                  "taint source and sink (same variable)"]]
           else case HM.lookup (srcT, snkT) legsByPair of
             Nothing -> error
               ("PB.Analysis.TaintClosure.materializeTaintStepKind: impossible: "
                 <> show snkT <> " has no witness path despite being taint_confirmed reachable from "
                 <> show srcT)
             Just legs ->
               let legRows = [ legRow sourceKey sinkKey o fromT toT kind
                              | (o, (fromT, toT, kind, _desc)) <- zip [0 :: Int ..] legs ]
                   terminal = [sourceKey, sinkKey, T.pack (show (length legs)), sinkKey, sinkKey,
                               "sink", "sink", "taint propagation via sink"]
               in legRows ++ [terminal]
    legRow sourceKey sinkKey o fromT toT kind =
      let lf = taintKey3 fromT
          lt = taintKey3 toT
      in if o == (0 :: Int)
           then [sourceKey, sinkKey, "0", lf, lt, kind, "source", "taint source"]
           else [sourceKey, sinkKey, T.pack (show o), lf, lt, kind, kind, "taint propagation via " <> kind]

-- | The @object::proc::var@ key every taint table joins on.
taintKey :: Text -> Text -> Text -> Text
taintKey obj proc var = obj <> "::" <> proc <> "::" <> var

