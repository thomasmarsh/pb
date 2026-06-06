module FileTest (tests) where

import PB.Prelude
import PB.Grammar.File        (pForwardBlock, pPrototypesBlock, pVariablesBlock, pTypeDecl, pVarDecl)
import PB.Grammar.Stream      (FileParser, StmtStream (..))
import PB.AST.Object          (ForwardBlock (..), PrototypesBlock (..), ProtoDecl (..), TypeDecl (..), VariablesBlock (..), VarScope (..), VarDecl (..), FnSig (..), SubSig (..))
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

  , testGroup "pVarDecl"
    [ testCase "simple: string s_name" $ do
        let stmt = mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
        runSection pVarDecl [stmt] @?= Right (VarDecl [] "string" "s_name")

    , testCase "with modifier: public integer i_count" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "public")
              , (TkDatatype,       "integer")
              , (TkIdent,          "i_count")
              ]
        runSection pVarDecl [stmt] @?= Right (VarDecl ["public"] "integer" "i_count")

    , testCase "negative: keyword as type name is rejected" $ do
        let stmt = mkStmt [(TkDeclKw, "function"), (TkIdent, "i_count")]
        case runSection pVarDecl [stmt] of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when keyword is used as type name"
    ]

  , testGroup "pVariablesBlock"
    [ testCase "positive: global variables, one VarDecl" $ do
        let stmts =
              [ mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "variables")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock GlobalVars [VarDecl [] "string" "s_name"])

    , testCase "positive: shared variables, scope is TypeVars" $ do
        let stmts =
              [ mkStmt [(TkAccessModifier, "shared"), (TkDeclKw, "variables")]
              , mkStmt [(TkDatatype, "integer"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock TypeVars [VarDecl [] "integer" "i_count"])

    , testCase "positive: type variables, two VarDecls" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
              , mkStmt [(TkAccessModifier, "public"), (TkDatatype, "integer"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock TypeVars [ VarDecl [] "string" "s_name"
                                         , VarDecl ["public"] "integer" "i_count"
                                         ])

    , testCase "positive: empty variables block" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "variables")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?= Right (VariablesBlock TypeVars [])

    , testCase "negative: missing end variables" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "variables")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
              ]
        case runSection pVariablesBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end variables' is missing"

    , testProperty "variable names non-empty"
        prop_varDecl_names_nonempty
    ]

  , testGroup "pPrototypesBlock"
    [ testCase "positive: function prototype" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "getCount")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoFn (FnSig [] "integer" "getCount" "" Nothing)])

    , testCase "positive: subroutine prototype" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkDeclKw, "subroutine"), (TkIdent, "doSomething")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoSub (SubSig [] "doSomething" "" Nothing)])

    , testCase "positive: forward prototypes opener" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward prototypes")]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?= Right (PrototypesBlock [])

    , testCase "negative: unclosed prototypes" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "getCount")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              ]
        case runSection pPrototypesBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end prototypes' is missing"

    , testCase "positive: external function prototype" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkDeclKw, "external"), (TkDeclKw, "function")
                       , (TkDatatype, "integer"), (TkIdent, "getCount")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoFn (FnSig ["external"] "integer" "getCount" "" Nothing)])

    , testCase "positive: rpcfunc subroutine prototype" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkOtherKw, "rpcfunc"), (TkDeclKw, "subroutine")
                       , (TkIdent, "doRemote")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoSub (SubSig ["rpcfunc"] "doRemote" "" Nothing)])

    , testCase "positive: intrinsic function prototype" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkDeclKw, "intrinsic"), (TkDeclKw, "function")
                       , (TkDatatype, "string"), (TkIdent, "getName")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoFn (FnSig ["intrinsic"] "string" "getName" "" Nothing)])
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

prop_varDecl_names_nonempty :: Property
prop_varDecl_names_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  typ  <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmt = mkStmt
        [ (TkDatatype, typ)
        , (TkIdent,    name)
        ]
  case runSection pVarDecl [stmt] of
    Right vd -> assert (not (T.null (vdName vd)))
    Left _   -> pure ()

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
