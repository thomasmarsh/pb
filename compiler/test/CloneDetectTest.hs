module CloneDetectTest (tests) where

import PB.Prelude
import PB.Compile.InstrTypes  (ShapeNode (..))
import PB.Analysis.CloneDetect (CloneFamily (..), cloneFamilies)

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

shapeA :: [ShapeNode]
shapeA = [SAsgn 1, SRet]

shapeB :: [ShapeNode]
shapeB = [SSusp "dw.retrieve" 1, SRet]

tests :: TestTree
tests = testGroup "CloneDetect"
  [ testGroup "cloneFamilies"
    [ testCase "two procedures with identical canonical shape group into one family" $
        cloneFamilies
          [ ("w_a", "of_one", shapeA)
          , ("w_b", "of_two", shapeA)
          ]
        @?= [ CloneFamily shapeA [("w_a", "of_one"), ("w_b", "of_two")] ]

    , testCase "two procedures differing only in a suspend effect name are distinct families" $
        cloneFamilies
          [ ("w_a", "of_one", shapeB)
          , ("w_b", "of_two", [SSusp "dw.update" 1, SRet])
          ]
        @?= [ CloneFamily shapeB [("w_a", "of_one")]
            , CloneFamily [SSusp "dw.update" 1, SRet] [("w_b", "of_two")]
            ]

    , testCase "a procedure with a unique shape is its own singleton family" $
        cloneFamilies [ ("w_a", "of_one", shapeA) ]
        @?= [ CloneFamily shapeA [("w_a", "of_one")] ]

    , testCase "three procedures, two matching and one not, split 2-family + 1-family" $
        cloneFamilies
          [ ("w_a", "of_one",   shapeA)
          , ("w_b", "of_two",   shapeB)
          , ("w_c", "of_three", shapeA)
          ]
        @?= [ CloneFamily shapeA [("w_a", "of_one"), ("w_c", "of_three")]
            , CloneFamily shapeB [("w_b", "of_two")]
            ]
    ]
  ]
