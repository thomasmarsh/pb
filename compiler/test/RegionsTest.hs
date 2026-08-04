module RegionsTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (Expr (..))
import PB.Analysis.CallClassify (EffectTag (..))
import PB.Compile.IR
import PB.Explain.Regions (Region (..), RegionOps (..), computeRegions, computeRegionsWith, defaultComplexityThreshold)

import Control.Exception  (evaluate)
import System.Timeout     (timeout)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertBool, assertFailure, testCase, (@?=))

-- | A chain of @n@ table bindings, each (from level 1 up) referencing the
-- previous level TWICE via a straight-line 'EComp' of two 'ELetRef's --
-- the minimal shape that exercises 'PB.Explain.Regions' DAG sharing
-- (documented in @doc/plan/222-explain-ui-wiring.md@'s Design section: one
-- region referenced from multiple call sites). A walk that re-derives each
-- referenced body from scratch on every occurrence (instead of computing it
-- once) does @2^n@ leaf visits by the time it reaches @"blk" <> show n@.
sharedChainTable :: Int -> (Map.Map Text (Eff () ()), Eff () ())
sharedChainTable n = (Map.fromList (("blk0", leaf) : [ (nm i, body i) | i <- [1 .. n] ]), ELetRef (nm n))
  where
    nm i = "blk" <> T.pack (show i)
    leaf = EAssignWithRhs "x" (ExInt "0") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
    body i = EComp (ELetRef (nm (i - 1))) (ELetRef (nm (i - 1))) :: Eff () ()

trivialOps :: RegionOps ()
trivialOps = RegionOps
  { opLeaf   = const ()
  , opFanIn  = \_ _ -> ()
  , opBranch = \_ _ _ _ -> ()
  , opLoop   = \_ _ -> ()
  , opRef    = \_ _ -> ()
  , opSeq    = \_ _ -> ()
  , opEmpty  = ()
  }

-- | Five sequential trivial branches (arms are pure no-ops, so each
-- contributes exactly +1 decision point), on lines 1..5 — used to exercise
-- the length-based cut policy with a small custom threshold.
fiveBranches :: Eff () ()
fiveBranches = branchEff (ExBool True) (J PId) (J PId) 5
             . branchEff (ExBool True) (J PId) (J PId) 4
             . branchEff (ExBool True) (J PId) (J PId) 3
             . branchEff (ExBool True) (J PId) (J PId) 2
             . branchEff (ExBool True) (J PId) (J PId) 1

tests :: TestTree
tests = testGroup "PB.Explain.Regions"
  [ testCase "straight-line assigns, no branches -> complexity 1" $
      let term = EAssignWithRhs "y" (ExInt "0") (ExInt "2") 2 Nothing Set.empty
               . EAssignWithRhs "x" (ExInt "0") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 1

  , testCase "single EBranch -> complexity 2" $
      let term = branchEff (ExBool True)
                   (EAssignWithRhs "a" (ExInt "0") (ExInt "1") 2 Nothing Set.empty)
                   (EAssignWithRhs "b" (ExInt "0") (ExInt "2") 3 Nothing Set.empty) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 2

  , testCase "EBranch nested inside EBranch -> complexity 3" $
      let inner = branchEff (ExBool True)
                    (EAssignWithRhs "a" (ExInt "0") (ExInt "1") 3 Nothing Set.empty)
                    (EAssignWithRhs "b" (ExInt "0") (ExInt "2") 4 Nothing Set.empty) 2 :: Eff () ()
          outer = branchEff (ExBool True) inner
                    (EAssignWithRhs "c" (ExInt "0") (ExInt "3") 5 Nothing Set.empty) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable outer)
      in regionComplexity region @?= 3

  , testCase "ELoop counted once statically, not per iteration" $
      let loopBody = J PInr . EAssignWithRhs "i" (ExInt "0") (ExInt "1") 2 Nothing Set.empty :: Eff () (Either () ())
          term = ELoop loopBody 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 2

  , testCase "region under threshold stays uncut (no children)" $
      let term = branchEff (ExBool True) (J PId) (J PId) 3
               . branchEff (ExBool True) (J PId) (J PId) 2
               . branchEff (ExBool True) (J PId) (J PId) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in length (regionChildren region) @?= 0

  , testCase "ELetRef-backed block is always its own Region regardless of size" $
      let body = EAssignWithRhs "x" (ExInt "0") (ExInt "1") 5 Nothing Set.empty :: Eff () ()
          term = ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", body)])
          region = computeRegions defaultComplexityThreshold effTerm
      in case regionChildren region of
           [child] -> regionComplexity child @?= 1
           other   -> assertFailure ("expected exactly 1 child region, got " ++ show (length other))

  , testCase "long straight-line run above threshold gets a synthetic cut" $
      let region = computeRegions 2 (extractEffTable fiveBranches)
      in length (regionChildren region) @?= 2

  , testCase "a cut child's complexity is not double-counted into its parent" $
      let region = computeRegions 2 (extractEffTable fiveBranches)
      in regionComplexity region @?= 2

  , testCase "same EffTerm compiled twice yields identical RegionIds (determinism)" $
      let effTerm = extractEffTable fiveBranches
          r1 = computeRegions 2 effTerm
          r2 = computeRegions 2 effTerm
      in map regionId (regionChildren r1) @?= map regionId (regionChildren r2)

  , testCase "EBranch arms sharing a merge-point ELetRef (if-without-else shape) -> the shared child region is listed once, not once per arm" $
      -- Mirrors PB.Compile.FromSSA.compileTermToEff's SsaBranch case for an
      -- if-without-else: both arms fall through to the same 2-predecessor
      -- merge block, promoted to a single, literally-shared 'ELetRef' value
      -- (memo-threaded from the true-arm compile into the false-arm
      -- compile) -- not two structurally-identical copies.
      let mergeBody = EAssignWithRhs "y" (ExInt "0") (ExInt "9") 5 Nothing Set.empty :: Eff () ()
          trueArm   = EComp (ELetRef "merge") (EAssignWithRhs "x" (ExInt "0") (ExInt "1") 2 Nothing Set.empty) :: Eff () ()
          falseArm  = ELetRef "merge" :: Eff () ()
          term      = branchEff (ExBool True) trueArm falseArm 1 :: Eff () ()
          effTerm   = EffTerm term (Map.fromList [("merge", mergeBody)])
          region    = computeRegions defaultComplexityThreshold effTerm
      in length (regionChildren region) @?= 1

  , testCase "a chain of nested doubly-referenced ELetRef bindings computes without exponential blowup" $ do
      let (table, spine) = sharedChainTable 24
          effTerm = EffTerm spine table
      result <- timeout 5000000 (evaluate (Map.size (snd (computeRegionsWith defaultComplexityThreshold trivialOps effTerm))))
      case result of
        Just sz -> assertBool ("expected a small region count, got " ++ show sz) (sz < 100)
        Nothing -> assertFailure "timed out after 5s: PB.Explain.Regions.walk's ELetRef case is re-deriving each shared binding's region on every occurrence instead of computing it once (exponential in the sharing chain's depth)"

  , testGroup "effect-boundary-aware cutting (Plan 227 Phase 2)"
    -- Complexity threshold set far above anything these terms can reach
    -- (1000), isolating the effect-gap trigger from the pre-existing
    -- complexity trigger.
    [ testCase "adjacent effectful leaves (no intervening pure statements) never cut between them, however many" $
        let leaf n = ECall ("c" <> T.pack (show n)) [] n (Set.singleton WritesDb)
            term = leaf 5 . leaf 4 . leaf 3 . leaf 2 . leaf 1 :: Eff () ()
            region = computeRegions 1000 (extractEffTable term)
        in length (regionChildren region) @?= 0

    , testCase "an effectful leaf followed by more pure leaves than the gap bound forces a cut" $
        let effLeaf = ECall "c1" [] 1 (Set.singleton WritesDb) :: Eff () ()
            pureLeaf n = EAssignWithRhs ("x" <> T.pack (show n)) (ExInt "0") (ExInt "1") n Nothing Set.empty
            -- 6 pure leaves after the one effectful leaf -- more than
            -- defaultEffectGapBound (4).
            term = pureLeaf 7 . pureLeaf 6 . pureLeaf 5 . pureLeaf 4 . pureLeaf 3 . pureLeaf 2 . effLeaf :: Eff () ()
            region = computeRegions 1000 (extractEffTable term)
        in length (regionChildren region) @?= 1

    , testCase "a pure-only run never force-cuts on the effect-gap policy, only the complexity threshold can" $
        let pureLeaf n = EAssignWithRhs ("x" <> T.pack (show n)) (ExInt "0") (ExInt "1") n Nothing Set.empty
            term = foldr (.) (J PId) [pureLeaf i | i <- [1 .. 20]] :: Eff () ()
            region = computeRegions 1000 (extractEffTable term)
        in length (regionChildren region) @?= 0

    , testCase "an effect immediately followed by a branch whose own combined effects are non-empty stays merged with it (w_gridfind.if_find's SetRedraw(false)+choose-case shape)" $
        let leadEff = ECall "SetRedraw" [] 1 (Set.singleton WritesUi) :: Eff () ()
            armEff  = ECall "Find" [] 3 (Set.singleton ReadsDb) :: Eff () ()
            armPure = EAssignWithRhs "x" (ExInt "0") (ExInt "1") 2 Nothing Set.empty :: Eff () ()
            armBranch = branchEff (ExBool True) armEff armPure 2 :: Eff () ()
            term    = armBranch . leadEff :: Eff () ()
            region  = computeRegions 1000 (extractEffTable term)
        in length (regionChildren region) @?= 0
    ]
  ]
