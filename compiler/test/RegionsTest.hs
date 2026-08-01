module RegionsTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (Expr (..))
import PB.Compile.IR
import PB.Explain.Regions (Region (..), RegionOps (..), computeRegions, computeRegionsWith, defaultComplexityThreshold)

import Control.Exception  (evaluate)
import System.Timeout     (timeout)
import qualified Data.Map.Strict as Map
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
    leaf = EAssignWithRhs "x" (ExInt "0") (ExInt "1") 1 Nothing :: Eff () ()
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
      let term = EAssignWithRhs "y" (ExInt "0") (ExInt "2") 2 Nothing
               . EAssignWithRhs "x" (ExInt "0") (ExInt "1") 1 Nothing :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 1

  , testCase "single EBranch -> complexity 2" $
      let term = branchEff (ExBool True)
                   (EAssignWithRhs "a" (ExInt "0") (ExInt "1") 2 Nothing)
                   (EAssignWithRhs "b" (ExInt "0") (ExInt "2") 3 Nothing) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable term)
      in regionComplexity region @?= 2

  , testCase "EBranch nested inside EBranch -> complexity 3" $
      let inner = branchEff (ExBool True)
                    (EAssignWithRhs "a" (ExInt "0") (ExInt "1") 3 Nothing)
                    (EAssignWithRhs "b" (ExInt "0") (ExInt "2") 4 Nothing) 2 :: Eff () ()
          outer = branchEff (ExBool True) inner
                    (EAssignWithRhs "c" (ExInt "0") (ExInt "3") 5 Nothing) 1 :: Eff () ()
          region = computeRegions defaultComplexityThreshold (extractEffTable outer)
      in regionComplexity region @?= 3

  , testCase "ELoop counted once statically, not per iteration" $
      let loopBody = J PInr . EAssignWithRhs "i" (ExInt "0") (ExInt "1") 2 Nothing :: Eff () (Either () ())
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
      let body = EAssignWithRhs "x" (ExInt "0") (ExInt "1") 5 Nothing :: Eff () ()
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

  , testCase "a chain of nested doubly-referenced ELetRef bindings computes without exponential blowup" $ do
      let (table, spine) = sharedChainTable 24
          effTerm = EffTerm spine table
      result <- timeout 5000000 (evaluate (Map.size (snd (computeRegionsWith defaultComplexityThreshold trivialOps effTerm))))
      case result of
        Just sz -> assertBool ("expected a small region count, got " ++ show sz) (sz < 100)
        Nothing -> assertFailure "timed out after 5s: PB.Explain.Regions.walk's ELetRef case is re-deriving each shared binding's region on every occurrence instead of computing it once (exponential in the sharing chain's depth)"
  ]
