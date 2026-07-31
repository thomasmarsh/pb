-- | Region computation over 'PB.Compile.IR.Eff'/'EffTerm' (Plan 218 Layer
-- 1): decomposes a compiled procedure into complexity-bounded 'Region's,
-- each a candidate functional-core/imperative-shell boundary.
--
-- A direct recursive walk over 'Eff', not a 'PB.Compile.IR.foldFreyd'
-- instantiation — a fold target produces one @k a b@ morphism per target
-- category, which cannot express "return a tree whose shape depends on
-- where a cut was decided." Do not try to re-express this as a fold
-- target; the cut-point/shape decision has no morphism to fold into.
module PB.Explain.Regions
  ( RegionId
  , Region (..)
  , defaultComplexityThreshold
  , computeRegions
  ) where

import PB.Prelude hiding (id, (.))
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import PB.Compile.IR (Eff (..), EffTerm (..))

-- | Opaque handle — the constructor is not exported. Every other layer
-- treats this as an inert 'Eq'/'Ord' key for matching a @PRegionRef@ back
-- to its defining block; it must never be parsed or displayed for its own
-- content. Display uses 'regionLines'. The line-keyed minting scheme below
-- is a 'PB.Explain.Regions'-internal implementation detail, not a
-- contract — it may change shape later without rippling to other layers.
newtype RegionId = RegionId Text
  deriving (Eq, Ord, Show)

data Region = Region
  { regionId         :: RegionId
  , regionComplexity :: Int        -- ^ McCabe of THIS region only; a cut
                                    -- child contributes 0 extra decision
                                    -- points to its parent.
  , regionLines      :: (Int, Int) -- ^ min/max source line directly owned
                                    -- by this region (excludes any cut
                                    -- child's own span).
  , regionChildren   :: [Region]
  }

-- | Common McCabe convention; override freely via 'computeRegions'\'s
-- explicit threshold argument.
defaultComplexityThreshold :: Int
defaultComplexityThreshold = 10

-- | The still-open, not-yet-cut portion of the region currently being
-- built, plus every sibling region already cut from earlier in the same
-- straight-line run. Fields (positional, no accessors): running
-- complexity, running line span, children of the still-open portion,
-- already-cut sibling regions.
data WalkState = WalkState Int (Maybe (Int, Int)) [Region] [Region]

initWalkState :: WalkState
initWalkState = WalkState 1 Nothing [] []

mergeLines :: Maybe (Int, Int) -> Maybe (Int, Int) -> Maybe (Int, Int)
mergeLines Nothing y = y
mergeLines x Nothing = x
mergeLines (Just (a1, b1)) (Just (a2, b2)) = Just (min a1 a2, max b1 b2)

mkRegionId :: Maybe (Int, Int) -> RegionId
mkRegionId lns = RegionId ("region@" <> maybe "0" (\(startLine, _) -> T.pack (show startLine)) lns)

closeState :: WalkState -> Region
closeState (WalkState cplx lns ownKids cutKids) = Region
  { regionId         = mkRegionId lns
  , regionComplexity = cplx
  , regionLines      = fromMaybe (0, 0) lns
  , regionChildren   = cutKids <> ownKids
  }

-- | Fold one atomic action's contribution into the still-open portion,
-- cutting it into a finished sibling 'Region' when the running complexity
-- exceeds the threshold ("cut at the next statement boundary").
addContribution :: Int -> Int -> Maybe (Int, Int) -> [Region] -> WalkState -> WalkState
addContribution threshold deltaComplexity lns extraKids (WalkState cplx lns0 ownKids cutKids) =
  let cplx'    = cplx + deltaComplexity
      lines'   = mergeLines lns0 lns
      ownKids' = ownKids <> extraKids
  in if cplx' > threshold
       then WalkState 1 Nothing [] (cutKids <> [closeState (WalkState cplx' lines' ownKids' [])])
       else WalkState cplx' lines' ownKids' cutKids

-- | Compute a whole 'Region' for one self-contained 'Eff' subterm — used
-- both for the top-level 'computeRegions' call and recursively for each
-- 'ELetRef' body, 'EBranch' arm, and 'ELoop' body (each of which is its own
-- straight-line run for cut-point purposes).
regionOf :: Int -> Map.Map Text (Eff () ()) -> Eff x y -> Region
regionOf threshold table eff = closeState (walk threshold table initWalkState eff)

walk :: Int -> Map.Map Text (Eff () ()) -> WalkState -> Eff x y -> WalkState
walk threshold table st eff = case eff of
  J _ -> st
  ELetRef bid ->
    let body = case Map.lookup bid table of
          Just b  -> b
          Nothing -> error ("PB.Explain.Regions.computeRegions: unbound ELetRef " <> show bid)
        childRegion = regionOf threshold table body
        WalkState cplx lns0 ownKids cutKids = st
    in WalkState cplx lns0 (ownKids <> [childRegion]) cutKids
  EComp g f -> walk threshold table (walk threshold table st f) g
  EAssign _ ln _              -> addContribution threshold 0 (Just (ln, ln)) [] st
  EAssignWithRhs _ _ _ ln _   -> addContribution threshold 0 (Just (ln, ln)) [] st
  ECall _ _ ln                -> addContribution threshold 0 (Just (ln, ln)) [] st
  ESuspend _ _ ln             -> addContribution threshold 0 (Just (ln, ln)) [] st
  EReturn _ ln                -> addContribution threshold 0 (Just (ln, ln)) [] st
  ESplitValue -> st
  EFanIn a b ->
    let aRegion = regionOf threshold table a
        bRegion = regionOf threshold table b
        delta   = regionComplexity aRegion + regionComplexity bRegion - 1
        lns     = mergeLines (Just (regionLines aRegion)) (Just (regionLines bRegion))
        kids    = regionChildren aRegion <> regionChildren bRegion
    in addContribution threshold delta lns kids st
  EBranch _cond t f ln ->
    let tRegion = regionOf threshold table t
        fRegion = regionOf threshold table f
        delta   = regionComplexity tRegion + regionComplexity fRegion - 1
        lns     = mergeLines (Just (ln, ln)) (mergeLines (Just (regionLines tRegion)) (Just (regionLines fRegion)))
        kids    = regionChildren tRegion <> regionChildren fRegion
    in addContribution threshold delta lns kids st
  ELoop body ln ->
    let bodyRegion = regionOf threshold table body
        delta       = regionComplexity bodyRegion
        lns         = mergeLines (Just (ln, ln)) (Just (regionLines bodyRegion))
        kids        = regionChildren bodyRegion
    in addContribution threshold delta lns kids st

-- | 'PB.Compile.IR.EffTerm''s 'ELetRef' table only ever stores bodies
-- shaped @Eff () ()@ (see 'PB.Compile.IR.EffTerm'\'s own definition) — the
-- walk resolves each reference through it by that fixed shape, same as
-- 'PB.Compile.IR.inlineEffTable'\/'foldFreyd'.
computeRegions :: Int -> EffTerm a b -> Region
computeRegions threshold (EffTerm spine table) = regionOf threshold table spine
