{-# LANGUAGE StrictData #-}
module PB.Analysis.DeadCode
  ( DeadProcedure (..)
  , ProcInfo (..)
  , classifyDeadProcedures
  , cyclomaticComplexity
  ) where

import PB.Prelude
import PB.Analysis.Cfg  (Cfg (..))
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

-- | Classify confidence/caller-counts for a given, already-known dead set.
--
-- Plan 161 Phase 2b cutover (2026-07-11): this used to also COMPUTE the
-- dead set itself, via a seeded BFS over same-object/cross-object/override
-- call edges (the "reachable" core the plan's Migration Inventory tracked).
-- That reachability walk is now Datalog (see 'PB.Pipeline.Souffle.deadReachRules'
-- -- @proc_reachable@\/@proc_dead@), proven exact on the real corpus
-- (104/104 rows vs. the old Haskell BFS) before the Haskell copy was
-- deleted here, so 'PB.Pipeline.Passes.runPass8' now reads @proc_dead@
-- back from DuckDB and passes it in as 'deadSet'. What's left here is
-- genuinely Haskell-only: confidence/caller-count classification has no
-- Datalog equivalent (it's a report-formatting concern, not a fixpoint
-- query) and still needs 'calls'\/'resolved' for the naive\/scoped caller
-- counts. 'inherits'\/@dwObjects@ are gone from the signature -- they were
-- only ever used to seed\/extend the BFS, which no longer happens here.
classifyDeadProcedures
  :: Set.Set (Text, Text)       -- ^ dead (object, proc) pairs, from @proc_dead@
  -> [ProcInfo]                 -- ^ all procedures
  -> [(Text, Text, Text)]       -- ^ raw calls: (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)] -- ^ resolved calls: (object, from_proc, target_object, target_proc)
  -> [DeadProcedure]
classifyDeadProcedures deadSet procedures calls resolved =
  let -- Compute caller counts for dead procedures
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
        , (piObject p, piName p) `Set.member` deadSet
        ]
  in  sortOn (\d -> (dpObject d, dpName d)) (Map.elems deadMap)
