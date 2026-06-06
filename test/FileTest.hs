module FileTest (tests) where

import PB.Prelude
import PB.Grammar.File        (pForwardBlock, pTypeDecl)
import PB.Grammar.Stream      (FileParser, StmtStream (..))
import PB.AST.Object          (ForwardBlock (..), TypeDecl (..))
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Hedgehog (Property, forAll, property, assert)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)
import Text.Megaparsec (parse)
import Text.Megaparsec.Error (errorBundlePretty)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Helpers

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens = [ Token k t (SourceSpan 1 1 1) | (k, t) <- pairs ]
  , stmtSource = LogicalLine "" 1 1
  }

runSection :: FileParser a -> [Statement] -> Either String a
runSection p stmts = case parse p "" (StmtStream stmts) of
  Right x  -> Right x
  Left err -> Left (errorBundlePretty err)

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Grammar.File"
  [ testGroup "pForwardBlock"
    [ testCase "positive: one TypeDecl" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [TypeDecl "w_foo" "window" Nothing])

    , testCase "positive: two TypeDecls" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "d_bar"), (TkDeclKw, "from"), (TkIdent, "datawindow")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [ TypeDecl "w_foo" "window" Nothing
                              , TypeDecl "d_bar" "datawindow" Nothing
                              ])

    , testCase "positive: empty forward block" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?= Right (ForwardBlock [])

    , testCase "positive: TypeDecl with within clause" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [ (TkDeclKw, "type"), (TkIdent, "w_sub"), (TkDeclKw, "from")
                       , (TkIdent, "window"), (TkDeclKw, "within"), (TkIdent, "w_main")
                       ]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [TypeDecl "w_sub" "window" (Just "w_main")])

    , testCase "negative: missing end forward" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              ]
        case runSection pForwardBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end forward' is missing"

    , testCase "negative: wrong end keyword" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        case runSection pForwardBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure with wrong end keyword"

    , testProperty "all TypeDecl names are non-empty"
        prop_typeDecl_names_nonempty
    ]

  , testGroup "pTypeDecl"
    [ testCase "simple: type Name from Ancestor" $ do
        let stmt = mkStmt
              [ (TkDeclKw, "type")
              , (TkIdent,  "w_mywindow")
              , (TkDeclKw, "from")
              , (TkIdent,  "window")
              ]
        runSection pTypeDecl [stmt] @?=
          Right (TypeDecl "w_mywindow" "window" Nothing)

    , testCase "with within: type Name from Ancestor within Container" $ do
        let stmt = mkStmt
              [ (TkDeclKw, "type")
              , (TkIdent,  "w_mywindow")
              , (TkDeclKw, "from")
              , (TkIdent,  "window")
              , (TkDeclKw, "within")
              , (TkIdent,  "w_main")
              ]
        runSection pTypeDecl [stmt] @?=
          Right (TypeDecl "w_mywindow" "window" (Just "w_main"))

    , testCase "negative: missing from" $ do
        let stmt = mkStmt
              [ (TkDeclKw, "type")
              , (TkIdent,  "w_mywindow")
              , (TkIdent,  "window")
              ]
        case runSection pTypeDecl [stmt] of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'from' keyword is missing"
    ]
  ]

-- ---------------------------------------------------------------------------
-- Properties

prop_typeDecl_names_nonempty :: Property
prop_typeDecl_names_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  anc  <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmt = mkStmt
        [ (TkDeclKw, "type")
        , (TkIdent,  name)
        , (TkDeclKw, "from")
        , (TkIdent,  anc)
        ]
  case runSection pTypeDecl [stmt] of
    Right td -> assert (not (T.null (tdName td)))
    Left _   -> pure ()
