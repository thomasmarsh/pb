{-# LANGUAGE StrictData #-}
module PB.Analysis.DeadCode
  ( DeadProcedure (..)
  , ProcInfo (..)
  , classifyDeadProcedures
  ) where

import PB.Prelude

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
-- query).
--
-- Plan 166 Stage 4: caller counts are now pre-computed by Soufflé
-- ('callerCountRules' in 'PB.Pipeline.Rules.DeadCode') and read back as
-- 'Map.Map' arguments, replacing the raw call lists that used to be
-- aggregated internally.
classifyDeadProcedures
  :: Set.Set (Text, Text)       -- ^ dead (object, proc) pairs, from @proc_dead@
  -> [ProcInfo]                 -- ^ all procedures
  -> Map.Map Text Int           -- ^ naive caller counts (callee_name -> count), from @caller_count_naive@
  -> Map.Map (Text, Text) Int   -- ^ scoped caller counts ((object, proc) -> count), from @caller_count_scoped@
  -> [DeadProcedure]
classifyDeadProcedures deadSet procedures naiveCounts scopedCounts =
  let -- Collect dead procedures (deduplicate on (object, name) --
      -- overloaded functions may produce multiple ProcInfo entries).
      deadMap = Map.fromListWith (\a _b -> a)
        [ ((piObject p, piName p), DeadProcedure
              { dpObject = piObject p
              , dpName = piName p
              , dpProcType = piProcType p
              , dpCyclomatic = piCyclomatic p
              , dpConfidence =
                  let naive  = Map.findWithDefault 0 (T.toLower (piName p)) naiveCounts
                      scoped = Map.findWithDefault 0 (piObject p, piName p) scopedCounts
                  in if naive == 0 then "high"
                     else if scoped == 0 then "medium"
                     else "low"
              , dpCallerCountNaive =
                  Map.findWithDefault 0 (T.toLower (piName p)) naiveCounts
              , dpCallerCountScoped =
                  Map.findWithDefault 0 (piObject p, piName p) scopedCounts
              })
        | p <- procedures
        , (piObject p, piName p) `Set.member` deadSet
        ]
  in  sortOn (\d -> (dpObject d, dpName d)) (Map.elems deadMap)
