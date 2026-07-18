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
import qualified Data.IntMap.Strict as IM
import qualified Data.List         as L
import qualified Data.Set          as Set
import           Data.Set          (Set)

-- | A taint graph node: (object, procedure, variable).
type TaintTriple = (Text, Text, Text)

-- | The five per-corpus indexes 'taintSuccessorsIx' reads. Built ONCE via
-- 'buildTaintIndex' and passed around as a plain, already-evaluated
-- value -- deliberately NOT left as a 'where'-clause under a curried
-- function's last argument (the shape 'taintSuccessors' used to have).
-- That shape relies on GHC's full-laziness optimization to float the
-- five 'HM.fromListWith' builds out of the per-call lambda; on the real
-- corpus (5233 defs/15201 uses/3968 edges, ~28,000 seed lookups in
-- 'taintRelation'/'taintPathRelation') that sharing did not reliably
-- happen, rebuilding all five HashMaps from scratch on every seed lookup
-- -- confirmed via 'TaintCorpusBench': a 3.8-node-average-per-seed
-- relaxation (1525 total node-visits across 403 seeds) took 140+
-- seconds, orders of magnitude more than the real work involved. See
-- doc/plan/182-algebraic-analysis.md Section 11.
data TaintIndex = TaintIndex
  { tiUsesByTriple       :: HM.HashMap TaintTriple [UseRow]
  , tiDefsByLine         :: HM.HashMap (Text, Text, Int) [Text]
  , tiArgEdgesByCaller   :: HM.HashMap TaintTriple [InterprocEdge]
  , tiReturnEdgesByCallee :: HM.HashMap (Text, Text) [InterprocEdge]
  , tiGlobalWriteEdges   :: HM.HashMap TaintTriple [InterprocEdge]
  }

buildTaintIndex :: [DefRow] -> [UseRow] -> [InterprocEdge] -> TaintIndex
buildTaintIndex defs uses edges = TaintIndex
  { tiUsesByTriple = HM.fromListWith (++)
      [ ((urObject u, urProcName u, urVarName u), [u]) | u <- uses ]
  -- NB key uses the *Int* line (cf. propagateTaint:720), not the Maybe.
  , tiDefsByLine = HM.fromListWith (++)
      [ ((drObject d, drProcName d, line), [drVarName d])
      | d <- defs, Just line <- [drLine d] ]
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
    intraProc =
      [ ((obj, proc, newVar), "def", var <> " used in expression that defines " <> newVar)
      | u <- HM.findWithDefault [] (obj, proc, var) tiUsesByTriple
      , Just line <- [urLine u]
      , newVar <- HM.findWithDefault [] (obj, proc, line) tiDefsByLine
      , newVar /= var
      ]
    arg =
      [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "arg", "passed as argument from " <> obj <> "." <> proc)
      | e <- HM.findWithDefault [] (obj, proc, var) tiArgEdgesByCaller
      ]
    ret =
      [ ((ieCallerObject e, ieCallerProc e, ieCallerContext e), "return", "return value of " <> obj <> "." <> proc <> " received by caller")
      | u <- HM.findWithDefault [] (obj, proc, var) tiUsesByTriple
      , urKind u == "return"
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
  :: [DefRow] -> [UseRow] -> [InterprocEdge]
  -> TaintTriple -> [(TaintTriple, Text, Text)]
taintSuccessors defs uses edges = taintSuccessorsIx (buildTaintIndex defs uses edges)

-- | Build the interned Boolean relation for a taint problem. Returns the
-- interner (for decoding ids back to triples) and the raw relation.
taintRelation
  :: [DefRow] -> [UseRow] -> [InterprocEdge] -> [TaintSource]
  -> (Interner TaintTriple, Relation Boolean)
taintRelation defs uses edges sources =
  let !idx = buildTaintIndex defs uses edges
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
  :: [DefRow] -> [UseRow] -> [InterprocEdge] -> [TaintSource]
  -> (Interner TaintTriple, Relation (PathValue (Text, Text, Text)))
taintPathRelation defs uses edges sources =
  let !idx = buildTaintIndex defs uses edges
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
  :: [TaintSource] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> Set TaintTriple
taintReachable sources defs uses edges =
  let (interner, rel) = taintRelation defs uses edges sources
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

-- | Confirmed (source, sink) pairs: a sink reachable from a *specific*
-- source (cf. 'taint_confirmed').
taintConfirmed
  :: [TaintSource] -> [TaintSink] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintSource, TaintSink)]
taintConfirmed sources sinks defs uses edges =
  let (interner, rel) = taintRelation defs uses edges sources
      idByVal = internByVal interner
      srcIds = [ i | s <- sources
               , let t = (tsObject s, tsProcName s, tsVarName s)
               , Just i <- [HM.lookup t idByVal] ]
      reachRel = reachFrom rel srcIds
      sinkTriple snk = (tskObject snk, tskProcName snk, tskVarName snk)
  in [ (src, snk)
     | src <- sources
     , let srcT = (tsObject src, tsProcName src, tsVarName src)
     , Just srcId <- [HM.lookup srcT idByVal]
     , snk <- sinks
     , let snkT = sinkTriple snk
     , Just sinkId <- [HM.lookup snkT idByVal]
     , sinkId `Set.member` reachableSet reachRel srcId
     ]

-- | Convenience: decode a starred PathValue relation back to a list of
-- (srcTriple, dstTriple, edgeLabel) reachable pairs. Useful for tests.
taintWitnesses
  :: [TaintSource] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple, (Text, Text, Text))]
taintWitnesses sources defs uses edges =
  let (interner, rel) = taintPathRelation defs uses edges sources
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

