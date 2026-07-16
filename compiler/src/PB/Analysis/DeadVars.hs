{-# LANGUAGE StrictData #-}
-- | Unused-variable / dead-store analysis.
--
-- Pure module — no I/O. A query over 'PB.Analysis.Dataflow''s def-use and
-- live-variable data, plus 'PB.Analysis.TypeResolve''s per-procedure local
-- variable declarations. Public API:
--
--   findDeadVars :: [LocalVar] -> ProcFlow -> [DeadVarFinding]
module PB.Analysis.DeadVars
  ( DeadVarKind (..)
  , DeadVarFinding (..)
  , deadVarKindText
  , findDeadVars
  ) where

import PB.Prelude
import PB.Analysis.Dataflow
  ( ProcFlow (..), BlockFlow (..), DefSite (..), UseSite (..) )
import PB.Analysis.TypeResolve (LocalVar (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import GHC.Generics (Generic)

data DeadVarKind
  = NeverRead
  | OverwrittenBeforeRead
  | UnusedParam
  deriving (Eq, Ord, Show, Generic)

deadVarKindText :: DeadVarKind -> Text
deadVarKindText NeverRead             = "never-read"
deadVarKindText OverwrittenBeforeRead = "overwritten-before-read"
deadVarKindText UnusedParam           = "unused-param"

data DeadVarFinding = DeadVarFinding
  { dvfObject :: Text
  , dvfProc   :: Text
  , dvfVar    :: Text
  , dvfLine   :: Maybe Int
  , dvfKind   :: DeadVarKind
  } deriving (Eq, Show, Generic)

-- | Def-site kinds ('PB.Analysis.Dataflow.dsKind') that never get reported
-- as the dead side of an overwritten-before-read pair. A bare declaration
-- (@int li_x@) immediately followed by its first real assignment is
-- idiomatic PB, not a bug; a for-loop counter unused in the loop body is a
-- normal iteration idiom, not a discarded value. Both still participate as
-- ordinary kills when computing whether *other* defs are dead.
silentDefKinds :: Set.Set Text
silentDefKinds = Set.fromList ["local_var", "for_var"]

-- | Unused locals/params and dead stores for one procedure.
findDeadVars :: [LocalVar] -> ProcFlow -> [DeadVarFinding]
findDeadVars lvs pf = neverReadFindings <> unusedParamFindings <> overwrittenFindings
  where
    usedVars = Map.keysSet (pfAllUses pf)

    neverReadFindings =
      [ DeadVarFinding (pfObject pf) (pfProc pf) (lvVarName lv) (Just (lvScopeLine lv)) NeverRead
      | lv <- lvs, not (lvIsParam lv), not (Set.member (lvVarName lv) usedVars)
      ]

    unusedParamFindings =
      [ DeadVarFinding (pfObject pf) (pfProc pf) (lvVarName lv) (Just (lvScopeLine lv)) UnusedParam
      | lv <- lvs, lvIsParam lv, not (Set.member (lvVarName lv) usedVars)
      ]

    overwrittenFindings =
      [ f
      | bf <- Map.elems (pfBlocks pf)
      , let blockLiveOut = Map.findWithDefault Set.empty (bfBlockId bf) (pfLiveOut pf)
      , f <- deadStoresInBlock (pfObject pf) (pfProc pf) usedVars blockLiveOut bf
      ]

-- | Walk one block's statements backward from its live-out set, flagging
-- any def whose variable isn't live immediately afterward — i.e. the value
-- it writes is clobbered or discarded before ever being read.
deadStoresInBlock :: Text -> Text -> Set.Set Text -> Set.Set Text -> BlockFlow -> [DeadVarFinding]
deadStoresInBlock obj proc usedVars blockLiveOut bf = go idxsDesc blockLiveOut
  where
    defByIdx  = Map.fromList [(dsStmtIdx d, d) | d <- bfDefs bf]
    usesByIdx = Map.fromListWith Set.union [(usStmtIdx u, Set.singleton (usVar u)) | u <- bfUses bf]
    idxsDesc  = Set.toDescList (Set.fromList (map dsStmtIdx (bfDefs bf) <> map usStmtIdx (bfUses bf)))

    go [] _ = []
    go (idx:rest) live =
      let mDef   = Map.lookup idx defByIdx
          useSet = Map.findWithDefault Set.empty idx usesByIdx
          finding = case mDef of
            Just d
              | not (dsPartial d)
              , not (Set.member (dsKind d) silentDefKinds)
              , not (Set.member (dsVar d) live)
              , Set.member (dsVar d) usedVars
              -> [DeadVarFinding obj proc (dsVar d) (dsLine d) OverwrittenBeforeRead]
            _ -> []
          live' = maybe live (\d -> Set.delete (dsVar d) live) mDef `Set.union` useSet
      in finding <> go rest live'
