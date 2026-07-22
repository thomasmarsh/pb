module IdentTest (tests) where

import PB.Prelude
import PB.AST.Ident
import PB.Lexing.Token (SourceSpan (..))
import Data.Aeson (toJSON)
import Data.List.NonEmpty (NonEmpty (..))
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- A reusable test span
sp1, sp2 :: SourceSpan
sp1 = SourceSpan 10 1 10 5
sp2 = SourceSpan 10 7 10 11

tests :: TestTree
tests = testGroup "Ident"
  [ testGroup "Ident basics"
      [ testCase "identOrig preserves declared casing" $
          identOrig (mkIdentAt sp1 "N_Cst_Util") @?= "N_Cst_Util"
      , testCase "identCanon lowercases" $
          identCanon (mkIdentAt sp1 "N_Cst_Util") @?= "n_cst_util"
      , testCase "Eq compares case-insensitively" $
          mkIdentAt sp1 "n_cst_util" @?= mkIdentAt sp2 "N_CST_UTIL"
      , testCase "Eq distinguishes different identifiers" $
          (mkIdentAt sp1 "n_cst_util" == mkIdentAt sp1 "n_other") @?= False
      , testCase "Ord orders by canonical form" $
          compare (mkIdentAt sp1 "ABC") (mkIdentAt sp1 "abd") @?= LT
      , testCase "ToJSON renders original casing only" $
          toJSON (mkIdentAt sp1 "N_Cst_Util") @?= toJSON ("N_Cst_Util" :: Text)
      , testCase "IsString produces a Synthetic ident" $
          case identSpan ("n_cst_util" :: Ident) of
            Synthetic "IsString" -> pure ()
            other -> fail $ "expected Synthetic IsString, got " <> show other
      ]

  , testGroup "IdentProvenance"
      [ testCase "mkIdentAt produces FromSource with one span" $
          case identSpan (mkIdentAt sp1 "foo") of
            FromSource (s :| []) | s == sp1 -> pure ()
            other -> fail $ "expected FromSource [sp1], got " <> show other
      , testCase "mkIdentDerived produces FromSource with multiple spans" $
          case identSpan (mkIdentDerived (sp1 :| [sp2]) "foo::bar") of
            FromSource (a :| [b]) | a == sp1 && b == sp2 -> pure ()
            other -> fail $ "expected FromSource [sp1, sp2], got " <> show other
      , testCase "mkIdentSynthetic produces Synthetic with reason" $
          case identSpan (mkIdentSynthetic "test reason" "foo") of
            Synthetic "test reason" -> pure ()
            other -> fail $ "expected Synthetic, got " <> show other
      ]

  , testGroup "Provenance does not affect Eq/Ord"
      [ testCase "FromSource and Synthetic with same text are equal" $
          mkIdentAt sp1 "n_cst_util" @?= mkIdentSynthetic "test" "N_CST_UTIL"
      , testCase "FromSource with different spans but same text are equal" $
          mkIdentAt sp1 "abc" @?= mkIdentAt sp2 "ABC"
      , testCase "Ord ignores provenance" $
          compare (mkIdentSynthetic "x" "abc") (mkIdentAt sp1 "ABD") @?= LT
      ]

  , testGroup "IdentSet"
      [ testCase "empty set has no members" $
          identSetMember "n_cst_util" identSetEmpty @?= False
      , testCase "singleton set matches case-insensitively" $
          identSetMember "N_CST_UTIL" (identSetSingleton (mkIdentAt sp1 "n_cst_util")) @?= True
      , testCase "lookup recovers the originally-declared casing" $
          identSetLookup "N_CST_UTIL" (identSetSingleton (mkIdentAt sp1 "n_cst_util"))
            @?= Just (mkIdentAt sp1 "n_cst_util")
      , testCase "lookup on a miss is Nothing" $
          identSetLookup "xyz_unknown" (identSetSingleton (mkIdentAt sp1 "n_cst_util")) @?= Nothing
      , testCase "fromList dedupes by canonical form" $
          let s = identSetFromList [mkIdentAt sp1 "n_cst_util", mkIdentAt sp2 "N_CST_UTIL", mkIdentAt sp1 "n_other"]
          in length (identSetToList s) @?= 2
      ]

  , testGroup "IdentMap"
      [ testCase "empty map has no entries" $
          identMapLookup "n_cst_util" identMapEmpty @?= (Nothing :: Maybe (Ident, Int))
      , testCase "lookup recovers the originally-declared key casing and its value" $
          let m = identMapFromList [(mkIdentAt sp1 "n_cst_util", (42 :: Int))]
          in identMapLookup "N_CST_UTIL" m @?= Just (mkIdentAt sp1 "n_cst_util", 42)
      , testCase "lookup on a miss is Nothing" $
          let m = identMapFromList [(mkIdentAt sp1 "n_cst_util", (42 :: Int))]
          in identMapLookup "xyz_unknown" m @?= Nothing
      , testCase "fromListWith combines values and keeps the first-seen casing on a canonical collision" $
          let m = identMapFromListWith (+) [(mkIdentAt sp1 "N_Cst_Util", (1 :: Int)), (mkIdentAt sp2 "n_cst_util", 2)]
          in identMapLookup "n_cst_util" m @?= Just (mkIdentAt sp1 "N_Cst_Util", 3)
      , testCase "fromList (last-wins values) still keeps the first-seen casing" $
          let m = identMapFromList [(mkIdentAt sp1 "N_Cst_Util", (1 :: Int)), (mkIdentAt sp2 "n_cst_util", 2)]
          in identMapLookup "n_cst_util" m @?= Just (mkIdentAt sp1 "N_Cst_Util", 2)
      , testCase "size counts distinct canonical keys" $
          let m = identMapFromList [(mkIdentAt sp1 "a", (1 :: Int)), (mkIdentAt sp2 "A", 2), (mkIdentAt sp1 "b", 3)]
          in identMapSize m @?= 2
      ]
  ]
