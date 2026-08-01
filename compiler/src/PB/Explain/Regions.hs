-- | Region computation over 'PB.Compile.IR.Eff'/'EffTerm' (Plan 218 Layer
-- 1): decomposes a compiled procedure into complexity-bounded 'Region's,
-- each a candidate functional-core/imperative-shell boundary.
--
-- A direct recursive walk over 'Eff', not a 'PB.Compile.IR.foldFreyd'
-- instantiation — a fold target produces one @k a b@ morphism per target
-- category, which cannot express "return a tree whose shape depends on
-- where a cut was decided." Do not try to re-express this as a fold
-- target; the cut-point/shape decision has no morphism to fold into.
--
-- 'computeRegionsWith' generalizes the same walk with a caller-supplied
-- 'RegionOps' accumulator (Plan 218 Layer 2 note: 'PB.Explain.Signatures'
-- needs to know exactly which 'RegionId' each atomic 'Eff' action lands in
-- to compute a per-region free/live-variable signature — that assignment
-- is decided by this module's threshold-cut walk, not recoverable from the
-- finished 'Region' tree by line-range containment, since a branch/loop
-- arm's own line-range envelope can legitimately contain a cut child's
-- exact range). 'computeRegions' is the trivial @()@-accumulator
-- instantiation and its behavior is unchanged.
module PB.Explain.Regions
  ( RegionId
  , regionIdLabel
  , Region (..)
  , EffLeaf (..)
  , RegionOps (..)
  , defaultComplexityThreshold
  , computeRegions
  , computeRegionsWith
  ) where

import PB.Prelude hiding (id, (.))
import Control.Monad.State.Strict (State, evalState, get, modify')
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Set as Set
import PB.AST.Expr (Expr)
import PB.AST.Type (PbType)
import PB.Analysis.CallClassify (EffectTag)
import PB.Compile.IR (Eff (..), EffTerm (..))

-- | Opaque handle — the constructor is not exported. Every other layer
-- treats this as an inert 'Eq'/'Ord' key for matching a @PRegionRef@ back
-- to its defining block, plus 'regionIdLabel' for a stable, guaranteed-
-- unique-per-'computeRegionsWith'-call display fallback (used only when a
-- region carries no line info of its own to show instead — see
-- 'regionLines'). The minting scheme behind both is a
-- 'PB.Explain.Regions'-internal implementation detail, not a contract — it
-- may change shape later without rippling to other layers.
newtype RegionId = RegionId Text
  deriving (Eq, Ord, Show)

-- | A stable, human-distinguishable (not human-meaningful) display label.
-- Never parsed back or relied on for identity — use 'Eq'/'Ord' for that.
regionIdLabel :: RegionId -> Text
regionIdLabel (RegionId t) = t

data Region = Region
  { regionId         :: RegionId
  , regionComplexity :: Int              -- ^ McCabe of THIS region only; a
                                          -- cut child contributes 0 extra
                                          -- decision points to its parent.
  , regionLines      :: Maybe (Int, Int) -- ^ min/max source line directly
                                          -- owned by this region (excludes
                                          -- any cut child's own span);
                                          -- 'Nothing' for a genuinely
                                          -- leaf-free region (distinct from
                                          -- a real region starting at line
                                          -- 0).
  , regionChildren   :: [Region]
  }

-- | Common McCabe convention; override freely via 'computeRegions'\'s
-- explicit threshold argument.
defaultComplexityThreshold :: Int
defaultComplexityThreshold = 10

-- | Non-GADT projection of one atomic 'Eff' contribution — what a
-- 'computeRegionsWith' caller's accumulator sees. Exists because 'Eff'\'s
-- own GADT type indices vary per constructor, so a walk caller only ever
-- needs each leaf's own fields, never its typed continuation.
-- 'LBranchCond' is not a distinct 'Eff' constructor — it is 'EBranch'\'s
-- own condition, surfaced as a leaf-shaped fact so a caller's accumulator
-- sees it the same way it sees every other read-bearing site.
data EffLeaf
  = LAssign        Text Int (Maybe PbType)
  | LAssignWithRhs Text Expr Expr Int (Maybe PbType)
  | LCall          Text [Expr] Int (Set.Set EffectTag)
  | LSuspend       Text [Expr] Int (Set.Set EffectTag)
  | LReturn        Expr Int
  | LBranchCond    Expr Int

-- | Caller-supplied accumulator operations threaded alongside the
-- existing complexity/line-span bookkeeping. 'opLeaf' produces one atomic
-- leaf's own contribution in isolation (relative to a fresh/empty
-- context); 'opSeq' threads that isolated contribution (or a structural
-- sub-term's own combined result) after whatever has already accumulated
-- in the same straight-line run. 'opFanIn'\/'opBranch'\/'opLoop' each
-- combine two alternative paths, kept as three separate fields (not one
-- generic two-argument combinator) because a caller reconstructing real
-- surface syntax (a rendered @if@\/@else@, a rendered loop) needs to know
-- *which* 'Eff' construct produced the two arms it's combining -- a
-- generic combinator can't recover that once each arm has already been
-- folded into the same @acc@ shape. 'opRef' produces the acc contribution
-- for referencing an already-closed region from its own enclosing region
-- (an 'ELetRef' occurrence, or the point in a straight-line run where a
-- threshold cut moved everything before it into a sibling 'Region') --
-- needed so a caller reconstructing a statement sequence can mark exactly
-- where a child region was cut out, not just that it exists in the tree.
-- 'computeRegions' instantiates this with @acc = ()@ and every operation a
-- no-op.
data RegionOps acc = RegionOps
  { opLeaf   :: EffLeaf -> acc
  , opFanIn  :: acc -> acc -> acc
  , opBranch :: Expr -> Int -> acc -> acc -> acc
  , opLoop   :: Int -> acc -> acc
  , opRef    :: RegionId -> Maybe (Int, Int) -> acc
  , opSeq    :: acc -> acc -> acc
  , opEmpty  :: acc
  }

-- | The still-open, not-yet-cut portion of the region currently being
-- built, plus every sibling region already cut from earlier in the same
-- straight-line run, plus the caller's own running accumulator and the
-- map of every region closed so far (this run's cuts and any recursively
-- closed sub-regions). Fields (positional, no accessors): running
-- complexity, running line span, children of the still-open portion,
-- already-cut sibling regions, running accumulator, closed-region map.
data WalkState acc = WalkState Int (Maybe (Int, Int)) [Region] [Region] acc (Map.Map RegionId acc)

initWalkState :: acc -> WalkState acc
initWalkState accEmpty = WalkState 1 Nothing [] [] accEmpty Map.empty

mergeLines :: Maybe (Int, Int) -> Maybe (Int, Int) -> Maybe (Int, Int)
mergeLines Nothing y = y
mergeLines x Nothing = x
mergeLines (Just (a1, b1)) (Just (a2, b2)) = Just (min a1 a2, max b1 b2)

-- | Smallest-index fresh id not already a key in @doneMap@. Guarantees the
-- 'Map.insert' in 'closeState' can never clobber a still-live entry,
-- regardless of how many regions close with the same (or no) line info —
-- the collision this replaces: two independently-closed leaf-free regions
-- (e.g. two empty 'PB.Compile.IR.ELetRef' bodies) used to both mint the
-- literal id @"region@0"@ and silently overwrite one another via
-- 'Map.insert'. Reusing a numeric slot after its original entry has been
-- deleted (an 'EFanIn'/'EBranch'/'ELoop' arm's own transient sub-region,
-- see 'walk') is harmless: nothing still references the deleted entry.
mkRegionId :: Map.Map RegionId acc -> RegionId
mkRegionId doneMap = fresh (0 :: Int)
  where
    fresh n = let rid = RegionId ("region@" <> T.pack (show n))
              in if Map.member rid doneMap then fresh (n + 1) else rid

closeState :: WalkState acc -> (Region, acc, Map.Map RegionId acc)
closeState (WalkState cplx lns ownKids cutKids acc doneMap) =
  let rid = mkRegionId doneMap
      region = Region
        { regionId         = rid
        , regionComplexity = cplx
        , regionLines      = lns
        , regionChildren   = cutKids <> ownKids
        }
  in (region, acc, Map.insert rid acc doneMap)

-- | Fold one contribution (an atomic leaf's own isolated 'RegionOps.opLeaf'
-- result, or a structural node's already-'RegionOps.opChoice'-combined
-- result) into the still-open portion, cutting it into a finished sibling
-- 'Region' when the running complexity exceeds the threshold ("cut at the
-- next statement boundary"). @extraKids@/@subDoneMap@ carry any child
-- regions (and their own accumulators) already closed while computing
-- @subAcc@ (an 'ELetRef'\/'EBranch'\/'ELoop'\/'EFanIn' sub-walk).
addContribution :: RegionOps acc -> Int -> Int -> Maybe (Int, Int) -> [Region] -> acc -> Map.Map RegionId acc -> WalkState acc -> WalkState acc
addContribution ops threshold deltaComplexity lns extraKids subAcc subDoneMap (WalkState cplx lns0 ownKids cutKids acc doneMap) =
  let cplx'    = cplx + deltaComplexity
      lines'   = mergeLines lns0 lns
      ownKids' = ownKids <> extraKids
      acc'     = opSeq ops acc subAcc
      doneMap0 = Map.union doneMap subDoneMap
  in if cplx' > threshold
       then let (closed, _closedAcc, doneMap1) = closeState (WalkState cplx' lines' ownKids' [] acc' doneMap0)
                -- Seed the next run with a reference to the sibling just cut
                -- out, so a caller reconstructing a statement sequence can
                -- mark where it was -- not just that it exists in the tree.
                freshAcc = opRef ops (regionId closed) (regionLines closed)
            in WalkState 1 Nothing [] (cutKids <> [closed]) freshAcc doneMap1
       else WalkState cplx' lines' ownKids' cutKids acc' doneMap0

-- | Per-@bid@ memo cache threaded through one 'computeRegionsWith' call:
-- once a shared 'ELetRef' binding has been walked, every later occurrence
-- reuses its already-closed triple instead of re-deriving it from
-- scratch. Region computation walks a DAG, not a tree — 'ELetRef' sharing
-- lets one binding be referenced from multiple call sites (see this
-- module's own header and 'RegionOps'\'s 'opRef' doc) — so without this
-- cache, 'walk' unshares the DAG into a tree: each reference re-walks its
-- entire subtree (including any further sharing inside it), exponential
-- in the depth of nested sharing. Scoped to a single 'computeRegionsWith'
-- call (a fresh 'Map.empty' per call), never shared across calls, since
-- different calls can pass different 'RegionOps' (a different @acc@ type
-- entirely, per 'PB.Explain.Signatures.computeSignatures' vs.
-- 'PB.Explain.Pseudocode.buildPseudocode').
type RegionMemo acc = Map.Map Text (Region, acc, Map.Map RegionId acc)

-- | Compute a whole 'Region' (plus its own final accumulator and every
-- region closed while computing it) for one self-contained 'Eff' subterm
-- — used both for the top-level 'computeRegionsWith' call and recursively
-- for each 'ELetRef' body, 'EBranch' arm, and 'ELoop' body (each of which
-- is its own straight-line run for cut-point purposes).
regionOf :: RegionOps acc -> Int -> Map.Map Text (Eff () ()) -> Eff x y -> State (RegionMemo acc) (Region, acc, Map.Map RegionId acc)
regionOf ops threshold table eff = do
  st <- walk ops threshold table (initWalkState (opEmpty ops)) eff
  pure (closeState st)

walk :: RegionOps acc -> Int -> Map.Map Text (Eff () ()) -> WalkState acc -> Eff x y -> State (RegionMemo acc) (WalkState acc)
walk ops threshold table st eff = case eff of
  J _ -> pure st
  ELetRef bid -> do
    memo <- get
    (childRegion, _childAcc, childMap) <- case Map.lookup bid memo of
      Just cached -> pure cached
      Nothing -> do
        let body = case Map.lookup bid table of
              Just b  -> b
              Nothing -> error ("PB.Explain.Regions.computeRegions: unbound ELetRef " <> show bid)
        result <- regionOf ops threshold table body
        modify' (Map.insert bid result)
        pure result
    let WalkState cplx lns0 ownKids cutKids acc doneMap = st
        acc' = opSeq ops acc (opRef ops (regionId childRegion) (regionLines childRegion))
    pure (WalkState cplx lns0 (ownKids <> [childRegion]) cutKids acc' (Map.union doneMap childMap))
  EComp g f -> do
    st' <- walk ops threshold table st f
    walk ops threshold table st' g
  EAssign var ln ty ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LAssign var ln ty)) Map.empty st)
  EAssignWithRhs var lhsE rhsE ln ty ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LAssignWithRhs var lhsE rhsE ln ty)) Map.empty st)
  ECall n as ln tags ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LCall n as ln tags)) Map.empty st)
  ESuspend n as ln tags ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LSuspend n as ln tags)) Map.empty st)
  EReturn e ln ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LReturn e ln)) Map.empty st)
  ESplitValue -> pure st
  EFanIn a b -> do
    (aRegion, aAcc, aMap) <- regionOf ops threshold table a
    (bRegion, bAcc, bMap) <- regionOf ops threshold table b
    let delta   = regionComplexity aRegion + regionComplexity bRegion - 1
        lns     = mergeLines (regionLines aRegion) (regionLines bRegion)
        kids    = regionChildren aRegion <> regionChildren bRegion
        subAcc  = opFanIn ops aAcc bAcc
        -- aRegion/bRegion themselves are discarded (only their own
        -- children survive into 'kids'), so their own map entries --
        -- inserted by 'closeState' -- must be dropped too, not unioned in.
        subDoneMap = Map.union (Map.delete (regionId aRegion) aMap) (Map.delete (regionId bRegion) bMap)
    pure (addContribution ops threshold delta lns kids subAcc subDoneMap st)
  EBranch cond t f ln -> do
    (tRegion, tAcc, tMap) <- regionOf ops threshold table t
    (fRegion, fAcc, fMap) <- regionOf ops threshold table f
    let delta   = regionComplexity tRegion + regionComplexity fRegion - 1
        lns     = mergeLines (Just (ln, ln)) (mergeLines (regionLines tRegion) (regionLines fRegion))
        kids    = regionChildren tRegion <> regionChildren fRegion
        subAcc  = opBranch ops cond ln tAcc fAcc
        -- see EFanIn's own note: tRegion/fRegion are discarded, keep only
        -- their children's already-closed map entries.
        subDoneMap = Map.union (Map.delete (regionId tRegion) tMap) (Map.delete (regionId fRegion) fMap)
    pure (addContribution ops threshold delta lns kids subAcc subDoneMap st)
  ELoop body ln -> do
    (bodyRegion, bodyAcc, bodyMap) <- regionOf ops threshold table body
    let delta   = regionComplexity bodyRegion
        lns     = mergeLines (Just (ln, ln)) (regionLines bodyRegion)
        kids    = regionChildren bodyRegion
        subAcc  = opLoop ops ln bodyAcc
        -- see EFanIn's own note: bodyRegion is discarded, keep only its
        -- children's already-closed map entries.
        subDoneMap = Map.delete (regionId bodyRegion) bodyMap
    pure (addContribution ops threshold delta lns kids subAcc subDoneMap st)

-- | 'PB.Compile.IR.EffTerm''s 'ELetRef' table only ever stores bodies
-- shaped @Eff () ()@ (see 'PB.Compile.IR.EffTerm'\'s own definition) — the
-- walk resolves each reference through it by that fixed shape, same as
-- 'PB.Compile.IR.inlineEffTable'\/'foldFreyd'.
computeRegionsWith :: Int -> RegionOps acc -> EffTerm a b -> (Region, Map.Map RegionId acc)
computeRegionsWith threshold ops (EffTerm spine table) =
  let (region, _acc, doneMap) = evalState (regionOf ops threshold table spine) Map.empty
  in (region, doneMap)

computeRegions :: Int -> EffTerm a b -> Region
computeRegions threshold term = fst (computeRegionsWith threshold trivialOps term)
  where
    trivialOps = RegionOps
      { opLeaf   = const ()
      , opFanIn  = \_ _ -> ()
      , opBranch = \_ _ _ _ -> ()
      , opLoop   = \_ _ -> ()
      , opRef    = \_ _ -> ()
      , opSeq    = \_ _ -> ()
      , opEmpty  = ()
      }
