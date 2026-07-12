module DeadCodeTest (tests) where

import PB.Prelude
import PB.Analysis.Cfg  (Cfg (..), CfgBlock (..), CfgEdge (..), cyclomaticComplexity)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "DeadCode"
  [ testGroup "cyclomaticComplexity"
    [ testCase "empty CFG" $
        cyclomaticComplexity emptyCfg @?= 1
    , testCase "linear chain" $
        cyclomaticComplexity linearCfg @?= 1
    , testCase "branch" $
        cyclomaticComplexity branchCfg @?= 2
    ]
  ]

-- Test fixtures

emptyCfg :: Cfg
emptyCfg = Cfg
  { cfgEntry = "b0"
  , cfgExits = []
  , cfgBlocks = [CfgBlock "b0" [] Nothing Nothing]
  , cfgEdges = []
  }

linearCfg :: Cfg
linearCfg = Cfg
  { cfgEntry = "b0"
  , cfgExits = []
  , cfgBlocks =
      [ CfgBlock "b0" [] (Just 1) (Just 1)
      , CfgBlock "b1" [] (Just 2) (Just 2)
      ]
  , cfgEdges = [CfgEdge "b0" "b1" ""]
  }

branchCfg :: Cfg
branchCfg = Cfg
  { cfgEntry = "b0"
  , cfgExits = []
  , cfgBlocks =
      [ CfgBlock "b0" [] (Just 1) (Just 1)
      , CfgBlock "b1" [] (Just 2) (Just 2)
      , CfgBlock "b2" [] (Just 3) (Just 3)
      , CfgBlock "b3" [] (Just 4) (Just 4)
      ]
  , cfgEdges =
      [ CfgEdge "b0" "b1" "T"
      , CfgEdge "b0" "b2" "F"
      , CfgEdge "b1" "b3" ""
      , CfgEdge "b2" "b3" ""
      ]
  }
