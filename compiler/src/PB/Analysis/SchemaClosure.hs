{-# LANGUAGE StrictData #-}
-- | Schema-category closure — production's sole source for
-- @reaches@, @path_leg_fwd@, and @path_leg_back@.
--
-- The closure is a pure Haskell fixpoint over the raw EDB inputs:
--
--   * 'legPriority' is the writes-vs-retrieve priority cascade,
--     re-expressed as a deterministic per-(x,y) highest-priority-kind pick
--     where ties keep the first input row.
--   * 'reachClosure' is the forward transitive closure of @leg@,
--     computed as a worklist fixpoint — NOT
--     'PB.Algebra.Closure.star''s all-pairs closure (which is asymptotically
--     wrong for this large/sparse graph with a small seed set).
--   * 'cosliceClosure' is the forward + backward shortest-path witness
--     reconstruction: for every seed it emits EVERY shortest leg on a path
--     to a target (set semantics through a diamond, bounded 2x), so the
--     downstream 'PB.Pipeline.DuckDb.materializeDecompositionCoslice'
--     ROW_NUMBER tie-break picks one witness per ordinal.
--
-- The EDB construction ('legSourceRows' / 'seedRows') is already Haskell
-- ('PB.Pipeline.DuckDb.Relations.initSchemaRelations'); only the IDB fixpoint is
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
  , querySchemaMorphismRows
  , querySchemaObjects
  , recreateTextTable
  , appendTextRows
  )

import qualified Data.List       as L
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import qualified Data.Set        as Set
import           Data.Set        (Set)
import qualified Data.Text       as T

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

-- | Forward transitive closure of @leg@ (kind ignored), computed as a
-- worklist fixpoint — NOT 'PB.Algebra.Closure.star''s all-pairs closure
-- (§12 item 6). Includes self-pairs via cycles (a node in a cycle reaches
-- itself).
reachClosure :: [[Text]] -> [[Text]]
reachClosure legRows =
  [ [s, t] | (s, outs) <- Map.toList (reachClosureMap legRows), t <- Set.toList outs ]

-- | Forward transitive closure as a 'Map' (node -> reachable set). Shared by
-- 'reachClosure' and 'cosliceClosure'.
reachClosureMap :: [[Text]] -> Map Text (Set Text)
reachClosureMap legRows =
  let adj = Map.fromListWith Set.union [ (x, Set.singleton y) | [x, y, _] <- legRows ]
      -- Iterative: reach(s) starts as direct successors; repeatedly add, for
      -- each s, the successors of everything currently reachable from s.
      -- Worklist over changed sources keeps it a single pass per growth layer.
      go reach [] = reach
      go reach (s : rest)
        | let outs    = Map.findWithDefault Set.empty s reach
        , let newOuts = Set.unions
                [ Map.findWithDefault Set.empty t adj | t <- Set.toList outs ]
        , let merged  = Set.union outs newOuts
        , merged /= outs
        = go (Map.insert s merged reach) (rest ++ [s])
        | otherwise = go reach rest
  in go adj (Map.keys adj)

-- | Reverse reachability: node -> set of nodes that can reach it. Needed for
-- the backward path-leg rule's @reaches(t, lf)@ guard.
reverseReachClosure :: Map Text (Set Text) -> Map Text (Set Text)
reverseReachClosure reach =
  Map.fromListWith Set.union
    [ (y, Set.singleton x) | (x, outs) <- Map.toList reach, y <- Set.toList outs ]

-- | Unweighted BFS distances from a seed over an adjacency map (node ->
-- [(neighbor, kind)]). Returns node -> hop count.
bfsDist :: Map Text [(Text, Text)] -> Text -> Map Text Int
bfsDist adj seed = go (Map.singleton seed 0) (Map.singleton seed 0)
  where
    go dist frontier
      | Map.null frontier = dist
      | otherwise =
          let next = Map.fromList
                [ (n, d + 1)
                | (node, d) <- Map.toList frontier
                , (n, _) <- Map.findWithDefault [] node adj
                , n `Map.notMember` dist
                ]
          in go (Map.union dist next) next

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
  let adjFwd   = Map.fromListWith (++)
        [ (x, [(y, k)]) | [x, y, k] <- legRows ]
      adjRev   = Map.fromListWith (++)
        [ (y, [(x, k)]) | [x, y, k] <- legRows ]   -- predecessors
      revReach = reverseReachClosure reach
      fwd  = [ r | s <- seeds, r <- fwdForSeed s adjFwd reach ]
      back = [ r | s <- seeds, r <- backForSeed s adjFwd adjRev revReach ]
  in (fwd, back)

fwdForSeed
  :: Text -> Map Text [(Text, Text)] -> Map Text (Set Text) -> [[Text]]
fwdForSeed s adjFwd reach =
  let dist = bfsDist adjFwd s
      legs = [ (x, y, k) | (x, ns) <- Map.toList adjFwd, (y, k) <- ns ]
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
  :: Text -> Map Text [(Text, Text)] -> Map Text [(Text, Text)]
  -> Map Text (Set Text) -> [[Text]]
backForSeed s adjFwd adjRev revReach =
  let dist = bfsDist adjRev s
      legs = [ (x, y, k) | (x, ns) <- Map.toList adjFwd, (y, k) <- ns ]
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
-- 'cosliceClosure' over the same raw EDB inputs
-- 'PB.Pipeline.DuckDb.Relations.initSchemaRelations' reads. Must run after
-- @schema_morphisms@\/@schema_objects@ are populated (same prerequisite as
-- 'initSchemaRelations'); called from 'PB.Pipeline.Passes.materializeAllRelationsViews',
-- before the downstream materializer that reads @reaches@ as an EDB input
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
