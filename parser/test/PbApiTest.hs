module PbApiTest (tests) where

import PB.Prelude
import PB.Pipeline.PbApi (builtinFnNames, builtinMethodNames)

import qualified Data.Set as Set

import Test.Tasty              (TestTree, testGroup)
import Test.Tasty.HUnit        (testCase, (@?=), assertBool)

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Pipeline"
  [ testGroup "PbApi"
    [ testCase "builtinFnNames is non-empty" $
        assertBool "expected non-empty" (not (Set.null builtinFnNames))
    , testCase "builtinMethodNames is non-empty" $
        assertBool "expected non-empty" (not (Set.null builtinMethodNames))
    , testCase "fn and method sets are disjoint" $
        Set.null (Set.intersection builtinFnNames builtinMethodNames) @?= True
    , testCase "builtinFnNames contains len" $
        assertBool "len" (Set.member "len" builtinFnNames)
    , testCase "builtinFnNames contains trim" $
        assertBool "trim" (Set.member "trim" builtinFnNames)
    , testCase "builtinFnNames contains mid" $
        assertBool "mid" (Set.member "mid" builtinFnNames)
    , testCase "builtinFnNames contains left" $
        assertBool "left" (Set.member "left" builtinFnNames)
    , testCase "builtinFnNames contains right" $
        assertBool "right" (Set.member "right" builtinFnNames)
    , testCase "builtinFnNames contains string" $
        assertBool "string" (Set.member "string" builtinFnNames)
    , testCase "builtinMethodNames contains retrieve" $
        assertBool "retrieve" (Set.member "retrieve" builtinMethodNames)
    , testCase "builtinMethodNames contains update" $
        assertBool "update" (Set.member "update" builtinMethodNames)
    , testCase "builtinMethodNames contains insertrow" $
        assertBool "insertrow" (Set.member "insertrow" builtinMethodNames)
    , testCase "builtinMethodNames contains deleterow" $
        assertBool "deleterow" (Set.member "deleterow" builtinMethodNames)
    , testCase "builtinMethodNames contains reset" $
        assertBool "reset" (Set.member "reset" builtinMethodNames)
    ]
  ]
