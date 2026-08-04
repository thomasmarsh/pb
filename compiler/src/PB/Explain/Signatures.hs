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
  , ResolvedCallSiteMap
  , buildResolvedCallSiteMap
  , lookupDeclaredSig
  , computeSignatures
  ) where

import PB.Prelude hiding (id, (.))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import GHC.Generics (Generic)
import PB.AST.Expr (Expr (..))
import PB.AST.Ident (Ident, IdentMap, identMapLookup, identOrig, mkIdentSynthetic)
import PB.AST.SourceFile (FnSig, SubSig)
import PB.AST.Type (PbType)
import PB.Analysis.CallClassify (EffectTag)
import PB.Analysis.Dataflow (lvRoot, lvalueSubscriptIdents, walkExprIdentsExcludingCallees)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..), lookupScopedVarOrSelf)
import PB.Analysis.Taint qualified as Taint
import PB.Compile.IR (EffTerm)
import PB.Explain.Regions (EffLeaf (..), Region, RegionId, RegionOps (..), computeRegionsWith)

data VarBinding = VarBinding
  { vbName :: Ident
  , vbType :: Maybe PbType
  } deriving (Eq, Show, Generic)

data InferredSignature = InferredSignature
  { sigInputs  :: [VarBinding]
  , sigOutputs :: [VarBinding]
  , sigEffects :: Set.Set EffectTag
  } deriving (Eq, Show, Generic)

-- | Every corpus-wide resolved call site, keyed by exactly where it's
-- written: @(callerObject, callerProc, callLine, calleeNameLower) ->
-- (calleeObject, calleeProc)@. Sourced from 'PB.Analysis.Taint.ResolvedCallRow'
-- — the same fact 'PB.Analysis.TypeResolve.resolveVirtual' already computes
-- once, corpus-wide, handling both a dotted receiver-typed call
-- (@dw_1.Retrieve()@) and a bare call to a global function or an unrelated
-- object (via 'resolveVirtual''s own "exactly one other match" fallback) — a
-- deliberately more complete resolution than any bare ancestor-chain walk
-- rooted at the caller's own object could give. A row with no line number or
-- no resolved target is simply absent, not an error (same "unresolved
-- degrades to no extra fact" shape the rest of this module already uses).
--
-- The trailing @calleeNameLower@ component (the as-written callee text,
-- lowercased) disambiguates two distinct calls sharing one source line — a
-- very common real shape via a nested call argument, e.g.
-- @MessageBox(trn(68), trn(161))@, where @MessageBox@ and both @trn@ calls
-- all resolve on line 103. Without it, @(object, proc, line)@ alone collides
-- and one call's lookup can return a sibling call's resolved target — a
-- confirmed real bug (region@1 in @w_gridfind.if_find@ showed a spurious
-- 'ReadsDb' tag that was actually @trn@'s, misattributed to @MessageBox@ on
-- the same line). Matching on the as-written text (not the resolved target
-- name) preserves the existing "resolution doesn't care what the call text
-- looks like" guarantee for a dotted receiver call — @dw_1.Retrieve()@'s own
-- leaf and its own resolved-call-row always carry the identical as-written
-- text, regardless of what the row's resolved target proc is named.
type ResolvedCallSiteMap = Map.Map (Text, Text, Int, Text) (Text, Text)

buildResolvedCallSiteMap :: [Taint.ResolvedCallRow] -> ResolvedCallSiteMap
buildResolvedCallSiteMap rows = Map.fromList
  [ ((Taint.rcrObject r, Taint.rcrFromProc r, ln, T.toLower (Taint.rcrToName r)), (tObj, tProc))
  | r <- rows
  , Just ln   <- [Taint.rcrCallLine r]
  , Just tObj <- [Taint.rcrTargetObject r]
  , Just tProc <- [Taint.rcrTargetProc r]
  ]

-- | A known @(object, name)@'s own declared signature, no resolution search
-- — 'buildCallableSigMap''s own intended shape ("this map does not itself
-- attempt any resolution"). Used both for a procedure's own self-lookup
-- (its declaring object is already known exactly) and, once a call site's
-- target is already known via 'ResolvedCallSiteMap', for that target's
-- declared signature.
lookupDeclaredSig :: IdentMap (Map.Map Ident (Either FnSig SubSig)) -> Text -> Text -> Maybe (Either FnSig SubSig)
lookupDeclaredSig sigMap objText nameText =
  case identMapLookup (mkIdentSynthetic "PB.Explain.Signatures.lookupDeclaredSig: object" objText) sigMap of
    Just (_, procs) -> Map.lookup (mkIdentSynthetic "PB.Explain.Signatures.lookupDeclaredSig: name" nameText) procs
    Nothing         -> Nothing

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
  , saEffects        :: Set.Set EffectTag
  }

sigAccEmpty :: SigAcc
sigAccEmpty = SigAcc Set.empty Set.empty Set.empty Set.empty Set.empty

-- | One atomic leaf's own contribution, relative to a fresh (empty) local-
-- def context — 'sigAccSeq' reconciles that isolation against whatever is
-- already locally defined when it threads this into a running
-- accumulator. A call leaf's transitive effect tags are resolved by keying
-- @(selfObj, selfProc, callLine)@ into @callSiteMap@
-- ('ResolvedCallSiteMap', already correct for dotted and cross-object
-- calls — see its own doc comment), then looked up in @procEffects@
-- ('PB.Analysis.EffectClosure.computeProcEffects''s real @(object,
-- proc_name)@-keyed closure) — an unresolved call site (absent from
-- @callSiteMap@) contributes nothing beyond the leaf's own direct tags,
-- same as a resolved-but-genuinely-effect-free call.
sigAccLeaf :: Text -> Text -> ResolvedCallSiteMap -> Map.Map (Text, Text) (Set.Set EffectTag) -> EffLeaf -> SigAcc
sigAccLeaf selfObj selfProc callSiteMap procEffects leaf = case leaf of
  LAssign var _ln _ty ->
    let d = defIdent var Nothing
    in sigAccEmpty { saLocallyDefined = Set.singleton d, saAllDefs = Set.singleton d }
  LAssignWithRhs var lhsE rhsE _ln _ty tags ->
    let d = defIdent var (Just lhsE)
        rs = walkExprIdentsExcludingCallees rhsE <> lhsSubscriptIdents lhsE
    in SigAcc
        { saLocallyDefined = Set.singleton d
        , saFreeReads      = rs
        , saAllDefs        = Set.singleton d
        , saAllUses        = rs
        , saEffects        = tags
        }
  LCall name callArgs ln tags    -> callLeaf name callArgs ln tags
  LSuspend name callArgs ln tags -> callLeaf name callArgs ln tags
  LReturn e _ln                -> readsOnly (walkExprIdentsExcludingCallees e)
  LBranchCond cond _ln         -> readsOnly (walkExprIdentsExcludingCallees cond)
  where
    readsOnly rs = sigAccEmpty { saFreeReads = rs, saAllUses = rs }
    callLeaf name callArgs ln tags =
      let rs  = foldMap walkExprIdentsExcludingCallees callArgs
          resolvedEff = case Map.lookup (selfObj, selfProc, ln, T.toLower name) callSiteMap of
            Just target -> Map.findWithDefault Set.empty target procEffects
            Nothing     -> Set.empty
          eff = tags <> resolvedEff
      in sigAccEmpty { saFreeReads = rs, saAllUses = rs, saEffects = eff }

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
  , saEffects        = saEffects left <> saEffects right
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
  , saEffects        = saEffects a <> saEffects b
  }

-- | 'opRef' contributes nothing: an 'PB.Explain.Regions.ELetRef' occurrence
-- (or a threshold-cut point) has no free reads/defs of its own for
-- free/live-variable purposes -- the referenced region's own reads/defs are
-- already captured under its own 'RegionId' in the accumulator map, read
-- back out by 'computeSignatures' via 'allUsesElsewhere'.
sigOps :: Text -> Text -> ResolvedCallSiteMap -> Map.Map (Text, Text) (Set.Set EffectTag) -> RegionOps SigAcc
sigOps selfObj selfProc callSiteMap procEffects = RegionOps
  { opLeaf   = sigAccLeaf selfObj selfProc callSiteMap procEffects
  , opFanIn  = sigAccChoice
  , opBranch = \cond ln t f -> sigAccSeq (sigAccLeaf selfObj selfProc callSiteMap procEffects (LBranchCond cond ln)) (sigAccChoice t f)
  , opLoop   = \_ln body -> sigAccChoice body sigAccEmpty
  , opRef    = \_ _ -> sigAccEmpty
  , opSeq    = sigAccSeq
  , opEmpty  = sigAccEmpty
  }

-- | For each ident, how many distinct regions have it in their 'saAllUses'.
-- Built once, in a single pass over 'accs', so a per-region "is this def
-- used elsewhere?" check ('usedElsewhere') is an O(1) map lookup instead of
-- re-unioning every other region's use-set from scratch — the difference
-- between this being O(regions * total-uses) overall and the O(regions^2)
-- all-pairs union it replaces (regions can run into the hundreds for a
-- large procedure, and this walk runs once per procedure corpus-wide).
usesRegionCount :: Map.Map RegionId SigAcc -> Map.Map Ident Int
usesRegionCount = Map.foldr
  (\a counts -> Set.foldr (\i -> Map.insertWith (+) i (1 :: Int)) counts (saAllUses a))
  Map.empty

-- | Every region's candidate signature. Inputs are that region's own free
-- reads, typed via 'lookupScopedVarOrSelf'. Outputs are the union of (a)
-- vars this region defines that some *other* region reads (live-out) and
-- (b) loop-carried vars — a var that is both a free read and a local def
-- of the *same* region is read (as its entering value) before being
-- redefined (its exiting value), which is exactly the loop-carried shape
-- an 'PB.Explain.Regions.ELoop' body produces; this falls out of the
-- general def\/use sets with no loop-specific case in the walk itself,
-- only in this final per-region derivation.
computeSignatures :: Int -> ScopedTypeEnv -> Text -> ResolvedCallSiteMap -> Map.Map (Text, Text) (Set.Set EffectTag) -> EffTerm a b -> Map.Map RegionId InferredSignature
computeSignatures threshold env selfProc callSiteMap procEffects term =
  let selfObj = identOrig (steObject env)
      (_root, accs) = computeRegionsWith threshold (sigOps selfObj selfProc callSiteMap procEffects) term :: (Region, Map.Map RegionId SigAcc)
      counts = usesRegionCount accs
      -- A def is used elsewhere iff some region other than its own uses it:
      -- the total region-count for that ident, minus 1 if the def's own
      -- region is itself among the users (self-use must not count).
      usedElsewhere acc i =
        Map.findWithDefault 0 i counts - (if Set.member i (saAllUses acc) then 1 else 0) > 0
      toBinding i = VarBinding i (lookupScopedVarOrSelf i env)
  in Map.map
       (\acc ->
          let loopCarried = Set.intersection (saFreeReads acc) (saAllDefs acc)
              liveOut     = Set.filter (usedElsewhere acc) (saAllDefs acc)
          in InferredSignature
               { sigInputs  = map toBinding (Set.toAscList (saFreeReads acc))
               , sigOutputs = map toBinding (Set.toAscList (loopCarried <> liveOut))
               , sigEffects = saEffects acc
               })
       accs
