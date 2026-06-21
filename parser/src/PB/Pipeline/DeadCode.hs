module PB.Pipeline.DeadCode
  ( DeadProcedure (..)
  , ProcInfo (..)
  , computeDeadProcedures
  , cyclomaticComplexity
  ) where

import PB.Prelude
import PB.Pipeline.CfgBuild  (Cfg (..))
import Data.List              (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T

-- | A procedure in the workspace.
data ProcInfo = ProcInfo
  { piObject   :: Text
  , piName     :: Text
  , piProcType :: Text   -- "function" | "subroutine" | "event" | "on"
  , piCyclomatic :: Maybe Int
  } deriving (Eq, Show)

-- | A dead (unreachable) procedure with confidence classification.
data DeadProcedure = DeadProcedure
  { dpObject          :: Text
  , dpName            :: Text
  , dpProcType        :: Text
  , dpCyclomatic      :: Maybe Int
  , dpConfidence      :: Text   -- "high" | "medium" | "low"
  , dpCallerCountNaive  :: Int
  , dpCallerCountScoped :: Int
  } deriving (Eq, Show)

-- | Compute cyclomatic complexity from a CFG: E - N + 2*P.
-- For a single connected procedure body, P = 1, so complexity = E - N + 2.
cyclomaticComplexity :: Cfg -> Int
cyclomaticComplexity cfg =
  let n = length (cfgBlocks cfg)
      e = length (cfgEdges cfg)
  in  if n == 0 then 1 else e - n + 2

-- | Compute unreachable procedures via BFS from entry points.
--
-- Inputs:
--   procedures — all procedures in the workspace
--   calls      — raw call sites (object, from_proc, to_name)
--   resolved   — resolved calls (object, from_proc, target_object, target_proc)
--   inherits   — inheritance edges (child, parent)
--   dwObjects  — set of DataWindow object names
computeDeadProcedures
  :: [ProcInfo]              -- ^ all procedures
  -> [(Text, Text, Text)]    -- ^ raw calls: (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)] -- ^ resolved calls: (object, from_proc, target_object, target_proc)
  -> [(Text, Text)]          -- ^ inherits: (child, parent)
  -> Set.Set Text            -- ^ DataWindow object names
  -> [DeadProcedure]
computeDeadProcedures procedures calls resolved inherits dwObjects =
  let -- Index procedures by (object, name)
      procIndex = Map.fromList
        [ ((piObject p, piName p), p) | p <- procedures ]

      -- Index procedure names by object (case-insensitive lookup)
      procsByObj :: Map.Map Text (Map.Map Text Text)
      procsByObj = Map.fromListWith Map.union
        [ (piObject p, Map.singleton (T.toLower (piName p)) (piName p))
        | p <- procedures
        ]

      -- Build same-object edges: caller -> callee when callee lives in same object
      sameObjEdges = Map.fromListWith (++)
        [ ((obj, fromProc), [(obj, matched)])
        | (obj, fromProc, toName) <- calls
        , nameMap <- maybeToList (Map.lookup obj procsByObj)
        , matched <- maybeToList (Map.lookup (T.toLower toName) nameMap)
        ]

      -- Build cross-object edges from resolved calls
      crossObjEdges = Map.fromListWith (++)
        [ ((obj, fromProc), [(tgtObj, tgtProc)])
        | (obj, fromProc, tgtObj, tgtProc) <- resolved
        ]

      -- Build override edges: if parent.m is reachable, child.m is too
      childrenOf = Map.fromListWith (++)
        [ (parent, [child]) | (child, parent) <- inherits ]

      methodsByObj = Map.fromListWith Set.union
        [ (piObject p, Set.singleton (piName p)) | p <- procedures ]

      overrideEdges = Map.fromListWith (++)
        [ ((parentObj, method), [(childObj, method)])
        | (parentObj, methods) <- Map.toList methodsByObj
        , childObj <- Map.findWithDefault [] parentObj childrenOf
        , method <- Set.toList methods
        , (childObj, method) `Map.member` procIndex
        ]

      -- Combine all edges
      allEdges = Map.unionWith (++) (Map.unionWith (++) sameObjEdges crossObjEdges) overrideEdges

      -- Seed 1: event and on handlers are always reachable
      seeds = Set.fromList
        [ (piObject p, piName p)
        | p <- procedures
        , piProcType p `elem` ["event", "on"]
        ]

      -- Seed 2: procedures in DW objects that have calls are reachable
      dwSeeds = Set.fromList
        [ (obj, fromProc)
        | (obj, fromProc, _) <- calls
        , obj `Set.member` dwObjects
        ]

      allSeeds = Set.union seeds dwSeeds

      -- BFS from seeds
      reachable = bfs allSeeds allEdges

      -- Compute caller counts for dead procedures
      naiveMap = Map.fromListWith Set.union
        [ (T.toLower toName, Set.singleton (obj, fromProc))
        | (obj, fromProc, toName) <- calls
        ]

      scopedMap = Map.fromListWith (+)
        [ ((tgtObj, tgtProc), 1 :: Int)
        | (_, _, tgtObj, tgtProc) <- resolved
        ]

      -- Collect dead procedures (deduplicate on (object, name) —
      -- overloaded functions may produce multiple ProcInfo entries).
      deadMap = Map.fromListWith (\a _b -> a)
        [ ((piObject p, piName p), DeadProcedure
              { dpObject = piObject p
              , dpName = piName p
              , dpProcType = piProcType p
              , dpCyclomatic = piCyclomatic p
              , dpConfidence =
                  let naive = Set.size (Map.findWithDefault Set.empty (T.toLower (piName p)) naiveMap)
                      scoped = Map.findWithDefault 0 (piObject p, piName p) scopedMap
                  in if naive == 0 then "high"
                     else if scoped == 0 then "medium"
                     else "low"
              , dpCallerCountNaive =
                  Set.size (Map.findWithDefault Set.empty (T.toLower (piName p)) naiveMap)
              , dpCallerCountScoped =
                  Map.findWithDefault 0 (piObject p, piName p) scopedMap
              })
        | p <- procedures
        , (piObject p, piName p) `Set.notMember` reachable
        ]
      dead = sortOn (\d -> (dpObject d, dpName d)) (Map.elems deadMap)
  in  sortOn (\d -> (dpObject d, dpName d)) dead

-- | BFS reachability from seed set through adjacency map.
bfs :: Set.Set (Text, Text) -> Map.Map (Text, Text) [(Text, Text)] -> Set.Set (Text, Text)
bfs seeds edges = go seeds (Set.toList seeds)
  where
    go visited [] = visited
    go visited (current:rest) =
      let neighbors = Map.findWithDefault [] current edges
          newNeighbors = filter (`Set.notMember` visited) neighbors
          visited' = foldl' (flip Set.insert) visited newNeighbors
      in  go visited' (rest ++ newNeighbors)
