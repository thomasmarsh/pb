{-# LANGUAGE BangPatterns #-}
-- | Kleene-star closure over an interned, semiring-labeled relation.
--
-- 'Relation' is a finite directed graph with semiring-labeled arcs.  'star'
-- computes the transitive closure as the fixpoint of @r ↣ r '.+.' (r '.*.' r)@
-- via iterated squaring — O(log n) matrix squarings, no worklist / BFS.
--
-- See doc/plan/182-algebraic-analysis.md.
module PB.Algebra.Closure
  ( Interner (..)
  , emptyInterner
  , intern
  , unintern
  , Relation
  , fromEdges
  , relUnion
  , relProduct
  , star
  , reachFrom
  , reachableSet
  , reconstructPath
  , reconstructPathNodes
  ) where
  
  
import PB.Prelude
import qualified PB.Algebra.Semiring as S
import PB.Algebra.Semiring (addS, mulS)

import qualified Data.HashMap.Strict as HM
import           Data.Hashable     (Hashable)
import qualified Data.IntMap.Strict as IM
import           Data.IntMap.Strict (IntMap)
import qualified Data.List        as L
import qualified Data.Set        as Set
import           Data.Set         (Set)

-- | Bidirectional interned-id <-> value mapping.
data Interner a = Interner
  { internCount :: !Int
  , internById  :: IntMap a
  , internByVal :: HM.HashMap a Int
  } deriving (Eq, Show)

emptyInterner :: Interner a
emptyInterner = Interner 0 IM.empty HM.empty

intern :: (Eq a, Hashable a) => a -> Interner a -> (Int, Interner a)
intern a (Interner n byId byVal) =
  case HM.lookup a byVal of
    Just i  -> (i, Interner n byId byVal)
    Nothing ->
      let i = n + 1
      in (i, Interner (n + 1) (IM.insert i a byId) (HM.insert a i byVal))

unintern :: Int -> Interner a -> Maybe a
unintern i (Interner _ byId _) = IM.lookup i byId

-- | Directed graph: src -> dst -> semiring label.  'zero' arcs are omitted.
type Relation s = IntMap (IntMap s)

-- | Build a 'Relation' from raw (src, dst, label) arcs.  Coincident
-- arcs are combined with the semiring 'addS'.
fromEdges :: S.Semiring s => [(Int, Int, s)] -> Relation s
fromEdges = L.foldl' ins IM.empty
  where
    ins m (i, j, s) =
      let inner = IM.findWithDefault IM.empty i m
      in IM.insert i (IM.insertWith addS j s inner) m

-- | Pointwise union of two relations (additive).  Coincident arcs are
-- combined with the semiring 'addS'.
relUnion :: S.Semiring s => Relation s -> Relation s -> Relation s
relUnion = IM.unionWith (IM.unionWith addS)

-- | Matrix product (multiplicative):  (p `relProduct` q)!i!j = sum_k (p!i!k `mulS` q!k!j).
relProduct :: S.Semiring s => Relation s -> Relation s -> Relation s
relProduct p q =
  fromEdges
    [ (i, j, pik `mulS` qkj)
    | (i, pInner) <- IM.toList p
    , (k, pik)    <- IM.toList pInner
    , Just qInner <- [IM.lookup k q]
    , (j, qkj)    <- IM.toList qInner
    ]

-- | Kleene star via iterated squaring.  Converges in O(log n) squarings
-- for an n-node graph; we also early-exit on fixpoint.
star :: (S.Semiring s, Eq s) => Relation s -> Relation s
star m0 =
  let nodes  = allNodes m0
      ident  = identityRel nodes
      r0     = relUnion ident m0
      maxIter = ceiling (logBase 2 (fromIntegral (max 1 (length nodes)) :: Double)) + 1 :: Int
  in iterateFix maxIter r0
  where
    iterateFix 0 r = r
    iterateFix n r =
      let r' = relUnion r (relProduct r r)
      in if r' == r then r else iterateFix (n - 1) r'
    identityRel ns = IM.fromList [ (i, IM.singleton i S.one) | i <- ns ]
    allNodes r = Set.toList
      (Set.fromList (IM.keys r) `Set.union` foldMap (Set.fromList . IM.keys) (IM.elems r))

-- | Semiring-weighted reachability from a set of seed nodes, computed via
-- worklist relaxation (generalized Bellman-Ford \/ semi-naive fixpoint)
-- instead of 'star's all-pairs iterated squaring. Only visits nodes
-- actually reachable from a seed, and unlike 'star' a seed keeps its own
-- 'S.one' membership even with zero outgoing edges (no arcPairs-endpoint
-- dependency). Returned shape matches 'star's (seed id -> reachable id ->
-- label), restricted to just the given seeds, so 'reachableSet'\/
-- 'reconstructPath' work unchanged against either.
reachFrom :: (S.Semiring s, Eq s) => Relation s -> [Int] -> Relation s
reachFrom rel seeds = IM.fromList [ (s, relaxFrom s) | s <- seeds ]
  where
    -- One worklist relaxation per seed (generalized Bellman-Ford): only
    -- ever visits nodes reachable from this seed, converging when no
    -- further relaxation improves any distance.
    relaxFrom s0 = go (IM.singleton s0 S.one) (Set.singleton s0)
      where
        go dist worklist = case Set.minView worklist of
          Nothing -> dist
          Just (u, rest) ->
            let du = IM.findWithDefault S.zero u dist
                outEdges = IM.findWithDefault IM.empty u rel
                (dist', worklist') = IM.foldlWithKey' (relax du) (dist, rest) outEdges
            in go dist' worklist'
        relax du (d, w) v wuv =
          let old = IM.findWithDefault S.zero v d
              new = old `addS` (du `mulS` wuv)
          in if new == old then (d, w) else (IM.insert v new d, Set.insert v w)

-- | Reachable destination ids from a source id, given a *starred* relation.
reachableSet :: Relation s -> Int -> Set Int
reachableSet starRel src =
  maybe Set.empty (Set.fromList . IM.keys) (IM.lookup src starRel)

-- | Reconstruct the witness edge sequence from src to dst, given a
-- *starred* 'Relation' (PathValue-labeled).  Returns the list of edge
-- labels in src→dst order, or 'Nothing' if unreachable.
--
-- Backtracks via 'pvPred' / 'pvLastEdge': each hop exposes the edge
-- into its destination and the node before it, recursing toward src.
reconstructPath :: Relation (S.PathValue e) -> Int -> Int -> Maybe [e]
reconstructPath starRel src dst
  | src == dst = Just []
  | otherwise    = go dst
  where
    go j
      | j == src  = Just []   -- reached the source: stop, no edge to append
      | otherwise = case IM.lookup src starRel >>= IM.lookup j of
          Nothing                 -> Nothing
          Just S.Unreachable       -> Nothing
          Just (S.Reachable _ Nothing _) -> Nothing   -- identity with no edge but j /= src: inconsistent
          Just (S.Reachable _ (Just e) k) ->
            case go k of
              Nothing -> Nothing
              Just es -> Just (es ++ [e])

-- | Like 'reconstructPath', but keeps each leg's endpoint node ids
-- alongside its label instead of discarding them -- 'pvPred' already
-- names each leg's from-node, this just surfaces it to the caller so a
-- domain layer (e.g. 'PB.Analysis.TaintClosure') can decode both
-- endpoints of every hop, not only the edge label.
reconstructPathNodes :: Relation (S.PathValue e) -> Int -> Int -> Maybe [(Int, Int, e)]
reconstructPathNodes starRel src dst
  | src == dst = Just []
  | otherwise    = go dst
  where
    go j
      | j == src  = Just []
      | otherwise = case IM.lookup src starRel >>= IM.lookup j of
          Nothing                 -> Nothing
          Just S.Unreachable       -> Nothing
          Just (S.Reachable _ Nothing _) -> Nothing
          Just (S.Reachable _ (Just e) k) ->
            case go k of
              Nothing -> Nothing
              Just es -> Just (es ++ [(k, j, e)])
