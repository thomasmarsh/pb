module Main (main) where

import PB.Prelude
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText)
import qualified MaskTest
import qualified TokenTest

import Hedgehog (Property, assert, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import qualified Data.Text      as T

import Data.Foldable (for_)

import Test.Tasty         (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit   (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "pb-ast"
  [ MaskTest.tests
  , TokenTest.tests
  , testGroup "Pipeline"
    [ testGroup "Preprocess"
      [ testCase "single line passthrough" $
          map llText (normalizeText "hello world") @?= ["hello world"]

      , testCase "strips trailing spaces" $
          map llText (normalizeText "hello   ") @?= ["hello"]

      , testCase "normalizes CRLF" $
          map llText (normalizeText "line1\r\nline2") @?= ["line1", "line2"]

      , testCase "joins one continuation line" $
          map llText (normalizeText "hello &\nworld") @?= ["hello  world"]

      , testCase "continuation across 3 lines" $
          map llText (normalizeText "a &\nb &\nc") @?= ["a  b  c"]

      , testCase "ampersand inside string is not a continuation" $
          map llText (normalizeText "\"&\"\nfoo") @?= ["\"&\"", "foo"]

      , testCase "empty input yields one empty logical line" $
          normalizeText "" @?= [LogicalLine "" 1 1]

      , testCase "start and end lines tracked for continuation" $ do
          let lls = normalizeText "x &\ny"
          case lls of
            (ll : _) -> (llStartLine ll, llEndLine ll) @?= (1, 2)
            []       -> assertFailure "expected at least one logical line"

      , testProperty "idempotence" prop_idempotent
      , testProperty "monotone line numbers" prop_monotone
      , testProperty "no trailing continuation marker" prop_noTrailingAmpersand
      ]
    ]
  ]

prop_idempotent :: Property
prop_idempotent = property $ do
  t <- forAll $ Gen.text (Range.linear 0 200) Gen.unicode
  let once          = normalizeText t
      reconstructed = T.intercalate "\n" (map llText once)
      twice         = normalizeText reconstructed
  map llText once === map llText twice

prop_monotone :: Property
prop_monotone = property $ do
  t <- forAll $ Gen.text (Range.linear 0 200) Gen.unicode
  let lls = normalizeText t
  for_ lls $ \ll -> assert (llStartLine ll <= llEndLine ll)

prop_noTrailingAmpersand :: Property
prop_noTrailingAmpersand = property $ do
  t <- forAll $ Gen.text (Range.linear 0 200) Gen.unicode
  let lls    = normalizeText t
      trimEnd = T.dropWhileEnd (\c -> c == ' ' || c == '\t')
  for_ lls $ \ll -> assert (not (T.isSuffixOf "&" (trimEnd (llText ll))))
