module StreamTest (tests) where

import PB.Prelude
import PB.Grammar.Stream      (StmtStream (..), FileParser, satisfyStmt, leadingKind, leadingText)
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Hedgehog (Gen, Property, forAll, property, failure, footnote, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)
import Text.Megaparsec (parse)

-- ---------------------------------------------------------------------------
-- Helpers

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens    = [ Token k t (SourceSpan 1 1 1) | (k, t) <- pairs ]
  , stmtSource    = LogicalLine "" 1 1
  , stmtTerminated = False
  }

genStmt :: Gen Statement
genStmt = do
  txt <- Gen.text (Range.linear 0 20) Gen.alphaNum
  pure $ mkStmt [(TkIdent, txt)]

runParse :: FileParser Statement -> StmtStream -> Either () Statement
runParse p stream = case parse p "" stream of
  Right s -> Right s
  Left  _ -> Left ()

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Grammar.Stream"
  [ testGroup "satisfyStmt"
    [ testCase "positive: matches first statement" $ do
        let stmt   = mkStmt [(TkIdent, "x")]
        case runParse (satisfyStmt (const True)) (StmtStream [stmt]) of
          Right s -> s @?= stmt
          Left _  -> assertFailure "expected parse success"

    , testCase "negative: rejects non-matching statement" $ do
        let stmt = mkStmt [(TkIdent, "x")]
        case runParse (satisfyStmt (const False)) (StmtStream [stmt]) of
          Right _  -> assertFailure "expected parse failure"
          Left _   -> pure ()

    , testCase "positive: empty stream fails" $
        case runParse (satisfyStmt (const True)) (StmtStream []) of
          Right _  -> assertFailure "expected parse failure on empty stream"
          Left _   -> pure ()
    ]

  , testGroup "leadingKind"
    [ testCase "matches TkDeclKw statement" $ do
        let stmt = mkStmt [(TkDeclKw, "function")]
        case runParse (leadingKind TkDeclKw) (StmtStream [stmt]) of
          Right s -> s @?= stmt
          Left _  -> assertFailure "expected parse success"

    , testCase "rejects TkIdent statement" $ do
        let stmt = mkStmt [(TkIdent, "x")]
        case runParse (leadingKind TkDeclKw) (StmtStream [stmt]) of
          Right _  -> assertFailure "expected parse failure"
          Left _   -> pure ()
    ]

  , testGroup "leadingText"
    [ testCase "matches 'forward' (case-insensitive)" $ do
        let stmt = mkStmt [(TkDeclKw, "FORWARD")]
        case runParse (leadingText "forward") (StmtStream [stmt]) of
          Right s -> s @?= stmt
          Left _  -> assertFailure "expected parse success"

    , testCase "rejects 'backward'" $ do
        let stmt = mkStmt [(TkIdent, "backward")]
        case runParse (leadingText "forward") (StmtStream [stmt]) of
          Right _  -> assertFailure "expected parse failure"
          Left _   -> pure ()

    , testCase "matches 'end forward' two-word token" $ do
        let stmt = mkStmt [(TkDeclKw, "end forward")]
        case runParse (leadingText "end forward") (StmtStream [stmt]) of
          Right s -> s @?= stmt
          Left _  -> assertFailure "expected parse success"
    ]

  , testProperty "satisfyStmt: consumed statement equals head of input"
      propConsumedEqualsHead
  , testProperty "satisfyStmt: on failure, stream is unchanged"
      propUnchangedOnFailure
  ]

-- ---------------------------------------------------------------------------
-- Properties

propConsumedEqualsHead :: Property
propConsumedEqualsHead = property $ do
  stmts <- forAll $ Gen.list (Range.linear 1 10) genStmt
  case stmts of
    []    -> failure
    (s:_) -> case runParse (satisfyStmt (const True)) (StmtStream stmts) of
      Right consumed -> consumed === s
      Left _         -> footnote "unexpected parse failure" >> failure

propUnchangedOnFailure :: Property
propUnchangedOnFailure = property $ do
  stmts <- forAll $ Gen.list (Range.linear 1 10) genStmt
  case stmts of
    []    -> failure
    (s:_) -> case runParse (satisfyStmt (const False) <|> satisfyStmt (const True)) (StmtStream stmts) of
      Right consumed -> consumed === s
      Left _         -> footnote "unexpected parse failure" >> failure
