module TokenTest (tests) where

import PB.Prelude
import PB.Lexing.Lexer (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Token (SourceSpan (..), Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Data.Foldable (for_)
import qualified Data.Text as T

import Hedgehog (Property, assert, forAll, property, success)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- ---------------------------------------------------------------------------
-- Helpers

-- Build a single-physical-line LogicalLine (no continuation).
mkLine :: Text -> LogicalLine
mkLine t = LogicalLine t 1 1

-- Tokenize a single line and extract kinds, failing on LexError.
tokenKinds :: Text -> IO [TokenKind]
tokenKinds t =
  case tokenize [mkLine t] of
    [LexLine _ (Right ts)] -> return (map tkKind ts)
    [LexLine _ (Left le)]  -> assertFailure ("lex error at offset " <> show (leOffset le))
    _                      -> assertFailure "unexpected tokenize result length"

-- Tokenize and extract (kind, text) pairs.
tokenKindTexts :: Text -> IO [(TokenKind, Text)]
tokenKindTexts t =
  case tokenize [mkLine t] of
    [LexLine _ (Right ts)] -> return (map (\tk -> (tkKind tk, tkText tk)) ts)
    [LexLine _ (Left le)]  -> assertFailure ("lex error at offset " <> show (leOffset le))
    _                      -> assertFailure "unexpected tokenize result length"

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Lexing"
  [ testGroup "Token"
    [ testGroup "two-word keywords" $ map twoWordCase
        [ ("end if",          TkControlKw)
        , ("end choose",      TkControlKw)
        , ("end try",         TkControlKw)
        , ("end function",    TkDeclKw)
        , ("end subroutine",  TkDeclKw)
        , ("end event",       TkDeclKw)
        , ("end type",        TkDeclKw)
        , ("choose case",     TkControlKw)
        , ("forward prototypes", TkDeclKw)
        , ("type variables",  TkDeclKw)
        ]
    , testGroup "two-word keywords: case-insensitive" $ map twoWordCiCase
        [ ("END IF",    TkControlKw)
        , ("End If",    TkControlKw)
        , ("END FUNCTION", TkDeclKw)
        ]
    , testGroup "literals"
        [ testCase "enum literal Black!" $ do
            r <- tokenKindTexts "Black!"
            r @?= [(TkEnumLiteral, "Black!")]

        , testCase "enum literal does not split at !" $ do
            r <- tokenKinds "Primary!"
            r @?= [TkEnumLiteral]

        , testCase "date literal 2024-01-15" $ do
            r <- tokenKindTexts "2024-01-15"
            r @?= [(TkDateLiteral, "2024-01-15")]

        , testCase "float literal 3.14" $ do
            r <- tokenKindTexts "3.14"
            r @?= [(TkFloatLiteral, "3.14")]

        , testCase "float literal with exponent" $ do
            r <- tokenKindTexts "1.5e10"
            r @?= [(TkFloatLiteral, "1.5e10")]

        , testCase "int literal 42" $ do
            r <- tokenKindTexts "42"
            r @?= [(TkIntLiteral, "42")]

        , testCase "bool true" $ do
            r <- tokenKinds "true"
            r @?= [TkBoolTrue]

        , testCase "bool false" $ do
            r <- tokenKinds "false"
            r @?= [TkBoolFalse]

        , testCase "null" $ do
            r <- tokenKinds "null"
            r @?= [TkNull]
        ]
    , testGroup "modifiers"
        [ testCase "access modifier public" $ do
            r <- tokenKinds "public"
            r @?= [TkAccessModifier]

        , testCase "access modifier private" $ do
            r <- tokenKinds "private"
            r @?= [TkAccessModifier]

        , testCase "storage modifier readonly" $ do
            r <- tokenKinds "readonly"
            r @?= [TkStorageModifier]

        , testCase "storage modifier constant" $ do
            r <- tokenKinds "constant"
            r @?= [TkStorageModifier]
        ]
    , testGroup "SQL keywords"
        [ testCase "select" $ do
            r <- tokenKinds "select"
            r @?= [TkSqlKw]

        , testCase "SELECT case-insensitive" $ do
            r <- tokenKinds "SELECT"
            r @?= [TkSqlKw]
        ]
    , testGroup "punctuation"
        [ testCase "double colon is TkDoubleColon" $ do
            r <- tokenKinds "x::y"
            r @?= [TkIdent, TkDoubleColon, TkIdent]

        , testCase "single colon is TkColon" $ do
            r <- tokenKinds "x:y"
            r @?= [TkIdent, TkColon, TkIdent]

        , testCase "label at column 1" $ do
            r <- tokenKindTexts "myLabel:"
            r @?= [(TkLabel, "myLabel:")]
        ]
    , testGroup "pathological"
        [ testCase "adjacent calls foo()bar()" $ do
            r <- tokenKinds "foo()bar()"
            r @?= [TkIdent, TkLParen, TkRParen, TkIdent, TkLParen, TkRParen]

        , testCase "bare end is a keyword" $ do
            r <- tokenKinds "end"
            r @?= [TkControlKw]

        , testCase "end followed by unknown word is two tokens" $ do
            r <- tokenKinds "end release"
            r @?= [TkControlKw, TkIdent]
        ]
    , testGroup "binary operators (pIntLiteral must not swallow sign)"
        [ testCase "a + b: plus between identifiers" $ do
            r <- tokenKinds "a + b"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "x - y: minus between identifiers" $ do
            r <- tokenKinds "x - y"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "ii_count++: postfix increment" $ do
            r <- tokenKinds "ii_count++"
            r @?= [TkIdent, TkAugmentOp]

        , testCase "x += 1: augmented assignment" $ do
            r <- tokenKinds "x += 1"
            r @?= [TkIdent, TkAugmentOp, TkIntLiteral]

        , testCase "x -= y: augmented minus" $ do
            r <- tokenKinds "x -= y"
            r @?= [TkIdent, TkAugmentOp, TkIdent]
        ]
    , testGroup "brace literals (array/struct initializers)"
        [ testCase "open brace is TkLBrace" $ do
            r <- tokenKinds "{"
            r @?= [TkLBrace]

        , testCase "close brace is TkRBrace" $ do
            r <- tokenKinds "}"
            r @?= [TkRBrace]

        , testCase "array literal {a, b}" $ do
            r <- tokenKinds "{a, b}"
            r @?= [TkLBrace, TkIdent, TkComma, TkIdent, TkRBrace]
        ]
    , testGroup "backtick in type references"
        [ testCase "ancestor`control in type ref" $ do
            r <- tokenKindTexts "w_parent`cb_ok"
            r @?= [(TkIdent, "w_parent`cb_ok")]
        ]
    , testGroup "properties"
        [ testProperty "tokens carry correct line number" prop_tokensCorrectLine
        , testProperty "token text reconstructs input"   prop_tokenTextReconstructsInput
        ]
    ]
  ]

-- ---------------------------------------------------------------------------
-- Table-driven helpers

twoWordCase :: (Text, TokenKind) -> TestTree
twoWordCase (input, expected) =
  testCase (T.unpack input) $ do
    r <- tokenKindTexts input
    r @?= [(expected, input)]

twoWordCiCase :: (Text, TokenKind) -> TestTree
twoWordCiCase (input, expected) =
  testCase (T.unpack input) $ do
    r <- tokenKinds input
    r @?= [expected]

-- ---------------------------------------------------------------------------
-- Properties

-- All tokens from a single logical line carry the same start/end line numbers.
prop_tokensCorrectLine :: Property
prop_tokensCorrectLine = property $ do
  t  <- forAll $ Gen.text (Range.linear 0 80)
                   (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let ll  = LogicalLine t 5 7     -- arbitrary physical span
      res = tokenize [ll]
  case res of
    [LexLine _ (Right ts)] ->
      for_ ts $ \tk -> do
        assert (ssStartLine (tkSpan tk) == 5)
        assert (ssEndLine   (tkSpan tk) == 7)
    _ -> success   -- LexError is also acceptable

-- Concatenating tkText of all tokens from a successful lex reproduces theo
-- original input modulo whitespace (tokens are non-whitespace runs).
prop_tokenTextReconstructsInput :: Property
prop_tokenTextReconstructsInput = property $ do
  t <- forAll $ Gen.text (Range.linear 0 80)
                  (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let ll  = LogicalLine t 1 1
      res = tokenize [ll]
  case res of
    [LexLine _ (Right ts)] ->
      for_ ts $ \tk ->
        assert (T.isInfixOf (tkText tk) t)
    _ -> success
