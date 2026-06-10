module ExprTest (tests) where

import PB.Prelude
import PB.AST.Expr        (BinOp (..), CallExpr (..), CreateExpr (..), Expr (..), Literal (..), LvSegment (..), Lvalue (..))
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

    , testGroup "datatype conversions"
      [ testCase "Integer(x) → ExCall" $
          parseExpr [ mkTok TkDatatype "Integer", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr (Lvalue [LvSegment "Integer" Nothing])
                        [[mkTok TkIdent "x"]])

      , testCase "String(x) → ExCall" $
          parseExpr [ mkTok TkDatatype "String", mkTok TkLParen "("
                    , mkTok TkIdent "myhours", mkTok TkRParen ")" ]
            @?= ExCall (CallExpr (Lvalue [LvSegment "String" Nothing])
                        [[mkTok TkIdent "myhours"]])

      , testCase "bare Integer → ExLvalue" $
          parseExpr [mkTok TkDatatype "Integer"]
            @?= ExLvalue (Lvalue [LvSegment "Integer" Nothing])

      , testCase "Integer(x) + 1 → ExBinOp BopAdd (call + literal)" $
          parseExpr [ mkTok TkDatatype "Integer", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkRParen ")"
                    , mkTok TkArithOp "+", mkTok TkIntLiteral "1" ]
            @?= ExBinOp
                  (ExCall (CallExpr (Lvalue [LvSegment "Integer" Nothing])
                           [[mkTok TkIdent "x"]]))
                  BopAdd
                  (ExLit (LitInt "1"))
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

      , testCase "not ll_rc > 0 → ExNot (ExBinOp BopGt)" $
          parseExpr [ mkTok TkOtherKw "not", mkTok TkIdent "ll_rc"
                    , mkTok TkCompareOp ">", mkTok TkIntLiteral "0" ]
            @?= ExNot (ExBinOp
                        (ExLvalue (Lvalue [LvSegment "ll_rc" Nothing]))
                        BopGt
                        (ExLit (LitInt "0")))

      , testCase "bare not (no operand) → ExNot (ExRaw [])" $
          parseExpr [mkTok TkOtherKw "not"]
            @?= ExNot (ExRaw [])
      ]

    , testGroup "host variable"
      [ testCase ":varname → ExHostVar" $
          parseExpr [ mkTok TkColon ":", mkTok TkIdent "ll_id" ]
            @?= ExHostVar (Lvalue [LvSegment "ll_id" Nothing])

      , testCase ":varname, (trailing comma discarded) → ExHostVar" $
          parseExpr [ mkTok TkColon ":", mkTok TkIdent "ll_id", mkTok TkComma "," ]
            @?= ExHostVar (Lvalue [LvSegment "ll_id" Nothing])

      , testCase ":struct.field → ExHostVar dotted lvalue" $
          parseExpr [ mkTok TkColon ":", mkTok TkIdent "asc_report"
                    , mkTok TkDot ".", mkTok TkIdent "kodreport" ]
            @?= ExHostVar (Lvalue [ LvSegment "asc_report" Nothing
                                  , LvSegment "kodreport"  Nothing ])

      , testCase ":struct.field, (trailing comma discarded) → ExHostVar" $
          parseExpr [ mkTok TkColon ":", mkTok TkIdent "asc_report"
                    , mkTok TkDot ".", mkTok TkIdent "kodreport", mkTok TkComma "," ]
            @?= ExHostVar (Lvalue [ LvSegment "asc_report" Nothing
                                  , LvSegment "kodreport"  Nothing ])

      , testCase "bare colon with no name → ExRaw fallback" $
          parseExpr [ mkTok TkColon ":", mkTok TkComma "," ]
            @?= ExRaw [ mkTok TkColon ":", mkTok TkComma "," ]
      ]

    , testGroup "ExRaw fallback"
      [ testCase "empty token list → ExRaw []" $
          parseExpr [] @?= ExRaw []

      , testCase "lvalue + literal → ExBinOp BopAdd" $
          parseExpr [mkTok TkIdent "ll_aa", mkTok TkArithOp "+", mkTok TkIntLiteral "1"]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "ll_aa" Nothing]))
                  BopAdd
                  (ExLit (LitInt "1"))

      , testCase "chained call result().method() → ExRaw (tokens after first close)" $
          let ts = [ mkTok TkIdent "parentwindow", mkTok TkLParen "(", mkTok TkRParen ")"
                   , mkTok TkDot ".", mkTok TkIdent "pointerx"
                   , mkTok TkLParen "(", mkTok TkRParen ")" ]
          in parseExpr ts @?= ExRaw ts

      , testCase "unmatched open paren → ExRaw" $
          let ts = [mkTok TkIdent "f", mkTok TkLParen "(", mkTok TkIdent "x"]
          in parseExpr ts @?= ExRaw ts
      ]

    , testGroup "binary operators"
      [ testCase "a > 0 → ExBinOp BopGt" $
          parseExpr [ mkTok TkIdent "a", mkTok TkCompareOp ">", mkTok TkIntLiteral "0" ]
            @?= ExBinOp (ExLvalue (Lvalue [LvSegment "a" Nothing])) BopGt (ExLit (LitInt "0"))

      , testCase "a = b → ExBinOp BopEq (not assignment)" $
          parseExpr [ mkTok TkIdent "a", mkTok TkAssignOp "=", mkTok TkIdent "b" ]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                  BopEq
                  (ExLvalue (Lvalue [LvSegment "b" Nothing]))

      , testCase "a <> b → ExBinOp BopNe" $
          parseExpr [ mkTok TkIdent "a", mkTok TkCompareOp "<>", mkTok TkIdent "b" ]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                  BopNe
                  (ExLvalue (Lvalue [LvSegment "b" Nothing]))

      , testCase "a + b * c → mul binds tighter than add" $
          parseExpr [ mkTok TkIdent "a", mkTok TkArithOp "+", mkTok TkIdent "b"
                    , mkTok TkArithOp "*", mkTok TkIdent "c" ]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                  BopAdd
                  (ExBinOp
                    (ExLvalue (Lvalue [LvSegment "b" Nothing]))
                    BopMul
                    (ExLvalue (Lvalue [LvSegment "c" Nothing])))

      , testCase "a or b or c → left-associative" $
          parseExpr [ mkTok TkIdent "a", mkTok TkOtherKw "or", mkTok TkIdent "b"
                    , mkTok TkOtherKw "or", mkTok TkIdent "c" ]
            @?= ExBinOp
                  (ExBinOp
                    (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                    BopOr
                    (ExLvalue (Lvalue [LvSegment "b" Nothing])))
                  BopOr
                  (ExLvalue (Lvalue [LvSegment "c" Nothing]))

      , testCase "a ^ b ^ c → right-associative" $
          parseExpr [ mkTok TkIdent "a", mkTok TkArithOp "^", mkTok TkIdent "b"
                    , mkTok TkArithOp "^", mkTok TkIdent "c" ]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                  BopPow
                  (ExBinOp
                    (ExLvalue (Lvalue [LvSegment "b" Nothing]))
                    BopPow
                    (ExLvalue (Lvalue [LvSegment "c" Nothing])))

      , testCase "a xor b → ExBinOp BopXor" $
          parseExpr [ mkTok TkIdent "a", mkTok TkOtherKw "xor", mkTok TkIdent "b" ]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                  BopXor
                  (ExLvalue (Lvalue [LvSegment "b" Nothing]))

      , testCase "(a + b) * c → paren transparent" $
          parseExpr [ mkTok TkLParen "(", mkTok TkIdent "a", mkTok TkArithOp "+"
                    , mkTok TkIdent "b", mkTok TkRParen ")"
                    , mkTok TkArithOp "*", mkTok TkIdent "c" ]
            @?= ExBinOp
                  (ExBinOp
                    (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                    BopAdd
                    (ExLvalue (Lvalue [LvSegment "b" Nothing])))
                  BopMul
                  (ExLvalue (Lvalue [LvSegment "c" Nothing]))

      , testCase "(x) → paren transparent: ExLvalue x" $
          parseExpr [ mkTok TkLParen "(", mkTok TkIdent "x", mkTok TkRParen ")" ]
            @?= ExLvalue (Lvalue [LvSegment "x" Nothing])

      , testCase "IsNull(x) or y → ExBinOp BopOr call lvalue" $
          parseExpr [ mkTok TkIdent "IsNull", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkRParen ")"
                    , mkTok TkOtherKw "or", mkTok TkIdent "y" ]
            @?= ExBinOp
                  (ExCall (CallExpr (Lvalue [LvSegment "IsNull" Nothing])
                           [[mkTok TkIdent "x"]]))
                  BopOr
                  (ExLvalue (Lvalue [LvSegment "y" Nothing]))

      , testCase "not a > b → ExNot (ExBinOp BopGt): not binds below comparison" $
          parseExpr [ mkTok TkOtherKw "not", mkTok TkIdent "a"
                    , mkTok TkCompareOp ">", mkTok TkIdent "b" ]
            @?= ExNot
                  (ExBinOp
                    (ExLvalue (Lvalue [LvSegment "a" Nothing]))
                    BopGt
                    (ExLvalue (Lvalue [LvSegment "b" Nothing])))

      , testCase "not a and b → (ExNot a) and b" $
          parseExpr [ mkTok TkOtherKw "not", mkTok TkIdent "a"
                    , mkTok TkOtherKw "and", mkTok TkIdent "b" ]
            @?= ExBinOp
                  (ExNot (ExLvalue (Lvalue [LvSegment "a" Nothing])))
                  BopAnd
                  (ExLvalue (Lvalue [LvSegment "b" Nothing]))
      ]

    , testGroup "unary minus"
      [ testCase "- x → ExUnaryMinus (ExLvalue x)" $
          parseExpr [ mkTok TkArithOp "-", mkTok TkIdent "x" ]
            @?= ExUnaryMinus (ExLvalue (Lvalue [LvSegment "x" Nothing]))

      , testCase "- 1 → ExUnaryMinus (ExLit (LitInt))" $
          parseExpr [ mkTok TkArithOp "-", mkTok TkIntLiteral "1" ]
            @?= ExUnaryMinus (ExLit (LitInt "1"))
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
      , (TkColon,       ":")
      ])
  let ts = map (uncurry mkTok) pairs
  assert $ case parseExpr ts of
    ExLit          _ -> True
    ExEnum         _ -> True
    ExLvalue       _ -> True
    ExCall         _ -> True
    ExCreate       _ -> True
    ExArray        _ -> True
    ExNot          _ -> True
    ExHostVar      _ -> True
    ExBinOp      _ _ _ -> True
    ExUnaryMinus _ -> True
    ExRaw          _ -> True

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
