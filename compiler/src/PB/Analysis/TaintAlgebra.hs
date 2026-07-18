{-# LANGUAGE StrictData #-}
-- | Algebraic taint closure: a Kleene star over a semiring-labeled
-- relation, replacing 'PB.Analysis.Taint.propagateTaint''s BFS (and
-- the separate backward walk) with one 'PB.Algebra.Closure.star'.
--
-- The edge relation is *identical* to the one 'propagateTaint' walks: the
-- four rules (intra-proc same-line def-use, arg, return, global-hub)
-- are re-stated as a pure successor function so the BFS and the 'star'
-- consume the same arcs — the A/B test in 'TaintAlgebraTest' proves
-- they agree.
--
-- See doc/plan/182-algebraic-analysis.md.
module PB.Analysis.TaintAlgebra
  ( TaintTriple
  , taintSuccessors
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
  , star
  , reachableSet
  )

import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap.Strict as IM
import qualified Data.List         as L
import qualified Data.Set          as Set
import           Data.Set          (Set)

-- | A taint graph node: (object, procedure, variable).
type TaintTriple = (Text, Text, Text)

-- | All taint-propagation successor arcs out of a triple, as a list of
-- (dst, stepKind, desc). Mirrors 'propagateTaint''s internal
-- 'propagateOne' exactly, minus the BFS-only 'notMember tainted'
-- pruning (which does not affect the edge *set*).
taintSuccessors
  :: [DefRow] -> [UseRow] -> [InterprocEdge]
  -> TaintTriple -> [(TaintTriple, Text, Text)]
taintSuccessors defs uses edges (obj, proc, var) =
  intraProc <> arg <> ret <> global
  where
    usesByTriple = HM.fromListWith (++)
      [ ((urObject u, urProcName u, urVarName u), [u]) | u <- uses ]
    -- NB key uses the *Int* line (cf. propagateTaint:720), not the Maybe.
    defsByLine = HM.fromListWith (++)
      [ ((drObject d, drProcName d, line), [drVarName d])
      | d <- defs, Just line <- [drLine d] ]
    argEdgesByCaller = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "arg" ]
    returnEdgesByCallee = HM.fromListWith (++)
      [ ((ieCalleeObject e, ieCalleeProc e), [e])
      | e <- edges, ieEdgeKind e == "return" ]
    globalWriteEdges = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "global_write" ]

    intraProc =
      [ ((obj, proc, newVar), "def", var <> " used in expression that defines " <> newVar)
      | u <- HM.findWithDefault [] (obj, proc, var) usesByTriple
      , Just line <- [urLine u]
      , newVar <- HM.findWithDefault [] (obj, proc, line) defsByLine
      , newVar /= var
      ]
    arg =
      [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "arg", "passed as argument from " <> obj <> "." <> proc)
      | e <- HM.findWithDefault [] (obj, proc, var) argEdgesByCaller
      ]
    ret =
      [ ((ieCallerObject e, ieCallerProc e, ieCallerContext e), "return", "return value of " <> obj <> "." <> proc <> " received by caller")
      | u <- HM.findWithDefault [] (obj, proc, var) usesByTriple
      , urKind u == "return"
      , e <- HM.findWithDefault [] (obj, proc) returnEdgesByCallee
      ]
    global =
      [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "global", "global variable " <> var <> " written in " <> obj <> "." <> proc)
      | e <- HM.findWithDefault [] (obj, proc, var) globalWriteEdges
      ]

-- | Build the interned Boolean relation for a taint problem. Returns the
-- interner (for decoding ids back to triples) and the raw relation.
taintRelation
  :: [DefRow] -> [UseRow] -> [InterprocEdge] -> [TaintSource]
  -> (Interner TaintTriple, Relation Boolean)
taintRelation defs uses edges sources =
  let successors = taintSuccessors defs uses edges
      seeds  = sourceTriples sources
                 ++ [ (drObject d, drProcName d, drVarName d) | d <- defs ]
                 ++ [ (urObject u, urProcName u, urVarName u) | u <- uses ]
                 ++ [ (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) | e <- edges ]
                 ++ [ (ieCallerObject e, ieCallerProc e, ieCallerContext e) | e <- edges ]
      arcPairs = dedup [ (cur, dst) | cur <- seeds, (dst, _, _) <- successors cur ]
      allTriples = dedup (concatMap (\(a, b) -> [a, b]) arcPairs)
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
  let successors = taintSuccessors defs uses edges
      seeds  = sourceTriples sources
                 ++ [ (drObject d, drProcName d, drVarName d) | d <- defs ]
                 ++ [ (urObject u, urProcName u, urVarName u) | u <- uses ]
                 ++ [ (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) | e <- edges ]
                 ++ [ (ieCallerObject e, ieCallerProc e, ieCallerContext e) | e <- edges ]
      labeled = [ (cur, dst, kind, desc)
                   | cur <- seeds, (dst, kind, desc) <- successors cur ]
      allTriples = dedup (concatMap (\(a, _, _, _) -> [a]) labeled)
                     ++ dedup (concatMap (\(_, b, _, _) -> [b]) labeled)
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
      starRel = star rel
      idOf t = HM.lookup t (internByVal interner)
      srcIds = [ i | s <- sources
               , let t = (tsObject s, tsProcName s, tsVarName s)
               , Just i <- [idOf t] ]
  in Set.fromList
       [ t | srcId <- srcIds
       , dstId <- Set.toList (reachableSet starRel srcId)
       , Just t <- [unintern dstId interner]
       ]

-- | Confirmed (source, sink) pairs: a sink reachable from a *specific*
-- source (cf. 'taint_confirmed').
taintConfirmed
  :: [TaintSource] -> [TaintSink] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintSource, TaintSink)]
taintConfirmed sources sinks defs uses edges =
  let (interner, rel) = taintRelation defs uses edges sources
      starRel = star rel
      idByVal = internByVal interner
      sinkTriple snk = (tskObject snk, tskProcName snk, tskVarName snk)
  in [ (src, snk)
     | src <- sources
     , let srcT = (tsObject src, tsProcName src, tsVarName src)
     , Just srcId <- [HM.lookup srcT idByVal]
     , snk <- sinks
     , let snkT = sinkTriple snk
     , Just sinkId <- [HM.lookup snkT idByVal]
     , sinkId `Set.member` reachableSet starRel srcId
     ]

-- | Convenience: decode a starred PathValue relation back to a list of
-- (srcTriple, dstTriple, edgeLabel) reachable pairs. Useful for tests.
taintWitnesses
  :: [TaintSource] -> [DefRow] -> [UseRow] -> [InterprocEdge]
  -> [(TaintTriple, TaintTriple, (Text, Text, Text))]
taintWitnesses sources defs uses edges =
  let (interner, rel) = taintPathRelation defs uses edges sources
      starRel = star rel
      idByVal = internByVal interner
      decode i = unintern i interner
      srcPairs = [ (s, i) | s <- sources
                  , let t = (tsObject s, tsProcName s, tsVarName s)
                  , Just i <- [HM.lookup t idByVal] ]
  in [ (srcT, dstT, lbl)
     | (_, srcId) <- srcPairs
     , Just srcT <- [decode srcId]
     , dstId <- Set.toList (reachableSet starRel srcId)
     , Just dstT <- [decode dstId]
     , Just (Reachable _ (Just lbl) _) <- [IM.lookup srcId starRel >>= IM.lookup dstId]
     ]

