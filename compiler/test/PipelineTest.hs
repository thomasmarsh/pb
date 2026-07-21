module PipelineTest (tests) where

import PB.Prelude
import PB.Pipeline.Preprocess
  (LogicalLine (..), SourceChunk (..), mkLogicalLine, resolveRawPos, normalizeText, stripHeaders)

import Test.Tasty             (testGroup, TestTree)
import Test.Tasty.HUnit       (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog    (testProperty)

import Data.List.NonEmpty (NonEmpty (..))
import Hedgehog (Property, assert, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import qualified Data.Text      as T


tests :: TestTree
tests = testGroup "Pipeline"
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
                [ LogicalLine "string s = \"say ~\"hello\" and  world!\"" 1 2
                    (SourceChunk 1 1 0 29 :| [SourceChunk 2 1 30 7]) ]

        , testCase "continuation: & inside open string with ~\" escape is joined" $ do
            let input = "string s = \"say ~\"hi &\nworld!\""
            normalizeText input @?=
                [ LogicalLine "string s = \"say ~\"hi  world!\"" 1 2
                    (SourceChunk 1 1 0 21 :| [SourceChunk 2 1 22 7]) ]

        , testCase "token spans resolve to true raw position across a continuation" $ do
            -- The identifier "world" sits on raw physical line 2, even though
            -- the joined logical line reports llStartLine=1/llEndLine=2 as a
            -- whole -- resolveRawPos must recover its true (line, col), not
            -- stamp every token in the join with the same (1, 2) bounds.
            case normalizeText "hello &\nworld" of
                [ll] -> do
                    resolveRawPos ll 0 @?= (1, 1)  -- "hello" starts on line 1, col 1
                    resolveRawPos ll 7 @?= (2, 1)  -- "world" starts on line 2, col 1
                lls  -> assertFailure ("expected one logical line, got " <> show (length lls))

        , testCase "block comment spanning two lines is joined" $ do
            map llText (normalizeText "/* start\nend */") @?=
                ["/* start end */"]

        , testCase "block comment after code, spanning lines" $ do
            map llText (normalizeText "code; /* begin\nstill comment\nend */ more") @?=
                ["code; /* begin still comment end */ more"]

        , testCase "closed block comment on one line is not joined" $ do
            map llText (normalizeText "x = /* inline */ 1\ny = 2") @?=
                ["x = /* inline */ 1", "y = 2"]

        , testCase "block comment closed by */ immediately before // line comment" $ do
            -- The closing */ and a line comment // share the same slash:
            -- "end *///" — the * and first / close the block, // is a line comment.
            -- lineCommentDepth must not strip // before counting */.
            map llText (normalizeText "/* start\nend *///") @?=
                ["/* start end *///"]

        , testCase "block comment closed by */ before // does not swallow next line" $ do
            -- If lineCommentDepth mishandles *// the block comment is never
            -- closed and the next logical line is consumed into it.
            map llText (normalizeText "code /* open\n*/// line cmt\nnext line") @?=
                ["code /* open */// line cmt", "next line"]

        , testCase "empty input yields one empty logical line" $
            normalizeText "" @?= [mkLogicalLine "" 1]

        , testCase "start and end lines tracked for continuation" $ do
            let lls = normalizeText "x &\ny"
            case lls of
                (ll : _) -> (llStartLine ll, llEndLine ll) @?= (1, 2)
                []       -> assertFailure "expected at least one logical line"

        , testProperty "idempotence" prop_idempotent
        , testProperty "monotone line numbers" prop_monotone
        , testProperty "no trailing continuation marker" prop_noTrailingAmpersand

        , testCase "stripHeaders: single header extracted" $ do
            let h = mkLogicalLine "$PBExportHeader$foo.srs" 1
                r = mkLogicalLine "x = 1" 2
            stripHeaders [h, r] @?= (["$PBExportHeader$foo.srs"], [r])

        , testCase "stripHeaders: non-header line not extracted" $ do
            let l = mkLogicalLine "x = 1" 1
            stripHeaders [l] @?= ([], [l])

        , testCase "stripHeaders: two headers then code" $ do
            let h1 = mkLogicalLine "$PBExportHeader$foo.srs" 1
                h2 = mkLogicalLine "$PBExportComments$some text" 2
                r  = mkLogicalLine "x = 1" 3
            stripHeaders [h1, h2, r] @?= (["$PBExportHeader$foo.srs", "$PBExportComments$some text"], [r])

        , testCase "stripHeaders: empty list returns empty headers" $
            stripHeaders [] @?= ([], [])

        , testCase "stripHeaders: HA$ prefix is stripped and normalised" $ do
            let h = mkLogicalLine "HA$PBExportHeader$foo.srf" 1
                r = mkLogicalLine "global type foo from function_object" 2
            stripHeaders [h, r] @?= (["$PBExportHeader$foo.srf"], [r])

        , testCase "stripHeaders: stops at first non-header even if later line looks like header" $ do
            let h  = mkLogicalLine "$PBExportHeader$foo.srs" 1
                r  = mkLogicalLine "x = 1" 2
                h2 = mkLogicalLine "$PBExportComments$later" 3
            stripHeaders [h, r, h2] @?= (["$PBExportHeader$foo.srs"], [r, h2])

        , testProperty "stripHeaders: header count + remaining count == total count" $
            prop_stripHeaders_countInvariant
        , testProperty "stripHeaders: all returned headers start with $" $
            prop_stripHeaders_allHeadersStartWithDollar
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
           ((\t -> mkLogicalLine t 1) <$> Gen.text (Range.linear 0 40) Gen.unicode)
  let (hdrs, rest) = stripHeaders lls
  length hdrs + length rest === length lls

prop_stripHeaders_allHeadersStartWithDollar :: Property
prop_stripHeaders_allHeadersStartWithDollar = property $ do
  lls <- forAll $ Gen.list (Range.linear 0 20)
           ((\t -> mkLogicalLine t 1) <$> Gen.text (Range.linear 0 40) Gen.unicode)
  let (hdrs, _) = stripHeaders lls
  for_ hdrs $ \h -> assert (T.isPrefixOf "$" h)
