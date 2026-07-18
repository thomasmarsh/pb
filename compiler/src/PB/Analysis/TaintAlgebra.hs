{-# LANGUAGE StrictData #-}
{-# LANGUAGE RecordWildCards #-}
-- | Algebraic taint closure: a semiring-weighted reachability computation
-- over an interned relation, replacing 'PB.Analysis.Taint.propagateTaint''s
-- BFS (and the separate backward walk) with
-- 'PB.Algebra.Closure.reachFrom' — a sparse worklist relaxation from the
-- taint sources, not 'PB.Algebra.Closure.star''s all-pairs closure (which
-- is asymptotically wrong for a large sparse graph with a small seed set;
-- see doc/plan/182-algebraic-analysis.md Section 11 for the real-corpus
-- evidence: 'star' was >15,000x slower than the BFS oracle).
--
-- The edge relation is *identical* to the one 'propagateTaint' walks: the
-- four rules (intra-proc same-line def-use, arg, return, global-hub)
-- are re-stated as a pure successor function so the BFS and the algebraic
-- closure consume the same arcs — the A/B test in 'TaintAlgebraTest'
-- proves they agree.
--
-- See doc/plan/182-algebraic-analysis.md.
module PB.Analysis.TaintAlgebra
  ( TaintTriple
  , TaintIndex
  , buildTaintIndex
  , taintSuccessors
  , taintSuccessorsIx
  , taintRelation
  , taintPathRelation
  , taintReachable
  , taintReachesPairs
  , taintConfirmed
  , taintWitnesses
  ) where

import PB.Prelude
import PB.Analysis.Taint
  ( DefRow (..)
  , UseRow (..)
  , InterprocEdge (..)
  , TaintSource (..)
  , TaintSink (..)
  )
import PB.Analysis.TaintEdges (TaintIntraEdgeRow (..), TaintReturnRow (..))
import PB.Algebra.Semiring (Boolean (..), PathValue (..))
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
  )

import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet        as HS
import qualified Data.IntMap.Strict as IM
import qualified Data.List         as L
import qualified Data.Map.Strict   as Map
import qualified Data.Set          as Set
import           Data.Set          (Set)

-- | A taint graph node: (object, procedure, variable).
type TaintTriple = (Text, Text, Text)

-- | The per-corpus indexes 'taintSuccessorsIx' reads. Built ONCE via
-- 'buildTaintIndex' and passed around as a plain, already-evaluated
-- value -- deliberately NOT left as a 'where'-clause under a curried
-- function's last argument (the shape 'taintSuccessors' used to have).
-- That shape relies on GHC's full-laziness optimization to float the
-- 'HM.fromListWith' builds out of the per-call lambda; on the real
-- corpus (5233 defs/15201 uses/3968 edges, ~28,000 seed lookups in
-- 'taintRelation'/'taintPathRelation') that sharing did not reliably
-- happen, rebuilding all five HashMaps from scratch on every seed lookup
-- -- confirmed via 'TaintCorpusBench': a 3.8-node-average-per-seed
-- relaxation (1525 total node-visits across 403 seeds) took 140+
-- seconds, orders of magnitude more than the real work involved. See
-- doc/plan/182-algebraic-analysis.md Section 11.
--
-- 'tiIntraSuccessors' (Plan 182 Move 2, 2026-07-18) replaces the old
-- 'tiUsesByTriple'\/'tiDefsByLine' same-line join with a direct read of
-- 'PB.Analysis.TaintEdges.foldTaintEdgesEff''s @(useVar, defVar)@ pairs,
-- each already exact (sourced from 'EAssignWithRhs''s fused def+rhs, no
-- line-number correlation). 'tiReturnUseTriples' (Plan 182b, 2026-07-18)
-- is built the same way, from 'TaintReturnRow' -- 'PB.Compile.IR.EReturn'
-- now carries the returned expression, so 'PB.Analysis.TaintEdges.ret' can
-- answer "is this var used in a return" directly from the term, no row
-- join needed (see doc/plan/182b-move2-intra.md Section 1 point 2).
data TaintIndex = TaintIndex
  { tiIntraSuccessors    :: HM.HashMap TaintTriple [Text]
  , tiReturnUseTriples   :: HS.HashSet TaintTriple
  , tiArgEdgesByCaller   :: HM.HashMap TaintTriple [InterprocEdge]
  , tiReturnEdgesByCallee :: HM.HashMap (Text, Text) [InterprocEdge]
  , tiGlobalWriteEdges   :: HM.HashMap TaintTriple [InterprocEdge]
  }

buildTaintIndex :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge] -> TaintIndex
buildTaintIndex intraEdges returnRows edges = TaintIndex
  { tiIntraSuccessors = HM.fromListWith (++)
      [ ((tierObject r, tierProcName r, tierUseVar r), [tierDefVar r])
      | r <- intraEdges ]
  , tiReturnUseTriples = HS.fromList
      [ (trrObject r, trrProcName r, trrVarName r) | r <- returnRows ]
  , tiArgEdgesByCaller = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "arg" ]
  , tiReturnEdgesByCallee = HM.fromListWith (++)
      [ ((ieCalleeObject e, ieCalleeProc e), [e])
      | e <- edges, ieEdgeKind e == "return" ]
  , tiGlobalWriteEdges = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "global_write" ]
  }

-- | All taint-propagation successor arcs out of a triple, as a list of
-- (dst, stepKind, desc). Mirrors 'propagateTaint''s internal
-- 'propagateOne' exactly, minus the BFS-only 'notMember tainted'
-- pruning (which does not affect the edge *set*). Reads a pre-built
-- 'TaintIndex' -- see its own doc comment for why this replaced the
-- 'where'-clause-under-a-curried-lambda shape.
taintSuccessorsIx :: TaintIndex -> TaintTriple -> [(TaintTriple, Text, Text)]
taintSuccessorsIx TaintIndex{..} (obj, proc, var) =
  intraProc <> arg <> ret <> global
  where
    -- The 'newVar /= var' self-loop exclusion the old same-line join
    -- needed is already applied by 'PB.Analysis.TaintEdges''s
    -- 'assignWithRhs' (it never emits a (var, var) pair), so no filter is
    -- needed here.
    intraProc =
      [ ((obj, proc, newVar), "def", var <> " used in expression that defines " <> newVar)
      | newVar <- HM.findWithDefault [] (obj, proc, var) tiIntraSuccessors
      ]
    arg =
      [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "arg", "passed as argument from " <> obj <> "." <> proc)
      | e <- HM.findWithDefault [] (obj, proc, var) tiArgEdgesByCaller
      ]
    ret =
      [ ((ieCallerObject e, ieCallerProc e, ieCallerContext e), "return", "return value of " <> obj <> "." <> proc <> " received by caller")
      | HS.member (obj, proc, var) tiReturnUseTriples
      , e <- HM.findWithDefault [] (obj, proc) tiReturnEdgesByCallee
      ]
    global =
      [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "global", "global variable " <> var <> " written in " <> obj <> "." <> proc)
      | e <- HM.findWithDefault [] (obj, proc, var) tiGlobalWriteEdges
      ]

-- | Convenience wrapper matching the original signature -- builds a fresh
-- 'TaintIndex' per call. NOT used by 'taintRelation'/'taintPathRelation'
-- (they build the index once themselves, see 'TaintIndex''s doc comment);
-- kept for exploration/tests that only need one-off successor lookups.
taintSuccessors
  :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [InterprocEdge]
  -> TaintTriple -> [(TaintTriple, Text, Text)]
taintSuccessors intraEdges returnRows edges = taintSuccessorsIx (buildTaintIndex intraEdges returnRows edges)

-- | Build the interned Boolean relation for a taint problem. Returns the
-- interner (for decoding ids back to triples) and the raw relation.
taintRelation
  :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [DefRow] -> [UseRow] -> [InterprocEdge] -> [TaintSource]
  -> (Interner TaintTriple, Relation Boolean)
taintRelation intraEdges returnRows defs uses edges sources =
  let !idx = buildTaintIndex intraEdges returnRows edges
      successors = taintSuccessorsIx idx
      seeds  = sourceTriples sources
                 ++ [ (drObject d, drProcName d, drVarName d) | d <- defs ]
                 ++ [ (urObject u, urProcName u, urVarName u) | u <- uses ]
                 ++ [ (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) | e <- edges ]
                 ++ [ (ieCallerObject e, ieCallerProc e, ieCallerContext e) | e <- edges ]
      arcPairs = dedup [ (cur, dst) | cur <- seeds, (dst, _, _) <- successors cur ]
      -- `seeds` is unioned in directly (not just derived from arcPairs'
      -- endpoints) so a seed with zero outgoing successors -- e.g. a
      -- taint source var never subsequently used/passed/returned -- still
      -- gets interned and keeps its own trivial 0-hop membership. See
      -- doc/plan/182-algebraic-analysis.md Section 11.
      allTriples = dedup (seeds ++ concatMap (\(a, b) -> [a, b]) arcPairs)
      interner = L.foldl' (\acc t -> snd (intern t acc)) emptyInterner allTriples
      idOf t = HM.lookup t (internByVal interner)
      rawArcs = [ (i, j) | (a, b) <- arcPairs, Just i <- [idOf a], Just j <- [idOf b] ]
  in (interner, fromEdges [ (i, j, Boolean True) | (i, j) <- rawArcs ])
  where
    sourceTriples ss = [ (tsObject s, tsProcName s, tsVarName s) | s <- ss ]
    dedup :: Ord a => [a] -> [a]
    dedup = Set.toList . Set.fromList

-- | Build the interned PathValue relation (carrying a witness label per
-- edge) for the same taint problem — used for witness reconstruction
-- via 'PB.Algebra.Closure.reconstructPath'.
taintPathRelation
  :: [TaintIntraEdgeRow] -> [TaintReturnRow] -> [DefRow] -> [UseRow] -> [InterprocEdge] -> [TaintSource]
  -> (Interner TaintTriple, Relation (PathValue (Text, Text, Text)))
taintPathRelation intraEdges returnRows defs uses edges sources =
  let !idx = buildTaintIndex intraEdges returnRows edges
      successors = taintSuccessorsIx idx
      seeds  = sourceTriples sources
                 ++ [ (drObject d, drProcName d, drVarName d) | d <- defs ]
                 ++ [ (urObject u, urProcName u, urVarName u) | u <- uses ]
                 ++ [ (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) | e <- edges ]
                 ++ [ (ieCallerObject e, ieCallerProc e, ieCallerContext e) | e <- edges ]
      labeled = [ (cur, dst, kind, desc)
                   | cur <- seeds, (dst, kind, desc) <- successors cur ]
      -- Same interner-seeding fix as taintRelation above -- see its
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
-- of triples. Equals the first component of 'propagateTaint'.
taintReachable
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> Set TaintTriple
taintReachable sources intraEdges returnRows defs uses edges =
  let (interner, rel) = taintRelation intraEdges returnRows defs uses edges sources
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

-- | Per-source (source, node reachable via >=1 real edge) pairs, mirroring
-- Souffle's @taint_reaches(x, y)@ relation exactly -- @x@ stays pinned to
-- the literal source (unlike 'taintReachable', which flattens per-source
-- structure into one global tainted set), and a source only re-appears as
-- its own target when a REAL cycle leads back to it.
--
-- 'reachFrom'/'reachableSet' always include a seed's own trivial 0-hop
-- membership (Section 11's Fix 1, needed for 'taintReachable''s "isolated
-- source is still tainted" contract) -- Souffle's base rule has no such
-- case, requiring >=1 real @taint_edge@ hop. Seeding 'reachFrom' from each
-- source's *direct successors* rather than the source itself sidesteps
-- this: a successor's own trivial membership genuinely IS one real hop
-- from the source, so it is never spurious, while a source only regains
-- membership in its own reachable set by a real path back through a
-- successor -- exactly Souffle's semantics.
taintReachesPairs
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple)]
taintReachesPairs sources intraEdges returnRows defs uses edges =
  let (interner, rel) = taintRelation intraEdges returnRows defs uses edges sources
      idOf t = HM.lookup t (internByVal interner)
      srcIds = dedup [ i | s <- sources
                     , let t = (tsObject s, tsProcName s, tsVarName s)
                     , Just i <- [idOf t] ]
      directSucc i = IM.keys (IM.findWithDefault IM.empty i rel)
      allSuccSeeds = dedup (concatMap directSucc srcIds)
      reachRel = reachFrom rel allSuccSeeds
      reach1Hop srcId = Set.unions
        [ Set.insert d (reachableSet reachRel d) | d <- directSucc srcId ]
  in [ (s, y)
     | srcId <- srcIds
     , Just s <- [unintern srcId interner]
     , yId <- Set.toList (reach1Hop srcId)
     , Just y <- [unintern yId interner]
     ]
  where
    dedup :: Ord a => [a] -> [a]
    dedup = Set.toList . Set.fromList

-- | Confirmed (source, sink) pairs: a sink reachable from a *specific*
-- source (cf. 'taint_confirmed'). Deduplicated by (source key, sink key)
-- -- Souffle's @taint_confirmed@ is a SET keyed on the STRING
-- object::proc::var key, so two 'TaintSource'\/'TaintSink' records that
-- differ only in metadata (line, file) but share a key must collapse to
-- one row, same as they would there. Real-corpus finding (Plan 182
-- cutover, 2026-07-18): the same var is legitimately classified as a
-- source\/sink more than once (e.g. two @SELECT INTO@ occurrences of the
-- same :host_var in one proc) -- 15\/19 duplicate-key groups on the real
-- openpay corpus, which inflated this function's un-deduplicated output
-- 26 -> 41 rows before this fix.
taintConfirmed
  :: [TaintSource] -> [TaintSink] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintSource, TaintSink)]
taintConfirmed sources sinks intraEdges returnRows defs uses edges =
  let (interner, rel) = taintRelation intraEdges returnRows defs uses edges sources
      idByVal = internByVal interner
      srcIds = [ i | s <- sources
               , let t = (tsObject s, tsProcName s, tsVarName s)
               , Just i <- [HM.lookup t idByVal] ]
      reachRel = reachFrom rel srcIds
      sinkTriple snk = (tskObject snk, tskProcName snk, tskVarName snk)
      allPairs =
        [ (src, snk)
        | src <- sources
        , let srcT = (tsObject src, tsProcName src, tsVarName src)
        , Just srcId <- [HM.lookup srcT idByVal]
        , snk <- sinks
        , let snkT = sinkTriple snk
        , Just sinkId <- [HM.lookup snkT idByVal]
        , sinkId `Set.member` reachableSet reachRel srcId
        ]
      keyOf (src, snk) =
        ((tsObject src, tsProcName src, tsVarName src), sinkTriple snk)
  in Map.elems (Map.fromList [ (keyOf p, p) | p <- allPairs ])

-- | Convenience: decode a starred PathValue relation back to a list of
-- (srcTriple, dstTriple, edgeLabel) reachable pairs. Useful for tests.
taintWitnesses
  :: [TaintSource] -> [TaintIntraEdgeRow] -> [TaintReturnRow] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple, (Text, Text, Text))]
taintWitnesses sources intraEdges returnRows defs uses edges =
  let (interner, rel) = taintPathRelation intraEdges returnRows defs uses edges sources
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

