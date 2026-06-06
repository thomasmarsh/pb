module MaskTest (tests) where

import PB.Prelude
import PB.Lexing.Mask (maskDocument, maskLine)

import Hedgehog (Gen, Property, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import qualified Data.Text as T

import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests = testGroup "Lexing"
  [ testGroup "Mask"
    [ testGroup "maskLine unit"
      [ testCase "plain code passes through" $
          maskLine "hello world" @?= "hello world"

      , testCase "line comment becomes spaces" $
          maskLine "foo // bar" @?= "foo       "

      , testCase "double-quoted string content becomes spaces" $
          maskLine "x \"hello\" y" @?= "x \"     \" y"

      , testCase "single-quoted string content becomes spaces" $
          maskLine "'hello'" @?= "'     '"

      , testCase "ampersand inside string is masked" $
          maskLine "\"&\"" @?= "\" \""

      , testCase "double-slash inside string is not a comment" $
          maskLine "\"//foo\"" @?= "\"     \""

      , testCase "opening quote after comment is not a string" $
          maskLine "// \"foo\"" @?= "        "

      , testCase "tilde-dot escape masked as two chars" $
          maskLine "\"a~.b\"" @?= "\"    \""

      , testCase "tilde-hex escape masked as four chars" $
          maskLine "\"~h4F\"" @?= "\"    \""

      , testCase "tilde-octal escape masked as five chars" $
          maskLine "\"~o101\"" @?= "\"     \""

      , testCase "block comment delimiters pass through (no block comment support)" $
          maskLine "a /* b */ c" @?= "a /* b */ c"
      ]

    , testGroup "maskDocument unit"
      [ testCase "plain code passes through" $
          maskDocument "hello world" @?= "hello world"

      , testCase "block comment on one line becomes spaces" $
          maskDocument "foo /* bar */ baz" @?= "foo           baz"

      , testCase "block comment spanning lines" $
          maskDocument "before\n/* in\nside */\nafter"
            @?= "before\n     \n       \nafter"

      , testCase "single-quoted string ends at newline" $
          maskDocument "'hello\nworld" @?= "'     \nworld"

      , testCase "double-quoted string spans newlines" $
          maskDocument "\"hello\nworld\"" @?= "\"     \n     \""

      , testCase "block comment delimiters inside double-quoted string are masked" $
          maskDocument "\"/* not a comment */\"" @?= "\"                   \""

      , testCase "line comment after code" $
          maskDocument "x = 1 // note\ny = 2"
            @?= "x = 1        \ny = 2"

      , testCase "newlines always preserved in output" $ do
          let inp = "a\nb\nc"
          T.count "\n" (maskDocument inp) @?= 2
      ]

    , testGroup "maskLine properties"
      [ testProperty "preserves length" prop_maskLinePreservesLength
      , testProperty "idempotent"       prop_maskLineIdempotent
      ]

    , testGroup "maskDocument properties"
      [ testProperty "preserves length"   prop_maskDocPreservesLength
      , testProperty "preserves newlines" prop_maskDocPreservesNewlines
      ]
    ]
  ]

-- Restrict to single-line input (no embedded newlines).
singleLineText :: Gen Text
singleLineText =
  Gen.text (Range.linear 0 200) (Gen.filter (/= '\n') Gen.unicode)

prop_maskLinePreservesLength :: Property
prop_maskLinePreservesLength = property $ do
  t <- forAll singleLineText
  T.length (maskLine t) === T.length t

prop_maskLineIdempotent :: Property
prop_maskLineIdempotent = property $ do
  t <- forAll singleLineText
  maskLine (maskLine t) === maskLine t

prop_maskDocPreservesLength :: Property
prop_maskDocPreservesLength = property $ do
  t <- forAll $ Gen.text (Range.linear 0 400) Gen.unicode
  T.length (maskDocument t) === T.length t

prop_maskDocPreservesNewlines :: Property
prop_maskDocPreservesNewlines = property $ do
  t <- forAll $ Gen.text (Range.linear 0 400) Gen.unicode
  T.count "\n" (maskDocument t) === T.count "\n" t
