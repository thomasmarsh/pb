module FileTest (tests) where

import PB.Prelude
import PB.Grammar.File        ( pForwardBlock, pPrototypesBlock, pVariablesBlock, pTypeDecl, pVarDecl
                              , pGlobalInstance
                              , pTypeBlock, pOnBlock, pEventBlock, pFunctionBlock, pSubroutineBlock
                              , parseSrFile
                              )
import PB.Grammar.Stream      (FileParser, StmtStream (..))
import PB.AST.SourceFile      ( ForwardBlock (..), PrototypesBlock (..), ProtoDecl (..)
                              , TypeDecl (..), TypeBlock (..)
                              , VariablesBlock (..), VarScope (..), VarDecl (..)
                              , GlobalInstance (..)
                              , FnSig (..), SubSig (..), EventSig (..)
                              , FunctionBlock (..), SubroutineBlock (..), EventBlock (..), OnBlock (..)
                              , SrFile (..)
                              )
import PB.AST.BodyStmt        (BodyStmt (..))
import PB.AST.Expr            (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located         (Located (..))
import PB.AST.Type            (PbType (..))
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

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1)

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens    = map (uncurry mkTok) pairs
  , stmtSource    = LogicalLine "" 1 1
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
          Right (ForwardBlock [TypeDecl "w_foo" "window" Nothing] [])

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
          Right (ForwardBlock [ TypeDecl "w_foo" "window" Nothing
                              , TypeDecl "d_bar" "datawindow" Nothing
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
          Right (ForwardBlock [TypeDecl "w_sub" "window" (Just "w_main")] [])

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
          Right (ForwardBlock [TypeDecl "u_foo" "userobject" Nothing] [])

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
          Right (ForwardBlock [ TypeDecl "u_foo" "userobject" Nothing
                              , TypeDecl "u_bar" "nonvisualobject" Nothing
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
          Right (ForwardBlock [TypeDecl "app" "application" Nothing]
                              [GlobalInstance "transaction" "sqlca"])

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
          Right (ForwardBlock [TypeDecl "page3" "userobject" (Just "tab1")] [])

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
          Right (ForwardBlock [ TypeDecl "w_foo" "window" Nothing
                              , TypeDecl "u_bar" "userobject" Nothing
                              ] [])

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

  , testGroup "pGlobalInstance"
    [ testCase "positive: global u_foo u_foo (same type and name)" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "global")
              , (TkIdent,          "u_foo")
              , (TkIdent,          "u_foo")
              ]
        runSection pGlobalInstance [stmt] @?=
          Right (GlobalInstance "u_foo" "u_foo")

    , testCase "positive: type name differs from instance name" $ do
        let stmt = mkStmt
              [ (TkAccessModifier, "global")
              , (TkIdent,          "u_base")
              , (TkIdent,          "u_derived_inst")
              ]
        runSection pGlobalInstance [stmt] @?=
          Right (GlobalInstance "u_base" "u_derived_inst")

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
          Right (PrototypesBlock [ProtoFn (FnSig [] "long" "SetConnect" "connection theConn" Nothing)])

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
            [ ProtoFn (FnSig [] "integer" "f1" "" Nothing)
            , ProtoFn (FnSig [] "integer" "f2" "" Nothing)
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

  , testGroup "pTypeBlock"
    [ testCase "positive: type Name from Ancestor, empty body" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (TypeDecl "w_foo" "window" Nothing) [])

    , testCase "positive: type Name from Ancestor within Container" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "type"), (TkIdent, "w_sub"), (TkDeclKw, "from")
                       , (TkIdent, "window"), (TkDeclKw, "within"), (TkIdent, "w_main")
                       ]
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (TypeDecl "w_sub" "window" (Just "w_main")) [])

    , testCase "positive: type block collects body statements" $ do
        let s1 = mkStmt [(TkDatatype, "integer"), (TkIdent, "i_count")]
            s2 = mkStmt [(TkDatatype, "string"),  (TkIdent, "s_name")]
            stmts =
              [ mkStmt [(TkDeclKw, "type"), (TkIdent, "w_foo"), (TkDeclKw, "from"), (TkIdent, "window")]
              , s1, s2
              , mkStmt [(TkDeclKw, "end type")]
              ]
        runSection pTypeBlock stmts @?=
          Right (TypeBlock (TypeDecl "w_foo" "window" Nothing)
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
          Right (TypeBlock (TypeDecl "w_foo" "window" Nothing)
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
          Right (OnBlock "modified" "" "modified" [])

    , testCase "positive: bare on close (OtherKw event name)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkOtherKw, "close")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "close" "" "close" [])

    , testCase "positive: bare on char (Datatype event name)" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkDatatype, "char")]
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "char" "" "char" [])

    , testCase "positive: bare on ue_keypress with body" $ do
        let bodyStmt = mkStmt [(TkIdent, "call"), (TkIdent, "super")]
            stmts =
              [ mkStmt [(TkDeclKw, "on"), (TkIdent, "ue_keypress")]
              , bodyStmt
              , mkStmt [(TkDeclKw, "end on")]
              ]
        runSection pOnBlock stmts @?=
          Right (OnBlock "ue_keypress" "" "ue_keypress"
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
          Right (EventBlock (EventSig "ue_custom" "") [])

    , testCase "positive: event with params" $ do
        let stmts =
              [ mkStmt [ (TkDeclKw, "event"), (TkIdent, "ue_custom")
                       , (TkLParen, "("), (TkDatatype, "integer"), (TkIdent, "al_value"), (TkRParen, ")")
                       ]
              , mkStmt [(TkDeclKw, "end event")]
              ]
        runSection pEventBlock stmts @?=
          Right (EventBlock (EventSig "ue_custom" "( integer al_value )") [])

    , testCase "negative: missing end event" $ do
        let stmts = [mkStmt [(TkDeclKw, "event"), (TkIdent, "ue_custom")]]
        case runSection pEventBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end event' is missing"
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
          Right (FunctionBlock (FnSig ["public"] "integer" "f_compute" "" Nothing) [])

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
          Right (FunctionBlock (FnSig ["private"] "string" "f_name" "" (Just "SomeError")) [])

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
          Right (FunctionBlock (FnSig [] "integer" "f_nested" "" Nothing)
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
          Right (FunctionBlock (FnSig ["public"] "boolean" "uf_zz_import_results"
                                      "ref boolean results_imported" Nothing) [])

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
    ]

  , testGroup "pSubroutineBlock"
    [ testCase "positive: subroutine of_setup()" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, "of_setup"), (TkLParen, "("), (TkRParen, ")")]
              , mkStmt [(TkDeclKw, "end subroutine")]
              ]
        runSection pSubroutineBlock stmts @?=
          Right (SubroutineBlock (SubSig [] "of_setup" "" Nothing) [])

    , testCase "negative: missing end subroutine" $ do
        let stmts =
              [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, "of_setup"), (TkLParen, "("), (TkRParen, ")")]
              ]
        case runSection pSubroutineBlock stmts of
          Left _  -> pure ()
          Right _ -> assertFailure "expected parse failure when 'end subroutine' is missing"

    , testProperty "ssName non-empty" prop_subBlock_name_nonempty
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
            , srVariables       = Nothing
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (TypeDecl "n_foo" "nonvisualobject" Nothing) []]
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = [FunctionBlock (FnSig [] "integer" "f_run" "" Nothing) []]
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
            , srForward         = Just (ForwardBlock [TypeDecl "n_base" "nonvisualobject" Nothing] [])
            , srPrototypes      = Just (PrototypesBlock [])
            , srVariables       = Just (VariablesBlock TypeVars [VarDecl [] "integer" "i_count"])
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (TypeDecl "n_base" "nonvisualobject" Nothing) []]
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
            , srVariables       = Nothing
            , srGlobalInstances = []
            , srTypeBlocks      = [ TypeBlock (TypeDecl "w_foo" "window" Nothing) []
                                  , TypeBlock (TypeDecl "cb_ok" "commandbutton" (Just "w_foo")) []
                                  ]
            , srOnBlocks        = [ OnBlock "w_foo.create" "w_foo" "create" []
                                  , OnBlock "cb_ok.clicked" "cb_ok" "clicked" []
                                  ]
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

    , testProperty "at most one variables block extracted"
        prop_at_most_one_variables
    ]

  , testGroup "parseSrFile (integration)"
    [ testCase "empty file" $
        parseSrFile [] [] @?=
          Right (SrFile [] Nothing Nothing Nothing [] [] [] [] [] [])

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
            , srVariables       = Nothing
            , srGlobalInstances = []
            , srTypeBlocks      = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       = [FunctionBlock (FnSig [] "integer" "f_run" "" Nothing) []]
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
            , srVariables       = Nothing
            , srGlobalInstances = []
            , srTypeBlocks      = []
            , srOnBlocks        = []
            , srEvents          = []
            , srFunctions       =
                [ FunctionBlock (FnSig [] "integer" "f_one" "" Nothing) []
                , FunctionBlock (FnSig [] "string"  "f_two" "" Nothing) []
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
            , srForward         = Just (ForwardBlock [TypeDecl "u_svc" "nonvisualobject" Nothing] [])
            , srPrototypes      = Nothing
            , srVariables       = Just (VariablesBlock TypeVars [VarDecl [] "integer" "i_count"])
            , srGlobalInstances = [GlobalInstance "u_svc" "u_svc"]
            , srTypeBlocks      = []
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
            , srVariables       = Nothing
            , srGlobalInstances = [GlobalInstance "u_foo" "u_foo", GlobalInstance "u_bar" "u_bar"]
            , srTypeBlocks      = []
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
            , srVariables       = Nothing
            , srGlobalInstances = []
            , srTypeBlocks      = [TypeBlock (TypeDecl "w_main" "window" Nothing) []]
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
      assert (not (T.null (giName gi)))
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
    Right ob -> assert (not (T.null (obEvent ob)))
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
    Right fb -> assert (not (T.null (fnsName (fbSig fb))))
    Left _   -> pure ()

prop_subBlock_name_nonempty :: Property
prop_subBlock_name_nonempty = property $ do
  name <- forAll $ Gen.text (Range.linear 1 20) Gen.alphaNum
  let stmts =
        [ mkStmt [(TkDeclKw, "subroutine"), (TkIdent, name), (TkLParen, "("), (TkRParen, ")")]
        , mkStmt [(TkDeclKw, "end subroutine")]
        ]
  case runSection pSubroutineBlock stmts of
    Right sb -> assert (not (T.null (ssName (sbSig sb))))
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

prop_at_most_one_variables :: Property
prop_at_most_one_variables = property $ do
  typ  <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  name <- forAll $ Gen.text (Range.linear 1 10) Gen.alphaNum
  let stmts = [ mkStmt [(TkDeclKw, "type variables")]
              , mkStmt [(TkDatatype, typ), (TkIdent, name)]
              , mkStmt [(TkDeclKw, "end variables")]
              ]
  case parseSrFile [] stmts of
    Right sf -> assert (isJust (srVariables sf))
    Left _   -> assert False
