module FileTest (tests) where

import PB.Prelude
import PB.Grammar.File        ( pForwardBlock, pPrototypesBlock, pVariablesBlock, pTypeDecl, pVarDecl
                              , pGlobalInstance
                              , pTypeBlock, pStructureBlock, pOnBlock, pEventBlock, pFunctionBlock, pSubroutineBlock
                              , parseSrFile
                              , parseParamsAndThrows
                              )
import PB.Grammar.Stream      (FileParser, StmtStream (..))
import PB.AST.SourceFile      ( ForwardBlock (..), PrototypesBlock (..), ProtoDecl (..)
                              , TypeDecl (..), TypeBlock (..), StructureBlock (..), mkTypeDecl
                              , VariablesBlock (..), VarScope (..), VarDecl (..)
                              , GlobalInstance (..)
                              , Param (..)
                              , FnSig (..), SubSig (..), EventSig (..)
                              , FunctionBlock (..), SubroutineBlock (..), EventBlock (..), OnBlock (..)
                              , SrFile (..)
                              )
import PB.AST.BodyStmt        (BodyStmt (..))
import PB.AST.Expr            (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident           (identOrig, identSpan, IdentProvenance (..))
import PB.AST.Located         (Located (..))
import PB.AST.Type            (PbType (..))
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (mkLogicalLine)

import Data.List                (nub)
import Hedgehog (Gen, Property, forAll, property, assert, failure, footnote, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)
import Text.Megaparsec (parse)
import Text.Megaparsec.Error (errorBundlePretty)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Helpers

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1 1)

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens    = map (uncurry mkTok) pairs
  , stmtSource    = mkLogicalLine "" 1
  , stmtTerminated = False
  }

runSection :: FileParser a -> [Statement] -> Either String a
runSection p stmts = case parse p "" (StmtStream stmts) of
  Right x  -> Right x
  Left err -> Left (errorBundlePretty err)

loc1 :: a -> Located a
loc1 = Located 1

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Grammar.File"
  [ testGroup "pForwardBlock"
    [ testCase "positive: one TypeDecl" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [mkTypeDecl "w_foo" "window" Nothing] [])

    , testCase "positive: two TypeDecls" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "d_bar"), (TkDeclKw, "from"), (TkIdent, "datawindow")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [ mkTypeDecl "w_foo" "window" Nothing
                              , mkTypeDecl "d_bar" "datawindow" Nothing
                              ] [])

    , testCase "positive: empty forward block" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?= Right (ForwardBlock [] [])

    , testCase "positive: TypeDecl with within clause" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [ (TkDeclKw, "type"), (TkIdent, "w_sub"), (TkDeclKw, "from")
                       , (TkIdent, "window"), (TkDeclKw, "within"), (TkIdent, "w_main")
                       ]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [mkTypeDecl "w_sub" "window" (Just "w_main")] [])

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

    , testCase "positive: full type…end type pair inside forward" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "type"), (TkIdent, "u_foo"), (TkDeclKw, "from"), (TkIdent, "userobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [mkTypeDecl "u_foo" "userobject" Nothing] [])

    , testCase "positive: two full type blocks inside forward" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "type"), (TkIdent, "u_foo"), (TkDeclKw, "from"), (TkIdent, "userobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "type"), (TkIdent, "u_bar"), (TkDeclKw, "from"), (TkIdent, "nonvisualobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [ mkTypeDecl "u_foo" "userobject" Nothing
                              , mkTypeDecl "u_bar" "nonvisualobject" Nothing
                              ] [])

    , testCase "positive: global instance declarations inside forward" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "type"), (TkIdent, "app"), (TkDeclKw, "from"), (TkIdent, "application")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkAccessModifier, "global"), (TkIdent, "transaction"), (TkIdent, "sqlca")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [mkTypeDecl "app" "application" Nothing]
                              [GlobalInstance "transaction" (SourceSpan 1 1 1 1) "sqlca"])

    , testCase "positive: type with body vars inside forward (w_misth_ypal_form pattern)" $ do
        let varStmt = mkStmt [(TkIdent, "uo_yvar"), (TkIdent, "uo_yvar")]
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "page3"), (TkDeclKw, "from"), (TkIdent, "userobject"), (TkDeclKw, "within"), (TkIdent, "tab1")]
              , varStmt
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [mkTypeDecl "page3" "userobject" (Just "tab1")] [])

    , testCase "positive: mixed bare and full type entries now both require end type" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "type"), (TkIdent, "u_bar"), (TkDeclKw, "from"), (TkIdent, "userobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
        runSection pForwardBlock stmts @?=
          Right (ForwardBlock [ mkTypeDecl "w_foo" "window" Nothing
                              , mkTypeDecl "u_bar" "userobject" Nothing
                              ] [])

    , testProperty "all TypeDecl names are non-empty"
        prop_typeDecl_names_nonempty
    ]

  , testGroup "pVarDecl"
    [ testCase "simple: string s_name" $ do
        let stmt = mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
        runSection pVarDecl [stmt] @?= Right [VarDecl [] "string" (SourceSpan 1 1 1 1) "s_name"]

    , testCase "with modifier: public integer i_count" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "public")
              , (TkDatatype,       "integer")
              , (TkIdent,          "i_count")
              ]
        runSection pVarDecl [stmt] @?= Right [VarDecl ["public"] "integer" (SourceSpan 1 1 1 1) "i_count"]

    , testCase "comma-separated: string s_name, s_other expands to two VarDecls" $ do
        let stmt = mkStmt
              [ (TkDatatype, "string"), (TkIdent, "s_name")
              , (TkComma, ","), (TkIdent, "s_other")
              ]
        runSection pVarDecl [stmt]
          @?= Right [VarDecl [] "string" (SourceSpan 1 1 1 1) "s_name", VarDecl [] "string" (SourceSpan 1 1 1 1) "s_other"]

    , testProperty "comma-separated: one VarDecl per name, order preserved"
        prop_varDecl_comma_names_preserved

    , testProperty "comma-separated: count matches comma count in the statement's own tokens"
        prop_varDecl_comma_count

    , testCase "negative: keyword as type name is rejected" $ do
        let stmt = mkStmt [(TkDeclKw, "function"), (TkIdent, "i_count")]
        case runSection pVarDecl [stmt] of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when keyword is used as type name"

    , testCase "case-insensitive equality: differently-cased names parse equal (Ident)" $ do
        let stmt1 = mkStmt [(TkDatatype, "string"), (TkIdent, "S_Name")]
            stmt2 = mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
        case (runSection pVarDecl [stmt1], runSection pVarDecl [stmt2]) of
          (Right [vd1], Right [vd2]) -> vdName vd1 @?= vdName vd2
          _                          -> assertFailure "expected both parses to succeed"
    ]

  , testGroup "pGlobalInstance"
    [ testCase "positive: global u_foo u_foo (same type and name)" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "global")
              , (TkIdent,          "u_foo")
              , (TkIdent,          "u_foo")
              ]
        runSection pGlobalInstance [stmt] @?=
          Right (GlobalInstance "u_foo" (SourceSpan 1 1 1 1) "u_foo")

    , testCase "positive: type name differs from instance name" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "global")
              , (TkIdent,          "u_base")
              , (TkIdent,          "u_derived_inst")
              ]
        runSection pGlobalInstance [stmt] @?=
          Right (GlobalInstance "u_base" (SourceSpan 1 1 1 1) "u_derived_inst")

    , testCase "negative: global type X from Y is not a global instance" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "global")
              , (TkDeclKw,         "type")
              , (TkIdent,          "u_foo")
              , (TkDeclKw,         "from")
              , (TkIdent,          "nonvisualobject")
              ]
        case runSection pGlobalInstance [stmt] of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure: global type declaration is not a global instance"

    , testCase "negative: global variables opener is not a global instance" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "global")
              , (TkDeclKw,         "variables")
              ]
        case runSection pGlobalInstance [stmt] of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure: global variables opener is not a global instance"

    , testCase "negative: bare identifier pair without global is not a global instance" $ do
        let stmt = mkStmt [(TkIdent, "u_foo"), (TkIdent, "u_foo")]
        case runSection pGlobalInstance [stmt] of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure: missing global modifier"

    , testProperty "giType and giName are non-empty after successful parse"
        prop_globalInstance_nonempty

    , testCase "case-insensitive equality: differently-cased instance names parse equal (Ident)" $ do
        let stmt1 = mkStmt
              [ (TkAccessModifier, "global"), (TkIdent, "u_foo"), (TkIdent, "U_Bar") ]
            stmt2 = mkStmt
              [ (TkAccessModifier, "global"), (TkIdent, "u_foo"), (TkIdent, "u_bar") ]
        case (runSection pGlobalInstance [stmt1], runSection pGlobalInstance [stmt2]) of
          (Right gi1, Right gi2) -> giName gi1 @?= giName gi2
          _                      -> assertFailure "expected both parses to succeed"
    ]

  , testGroup "pVariablesBlock"
    [ testCase "positive: global variables, one VarDecl" $ do
        let stmts =
              [ mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "variables")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock GlobalVars [VarDecl [] "string" (SourceSpan 1 1 1 1) "s_name"])

    , testCase "positive: shared variables, scope is TypeVars" $ do
        let stmts =
              [ mkStmt [(TkAccessModifier, "shared"), (TkDeclKw, "variables")]
              , mkStmt [(TkDatatype, "integer"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock TypeVars [VarDecl [] "integer" (SourceSpan 1 1 1 1) "i_count"])

    , testCase "positive: type variables, two VarDecls" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "s_name")]
              , mkStmt [(TkAccessModifier, "public"), (TkDatatype, "integer"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock TypeVars [ VarDecl [] "string" (SourceSpan 1 1 1 1) "s_name"
                                         , VarDecl ["public"] "integer" (SourceSpan 1 1 1 1) "i_count"
                                         ])

    , testCase "positive: type variables, comma-separated decl expands in place" $ do
        -- A single "string s_name, s_other" statement must expand into one
        -- VarDecl per name -- buildVarDecls shares the comma-split with
        -- local variable declarations, so a variables block gets it too.
        let stmts =
              [ mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [ (TkDatatype, "string"), (TkIdent, "s_name")
                       , (TkComma, ","), (TkIdent, "s_other") ]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        runSection pVariablesBlock stmts @?=
          Right (VariablesBlock TypeVars [ VarDecl [] "string" (SourceSpan 1 1 1 1) "s_name"
                                         , VarDecl [] "string" (SourceSpan 1 1 1 1) "s_other"
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
          Right (PrototypesBlock [ProtoFn (FnSig [] "integer" (SourceSpan 1 1 1 1) "getCount" [] Nothing Nothing Nothing)])

    , testCase "positive: subroutine prototype" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [ (TkDeclKw, "subroutine"), (TkIdent, "doSomething")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoSub (SubSig [] "doSomething" [] Nothing Nothing Nothing)])

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
          Right (PrototypesBlock [ProtoFn (FnSig ["external"] "integer" (SourceSpan 1 1 1 1) "getCount" [] Nothing Nothing Nothing)])

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
          Right (PrototypesBlock [ProtoSub (SubSig ["rpcfunc"] "doRemote" [] Nothing Nothing Nothing)])

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
          Right (PrototypesBlock [ProtoFn (FnSig ["intrinsic"] "string" (SourceSpan 1 1 1 1) "getName" [] Nothing Nothing Nothing)])

    , testCase "positive: public: header before function is skipped (.srx pattern)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward prototypes")]
              , mkStmt [(TkLabel, "public:")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "long"), (TkIdent, "SetConnect")
                       , (TkLParen, "("), (TkIdent, "connection"), (TkIdent, "theConn"), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock [ProtoFn (FnSig [] "long" (SourceSpan 1 1 1 1) "SetConnect" [Param [] "connection" (SourceSpan 1 1 1 1) "theConn"] Nothing Nothing Nothing)])

    , testCase "positive: interleaved public: protected: headers all skipped" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward prototypes")]
              , mkStmt [(TkLabel, "public:")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f1")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkLabel, "protected:")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f2")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?=
          Right (PrototypesBlock
            [ ProtoFn (FnSig [] "integer" (SourceSpan 1 1 1 1) "f1" [] Nothing Nothing Nothing)
            , ProtoFn (FnSig [] "integer" (SourceSpan 1 1 1 1) "f2" [] Nothing Nothing Nothing)
            ])

    , testCase "positive: only access-modifier headers yields empty decl list" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward prototypes")]
              , mkStmt [(TkLabel, "public:")]
              , mkStmt [(TkLabel, "private:")]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        runSection pPrototypesBlock stmts @?= Right (PrototypesBlock [])
    ]

  , testGroup "parseParamsAndThrows"
    [ testCase "empty parens: no params, no throws" $
        parseParamsAndThrows [mkTok TkRParen ")"] @?= ([], Nothing, Nothing, Nothing)

    , testCase "single param: long al_row" $
        parseParamsAndThrows [mkTok TkDatatype "long", mkTok TkIdent "al_row", mkTok TkRParen ")"]
          @?= ([Param [] "long" (SourceSpan 1 1 1 1) "al_row"], Nothing, Nothing, Nothing)

    , testCase "ref modifier stripped: ref datawindow adw" $
        parseParamsAndThrows
          [ mkTok TkStorageModifier "ref", mkTok TkDatatype "datawindow", mkTok TkIdent "adw"
          , mkTok TkRParen ")"
          ]
          @?= ([Param ["ref"] "datawindow" (SourceSpan 1 1 1 1) "adw"], Nothing, Nothing, Nothing)

    , testCase "two params split on top-level comma" $
        parseParamsAndThrows
          [ mkTok TkDatatype "long", mkTok TkIdent "al_row", mkTok TkComma ","
          , mkTok TkDatatype "string", mkTok TkIdent "as_name", mkTok TkRParen ")"
          ]
          @?= ( [ Param [] "long" (SourceSpan 1 1 1 1) "al_row"
                , Param [] "string" (SourceSpan 1 1 1 1) "as_name"
                ]
              , Nothing, Nothing, Nothing )

    , testCase "readonly modifier stripped" $
        parseParamsAndThrows
          [mkTok TkStorageModifier "readonly", mkTok TkDatatype "string", mkTok TkIdent "as_x", mkTok TkRParen ")"]
          @?= ([Param ["readonly"] "string" (SourceSpan 1 1 1 1) "as_x"], Nothing, Nothing, Nothing)

    , testCase "array-bracket param name: readonly string aarray[] -- real token split, no string-hack needed" $
        parseParamsAndThrows
          [ mkTok TkStorageModifier "readonly", mkTok TkDatatype "string", mkTok TkIdent "aarray"
          , mkTok TkLBracket "[", mkTok TkRBracket "]", mkTok TkRParen ")"
          ]
          @?= ([Param ["readonly"] "string" (SourceSpan 1 1 1 1) "aarray"], Nothing, Nothing, Nothing)

    , testCase "array-bracket param alongside a normal param" $
        parseParamsAndThrows
          [ mkTok TkStorageModifier "readonly", mkTok TkDatatype "string", mkTok TkIdent "aarray"
          , mkTok TkLBracket "[", mkTok TkRBracket "]", mkTok TkComma ","
          , mkTok TkDatatype "string", mkTok TkIdent "astr", mkTok TkRParen ")"
          ]
          @?= ( [ Param ["readonly"] "string" (SourceSpan 1 1 1 1) "aarray"
                , Param [] "string" (SourceSpan 1 1 1 1) "astr"
                ]
              , Nothing, Nothing, Nothing )

    , testCase "throws clause captured after the closing paren" $
        parseParamsAndThrows [mkTok TkRParen ")", mkTok TkDeclKw "throws", mkTok TkIdent "SomeError"]
          @?= ([], Just "SomeError", Nothing, Nothing)

    , testCase "parameter name Ident carries a real FromSource span, not Synthetic" $
        case parseParamsAndThrows [mkTok TkDatatype "long", mkTok TkIdent "al_row", mkTok TkRParen ")"] of
          ([p], _, _, _) -> case identSpan (paramName p) of
            FromSource _ -> pure ()
            Synthetic _  -> assertFailure "expected a real FromSource span, got Synthetic"
          (ps, _, _, _) -> assertFailure ("expected exactly 1 param, got " ++ show (length ps))

    , testCase "library and alias for captured after the closing paren" $
        parseParamsAndThrows
          [ mkTok TkRParen ")"
          , mkTok TkDeclKw "library", mkTok TkStringDouble "\"mathparser.dll\""
          , mkTok TkDeclKw "alias", mkTok TkControlKw "for", mkTok TkStringDouble "\"cfn_mathparserA\""
          ]
          @?= ([], Nothing, Just "mathparser.dll", Just "cfn_mathparserA")

    , testCase "library without alias for" $
        parseParamsAndThrows
          [ mkTok TkRParen ")"
          , mkTok TkDeclKw "library", mkTok TkStringDouble "\"somelib.dll\""
          ]
          @?= ([], Nothing, Just "somelib.dll", Nothing)

    , testCase "library with throws" $
        parseParamsAndThrows
          [ mkTok TkRParen ")"
          , mkTok TkDeclKw "throws", mkTok TkIdent "SomeError"
          , mkTok TkDeclKw "library", mkTok TkStringDouble "\"somelib.dll\""
          ]
          @?= ([], Just "SomeError", Just "somelib.dll", Nothing)

    , testCase "malformed library with no following string literal" $
        parseParamsAndThrows
          [ mkTok TkRParen ")"
          , mkTok TkDeclKw "library"
          ]
          @?= ([], Nothing, Nothing, Nothing)
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
          Right (mkTypeDecl "w_mywindow" "window" Nothing)

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
          Right (mkTypeDecl "w_mywindow" "window" (Just "w_main"))

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

  , testGroup "pTypeBlock"
    [ testCase "positive: type Name from Ancestor, empty body" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (mkTypeDecl "w_foo" "window" Nothing) [])

    , testCase "positive: type Name from Ancestor within Container" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "type"), (TkIdent, "w_sub"), (TkDeclKw, "from")
                       , (TkIdent, "window"), (TkDeclKw, "within"), (TkIdent, "w_main")
                       ]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (mkTypeDecl "w_sub" "window" (Just "w_main")) [])

    , testCase "positive: type block collects body statements" $ do
        let s1 = mkStmt [(TkDatatype, "integer"), (TkIdent, "i_count")]
            s2 = mkStmt [(TkDatatype, "string"),  (TkIdent, "s_name")]
            stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , s1, s2
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (mkTypeDecl "w_foo" "window" Nothing)
                   [loc1 (BsLocalVar [] (PtPrimitive "integer") "i_count" Nothing), loc1 (BsLocalVar [] (PtPrimitive "string") "s_name" Nothing)])

    , testCase "positive: type block with event decl in body" $ do
        let evStmt    = mkStmt [(TkDeclKw, "event"), (TkIdent, "ie_checkbuttons"), (TkLParen, "("), (TkRParen, ")")]
            childStmt = mkStmt [(TkIdent, "cb_delete"), (TkIdent, "cb_delete")]
            stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , evStmt, childStmt
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (mkTypeDecl "w_foo" "window" Nothing)
                   [loc1 (BsRaw ""), loc1 (BsLocalVar [] (PtUserDefined "cb_delete") "cb_delete" Nothing)])

    , testCase "negative: missing end type" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              ]
        case runSection pTypeBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end type' is missing"

    , testProperty "tbAncestor always non-empty" prop_typeBlock_ancestor_nonempty
    ]

  , testGroup "pStructureBlock"
    [ testCase "positive: type Name from structure, field list" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "os_data"), (TkDeclKw, "from"), (TkIdent, "structure")]
              , mkStmt [(TkDatatype, "long"),   (TkIdent, "i_count")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "s_string_data")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pStructureBlock stmts @?=
          Right (StructureBlock "os_data"
                   [ VarDecl [] "long"   (SourceSpan 1 1 1 1) "i_count"
                   , VarDecl [] "string" (SourceSpan 1 1 1 1) "s_string_data"
                   ])

    , testCase "positive: case-insensitive ancestor (Structure)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "os_data"), (TkDeclKw, "from"), (TkIdent, "Structure")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pStructureBlock stmts @?= Right (StructureBlock "os_data" [])

    , testCase "positive: empty structure body" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "os_empty"), (TkDeclKw, "from"), (TkIdent, "structure")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pStructureBlock stmts @?= Right (StructureBlock "os_empty" [])

    , testCase "negative: non-structure ancestor is rejected" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        case runSection pStructureBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected pStructureBlock to reject a non-structure ancestor"

    , testCase "negative: missing end type" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "os_data"), (TkDeclKw, "from"), (TkIdent, "structure")]
              ]
        case runSection pStructureBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end type' is missing"
    ]

  , testGroup "pOnBlock"
    [ testCase "positive: on w_main.create" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkIdent, "w_main"), (TkDot, "."), (TkIdent, "create")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "w_main.create" "w_main" "create" [])

    , testCase "positive: on w_main.destroy, body with statements" $ do
        let bodyStmt = mkStmt [(TkIdent, "i"), (TkAssignOp, "="), (TkIntLiteral, "0")]
            stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkIdent, "w_main"), (TkDot, "."), (TkIdent, "destroy")]
              , bodyStmt
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "w_main.destroy" "w_main" "destroy"
                   [loc1 (BsAssign (Lvalue [LvSegment "i" Nothing]) (ExInt "0"))])

    , testCase "positive: bare on modified (ident event name)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkIdent, "modified")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "modified" "modified" "modified" [])

    , testCase "positive: bare on close (OtherKw event name)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkOtherKw, "close")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "close" "close" "close" [])

    , testCase "positive: bare on char (Datatype event name)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkDatatype, "char")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "char" "char" "char" [])

    , testCase "positive: bare on ue_keypress with body" $ do
        let bodyStmt = mkStmt [(TkIdent, "call"), (TkIdent, "super")]
            stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkIdent, "ue_keypress")]
              , bodyStmt
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "ue_keypress" "ue_keypress" "ue_keypress"
                   [loc1 (BsLocalVar [] (PtUserDefined "call") "super" Nothing)])

    , testCase "negative: on alone (no event name)" $ do
        let stmts = [mkStmt [(TkDeclKw, "on")]]
        case runSection pOnBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when on has no event name"

    , testCase "negative: missing end on" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkIdent, "w_main"), (TkDot, "."), (TkIdent, "create")]
              ]
        case runSection pOnBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end on' is missing"

    , testProperty "obEvent non-empty" prop_onBlock_event_nonempty
    ]

  , testGroup "pEventBlock"
    [ testCase "positive: event ue_custom" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "event"), (TkIdent, "ue_custom")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        runSection pEventBlock stmts @?=
          Right (EventBlock (EventSig "ue_custom" []) Nothing [])

    , testCase "positive: event with params" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "event"), (TkIdent, "ue_custom")
                       , (TkLParen, "("), (TkDatatype, "integer"), (TkIdent, "al_value"), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        runSection pEventBlock stmts @?=
          Right (EventBlock (EventSig "ue_custom" [Param [] "integer" (SourceSpan 1 1 1 1) "al_value"]) Nothing [])

    , testCase "positive: system event with a message-ID name (no parens) has no params, not a garbage parse" $ do
        -- Corpus shape: `event ue_keypress pbm_char` -- pbm_char is a Windows
        -- message ID, not a parenthesized param list. Before this fix, a
        -- non-parenthesized remainder was joined into one opaque rawSig text
        -- and blindly re-parsed elsewhere as if it were always a param list.
        let stmts =
              [ mkStmt [(TkDeclKw, "event"), (TkIdent, "ue_keypress"), (TkOtherKw, "pbm_char")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        runSection pEventBlock stmts @?=
          Right (EventBlock (EventSig "ue_keypress" []) Nothing [])

    , testCase "negative: missing end event" $ do
        let stmts = [mkStmt [(TkDeclKw, "event"), (TkIdent, "ue_custom")]]
        case runSection pEventBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end event' is missing"

    , testCase "case-insensitive equality: differently-cased event names parse equal (Ident)" $ do
        let stmts1 =
              [ mkStmt [(TkDeclKw, "event"), (TkIdent, "UE_Custom")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
            stmts2 =
              [ mkStmt [(TkDeclKw, "event"), (TkIdent, "ue_custom")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case (runSection pEventBlock stmts1, runSection pEventBlock stmts2) of
          (Right eb1, Right eb2) -> esName (evSig eb1) @?= esName (evSig eb2)
          _                      -> assertFailure "expected both parses to succeed"
    ]

  , testGroup "Grammar.File.EventOwnership"
    [ testCase "event after global type block gets window as owner" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Just "w_foo"]

    , testCase "event after control type block gets control as owner" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [ (TkDeclKw, "type"), (TkIdent, "cb_ok"), (TkDeclKw, "from")
                       , (TkIdent, "commandbutton"), (TkDeclKw, "within"), (TkIdent, "w_foo") ]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "clicked")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Just "cb_ok"]

    , testCase "two consecutive controls each own their event" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end event")]
              , mkStmt [ (TkDeclKw, "type"), (TkIdent, "cb_a"), (TkDeclKw, "from")
                       , (TkIdent, "commandbutton"), (TkDeclKw, "within"), (TkIdent, "w_foo") ]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "clicked")]
              , mkStmt [(TkDeclKw, "end event")]
              , mkStmt [ (TkDeclKw, "type"), (TkIdent, "cb_b"), (TkDeclKw, "from")
                       , (TkIdent, "commandbutton"), (TkDeclKw, "within"), (TkIdent, "w_foo") ]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "clicked")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Just "w_foo", Just "cb_a", Just "cb_b"]

    , testCase "event before any type block gets Nothing" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "event"), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Nothing]

    , testCase "a structure block between a type block and an event does not become its owner" $ do
        -- TLStructure isn't a TypeBlock, so resolveEventOwners' context
        -- tracker must leave it alone -- the event still attributes to the
        -- window, not the structure.
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "os_data"), (TkDeclKw, "from"), (TkIdent, "structure")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Just "w_foo"]

    , testCase "on block does not update owner context" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "on"), (TkIdent, "w_foo"), (TkDot, "."), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end on")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Just "w_foo"]

    , testCase "function block does not update owner context" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_get")
                       , (TkLParen, "("), (TkRParen, ")") ]
              , mkStmt [(TkDeclKw, "end function")]
              , mkStmt [(TkDeclKw, "event"), (TkIdent, "open")]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        case parseSrFile [] stmts of
          Left err -> assertFailure (T.unpack err)
          Right sf -> map evOwner (srEvents sf) @?= [Just "w_foo"]
    ]

  , testGroup "pFunctionBlock"
    [ testCase "positive: public function integer f_compute()" $ do
        let stmts =
              [ mkStmt [ (TkAccessModifier, "public"), (TkDeclKw, "function")
                       , (TkDatatype, "integer"), (TkIdent, "f_compute")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        runSection pFunctionBlock stmts @?=
          Right (FunctionBlock (FnSig ["public"] "integer" (SourceSpan 1 1 1 1) "f_compute" [] Nothing Nothing Nothing) [])

    , testCase "positive: private function string f_name() throws SomeError" $ do
        let stmts =
              [ mkStmt [ (TkAccessModifier, "private"), (TkDeclKw, "function")
                       , (TkDatatype, "string"), (TkIdent, "f_name")
                       , (TkLParen, "("), (TkRParen, ")")
                       , (TkDeclKw, "throws"), (TkIdent, "SomeError")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        runSection pFunctionBlock stmts @?=
          Right (FunctionBlock (FnSig ["private"] "string" (SourceSpan 1 1 1 1) "f_name" [] (Just "SomeError") Nothing Nothing) [])

    , testCase "positive: body with nested if statements" $ do
        let ifStmt    = mkStmt [(TkControlKw, "if")]
            endIfStmt = mkStmt [(TkControlKw, "end if")]
            stmts =
              [ mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_nested")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , ifStmt
              , endIfStmt
              , mkStmt [(TkDeclKw, "end function")]
              ]
        runSection pFunctionBlock stmts @?=
          Right (FunctionBlock (FnSig [] "integer" (SourceSpan 1 1 1 1) "f_nested" [] Nothing Nothing Nothing)
                   [loc1 (BsRaw ""), loc1 (BsRaw "")])

    , testCase "negative: missing end function" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_compute")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              ]
        case runSection pFunctionBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end function' is missing"

    , testCase "positive: function name with trailing dot before paren (corpus: uf_fn.)" $ do
        let stmts =
              [ mkStmt [ (TkAccessModifier, "public"), (TkDeclKw, "function")
                       , (TkDatatype, "boolean"), (TkIdent, "uf_zz_import_results")
                       , (TkDot, "."), (TkLParen, "(")
                       , (TkStorageModifier, "ref"), (TkDatatype, "boolean"), (TkIdent, "results_imported")
                       , (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        runSection pFunctionBlock stmts @?=
          Right (FunctionBlock (FnSig ["public"] "boolean" (SourceSpan 1 1 1 1) "uf_zz_import_results"
                                      [Param ["ref"] "boolean" (SourceSpan 1 1 1 1) "results_imported"] Nothing Nothing Nothing) [])

    , testCase "negative: external function not parsed as body block" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "external"), (TkDeclKw, "function")
                       , (TkDatatype, "integer"), (TkIdent, "getCount")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              ]
        case runSection pFunctionBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure: external function has no body"

    , testProperty "fnsName non-empty" prop_fnBlock_name_nonempty

    , testCase "case-insensitive equality: differently-cased function names parse equal (Ident)" $ do
        let stmts1 =
              [ mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "F_Compute")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
            stmts2 =
              [ mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_compute")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        case (runSection pFunctionBlock stmts1, runSection pFunctionBlock stmts2) of
          (Right fb1, Right fb2) -> fnsName (fbSig fb1) @?= fnsName (fbSig fb2)
          _                      -> assertFailure "expected both parses to succeed"
    ]

  , testGroup "pSubroutineBlock"
    [ testCase "positive: subroutine of_setup()" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, "of_setup"), (TkLParen, "("), (TkRParen, ")")]
              , mkStmt [(TkDeclKw, "end subroutine")]
              ]
        runSection pSubroutineBlock stmts @?=
          Right (SubroutineBlock (SubSig [] "of_setup" [] Nothing Nothing Nothing) [])

    , testCase "negative: missing end subroutine" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, "of_setup"), (TkLParen, "("), (TkRParen, ")")]
              ]
        case runSection pSubroutineBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end subroutine' is missing"

    , testProperty "ssName non-empty" prop_subBlock_name_nonempty

    , testCase "case-insensitive equality: differently-cased subroutine names parse equal (Ident)" $ do
        let stmts1 =
              [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, "Of_Setup"), (TkLParen, "("), (TkRParen, ")")]
              , mkStmt [(TkDeclKw, "end subroutine")]
              ]
            stmts2 =
              [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, "of_setup"), (TkLParen, "("), (TkRParen, ")")]
              , mkStmt [(TkDeclKw, "end subroutine")]
              ]
        case (runSection pSubroutineBlock stmts1, runSection pSubroutineBlock stmts2) of
          (Right sb1, Right sb2) -> ssName (sbSig sb1) @?= ssName (sbSig sb2)
          _                      -> assertFailure "expected both parses to succeed"
    ]

  , testGroup "pSrFile (flexible ordering)"
    [ testCase "positive: TypeBlock before PrototypesBlock (.srf pattern)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "n_foo"), (TkDeclKw, "from"), (TkIdent, "nonvisualobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [(TkDeclKw, "end prototypes")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_run")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Nothing
            , srPrototypes      = Just (PrototypesBlock [])
            , srVariables       = []
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (mkTypeDecl "n_foo" "nonvisualobject" Nothing) []]
            , srStructureBlocks = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = [FunctionBlock (FnSig [] "integer" (SourceSpan 1 1 1 1) "f_run" [] Nothing Nothing Nothing) []]
            , srSubroutines     = []
            }
      -- Note: TypeBlock [] means empty body (no statements between header and end type)

    , testCase "positive: ForwardBlock then TypeBlock then VariablesBlock (.sru pattern)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "n_base"), (TkDeclKw, "from"), (TkIdent, "nonvisualobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "n_base"), (TkDeclKw, "from"), (TkIdent, "nonvisualobject")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, "integer"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              , mkStmt [(TkDeclKw, "prototypes")]
              , mkStmt [(TkDeclKw, "end prototypes")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Just (ForwardBlock [mkTypeDecl "n_base" "nonvisualobject" Nothing] [])
            , srPrototypes      = Just (PrototypesBlock [])
            , srVariables       = [VariablesBlock TypeVars [VarDecl [] "integer" (SourceSpan 1 1 1 1) "i_count"]]
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (mkTypeDecl "n_base" "nonvisualobject" Nothing) []]
            , srStructureBlocks = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = []
            , srSubroutines     = []
            }

    , testCase "positive: TypeBlocks interleaved with OnBlocks (.srw/.srm pattern)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "on"), (TkIdent, "w_foo"), (TkDot, "."), (TkIdent, "create")]
              , mkStmt [(TkDeclKw, "end on")]
              , mkStmt [ (TkDeclKw, "type"), (TkIdent, "cb_ok"), (TkDeclKw, "from"), (TkIdent, "commandbutton")
                       , (TkDeclKw, "within"), (TkIdent, "w_foo")
                       ]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "on"), (TkIdent, "cb_ok"), (TkDot, "."), (TkIdent, "clicked")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Nothing
            , srPrototypes      = Nothing
            , srVariables       = []
            , srGlobalInstances = []
            , srTypeBlocks      = [ TypeBlock (mkTypeDecl "w_foo" "window" Nothing) []
                                  , TypeBlock (mkTypeDecl "cb_ok" "commandbutton" (Just "w_foo")) []
                                  ]
            , srStructureBlocks = []
            , srOnBlocks        = [ OnBlock "w_foo.create" "w_foo" "create" []
                                  , OnBlock "cb_ok.clicked" "cb_ok" "clicked" []
                                  ]
            , srEvents          = []
            , srFunctions       = []
            , srSubroutines     = []
            }

    , testCase "positive: inline structure declared before the file's real TypeBlock (w_dw_copy.srw shape)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "os_data"), (TkDeclKw, "from"), (TkIdent, "structure")]
              , mkStmt [(TkDatatype, "long"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, "w_dw_copy"), (TkDeclKw, "from"), (TkIdent, "w_center")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Nothing
            , srPrototypes      = Nothing
            , srVariables       = []
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (mkTypeDecl "w_dw_copy" "w_center" Nothing) []]
            , srStructureBlocks = [StructureBlock "os_data" [VarDecl [] "long" (SourceSpan 1 1 1 1) "i_count"]]
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = []
            , srSubroutines     = []
            }

    , testCase "negative: unrecognised statement causes eof failure" $ do
        let stmts = [mkStmt [(TkIdent, "xyz")]]
        case parseSrFile [] stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure on unrecognised statement"

    , testProperty "forward+type vs type+forward: same srForward and srTypeBlocks"
        prop_flexible_forward_type_order

    , testProperty "at most one forward block extracted"
        prop_at_most_one_forward

    , testProperty "at most one prototypes block extracted"
        prop_at_most_one_prototypes

    , testProperty "single variables block parses"
        prop_single_variables_block_parses

    , testCase "two variables blocks (global + type) both survive, in order"
        unitTest_two_variables_blocks_both_survive
    ]

  , testGroup "parseSrFile (integration)"
    [ testCase "empty file" $
        parseSrFile [] [] @?=
          Right (SrFile [] Nothing Nothing [] [] [] [] [] [] [] [])

    , testCase "header + forward block + one function" $ do
        let headers = ["$PBExportHeader$foo.srf"]
            stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "end forward")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_run")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        parseSrFile headers stmts @?=
          Right SrFile
            { srHeaders         = headers
            , srForward         = Just (ForwardBlock [] [])
            , srPrototypes      = Nothing
            , srVariables       = []
            , srGlobalInstances = []
            , srTypeBlocks      = []
            , srStructureBlocks = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = [FunctionBlock (FnSig [] "integer" (SourceSpan 1 1 1 1) "f_run" [] Nothing Nothing Nothing) []]
            , srSubroutines     = []
            }

    , testCase "multiple functions in sequence" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, "f_one")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              , mkStmt [ (TkDeclKw, "function"), (TkDatatype, "string"), (TkIdent, "f_two")
                       , (TkLParen, "("), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end function")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Nothing
            , srPrototypes      = Nothing
            , srVariables       = []
            , srGlobalInstances = []
            , srTypeBlocks      = []
            , srStructureBlocks = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       =
                [ FunctionBlock (FnSig [] "integer" (SourceSpan 1 1 1 1) "f_one" [] Nothing Nothing Nothing) []
                , FunctionBlock (FnSig [] "string" (SourceSpan 1 1 1 1) "f_two" [] Nothing Nothing Nothing) []
                ]
            , srSubroutines     = []
            }

    , testCase "positive: forward block + global instance + variables (.sru pattern)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [ (TkAccessModifier, "global"), (TkDeclKw, "type"), (TkIdent, "u_svc")
                       , (TkDeclKw, "from"), (TkIdent, "nonvisualobject")
                       ]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              , mkStmt [(TkAccessModifier, "global"), (TkIdent, "u_svc"), (TkIdent, "u_svc")]
              , mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, "integer"), (TkIdent, "i_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Just (ForwardBlock [mkTypeDecl "u_svc" "nonvisualobject" Nothing] [])
            , srPrototypes      = Nothing
            , srVariables       = [VariablesBlock TypeVars [VarDecl [] "integer" (SourceSpan 1 1 1 1) "i_count"]]
            , srGlobalInstances = [GlobalInstance "u_svc" (SourceSpan 1 1 1 1) "u_svc"]
            , srTypeBlocks      = []
            , srStructureBlocks = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = []
            , srSubroutines     = []
            }

    , testCase "positive: two global instances are both collected" $ do
        let stmts =
              [ mkStmt [(TkAccessModifier, "global"), (TkIdent, "u_foo"), (TkIdent, "u_foo")]
              , mkStmt [(TkAccessModifier, "global"), (TkIdent, "u_bar"), (TkIdent, "u_bar")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Nothing
            , srPrototypes      = Nothing
            , srVariables       = []
            , srGlobalInstances = [GlobalInstance "u_foo" (SourceSpan 1 1 1 1) "u_foo", GlobalInstance "u_bar" (SourceSpan 1 1 1 1) "u_bar"]
            , srTypeBlocks      = []
            , srStructureBlocks = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = []
            , srSubroutines     = []
            }

    , testCase "real-world snippet: global type + on block" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_main"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "on"), (TkIdent, "w_main"), (TkDot, "."), (TkIdent, "create")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        parseSrFile [] stmts @?=
          Right SrFile
            { srHeaders         = []
            , srForward         = Nothing
            , srPrototypes      = Nothing
            , srVariables       = []
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (mkTypeDecl "w_main" "window" Nothing) []]
            , srStructureBlocks = []
            , srOnBlocks        = [OnBlock "w_main.create" "w_main" "create" []]
            , srEvents          = []
            , srFunctions       = []
            , srSubroutines     = []
            }
    ]
  ]

-- ---------------------------------------------------------------------------
-- Properties

prop_globalInstance_nonempty :: Property
prop_globalInstance_nonempty = property $ do
  typName  <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  instName <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmt = mkStmt
        [ (TkAccessModifier, "global")
        , (TkIdent,          typName)
        , (TkIdent,          instName)
        ]
  case runSection pGlobalInstance [stmt] of
    Right gi -> do
      assert (not (T.null (giType gi)))
      assert (not (T.null (identOrig (giName gi))))
    Left _ -> pure ()

prop_varDecl_names_nonempty :: Property
prop_varDecl_names_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  typ  <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmt = mkStmt
        [ (TkDatatype, typ)
        , (TkIdent,    name)
        ]
  case runSection pVarDecl [stmt] of
    Right vds -> assert (all (not . T.null . identOrig . vdName) vds)
    Left _    -> pure ()

-- | 2-4 distinct names for a comma-separated declarator list. Deduped with
-- 'nub' (order-preserving), not a Set-based dedup -- the properties below
-- assert the input name order survives the round trip.
genVarDeclNames :: Gen [Text]
genVarDeclNames =
  Gen.filter ((>= 2) . length) (nub <$> Gen.list (Range.linear 2 4) genVarDeclNamePool)
  where
    genVarDeclNamePool = Gen.element ["s_name", "s_other", "i_count", "ls_val", "lb_flag"]

-- | Tokens for `<datatype> name1, name2, ...` -- the comma-truncation shape
-- 'PB.Grammar.File.buildVarDecls' splits.
mkCommaVarDeclTokens :: [Text] -> [(TokenKind, Text)]
mkCommaVarDeclTokens names = (TkDatatype, "string") : go names
  where
    go []       = []
    go [n]      = [(TkIdent, n)]
    go (n : ns) = (TkIdent, n) : (TkComma, ",") : go ns

prop_varDecl_comma_names_preserved :: Property
prop_varDecl_comma_names_preserved = property $ do
  names <- forAll genVarDeclNames
  let stmt = mkStmt (mkCommaVarDeclTokens names)
  case runSection pVarDecl [stmt] of
    Right vds -> map (identOrig . vdName) vds === names
    Left err  -> footnote err >> failure

-- | Comma count is read back from the generated statement's own tokens
-- (not the generator's 'names' list length) so this checks the parser's
-- behaviour on its actual input, not just the generator's arithmetic.
prop_varDecl_comma_count :: Property
prop_varDecl_comma_count = property $ do
  names <- forAll genVarDeclNames
  let stmt   = mkStmt (mkCommaVarDeclTokens names)
      commas = length (filter ((== TkComma) . tkKind) (stmtTokens stmt))
  case runSection pVarDecl [stmt] of
    Right vds -> length vds === commas + 1
    Left err  -> footnote err >> failure

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
    Right td -> assert (not (T.null (identOrig (tdName td))))
    Left _   -> pure ()

prop_typeBlock_ancestor_nonempty :: Property
prop_typeBlock_ancestor_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  anc  <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmts =
        [ mkStmt [(TkDeclKw, "type"), (TkIdent, name), (TkDeclKw, "from"), (TkIdent, anc)]
        , mkStmt [(TkDeclKw, "end type")]
        ]
  case runSection pTypeBlock stmts of
    Right tb -> assert (not (T.null (tdAncestor (tbDecl tb))))
    Left _   -> pure ()

prop_onBlock_event_nonempty :: Property
prop_onBlock_event_nonempty = property $ do
  owner <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  event <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  let stmts =
        [ mkStmt [(TkDeclKw, "on"), (TkIdent, owner), (TkDot, "."), (TkIdent, event)]
        , mkStmt [(TkDeclKw, "end on")]
        ]
  case runSection pOnBlock stmts of
    Right ob -> assert (not (T.null (identOrig (obEvent ob))))
    Left _   -> pure ()

prop_fnBlock_name_nonempty :: Property
prop_fnBlock_name_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmts =
        [ mkStmt [ (TkDeclKw, "function"), (TkDatatype, "integer"), (TkIdent, name)
                 , (TkLParen, "("), (TkRParen, ")")
                 ]
        , mkStmt [(TkDeclKw, "end function")]
        ]
  case runSection pFunctionBlock stmts of
    Right fb -> assert (not (T.null (identOrig (fnsName (fbSig fb)))))
    Left _   -> pure ()

prop_subBlock_name_nonempty :: Property
prop_subBlock_name_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmts =
        [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, name), (TkLParen, "("), (TkRParen, ")")]
        , mkStmt [(TkDeclKw, "end subroutine")]
        ]
  case runSection pSubroutineBlock stmts of
    Right sb -> assert (not (T.null (identOrig (ssName (sbSig sb)))))
    Left _   -> pure ()

prop_flexible_forward_type_order :: Property
prop_flexible_forward_type_order = property $ do
  name <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  anc  <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  let fwdStmts  = [ mkStmt [(TkDeclKw, "forward")], mkStmt [(TkDeclKw, "end forward")] ]
  let typeStmts = [ mkStmt [(TkDeclKw, "type"), (TkIdent, name), (TkDeclKw, "from"), (TkIdent, anc)]
                  , mkStmt [(TkDeclKw, "end type")]
                  ]
  case (parseSrFile [] (fwdStmts ++ typeStmts), parseSrFile [] (typeStmts ++ fwdStmts)) of
    (Right sf1, Right sf2) -> do
      assert (srForward    sf1 == srForward    sf2)
      assert (srTypeBlocks sf1 == srTypeBlocks sf2)
    _ -> assert False

prop_at_most_one_forward :: Property
prop_at_most_one_forward = property $ do
  name <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  anc  <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  let stmts = [ mkStmt [(TkDeclKw, "forward")]
              , mkStmt [(TkDeclKw, "type"), (TkIdent, name), (TkDeclKw, "from"), (TkIdent, anc)]
              , mkStmt [(TkDeclKw, "end type")]
              , mkStmt [(TkDeclKw, "end forward")]
              ]
  case parseSrFile [] stmts of
    Right sf -> assert (isJust (srForward sf))
    Left _   -> assert False

prop_at_most_one_prototypes :: Property
prop_at_most_one_prototypes = property $ do
  let stmts = [ mkStmt [(TkDeclKw, "prototypes")], mkStmt [(TkDeclKw, "end prototypes")] ]
  case parseSrFile [] stmts of
    Right sf -> assert (isJust (srPrototypes sf))
    Left _   -> assert False

prop_single_variables_block_parses :: Property
prop_single_variables_block_parses = property $ do
  typ  <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  name <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  let stmts = [ mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, typ), (TkIdent, name)]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
  case parseSrFile [] stmts of
    Right sf -> assert (not (null (srVariables sf)))
    Left _   -> assert False

-- A file with both a 'global variables' and a 'type variables' block --
-- confirmed real shape (11 files in the example corpus, e.g.
-- pbexamw3.pbl/w_train.srw has 'shared variables' + 'type variables') --
-- must keep both blocks, not silently drop every block after the first.
unitTest_two_variables_blocks_both_survive :: Assertion
unitTest_two_variables_blocks_both_survive = do
  let stmts = [ mkStmt [(TkAccessModifier, "global"), (TkDeclKw, "variables")]
              , mkStmt [(TkDatatype, "integer"), (TkIdent, "ig_count")]
              , mkStmt [(TkDeclKw, "end variables")]
              , mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, "string"), (TkIdent, "is_name")]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
  case parseSrFile [] stmts of
    Left e   -> assertFailure ("expected parse success, got: " <> T.unpack e)
    Right sf -> do
      length (srVariables sf) @?= 2
      map varScope (srVariables sf) @?= [GlobalVars, TypeVars]
      map varDecls (srVariables sf)
        @?= [ [VarDecl [] "integer" (SourceSpan 1 1 1 1) "ig_count"]
            , [VarDecl [] "string" (SourceSpan 1 1 1 1) "is_name"]
            ]
