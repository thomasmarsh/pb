{-# LANGUAGE StrictData #-}
-- | Schema-category closure — production's sole source for
-- @reaches@, @path_leg_fwd@, and @path_leg_back@.
--
-- The closure is a pure Haskell fixpoint over the raw input relations:
--
--   * 'legPriority' is the writes-vs-retrieve priority cascade,
--     re-expressed as a deterministic per-(x,y) highest-priority-kind pick
--     where ties keep the first input row.
--   * 'reachClosure' is the forward transitive closure of @leg@, computed via
--     'PB.Algebra.Closure.reachFrom' (seeded worklist relaxation) — NOT an
--     all-pairs closure (which is asymptotically wrong for this large/sparse
--     graph with a small seed set). Includes self-pairs via cycles (a node in
--     a cycle reaches itself).
--   * 'cosliceClosure' is the forward + backward shortest-path witness
--     reconstruction: for every seed it emits EVERY shortest leg on a path
--     to a target (set semantics through a diamond, bounded 2x), so the
--     downstream 'PB.Pipeline.DuckDb.materializeDecompositionCoslice'
--     ROW_NUMBER tie-break picks one witness per ordinal.
--
-- All three closures are built on the single 'PB.Algebra.Closure.reachFrom'
-- primitive (Boolean for reachability, min-plus for hop distances, and the
-- transposed relation for reverse reachability) — there is no second
-- hand-rolled worklist in this module.
--
-- The input construction ('legSourceRows' / 'seedRows') is already Haskell
-- ('PB.Pipeline.DuckDb.Relations.initSchemaRelations'); only the derived fixpoint is
-- computed here.
module PB.Analysis.SchemaClosure
  ( legPriority
  , reachClosure
  , cosliceClosure
  , materializeSchemaClosure
  ) where

import PB.Prelude
import PB.Pipeline.DuckDb.Relations (legSourceRows, seedRows)
import PB.Pipeline.DuckDb
  ( Handle
  , recreateTextTable
  , appendTextRows
  )
import PB.Pipeline.DuckDb.PhaseB.Query
  ( querySchemaMorphismRows
  , querySchemaObjects
  )

import PB.Algebra.Closure
  ( Interner, emptyInterner, intern, unintern, Relation, fromEdges, reachFrom )
import qualified PB.Algebra.Semiring as S
import Data.Semigroup (Sum (..))

import qualified Data.List       as L
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import qualified Data.Set        as Set
import           Data.Set        (Set)
import qualified Data.Text       as T
import qualified Data.IntMap.Strict as IM

-- | Priority-cascade leg selection, reproducing the writes-vs-retrieve
-- choice-domain result deterministically. Groups @leg_source@ rows by
-- (x, y) and keeps the highest-priority kind
-- (writes = 0 > retrieve = 1 > reads\/fk = 2); ties within a tier keep the
-- first row in input order (matching the "first tuple derived for a key is
-- locked" lock-in — p0 rules derive before p1 before p2, and within p2 the
-- first @leg_source@ fact wins).
legPriority :: [[Text]] -> [[Text]]
legPriority rows = map third (Map.elems (L.foldl' step Map.empty (zip [0 :: Int ..] rows)))
  where
    third (_, _, r) = r
    prio :: Text -> Int
    prio "writes"   = 0
    prio "retrieve" = 1
    prio _          = 2
    step m (i, [x, y, k]) =
      let key = (x, y)
          p   = prio k
      in case Map.lookup key m of
           Nothing -> Map.insert key (p, i, [x, y, k]) m
           Just (p', i', row)
             | p < p'    -> Map.insert key (p, i, [x, y, k]) m
             | otherwise -> Map.insert key (p', i', row) m
    step m _ = m

-- | Intern the leg graph once, returning the Boolean reachability relation
-- plus, for each source node (as 'Text'), its list of successor node ids.
-- The raw interned edge list is also returned so callers can rebuild the
-- relation under a different semiring (e.g. min-plus for hop distances).
schemaGraph
  :: [[Text]]
  -> (Interner Text, [(Int, Int)], Relation S.Boolean, Map Text [Int])
schemaGraph legRows =
  let step (interner, edges, succMap) [x, y, _] =
        let (xi, int1) = intern x interner
            (yi, int2) = intern y int1
        in (int2, (xi, yi) : edges, Map.insertWith (++) x [yi] succMap)
      step acc _ = acc
      (intAcc, edgesRev, succRev) =
        L.foldl' step (emptyInterner, [], Map.empty) legRows
      allEdges = reverse edgesRev
      rel = fromEdges [ (u, v, S.one) | (u, v) <- allEdges ] :: Relation S.Boolean
  in (intAcc, allEdges, rel, succRev)

-- | Forward transitive closure of @leg@ (kind ignored), computed via
-- 'reachFrom' (Boolean) — NOT an all-pairs closure (§12 item 6). Includes
-- self-pairs via cycles (a node in a cycle reaches itself).
--
-- 'reachFrom' seeds keep their own 0-hop self-membership, so we seed it from
-- each node's *direct successors* rather than the node itself: a node then
-- appears in its own out-set only if it is reachable from a successor — i.e.
-- via a real cycle — exactly matching the old worklist fixpoint.
reachClosure :: [[Text]] -> [[Text]]
reachClosure legRows =
  [ [s, t] | (s, outs) <- Map.toList (reachClosureMap legRows), t <- Set.toList outs ]

-- | Forward transitive closure as a 'Map' (node -> reachable set). Shared by
-- 'reachClosure' and 'cosliceClosure'.
reachClosureMap :: [[Text]] -> Map Text (Set Text)
reachClosureMap legRows =
  let (interner, _edges, rel, succMap) = schemaGraph legRows
      -- Seed 'reachFrom' from every direct successor (not the node itself) so
      -- a node's self-pair appears only via a real cycle.
      closed = reachFrom rel (concat (Map.elems succMap))
  in Map.fromList
       [ (s, Set.fromList
            [ t'
            | succId <- succs
            , t <- IM.keys (IM.findWithDefault IM.empty succId closed)
            , Just t' <- [unintern t interner] ])
       | (s, succs) <- Map.toList succMap ]

-- | Reverse reachability: node -> set of nodes that can reach it, computed via
-- 'reachFrom' over the transposed relation — the algebraic dual of
-- 'reachClosureMap', not a second hand-rolled worklist. The same
-- successor-seeded trick keeps a node's self-pair present only via a cycle,
-- so reverse reachability agrees with the forward closure's inversion.
reverseReachClosure
  :: Interner Text -> Relation S.Boolean -> Map Text [Int] -> Map Text (Set Text)
reverseReachClosure interner rel succMap =
  let revRel = transposeRel rel
      closed = reachFrom revRel (concat (Map.elems succMap))
  in Map.fromList
       [ (t, Set.fromList
            [ x'
            | succId <- succs
            , x <- IM.keys (IM.findWithDefault IM.empty succId closed)
            , Just x' <- [unintern x interner] ])
       | (t, succs) <- Map.toList succMap ]

-- | Transpose a Boolean relation (swap every arc's endpoints).
transposeRel :: Relation S.Boolean -> Relation S.Boolean
transposeRel rel =
  fromEdges [ (v, u, lbl) | (u, inner) <- IM.toList rel, (v, lbl) <- IM.toList inner ]

-- | Shortest-hop distances from a seed over the leg graph, via 'reachFrom'
-- (min-plus semiring, each edge weighted one hop). Mirrors the old unweighted
-- 'bfsDist': a seed keeps distance 0, and only nodes reachable from the seed
-- appear.
hopDist :: Interner Text -> Relation (S.MinPlus ()) -> Text -> Map Text Int
hopDist interner relMinPlus seed =
  let (sId, interner') = intern seed interner
      closed = reachFrom relMinPlus [sId]
  in Map.fromList
       [ (t', d)
       | (t, S.MinPlus (Just (Sum d, ()))) <-
           IM.toList (IM.findWithDefault IM.empty sId closed)
       , Just t' <- [unintern t interner'] ]

-- | Multi-witness shortest-path reconstruction from seeds over @leg@,
-- emitting @path_leg_fwd@ / @path_leg_back@. Emits EVERY shortest leg on a
-- path from seed to target (set semantics through a diamond, bounded 2x), so
-- the downstream 'PB.Pipeline.DuckDb.materializeDecompositionCoslice'
-- ROW_NUMBER tie-break picks one witness per ordinal. Returns
-- @(path_leg_fwd, path_leg_back)@, each @[s, target, leg_ord, lf, lt, kind]@.
cosliceClosure
  :: [Text]            -- ^ seeds (column object keys)
  -> [[Text]]          -- ^ leg rows (x, y, kind)
  -> ([[Text]], [[Text]])
cosliceClosure seeds legRows =
  cosliceClosureWith seeds legRows (reachClosureMap legRows)

cosliceClosureWith
  :: [Text] -> [[Text]] -> Map Text (Set Text) -> ([[Text]], [[Text]])
cosliceClosureWith seeds legRows reach =
  let (interner, edges, rel, succMap) = schemaGraph legRows
      -- Min-plus relations: each edge costs one hop (NOT 'S.one', which is the
      -- 0-distance identity). Forward and transposed variants back the two
      -- distance maps below.
      relMinPlus = fromEdges [ (u, v, S.MinPlus (Just (Sum 1, ())))
                             | (u, v) <- edges ] :: Relation (S.MinPlus ())
      relMinPlusRev = fromEdges [ (v, u, S.MinPlus (Just (Sum 1, ())))
                               | (u, v) <- edges ] :: Relation (S.MinPlus ())
      revReach = reverseReachClosure interner rel succMap
      adjFwd   = Map.fromListWith (++) [ (x, [(y, k)]) | [x, y, k] <- legRows ]
      fwd  = [ r | s <- seeds, r <- fwdForSeed s adjFwd reach (hopDist interner relMinPlus s) ]
      back = [ r | s <- seeds, r <- backForSeed s adjFwd revReach (hopDist interner relMinPlusRev s) ]
  in (fwd, back)

fwdForSeed
  :: Text -> Map Text [(Text, Text)] -> Map Text (Set Text) -> Map Text Int -> [[Text]]
fwdForSeed s adjFwd reach dist =
  let legs = [ (x, y, k) | (x, ns) <- Map.toList adjFwd, (y, k) <- ns ]
      emit (lf, lt, k) =
        case (Map.lookup lf dist, Map.lookup lt dist) of
          (Just o, Just o') | o' == o + 1 ->
            let finalHop = [s, lt, T.pack (show o), lf, lt, k]
                inter = [ [s, t, T.pack (show o), lf, lt, k]
                        | t <- Set.toList (Map.findWithDefault Set.empty lt reach)
                        , Just dt <- [Map.lookup t dist]
                        , dt > o + 1 ]
            in finalHop : inter
          _ -> []
  in concatMap emit legs

backForSeed
  :: Text -> Map Text [(Text, Text)]
  -> Map Text (Set Text) -> Map Text Int -> [[Text]]
backForSeed s adjFwd revReach dist =
  let legs = [ (x, y, k) | (x, ns) <- Map.toList adjFwd, (y, k) <- ns ]
      emit (lf, lt, k) =
        case (Map.lookup lt dist, Map.lookup lf dist) of
          (Just o, Just o') | o' == o + 1 ->
            -- lf is the FAR node (dist o+1), lt the NEAR node (dist o); the
            -- backward head binds target = lf (path_leg_back(s, t, o, t, lt, kind)
            -- with leg(t, lt)).
            let finalHop = [s, lf, T.pack (show o), lf, lt, k]
                inter = [ [s, t, T.pack (show o), lf, lt, k]
                        | t <- Set.toList (Map.findWithDefault Set.empty lf revReach)
                        , Just dt <- [Map.lookup t dist]
                        , dt > o + 1 ]
            in finalHop : inter
          _ -> []
  in concatMap emit legs

-- | Materialize @reaches@, @path_leg_fwd@, @path_leg_back@ as real DuckDB
-- tables, computed by 'legPriority' / 'reachClosure' /
-- 'cosliceClosure' over the same raw input relations
-- 'PB.Pipeline.DuckDb.Relations.initSchemaRelations' reads. Must run after
-- @schema_morphisms@\/@schema_objects@ are populated (same prerequisite as
-- 'initSchemaRelations'); called from 'PB.Pipeline.Passes.materializeAllRelationsViews',
-- before the downstream materializer that reads @reaches@ as an input relation
-- ('PB.Pipeline.DuckDb.materializeRiskCount') runs and before
-- 'PB.Pipeline.DuckDb.materializeDecompositionCoslice'.
materializeSchemaClosure :: Handle -> IO ()
materializeSchemaClosure conn = do
  morphisms <- querySchemaMorphismRows conn
  objects   <- querySchemaObjects conn
  let legSource = legSourceRows morphisms
      seeds    = [ k | [k] <- seedRows objects ]
      leg      = legPriority legSource
      reach    = reachClosureMap leg
      reaches  = [ [s, t] | (s, outs) <- Map.toList reach, t <- Set.toList outs ]
      (pathFwd, pathBack) = cosliceClosureWith seeds leg reach
  recreateTextTable conn "reaches" ["x", "y"]
  appendTextRows conn "reaches" reaches
  recreateTextTable conn "path_leg_fwd" ["s", "target", "leg_ord", "lf", "lt", "kind"]
  appendTextRows conn "path_leg_fwd" pathFwd
  recreateTextTable conn "path_leg_back" ["s", "target", "leg_ord", "lf", "lt", "kind"]
  appendTextRows conn "path_leg_back" pathBack
