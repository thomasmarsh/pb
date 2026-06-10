module ExprTest (tests) where

import PB.Prelude
import PB.AST.Expr        (CallExpr (..), CreateExpr (..), Expr (..), Literal (..), LvSegment (..), Lvalue (..))
import PB.Grammar.Body    (parseExpr)
import PB.Lexing.Token    (Token (..), TokenKind (..), SourceSpan (..))

import Hedgehog (Property, assert, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty              (TestTree, testGroup)
import Test.Tasty.HUnit        (testCase, (@?=))
import Test.Tasty.Hedgehog     (testProperty)

-- ---------------------------------------------------------------------------
-- Helper

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1)

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Expr"
  [ testGroup "parseExpr"
    [ testGroup "literals"
      [ testCase "bool true → ExLit (LitBool True)" $
          parseExpr [mkTok TkBoolTrue "true"] @?= ExLit (LitBool True)

      , testCase "bool false → ExLit (LitBool False)" $
          parseExpr [mkTok TkBoolFalse "false"] @?= ExLit (LitBool False)

      , testCase "null literal → ExLit LitNull" $
          parseExpr [mkTok TkNull "null"] @?= ExLit LitNull

      , testCase "integer literal → ExLit (LitInt)" $
          parseExpr [mkTok TkIntLiteral "42"] @?= ExLit (LitInt "42")

      , testCase "float literal → ExLit (LitReal)" $
          parseExpr [mkTok TkFloatLiteral "3.14"] @?= ExLit (LitReal "3.14")

      , testCase "double-quoted string → ExLit (LitStr)" $
          parseExpr [mkTok TkStringDouble "\"hello\""] @?= ExLit (LitStr "\"hello\"")

      , testCase "date literal → ExLit (LitDate)" $
          parseExpr [mkTok TkDateLiteral "2024-01-01"] @?= ExLit (LitDate "2024-01-01")

      , testCase "time literal → ExLit (LitTime)" $
          parseExpr [mkTok TkTimeLiteral "12:00:00"] @?= ExLit (LitTime "12:00:00")
      ]

    , testGroup "enum"
      [ testCase "enum constant (Black!) → ExEnum \"Black\"" $
          parseExpr [mkTok TkEnumLiteral "Black!"] @?= ExEnum "Black"
      ]

    , testGroup "lvalue (non-call)"
      [ testCase "simple identifier → ExLvalue" $
          parseExpr [mkTok TkIdent "ll_row"]
            @?= ExLvalue (Lvalue [LvSegment "ll_row" Nothing])

      , testCase "OtherKw identifier (this) → ExLvalue" $
          parseExpr [mkTok TkOtherKw "this"]
            @?= ExLvalue (Lvalue [LvSegment "this" Nothing])

      , testCase "dotted chain → ExLvalue" $
          parseExpr [ mkTok TkIdent "adw", mkTok TkDot "."
                    , mkTok TkIdent "object" ]
            @?= ExLvalue (Lvalue [LvSegment "adw" Nothing, LvSegment "object" Nothing])

      , testCase "subscript access → ExLvalue" $
          parseExpr [ mkTok TkIdent "arr", mkTok TkLBracket "["
                    , mkTok TkIntLiteral "0", mkTok TkRBracket "]" ]
            @?= ExLvalue (Lvalue [LvSegment "arr" (Just [mkTok TkIntLiteral "0"])])
      ]

    , testGroup "calls"
      [ testCase "no-arg call → ExCall empty ceArgs" $
          parseExpr [ mkTok TkIdent "today", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr (Lvalue [LvSegment "today" Nothing]) [])

      , testCase "OtherKw callee (builtin fn) → ExCall" $
          parseExpr [ mkTok TkOtherKw "count", mkTok TkLParen "("
                    , mkTok TkIdent "kodypal", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr (Lvalue [LvSegment "count" Nothing])
                        [[mkTok TkIdent "kodypal"]])

      , testCase "single-arg call → ExCall singleton ceArgs" $
          parseExpr [ mkTok TkIdent "trn", mkTok TkLParen "("
                    , mkTok TkIntLiteral "411", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr (Lvalue [LvSegment "trn" Nothing])
                        [[mkTok TkIntLiteral "411"]])

      , testCase "multi-arg call → ExCall multiple ceArgs" $
          parseExpr [ mkTok TkIdent "f", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkComma ","
                    , mkTok TkIdent "y", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr (Lvalue [LvSegment "f" Nothing])
                        [[mkTok TkIdent "x"], [mkTok TkIdent "y"]])

      , testCase "method call obj.method() → ExCall" $
          parseExpr [ mkTok TkIdent "adw", mkTok TkDot "."
                    , mkTok TkIdent "setfocus", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr
                  (Lvalue [LvSegment "adw" Nothing, LvSegment "setfocus" Nothing])
                  [])

      , testCase "three-level chain call → ExCall" $
          parseExpr [ mkTok TkIdent "iw_filter", mkTok TkDot "."
                    , mkTok TkIdent "idw_filter", mkTok TkDot "."
                    , mkTok TkIdent "rowcount"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr
                  (Lvalue [ LvSegment "iw_filter"  Nothing
                           , LvSegment "idw_filter" Nothing
                           , LvSegment "rowcount"   Nothing ])
                  [])

      , testCase "args containing operators stay as raw tokens in ceArgs" $
          let inner = [mkTok TkIdent "x", mkTok TkArithOp "+", mkTok TkIntLiteral "1"]
          in parseExpr ([ mkTok TkIdent "foo", mkTok TkLParen "(" ]
                        <> inner
                        <> [mkTok TkRParen ")"])
               @?= ExCall (CallExpr (Lvalue [LvSegment "foo" Nothing]) [inner])

      , testCase "nested call arg stays as raw tokens in ceArgs" $
          let nestedCall = [ mkTok TkIdent "trn", mkTok TkLParen "("
                           , mkTok TkIntLiteral "157", mkTok TkRParen ")" ]
          in parseExpr ([ mkTok TkIdent "MessageBox", mkTok TkLParen "("
                        , mkTok TkIdent "title", mkTok TkComma "," ]
                        <> nestedCall
                        <> [mkTok TkRParen ")"])
               @?= ExCall (CallExpr (Lvalue [LvSegment "MessageBox" Nothing])
                           [ [mkTok TkIdent "title"]
                           , nestedCall
                           ])
      ]

    , testGroup "array"
      [ testCase "empty array {} → ExArray []" $
          parseExpr [ mkTok TkLBrace "{", mkTok TkRBrace "}" ]
            @?= ExArray []

      , testCase "single-element {this.m_file} → ExArray [ExLvalue]" $
          parseExpr [ mkTok TkLBrace "{"
                    , mkTok TkOtherKw "this", mkTok TkDot ".", mkTok TkIdent "m_file"
                    , mkTok TkRBrace "}" ]
            @?= ExArray [ ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                           , LvSegment "m_file" Nothing ]) ]

      , testCase "multi-element {a, b} → ExArray [ExLvalue, ExLvalue]" $
          parseExpr [ mkTok TkLBrace "{"
                    , mkTok TkOtherKw "this", mkTok TkDot ".", mkTok TkIdent "m_file"
                    , mkTok TkComma ","
                    , mkTok TkOtherKw "this", mkTok TkDot ".", mkTok TkIdent "m_edit"
                    , mkTok TkRBrace "}" ]
            @?= ExArray [ ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                           , LvSegment "m_file" Nothing ])
                        , ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                           , LvSegment "m_edit" Nothing ]) ]

      , testCase "nested array {{a}} → ExArray [ExArray [ExLvalue]]" $
          parseExpr [ mkTok TkLBrace "{"
                    , mkTok TkLBrace "{"
                    , mkTok TkIdent "a"
                    , mkTok TkRBrace "}"
                    , mkTok TkRBrace "}" ]
            @?= ExArray [ ExArray [ ExLvalue (Lvalue [LvSegment "a" Nothing]) ] ]

      , testCase "unclosed brace → ExRaw fallback" $
          let ts = [ mkTok TkLBrace "{", mkTok TkIdent "a" ]
          in parseExpr ts @?= ExRaw ts
      ]

    , testGroup "create"
      [ testCase "create ident class → ExCreate (CreateClass)" $
          parseExpr [mkTok TkOtherKw "create", mkTok TkIdent "n_service"]
            @?= ExCreate (CreateClass "n_service")

      , testCase "create datatype class → ExCreate (CreateClass)" $
          parseExpr [mkTok TkOtherKw "create", mkTok TkDatatype "DataStore"]
            @?= ExCreate (CreateClass "DataStore")

      , testCase "create using variable → ExCreate (CreateUsing (ExLvalue))" $
          parseExpr [ mkTok TkOtherKw "create", mkTok TkOtherKw "using"
                    , mkTok TkIdent "ls_wintype" ]
            @?= ExCreate (CreateUsing (ExLvalue (Lvalue [LvSegment "ls_wintype" Nothing])))
      ]

    , testGroup "not negation"
      [ testCase "not true → ExNot (ExLit (LitBool True))" $
          parseExpr [mkTok TkOtherKw "not", mkTok TkBoolTrue "true"]
            @?= ExNot (ExLit (LitBool True))

      , testCase "not lvalue → ExNot (ExLvalue)" $
          parseExpr [mkTok TkOtherKw "not", mkTok TkIdent "ib_debug"]
            @?= ExNot (ExLvalue (Lvalue [LvSegment "ib_debug" Nothing]))

      , testCase "not call → ExNot (ExCall)" $
          parseExpr [ mkTok TkOtherKw "not", mkTok TkIdent "IsNull"
                    , mkTok TkLParen "(", mkTok TkIdent "x", mkTok TkRParen ")" ]
            @?= ExNot (ExCall (CallExpr (Lvalue [LvSegment "IsNull" Nothing])
                               [[mkTok TkIdent "x"]]))

      , testCase "not complex (binary op operand) → ExNot (ExRaw)" $
          let opToks = [ mkTok TkIdent "ll_rc", mkTok TkCompareOp ">"
                       , mkTok TkIntLiteral "0" ]
          in parseExpr (mkTok TkOtherKw "not" : opToks)
               @?= ExNot (ExRaw opToks)

      , testCase "bare not (no operand) → ExNot (ExRaw [])" $
          parseExpr [mkTok TkOtherKw "not"]
            @?= ExNot (ExRaw [])
      ]

    , testGroup "ExRaw fallback"
      [ testCase "empty token list → ExRaw []" $
          parseExpr [] @?= ExRaw []

      , testCase "binary op sequence → ExRaw" $
          let ts = [mkTok TkIdent "ll_aa", mkTok TkArithOp "+", mkTok TkIntLiteral "1"]
          in parseExpr ts @?= ExRaw ts

      , testCase "chained call result().method() → ExRaw (tokens after first close)" $
          let ts = [ mkTok TkIdent "parentwindow", mkTok TkLParen "(", mkTok TkRParen ")"
                   , mkTok TkDot ".", mkTok TkIdent "pointerx"
                   , mkTok TkLParen "(", mkTok TkRParen ")" ]
          in parseExpr ts @?= ExRaw ts

      , testCase "unmatched open paren → ExRaw" $
          let ts = [mkTok TkIdent "f", mkTok TkLParen "(", mkTok TkIdent "x"]
          in parseExpr ts @?= ExRaw ts
      ]

    , testProperty "total: parseExpr never raises" propParseExprTotal
    , testProperty "roundtrip: ExRaw tokens identical to input" propExRawRoundtrip
    ]
  ]

-- ---------------------------------------------------------------------------
-- Properties

propParseExprTotal :: Property
propParseExprTotal = property $ do
  pairs <- forAll $ Gen.list (Range.linear 0 10)
    (Gen.element
      [ (TkIdent,       "foo")
      , (TkOtherKw,     "today")
      , (TkOtherKw,     "not")
      , (TkBoolTrue,    "true")
      , (TkBoolFalse,   "false")
      , (TkIntLiteral,  "1")
      , (TkEnumLiteral, "Black!")
      , (TkDot,         ".")
      , (TkLParen,      "(")
      , (TkRParen,      ")")
      , (TkLBrace,      "{")
      , (TkRBrace,      "}")
      , (TkComma,       ",")
      , (TkArithOp,     "+")
      , (TkNull,        "null")
      ])
  let ts = map (uncurry mkTok) pairs
  assert $ case parseExpr ts of
    ExLit    _ -> True
    ExEnum   _ -> True
    ExLvalue _ -> True
    ExCall   _ -> True
    ExCreate _ -> True
    ExArray  _ -> True
    ExNot    _ -> True
    ExRaw    _ -> True

propExRawRoundtrip :: Property
propExRawRoundtrip = property $ do
  pairs <- forAll $ Gen.list (Range.linear 0 10)
    (Gen.element
      [ (TkIdent,     "foo")
      , (TkArithOp,   "+")
      , (TkIntLiteral,"1")
      , (TkCompareOp, ">")
      ])
  let ts = map (uncurry mkTok) pairs
  case parseExpr ts of
    ExRaw toks -> toks === ts
    _          -> pure ()
