module SplitterTest (tests) where

import PB.Prelude
import PB.Lexing.Lexer (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Splitter (Statement (..), splitStatements)
import PB.Lexing.Token (Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText)

import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Hedgehog (Property, assert, forAll, property, success, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- ---------------------------------------------------------------------------
-- Helpers

mkLine :: Text -> LogicalLine
mkLine t = LogicalLine t 1 1

tokenKindsOf :: Statement -> [TokenKind]
tokenKindsOf = map tkKind . stmtTokens

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "StatementSplitter"
  [ testGroup "unit"
    [ testCase "single statement, no semicolon" $ do
        let result = splitStatements (tokenize [mkLine "x = 1"])
        case result of
          [Right stmt] -> do
            stmtSource stmt @?= mkLine "x = 1"
            tokenKindsOf stmt @?= [TkIdent, TkAssignOp, TkIntLiteral]
          _ -> assertFailure ("expected one statement, got: " <> show result)

    , testCase "two statements separated by semicolon" $ do
        let result = splitStatements (tokenize [mkLine "x = 1; y = 2"])
        case result of
          [Right s1, Right s2] -> do
            tokenKindsOf s1 @?= [TkIdent, TkAssignOp, TkIntLiteral]
            tokenKindsOf s2 @?= [TkIdent, TkAssignOp, TkIntLiteral]
          _ -> assertFailure ("expected two statements, got: " <> show result)

    , testCase "three statements from two semicolons" $ do
        let result = splitStatements (tokenize [mkLine "a; b; c"])
        case result of
          [Right s1, Right s2, Right s3] -> do
            tokenKindsOf s1 @?= [TkIdent]
            tokenKindsOf s2 @?= [TkIdent]
            tokenKindsOf s3 @?= [TkIdent]
          _ -> assertFailure ("expected three statements, got: " <> show result)

    , testCase "trailing semicolon produces empty final statement" $ do
        let result = splitStatements (tokenize [mkLine "x = 1;"])
        case result of
          [Right s1, Right s2] -> do
            tokenKindsOf s1 @?= [TkIdent, TkAssignOp, TkIntLiteral]
            tokenKindsOf s2 @?= []
          _ -> assertFailure ("expected two statements, got: " <> show result)

    , testCase "semicolon inside double-quoted string is not a split point" $ do
        let result = splitStatements (tokenize [mkLine "x = \"a;b\""])
        case result of
          [Right stmt] -> tokenKindsOf stmt @?= [TkIdent, TkAssignOp, TkStringDouble]
          _ -> assertFailure ("expected one statement, got: " <> show result)

    , testCase "semicolon inside single-quoted string is not a split point" $ do
        let result = splitStatements (tokenize [mkLine "x = 'a;b'"])
        case result of
          [Right stmt] -> tokenKindsOf stmt @?= [TkIdent, TkAssignOp, TkStringSingle]
          _ -> assertFailure ("expected one statement, got: " <> show result)

    , testCase "lex error propagates as Left LexError" $ do
        let ll  = mkLine "x"
            err = LexError ll 0
            bad = LexLine ll (Left err)
        splitStatements [bad] @?= [Left err]

    , testCase "multiple LexLines produce statements in order" $ do
        let ll1    = mkLine "a"
            ll2    = mkLine "b"
            result = splitStatements (tokenize [ll1, ll2])
        case result of
          [Right s1, Right s2] -> do
            stmtSource s1 @?= ll1
            stmtSource s2 @?= ll2
          _ -> assertFailure ("expected two statements, got: " <> show result)

    , testCase "empty token list produces one empty statement" $ do
        let ll      = mkLine ""
            lexLine = LexLine ll (Right [])
        splitStatements [lexLine] @?= [Right (Statement [] ll)]

    , testCase "stmtSource matches originating LogicalLine" $ do
        let ll     = mkLine "a; b"
            result = splitStatements (tokenize [ll])
        length result @?= 2
        for_ result $ \case
          Right stmt -> stmtSource stmt @?= ll
          Left  _    -> assertFailure "unexpected lex error"

    , testCase "adjacent calls foo()bar(); baz()" $ do
        let result = splitStatements (tokenize [mkLine "foo()bar(); baz()"])
        case result of
          [Right s1, Right s2] -> do
            tokenKindsOf s1 @?= [TkIdent, TkLParen, TkRParen, TkIdent, TkLParen, TkRParen]
            tokenKindsOf s2 @?= [TkIdent, TkLParen, TkRParen]
          _ -> assertFailure ("expected two statements, got: " <> show result)
    ]
  , testGroup "properties"
    [ testProperty "no statement contains TkSemi"          propNoSemi
    , testProperty "statement count >= line count"         propStatementCount
    , testProperty "token spans unchanged after splitting" propSpansPreserved
    ]
  ]

-- ---------------------------------------------------------------------------
-- Properties

propNoSemi :: Property
propNoSemi = property $ do
  t <- forAll $ Gen.text (Range.linear 0 80)
                  (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let stmts = splitStatements (tokenize (normalizeText t))
  for_ stmts $ \case
    Left  _    -> success
    Right stmt -> assert (TkSemi `notElem` map tkKind (stmtTokens stmt))

propStatementCount :: Property
propStatementCount = property $ do
  t <- forAll $ Gen.text (Range.linear 0 80)
                  (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let lls   = normalizeText t
      stmts = splitStatements (tokenize lls)
  assert (length stmts >= length lls)

propSpansPreserved :: Property
propSpansPreserved = property $ do
  t <- forAll $ Gen.text (Range.linear 0 80)
                  (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let lexLines = tokenize (normalizeText t)
      stmts    = splitStatements lexLines
      origToks = [ tok
                 | LexLine _ (Right ts) <- lexLines
                 , tok                  <- ts
                 , tkKind tok /= TkSemi
                 ]
      stmtToks = [ tok
                 | Right stmt <- stmts
                 , tok        <- stmtTokens stmt
                 ]
  map tkSpan stmtToks === map tkSpan origToks
