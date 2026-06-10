module Main (main) where

import PB.Prelude
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText, stripHeaders)
import qualified BodyParserTest
import qualified BodyStmtTest
import qualified ExprTest
import qualified CorpusTest
import qualified FileTest
import qualified MaskTest
import qualified RunnerTest
import qualified SplitterTest
import qualified StreamTest
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
  [ BodyParserTest.tests
  , BodyStmtTest.tests
  , ExprTest.tests
  , CorpusTest.tests
  , FileTest.tests
  , MaskTest.tests
  , RunnerTest.tests
  , TokenTest.tests
  , SplitterTest.tests
  , StreamTest.tests
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

      , testCase "continuation: & outside ~\"-escaped string is joined" $ do
          let input = "string s = \"say ~\"hello\" and &\nworld!\""
          normalizeText input @?=
            [ LogicalLine "string s = \"say ~\"hello\" and  world!\"" 1 2 ]

      , testCase "continuation: & inside open string with ~\" escape is not joined" $ do
          let input = "string s = \"say ~\"hi &\nworld!\""
          normalizeText input @?=
            [ LogicalLine "string s = \"say ~\"hi &" 1 1
            , LogicalLine "world!\"" 2 2
            ]

      , testCase "block comment spanning two lines is joined" $ do
          map llText (normalizeText "/* start\nend */") @?=
            ["/* start end */"]

      , testCase "block comment after code, spanning lines" $ do
          map llText (normalizeText "code; /* begin\nstill comment\nend */ more") @?=
            ["code; /* begin still comment end */ more"]

      , testCase "closed block comment on one line is not joined" $ do
          map llText (normalizeText "x = /* inline */ 1\ny = 2") @?=
            ["x = /* inline */ 1", "y = 2"]

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

      , testCase "stripHeaders: single header extracted" $ do
          let h = LogicalLine "$PBExportHeader$foo.srs" 1 1
              r = LogicalLine "x = 1" 2 2
          stripHeaders [h, r] @?= (["$PBExportHeader$foo.srs"], [r])

      , testCase "stripHeaders: non-header line not extracted" $ do
          let l = LogicalLine "x = 1" 1 1
          stripHeaders [l] @?= ([], [l])

      , testCase "stripHeaders: two headers then code" $ do
          let h1 = LogicalLine "$PBExportHeader$foo.srs" 1 1
              h2 = LogicalLine "$PBExportComments$some text" 2 2
              r  = LogicalLine "x = 1" 3 3
          stripHeaders [h1, h2, r] @?= (["$PBExportHeader$foo.srs", "$PBExportComments$some text"], [r])

      , testCase "stripHeaders: empty list returns empty headers" $
          stripHeaders [] @?= ([], [])

      , testCase "stripHeaders: HA$ prefix is stripped and normalised" $ do
          let h = LogicalLine "HA$PBExportHeader$foo.srf" 1 1
              r = LogicalLine "global type foo from function_object" 2 2
          stripHeaders [h, r] @?= (["$PBExportHeader$foo.srf"], [r])

      , testCase "stripHeaders: stops at first non-header even if later line looks like header" $ do
          let h  = LogicalLine "$PBExportHeader$foo.srs" 1 1
              r  = LogicalLine "x = 1" 2 2
              h2 = LogicalLine "$PBExportComments$later" 3 3
          stripHeaders [h, r, h2] @?= (["$PBExportHeader$foo.srs"], [r, h2])

      , testProperty "stripHeaders: header count + remaining count == total count" $
          prop_stripHeaders_countInvariant
      , testProperty "stripHeaders: all returned headers start with $" $
          prop_stripHeaders_allHeadersStartWithDollar
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

prop_stripHeaders_countInvariant :: Property
prop_stripHeaders_countInvariant = property $ do
  lls <- forAll $ Gen.list (Range.linear 0 20)
           ((\t -> LogicalLine t 1 1) <$> Gen.text (Range.linear 0 40) Gen.unicode)
  let (hdrs, rest) = stripHeaders lls
  length hdrs + length rest === length lls

prop_stripHeaders_allHeadersStartWithDollar :: Property
prop_stripHeaders_allHeadersStartWithDollar = property $ do
  lls <- forAll $ Gen.list (Range.linear 0 20)
           ((\t -> LogicalLine t 1 1) <$> Gen.text (Range.linear 0 40) Gen.unicode)
  let (hdrs, _) = stripHeaders lls
  for_ hdrs $ \h -> assert (T.isPrefixOf "$" h)
