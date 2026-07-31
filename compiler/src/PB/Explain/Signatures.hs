-- | Signature inference over 'PB.Explain.Regions.Region' (Plan 218 Layer
-- 2): a structural free\/live-variable walk giving every 'Region' a
-- candidate signature (inputs the region reads before locally redefining,
-- outputs it defines that are read elsewhere), computed via the same
-- 'PB.Explain.Regions.computeRegionsWith' threshold-cut walk 'Region'
-- itself is built from — not re-derived independently, since the exact
-- 'PB.Explain.Regions.RegionId' an atomic action lands in is decided by
-- that walk and is not recoverable from a finished 'Region' tree by line-
-- range containment alone.
module PB.Explain.Signatures
  ( VarBinding (..)
  , InferredSignature (..)
  , computeSignatures
  ) where

import PB.Prelude hiding (id, (.))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import PB.AST.Expr (Expr (..))
import PB.AST.Ident (Ident, mkIdentSynthetic)
import PB.AST.Type (PbType)
import PB.Analysis.Dataflow (lvRoot, lvalueSubscriptIdents, walkExprIdentsExcludingCallees)
import PB.Analysis.TypeEnv (ScopedTypeEnv, lookupScopedVarOrSelf)
import PB.Compile.IR (EffTerm)
import PB.Explain.Regions (EffLeaf (..), Region, RegionId, RegionOps (..), computeRegionsWith)

data VarBinding = VarBinding
  { vbName :: Ident
  , vbType :: Maybe PbType
  } deriving (Eq, Show)

data InferredSignature = InferredSignature
  { sigInputs  :: [VarBinding]
  , sigOutputs :: [VarBinding]
  } deriving (Eq, Show)

-- | Per-region free\/live-variable accumulator threaded through
-- 'computeRegionsWith'. 'saLocallyDefined' tracks definite assignment —
-- intersected across 'PB.Explain.Regions.EBranch'\/'EFanIn' alternatives
-- and an 'PB.Explain.Regions.ELoop' body versus its own zero-iteration
-- skip, since a var assigned on only one path can't be assumed defined
-- afterward. 'saFreeReads' is order-sensitive: a read only joins it the
-- first time it's seen with no prior local def in the same region.
-- 'saAllDefs'\/'saAllUses' are the region's full def\/use sets, compared
-- across regions after the walk to derive live-out outputs.
data SigAcc = SigAcc
  { saLocallyDefined :: Set.Set Ident
  , saFreeReads      :: Set.Set Ident
  , saAllDefs        :: Set.Set Ident
  , saAllUses        :: Set.Set Ident
  }

sigAccEmpty :: SigAcc
sigAccEmpty = SigAcc Set.empty Set.empty Set.empty Set.empty

-- | One atomic leaf's own contribution, relative to a fresh (empty) local-
-- def context — 'sigAccSeq' reconciles that isolation against whatever is
-- already locally defined when it threads this into a running
-- accumulator.
sigAccLeaf :: EffLeaf -> SigAcc
sigAccLeaf leaf = case leaf of
  LAssign var _ln _ty ->
    let d = defIdent var Nothing
    in sigAccEmpty { saLocallyDefined = Set.singleton d, saAllDefs = Set.singleton d }
  LAssignWithRhs var lhsE rhsE _ln _ty ->
    let d = defIdent var (Just lhsE)
        rs = walkExprIdentsExcludingCallees rhsE <> lhsSubscriptIdents lhsE
    in SigAcc
        { saLocallyDefined = Set.singleton d
        , saFreeReads      = rs
        , saAllDefs        = Set.singleton d
        , saAllUses        = rs
        }
  LCall _name callArgs _ln    -> readsOnly (foldMap walkExprIdentsExcludingCallees callArgs)
  LSuspend _name callArgs _ln -> readsOnly (foldMap walkExprIdentsExcludingCallees callArgs)
  LReturn e _ln                -> readsOnly (walkExprIdentsExcludingCallees e)
  LBranchCond cond _ln         -> readsOnly (walkExprIdentsExcludingCallees cond)
  where
    readsOnly rs = sigAccEmpty { saFreeReads = rs, saAllUses = rs }

-- | The assigned variable's real 'Ident'. Every real (FromSSA-compiled)
-- @EAssignWithRhs@ carries its target as an @ExLvalue@ in @lhs@ (see
-- 'PB.Compile.SSA.noSubscriptLhs'\/'PB.Compile.SSA.stmtToAssigns'), so the
-- root segment's already-minted Ident ('lvRoot') is used directly — never
-- re-minted from the parallel 'Text' field. The 'mkIdentSynthetic'
-- fallback only fires for a hand-built term whose @lhs@ isn't an
-- @ExLvalue@ (never true of compiled output) or for a bare @EAssign@
-- (dead in production; carries no Expr to read a real Ident from at all).
defIdent :: Text -> Maybe Expr -> Ident
defIdent var mLhs = case mLhs of
  Just (ExLvalue lv) | Just root <- lvRoot lv -> root
  Just _  -> mkIdentSynthetic "PB.Explain.Signatures: EAssignWithRhs lhs is not an ExLvalue (hand-built term)" var
  Nothing -> mkIdentSynthetic "PB.Explain.Signatures: EAssign carries no lhs Expr (Effectful-typeclass placeholder, dead in production)" var

lhsSubscriptIdents :: Expr -> Set.Set Ident
lhsSubscriptIdents (ExLvalue lv) = lvalueSubscriptIdents lv
lhsSubscriptIdents _             = Set.empty

-- | Combine "facts accumulated so far" with "what comes next," filtering
-- the next portion's own free reads against what's already definitely
-- defined. Each sub-walk ('PB.Explain.Regions.ELetRef' body,
-- 'PB.Explain.Regions.EBranch' arm, 'PB.Explain.Regions.ELoop' body)
-- starts from a fresh empty context, unaware of the enclosing scope's own
-- prior definitions, so a read that looks free in isolation must be re-
-- checked here before it counts as a genuine free input of the combined
-- region.
sigAccSeq :: SigAcc -> SigAcc -> SigAcc
sigAccSeq left right = SigAcc
  { saLocallyDefined = saLocallyDefined left <> saLocallyDefined right
  , saFreeReads      = saFreeReads left <> Set.filter (`Set.notMember` saLocallyDefined left) (saFreeReads right)
  , saAllDefs        = saAllDefs left <> saAllDefs right
  , saAllUses        = saAllUses left <> saAllUses right
  }

-- | Combine two alternative-path accumulators. Reads\/defs\/uses union
-- (either path may take it); definite assignment intersects (only a var
-- set on every path can be assumed defined afterward).
sigAccChoice :: SigAcc -> SigAcc -> SigAcc
sigAccChoice a b = SigAcc
  { saLocallyDefined = Set.intersection (saLocallyDefined a) (saLocallyDefined b)
  , saFreeReads      = saFreeReads a <> saFreeReads b
  , saAllDefs        = saAllDefs a <> saAllDefs b
  , saAllUses        = saAllUses a <> saAllUses b
  }

-- | 'opRef' contributes nothing: an 'PB.Explain.Regions.ELetRef' occurrence
-- (or a threshold-cut point) has no free reads/defs of its own for
-- free/live-variable purposes -- the referenced region's own reads/defs are
-- already captured under its own 'RegionId' in the accumulator map, read
-- back out by 'computeSignatures' via 'allUsesElsewhere'.
sigOps :: RegionOps SigAcc
sigOps = RegionOps
  { opLeaf   = sigAccLeaf
  , opFanIn  = sigAccChoice
  , opBranch = \cond ln t f -> sigAccSeq (sigAccLeaf (LBranchCond cond ln)) (sigAccChoice t f)
  , opLoop   = \_ln body -> sigAccChoice body sigAccEmpty
  , opRef    = \_ _ -> sigAccEmpty
  , opSeq    = sigAccSeq
  , opEmpty  = sigAccEmpty
  }

-- | Every region's candidate signature. Inputs are that region's own free
-- reads, typed via 'lookupScopedVarOrSelf'. Outputs are the union of (a)
-- vars this region defines that some *other* region reads (live-out) and
-- (b) loop-carried vars — a var that is both a free read and a local def
-- of the *same* region is read (as its entering value) before being
-- redefined (its exiting value), which is exactly the loop-carried shape
-- an 'PB.Explain.Regions.ELoop' body produces; this falls out of the
-- general def\/use sets with no loop-specific case in the walk itself,
-- only in this final per-region derivation.
computeSignatures :: Int -> ScopedTypeEnv -> EffTerm a b -> Map.Map RegionId InferredSignature
computeSignatures threshold env term =
  let (_root, accs) = computeRegionsWith threshold sigOps term :: (Region, Map.Map RegionId SigAcc)
      allUsesElsewhere rid = Map.foldrWithKey
        (\rid' a acc -> if rid' == rid then acc else acc <> saAllUses a)
        Set.empty accs
      toBinding i = VarBinding i (lookupScopedVarOrSelf i env)
  in Map.mapWithKey
       (\rid acc ->
          let loopCarried = Set.intersection (saFreeReads acc) (saAllDefs acc)
              liveOut     = Set.intersection (saAllDefs acc) (allUsesElsewhere rid)
          in InferredSignature
               { sigInputs  = map toBinding (Set.toAscList (saFreeReads acc))
               , sigOutputs = map toBinding (Set.toAscList (loopCarried <> liveOut))
               })
       accs
