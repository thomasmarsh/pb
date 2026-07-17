module IdentTest (tests) where

import PB.Prelude
import PB.AST.Ident
import Data.Aeson (toJSON)

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "Ident"
  [ testGroup "Ident"
      [ testCase "identOrig preserves declared casing" $
          identOrig (mkIdent "N_Cst_Util") @?= "N_Cst_Util"
      , testCase "identCanon lowercases" $
          identCanon (mkIdent "N_Cst_Util") @?= "n_cst_util"
      , testCase "Eq compares case-insensitively" $
          mkIdent "n_cst_util" @?= mkIdent "N_CST_UTIL"
      , testCase "Eq distinguishes different identifiers" $
          (mkIdent "n_cst_util" == mkIdent "n_other") @?= False
      , testCase "Ord orders by canonical form" $
          compare (mkIdent "ABC") (mkIdent "abd") @?= LT
      , testCase "OverloadedStrings literal is an Ident" $
          ("n_cst_util" :: Ident) @?= mkIdent "N_CST_UTIL"
      , testCase "ToJSON renders original casing only" $
          toJSON (mkIdent "N_Cst_Util") @?= toJSON ("N_Cst_Util" :: Text)
      ]

  , testGroup "IdentSet"
      [ testCase "empty set has no members" $
          identSetMember "n_cst_util" identSetEmpty @?= False
      , testCase "singleton set matches case-insensitively" $
          identSetMember "N_CST_UTIL" (identSetSingleton "n_cst_util") @?= True
      , testCase "lookup recovers the originally-declared casing" $
          identSetLookup "N_CST_UTIL" (identSetSingleton "n_cst_util")
            @?= Just (mkIdent "n_cst_util")
      , testCase "lookup on a miss is Nothing" $
          identSetLookup "xyz_unknown" (identSetSingleton "n_cst_util") @?= Nothing
      , testCase "fromList dedupes by canonical form" $
          let s = identSetFromList ["n_cst_util", "N_CST_UTIL", "n_other"]
          in length (identSetToList s) @?= 2
      ]

  , testGroup "IdentMap"
      [ testCase "empty map has no entries" $
          identMapLookup "n_cst_util" identMapEmpty @?= (Nothing :: Maybe (Ident, Int))
      , testCase "lookup recovers the originally-declared key casing and its value" $
          let m = identMapFromList [("n_cst_util", (42 :: Int))]
          in identMapLookup "N_CST_UTIL" m @?= Just (mkIdent "n_cst_util", 42)
      , testCase "lookup on a miss is Nothing" $
          let m = identMapFromList [("n_cst_util", (42 :: Int))]
          in identMapLookup "xyz_unknown" m @?= Nothing
      , testCase "fromListWith combines values and keeps the first-seen casing on a canonical collision" $
          let m = identMapFromListWith (+) [("N_Cst_Util", (1 :: Int)), ("n_cst_util", 2)]
          in identMapLookup "n_cst_util" m @?= Just (mkIdent "N_Cst_Util", 3)
      , testCase "fromList (last-wins values) still keeps the first-seen casing" $
          let m = identMapFromList [("N_Cst_Util", (1 :: Int)), ("n_cst_util", 2)]
          in identMapLookup "n_cst_util" m @?= Just (mkIdent "N_Cst_Util", 2)
      , testCase "size counts distinct canonical keys" $
          let m = identMapFromList [("a", (1 :: Int)), ("A", 2), ("b", 3)]
          in identMapSize m @?= 2
      ]
  ]
