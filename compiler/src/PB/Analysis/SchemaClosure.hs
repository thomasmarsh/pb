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
-- primitive (Boolean for reachability, min-plus for hop distances) — there is
-- no second hand-rolled worklist in this module.
--
-- The input construction ('legSourceRows' / 'seedRows') is already Haskell
-- ('PB.Pipeline.DuckDb.Relations.initSchemaRelations'); only the derived fixpoint is
-- computed here.
module PB.Analysis.SchemaClosure
  ( legPriority
  , reachClosure
  , reachClosureMap
  , reachClosureMapFrom
  , schemaGraph
  , cosliceClosure
  , cosliceClosureWith
  , cosliceClosureWithFrom
  , fwdForSeed
  , backForSeed
  , materializeSchemaClosure
  ) where

import PB.Prelude
import PB.Pipeline.DuckDb.Relations (legSourceRows, seedRows, SchemaInputRows (..))
import PB.Pipeline.DuckDb
  ( Handle
  , recreateTextTable
  , appendTextRows
  )

import PB.Algebra.Closure
  ( Interner, emptyInterner, intern, unintern, Relation, fromEdges, reachFrom, internByVal )
import qualified PB.Algebra.Semiring as S
import Data.Semigroup (Sum (..))

import qualified Data.HashMap.Strict as HM
import qualified Data.List           as L
import qualified Data.Map.Strict     as Map
import           Data.Map.Strict     (Map)
import qualified Data.Set            as Set
import           Data.Set            (Set)
import qualified Data.Text           as T
import qualified Data.IntMap.Strict  as IM

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
-- 'reachFrom' (Boolean) — NOT an all-pairs closure. Includes self-pairs via
-- cycles (a node in a cycle reaches itself).
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
  in reachClosureMapFrom interner rel succMap

-- | Forward transitive closure from already-built graph components.
reachClosureMapFrom
  :: Interner Text -> Relation S.Boolean -> Map Text [Int] -> Map Text (Set Text)
reachClosureMapFrom interner rel succMap =
  let -- Seed 'reachFrom' from every direct successor (not the node itself) so
      -- a node's self-pair appears only via a real cycle.
      closed = reachFrom rel (concat (Map.elems succMap))
  in Map.fromList
       [ (s, Set.fromList
            [ t'
            | succId <- succs
            , t <- IM.keys (IM.findWithDefault IM.empty succId closed)
            , Just t' <- [unintern t interner] ])
       | (s, succs) <- Map.toList succMap ]

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

-- | cosliceClosure wrapper that accepts a pre-computed reach map.
-- Builds the graph internally (duplicate work — use 'cosliceClosureWithFrom'
-- when the graph is already available).
cosliceClosureWith
  :: [Text] -> [[Text]] -> Map Text (Set Text) -> ([[Text]], [[Text]])
cosliceClosureWith seeds legRows reach =
  let (interner, edges, rel, succMap) = schemaGraph legRows
  in cosliceClosureWithFrom (interner, edges, rel, succMap) seeds legRows reach

-- | cosliceClosure from already-built graph components.
--
-- Builds min-plus relations once from the shared edge list (instead of
-- rebuilding for each relation variant), batches all seeds into one
-- 'reachFrom' call for forward and reverse distances (instead of N per-seed
-- calls), and derives reverse reachability by inverting the already-computed
-- forward 'reach' map (O(|reach|) instead of a separate Boolean fixpoint).
cosliceClosureWithFrom
  :: (Interner Text, [(Int, Int)], Relation S.Boolean, Map Text [Int])
  -> [Text] -> [[Text]] -> Map Text (Set Text) -> ([[Text]], [[Text]])
cosliceClosureWithFrom (interner, edges, _rel, _succMap) seeds legRows reach =
  let -- Min-plus relations: each edge costs one hop.
      relMinPlus    = fromEdges [ (u, v, S.MinPlus (Just (Sum 1, ())))
                                | (u, v) <- edges ] :: Relation (S.MinPlus ())
      relMinPlusRev = fromEdges [ (v, u, S.MinPlus (Just (Sum 1, ())))
                                | (u, v) <- edges ] :: Relation (S.MinPlus ())

      -- Batch all seeds into one 'reachFrom' call instead of N per-seed
      -- calls. Interned id lookup via the shared interner.
      seedIds = [ i | s <- seeds, Just i <- [HM.lookup s (internByVal interner)] ]

      -- Single batched forward + reverse distance computation.
      allDists    = reachFrom relMinPlus    seedIds
      allDistsRev = reachFrom relMinPlusRev seedIds

      -- Reverse reachability: invert the forward 'reach' map instead of
      -- computing a separate Boolean fixpoint over the transposed relation.
      revReach = Map.foldlWithKey'
        (\acc s' outs -> Set.foldl'
          (\acc' t' -> Map.insertWith Set.union t' (Set.singleton s') acc') acc outs)
        Map.empty reach

      -- Helper: extract a per-seed distance map from the batched result.
      seedDist :: Text -> Relation (S.MinPlus ()) -> Map Text Int
      seedDist s distRel =
        case HM.lookup s (internByVal interner) of
          Nothing -> Map.empty
          Just sId -> Map.fromList
             [ (t', d)
             | (t, S.MinPlus (Just (Sum d, ()))) <-
                 IM.toList (IM.findWithDefault IM.empty sId distRel)
             , Just t' <- [unintern t interner] ]

      adjFwd = Map.fromListWith (++) [ (x, [(y, k)]) | [x, y, k] <- legRows ]

      fwd  = [ r | s <- seeds, r <- fwdForSeed s adjFwd reach (seedDist s allDists) ]
      back = [ r | s <- seeds, r <- backForSeed s adjFwd revReach (seedDist s allDistsRev) ]
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
-- 'cosliceClosure' over the same raw input rows
-- 'PB.Pipeline.DuckDb.Relations.initSchemaRelations' already fetched and
-- passes in as 'SchemaInputRows' (Plan 187 §18 tier 1 — no re-query of
-- @schema_morphisms@\/@schema_objects@). Called from
-- 'PB.Pipeline.Passes.computeSchemaClosure', immediately after
-- 'PB.Pipeline.DuckDb.Relations.initSchemaRelations', before the downstream
-- materializer that reads @reaches@ as an input relation
-- ('PB.Pipeline.DuckDb.materializeRiskCount') runs and before
-- 'PB.Pipeline.DuckDb.materializeDecompositionCoslice'.
materializeSchemaClosure :: SchemaInputRows -> Handle -> IO ()
materializeSchemaClosure SchemaInputRows{sirMorphisms, sirObjects} conn = do
  let morphisms = sirMorphisms
      objects   = sirObjects
      legSource = legSourceRows morphisms
      seeds    = [ k | [k] <- seedRows objects ]
      leg      = legPriority legSource
      -- Build the graph once and share between reach and coslice closures.
      graph@(interner, _edges, rel, succMap) = schemaGraph leg
      reach    = reachClosureMapFrom interner rel succMap
      reaches  = [ [s, t] | (s, outs) <- Map.toList reach, t <- Set.toList outs ]
      (pathFwd, pathBack) = cosliceClosureWithFrom graph seeds leg reach
  recreateTextTable conn "reaches" ["x", "y"]
  appendTextRows conn "reaches" reaches
  recreateTextTable conn "path_leg_fwd" ["s", "target", "leg_ord", "lf", "lt", "kind"]
  appendTextRows conn "path_leg_fwd" pathFwd
  recreateTextTable conn "path_leg_back" ["s", "target", "leg_ord", "lf", "lt", "kind"]
  appendTextRows conn "path_leg_back" pathBack