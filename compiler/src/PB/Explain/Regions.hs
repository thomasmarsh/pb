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
  , regionLabel
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

-- | A real line range prints as @region\@\<line\>@; a genuinely leaf-free
-- region (no line info at all) falls back to 'regionIdLabel' so two such
-- regions in the same output are still visually distinguishable, not both
-- printed as an identical, ambiguous label. Shared by every renderer over
-- 'PB.Explain.Pseudocode.Pseudocode' so the @region\@N@ convention can't
-- drift between them.
regionLabel :: RegionId -> Maybe (Int, Int) -> Text
regionLabel _   (Just (startLine, _)) = "region@" <> T.pack (show startLine)
regionLabel rid Nothing               = regionIdLabel rid

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
  , regionDirectEffects :: Set.Set EffectTag
      -- ^ Union of every direct (unresolved, no 'ResolvedCallSiteMap'
      -- lookup) 'EffectTag' carried by a leaf that stayed inline in this
      -- region — excludes any cut child's own tags (those live under the
      -- child's own 'regionDirectEffects'). Feeds 'addContribution'\'s
      -- effect-gap cut trigger only; a fuller, transitively-resolved
      -- effect set for *display* is 'PB.Explain.Signatures.InferredSignature'
      -- 'sigEffects', computed separately since resolving a call's
      -- transitive effects needs 'PB.Explain.Signatures.ResolvedCallSiteMap'
      -- \/ 'procEffects', which this module deliberately never resolves
      -- itself (this module's own header note).
  }

-- | Common McCabe convention; override freely via 'computeRegions'\'s
-- explicit threshold argument.
defaultComplexityThreshold :: Int
defaultComplexityThreshold = 10

-- | How many effect-free leaves may follow the most recent direct effect
-- before the still-open region cuts, once at least one effect has already
-- occurred in it (Plan 227 Phase 2). Two effectful leaves separated by
-- fewer than this many pure statements — including separated by a
-- structural boundary whose own combined contribution carries an effect,
-- e.g. an @if@ where one arm calls something effectful — stay in the same
-- region (a real corpus example: @idw.SetRedraw(false)@ immediately
-- followed by a multi-arm @choose case@ where only one arm calls
-- @idw.Find@ stay merged, since the branch's own combined 'regionDirectEffects'
-- is non-empty). A leaf carrying no direct effect never cuts on its own —
-- only 'defaultComplexityThreshold' still bounds a pathologically long pure
-- run (Open Question 3 in doc/plan/227-explain-effect-boundary-regions.md).
-- Picked empirically against @w_gridfind.if_find@ and re-tunable without
-- any caller-visible shape change (an 'Int', not a type).
defaultEffectGapBound :: Int
defaultEffectGapBound = 4

-- | Non-GADT projection of one atomic 'Eff' contribution — what a
-- 'computeRegionsWith' caller's accumulator sees. Exists because 'Eff'\'s
-- own GADT type indices vary per constructor, so a walk caller only ever
-- needs each leaf's own fields, never its typed continuation.
-- 'LBranchCond' is not a distinct 'Eff' constructor — it is 'EBranch'\'s
-- own condition, surfaced as a leaf-shaped fact so a caller's accumulator
-- sees it the same way it sees every other read-bearing site.
data EffLeaf
  = LAssign        Text Int (Maybe PbType)
  | LAssignWithRhs Text Expr Expr Int (Maybe PbType) (Set.Set EffectTag)
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
-- already-cut sibling regions, running accumulator, closed-region map,
-- running direct-effect union for the still-open portion, count of
-- contributions since the most recent one that carried a direct effect
-- (see 'defaultEffectGapBound').
data WalkState acc = WalkState Int (Maybe (Int, Int)) [Region] [Region] acc (Map.Map RegionId acc) (Set.Set EffectTag) Int

initWalkState :: acc -> WalkState acc
initWalkState accEmpty = WalkState 1 Nothing [] [] accEmpty Map.empty Set.empty 0

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
closeState (WalkState cplx lns ownKids cutKids acc doneMap directEff _sinceEff) =
  let rid = mkRegionId doneMap
      region = Region
        { regionId            = rid
        , regionComplexity    = cplx
        , regionLines         = lns
        , regionChildren      = cutKids <> ownKids
        , regionDirectEffects = directEff
        }
  in (region, acc, Map.insert rid acc doneMap)

-- | Fold one contribution (an atomic leaf's own isolated 'RegionOps.opLeaf'
-- result, or a structural node's already-'RegionOps.opChoice'-combined
-- result) into the still-open portion, cutting it into a finished sibling
-- 'Region' when the running complexity exceeds the threshold ("cut at the
-- next statement boundary") OR, independently, when the still-open portion
-- has already seen a direct effect and 'defaultEffectGapBound' effect-free
-- contributions have gone by since the most recent one (Plan 227 Phase 2) —
-- either trigger cuts, whichever fires first; a contribution carrying no
-- direct effect at all never cuts on its own, only the complexity threshold
-- can. @extraKids@/@subDoneMap@ carry any child regions (and their own
-- accumulators) already closed while computing @subAcc@ (an
-- 'ELetRef'\/'EBranch'\/'ELoop'\/'EFanIn' sub-walk); @deltaEffects@ is this
-- contribution's own direct effect set (a leaf's own tags, or a structural
-- node's already-combined 'regionDirectEffects' union across its arms).
addContribution :: RegionOps acc -> Int -> Int -> Maybe (Int, Int) -> [Region] -> acc -> Map.Map RegionId acc -> Set.Set EffectTag -> WalkState acc -> WalkState acc
addContribution ops threshold deltaComplexity lns extraKids subAcc subDoneMap deltaEffects (WalkState cplx lns0 ownKids cutKids acc doneMap directEff sinceEff) =
  let cplx'      = cplx + deltaComplexity
      lines'     = mergeLines lns0 lns
      ownKids'   = ownKids <> extraKids
      acc'       = opSeq ops acc subAcc
      doneMap0   = Map.union doneMap subDoneMap
      directEff' = directEff <> deltaEffects
      sinceEff'  = if Set.null deltaEffects then sinceEff + 1 else 0
      cutOnEffectGap = not (Set.null directEff') && sinceEff' > defaultEffectGapBound
  in if cplx' > threshold || cutOnEffectGap
       then let (closed, _closedAcc, doneMap1) = closeState (WalkState cplx' lines' ownKids' [] acc' doneMap0 directEff' sinceEff')
                -- Seed the next run with a reference to the sibling just cut
                -- out, so a caller reconstructing a statement sequence can
                -- mark where it was -- not just that it exists in the tree.
                freshAcc = opRef ops (regionId closed) (regionLines closed)
            in WalkState 1 Nothing [] (cutKids <> [closed]) freshAcc doneMap1 Set.empty 0
       else WalkState cplx' lines' ownKids' cutKids acc' doneMap0 directEff' sinceEff'

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
    let WalkState cplx lns0 ownKids cutKids acc doneMap directEff sinceEff = st
        acc' = opSeq ops acc (opRef ops (regionId childRegion) (regionLines childRegion))
    pure (WalkState cplx lns0 (ownKids <> [childRegion]) cutKids acc' (Map.union doneMap childMap) directEff sinceEff)
  EComp g f -> do
    st' <- walk ops threshold table st f
    walk ops threshold table st' g
  EAssign var ln ty ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LAssign var ln ty)) Map.empty Set.empty st)
  EAssignWithRhs var lhsE rhsE ln ty tags ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LAssignWithRhs var lhsE rhsE ln ty tags)) Map.empty tags st)
  ECall n as ln tags ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LCall n as ln tags)) Map.empty tags st)
  ESuspend n as ln tags ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LSuspend n as ln tags)) Map.empty tags st)
  EReturn e ln ->
    pure (addContribution ops threshold 0 (Just (ln, ln)) [] (opLeaf ops (LReturn e ln)) Map.empty Set.empty st)
  ESplitValue -> pure st
  EFanIn a b -> do
    (aRegion, aAcc, aMap) <- regionOf ops threshold table a
    (bRegion, bAcc, bMap) <- regionOf ops threshold table b
    let delta   = regionComplexity aRegion + regionComplexity bRegion - 1
        lns     = mergeLines (regionLines aRegion) (regionLines bRegion)
        kids    = regionChildren aRegion <> regionChildren bRegion
        subAcc  = opFanIn ops aAcc bAcc
        deltaEff = regionDirectEffects aRegion <> regionDirectEffects bRegion
        -- aRegion/bRegion themselves are discarded (only their own
        -- children survive into 'kids'), so their own map entries --
        -- inserted by 'closeState' -- must be dropped too, not unioned in.
        subDoneMap = Map.union (Map.delete (regionId aRegion) aMap) (Map.delete (regionId bRegion) bMap)
    pure (addContribution ops threshold delta lns kids subAcc subDoneMap deltaEff st)
  EBranch cond t f ln -> do
    -- An if-without-else's two arms often fall through to the SAME
    -- 2-predecessor merge block, promoted by 'PB.Compile.FromSSA' to a
    -- single, literally-shared 'ELetRef' value (its memo is threaded from
    -- the true-arm compile into the false-arm compile) -- not two
    -- structurally-identical copies. Walking @t@/@f@ independently via the
    -- ordinary 'regionOf' would fold that ONE shared reference into BOTH
    -- arms' own accumulators (a real, corpus-confirmed bug: see
    -- doc/plan/226-explain-live-ui-regressions.md Layer 3), so the trailing
    -- reference is peeled off both arms first via 'regionOfExceptTail' and,
    -- when it's the SAME id on both sides, hoisted to run once after the
    -- combined 'opBranch' contribution instead.
    tPending <- regionOfExceptTail ops threshold table t
    fPending <- regionOfExceptTail ops threshold table f
    case (tPending, fPending) of
      ((tSt, Just bid1), (fSt, Just bid2)) | bid1 == bid2 ->
        let (tRegion, tAcc, tMap) = closeState tSt
            (fRegion, fAcc, fMap) = closeState fSt
            (delta, lns, kids, subAcc, subDoneMap, deltaEff) = combineBranchContribution ops cond ln tRegion tAcc tMap fRegion fAcc fMap
            st1 = addContribution ops threshold delta lns kids subAcc subDoneMap deltaEff st
        in walk ops threshold table st1 (ELetRef bid1)
      _ -> do
        (tRegion, tAcc, tMap) <- foldPendingRef ops threshold table tPending
        (fRegion, fAcc, fMap) <- foldPendingRef ops threshold table fPending
        let (delta, lns, kids, subAcc, subDoneMap, deltaEff) = combineBranchContribution ops cond ln tRegion tAcc tMap fRegion fAcc fMap
        pure (addContribution ops threshold delta lns kids subAcc subDoneMap deltaEff st)
  ELoop body ln -> do
    (bodyRegion, bodyAcc, bodyMap) <- regionOf ops threshold table body
    let delta   = regionComplexity bodyRegion
        lns     = mergeLines (Just (ln, ln)) (regionLines bodyRegion)
        kids    = regionChildren bodyRegion
        subAcc  = opLoop ops ln bodyAcc
        deltaEff = regionDirectEffects bodyRegion
        -- see EFanIn's own note: bodyRegion is discarded, keep only its
        -- children's already-closed map entries.
        subDoneMap = Map.delete (regionId bodyRegion) bodyMap
    pure (addContribution ops threshold delta lns kids subAcc subDoneMap deltaEff st)

-- | The shared "combine two closed arms into one 'RegionOps.opBranch'
-- contribution" computation behind 'EBranch'\'s two call sites above
-- (identical whether the shared-tail hoist fired or not).
combineBranchContribution
  :: RegionOps acc -> Expr -> Int
  -> Region -> acc -> Map.Map RegionId acc
  -> Region -> acc -> Map.Map RegionId acc
  -> (Int, Maybe (Int, Int), [Region], acc, Map.Map RegionId acc, Set.Set EffectTag)
combineBranchContribution ops cond ln tRegion tAcc tMap fRegion fAcc fMap =
  ( regionComplexity tRegion + regionComplexity fRegion - 1
  , mergeLines (Just (ln, ln)) (mergeLines (regionLines tRegion) (regionLines fRegion))
  , regionChildren tRegion <> regionChildren fRegion
  , opBranch ops cond ln tAcc fAcc
  -- see EFanIn's own note: tRegion/fRegion are discarded, keep only their
  -- children's already-closed map entries.
  , Map.union (Map.delete (regionId tRegion) tMap) (Map.delete (regionId fRegion) fMap)
  , regionDirectEffects tRegion <> regionDirectEffects fRegion
  )

-- | Mirrors 'regionOf', except: if @eff@\'s right-spine ends in a bare
-- 'ELetRef' (the shape a branch arm gets when it falls straight through to
-- an already-named merge point — see 'PB.Compile.FromSSA.compileTermToEff'\'s
-- 'SsaBranch' case), that trailing reference is left un-walked and its
-- binding id returned separately instead of being folded into the
-- accumulator immediately. Used only by 'EBranch', to detect when both arms
-- end in the identical reference and hoist it to the enclosing straight-
-- line run exactly once — see 'foldPendingRef' for completing either
-- choice once that decision is made.
regionOfExceptTail
  :: RegionOps acc -> Int -> Map.Map Text (Eff () ())
  -> Eff x y -> State (RegionMemo acc) (WalkState acc, Maybe Text)
regionOfExceptTail ops threshold table = go (initWalkState (opEmpty ops))
  where
    go st (ELetRef bid)           = pure (st, Just bid)
    go st (EComp (ELetRef bid) f) = do
      st' <- walk ops threshold table st f
      pure (st', Just bid)
    go st other = do
      st' <- walk ops threshold table st other
      pure (st', Nothing)

-- | Complete a 'regionOfExceptTail' result: fold its pending reference (if
-- any) back in via the ordinary 'ELetRef' walk case, then close —
-- reproducing exactly what 'regionOf' alone would have produced.
foldPendingRef
  :: RegionOps acc -> Int -> Map.Map Text (Eff () ())
  -> (WalkState acc, Maybe Text) -> State (RegionMemo acc) (Region, acc, Map.Map RegionId acc)
foldPendingRef ops threshold table (st, mbid) = do
  st' <- maybe (pure st) (\bid -> walk ops threshold table st (ELetRef bid)) mbid
  pure (closeState st')

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
