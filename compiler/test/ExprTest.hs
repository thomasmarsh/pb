module ExprTest (tests) where

import PB.Prelude
import PB.AST.Expr        (BinOp (..), DispatchExpr (..), DispatchMode (..), Expr (..), LvSegment (..), Lvalue (..), exprChildren, foldExprs)
import PB.AST.Ident        (mkIdent)
import PB.Grammar.Body    (parseExpr)
import PB.Grammar.Unparse (unparseExpr)
import PB.Lexing.Lexer       (tokenizeLine, LexLine (..))
import PB.Lexing.Token       (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (mkLogicalLine)

import Hedgehog (Gen, Property, assert, failure, footnote, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import SmallCheckInstances      (StructuredExpr (..))
import Test.Tasty              (TestTree, localOption, testGroup)
import Test.Tasty.HUnit        (testCase, (@?=))
import Test.Tasty.Hedgehog     (testProperty)
import Test.Tasty.SmallCheck   (SmallCheckDepth (..))
import qualified Test.Tasty.SmallCheck as SC

-- ---------------------------------------------------------------------------
-- Helper

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1 1)

countNodes :: [()] -> Int
countNodes = length

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Expr"
  [ testGroup "parseExpr"
    [ testGroup "literals"
      [ testCase "bool true → ExBool True" $
          parseExpr [mkTok TkBoolTrue "true"] @?= ExBool True

      , testCase "bool false → ExBool False" $
          parseExpr [mkTok TkBoolFalse "false"] @?= ExBool False

      , testCase "null literal → ExNull" $
          parseExpr [mkTok TkNull "null"] @?= ExNull

      , testCase "integer literal → ExInt" $
          parseExpr [mkTok TkIntLiteral "42"] @?= ExInt "42"

      , testCase "float literal → ExReal" $
          parseExpr [mkTok TkFloatLiteral "3.14"] @?= ExReal "3.14"

      , testCase "double-quoted string → ExStr" $
          parseExpr [mkTok TkStringDouble "\"hello\""] @?= ExStr "hello"

      , testCase "date literal → ExDate" $
          parseExpr [mkTok TkDateLiteral "2024-01-01"] @?= ExDate "2024-01-01"

      , testCase "time literal → ExTime" $
          parseExpr [mkTok TkTimeLiteral "12:00:00"] @?= ExTime "12:00:00"
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
      [ testCase "no-arg call → ExCall empty callArgs" $
          parseExpr [ mkTok TkIdent "today", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "today" Nothing]) []

      , testCase "OtherKw callee (builtin fn) → ExCall" $
          parseExpr [ mkTok TkOtherKw "count", mkTok TkLParen "("
                    , mkTok TkIdent "kodypal", mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "count" Nothing]) [ExLvalue (Lvalue [LvSegment "kodypal" Nothing])]

      , testCase "single-arg call → ExCall singleton callArgs" $
          parseExpr [ mkTok TkIdent "trn", mkTok TkLParen "("
                    , mkTok TkIntLiteral "411", mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "trn" Nothing]) [ExInt "411"]

      , testCase "multi-arg call → ExCall multiple callArgs" $
          parseExpr [ mkTok TkIdent "f", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkComma ","
                    , mkTok TkIdent "y", mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "f" Nothing])
                  [ ExLvalue (Lvalue [LvSegment "x" Nothing])
                  , ExLvalue (Lvalue [LvSegment "y" Nothing])
                  ]

      , testCase "method call obj.method() → ExMethodCall" $
          parseExpr [ mkTok TkIdent "adw", mkTok TkDot "."
                    , mkTok TkIdent "setfocus", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall
                  (ExLvalue (Lvalue [LvSegment "adw" Nothing]))
                  "setfocus" []

      , testCase "three-level chain call → ExMethodCall with multi-segment receiver" $
          parseExpr [ mkTok TkIdent "iw_filter", mkTok TkDot "."
                    , mkTok TkIdent "idw_filter", mkTok TkDot "."
                    , mkTok TkIdent "rowcount"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall
                  (ExLvalue (Lvalue [ LvSegment "iw_filter"  Nothing
                                     , LvSegment "idw_filter" Nothing ]))
                  "rowcount" []

      , testCase "x.y() → ExMethodCall (single dotted hop)" $
          parseExpr [ mkTok TkIdent "x", mkTok TkDot "."
                    , mkTok TkIdent "y", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall (ExLvalue (Lvalue [LvSegment "x" Nothing])) "y" []

      , testCase "this.y() → ExMethodCall (dispatch-adjacent keyword as receiver)" $
          parseExpr [ mkTok TkOtherKw "this", mkTok TkDot "."
                    , mkTok TkIdent "y", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall (ExLvalue (Lvalue [LvSegment "this" Nothing])) "y" []

      , testCase "super.y() → ExMethodCall (dispatch-adjacent keyword as receiver)" $
          parseExpr [ mkTok TkOtherKw "super", mkTok TkDot "."
                    , mkTok TkIdent "y", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall (ExLvalue (Lvalue [LvSegment "super" Nothing])) "y" []

      , testCase "super::create() → ExMethodCall (scope-qualified dispatch)" $
          parseExpr [ mkTok TkOtherKw "super", mkTok TkDoubleColon "::"
                    , mkTok TkIdent "create", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall (ExLvalue (Lvalue [LvSegment "super" Nothing])) "create" []

      , testCase "w_main::event() → ExMethodCall (class-qualified static dispatch)" $
          parseExpr [ mkTok TkIdent "w_main", mkTok TkDoubleColon "::"
                    , mkTok TkIdent "event", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall (ExLvalue (Lvalue [LvSegment "w_main" Nothing])) "event" []

      , testCase "ancestor::somevar (no parens) → ExLvalue (matches bare dot-chain, no method call)" $
          parseExpr [ mkTok TkIdent "ancestor", mkTok TkDoubleColon "::"
                    , mkTok TkIdent "somevar" ]
            @?= ExLvalue (Lvalue [LvSegment "ancestor" Nothing, LvSegment "somevar" Nothing])

      , testCase "args containing operators parse into a structured ExBinOp arg" $
          parseExpr [ mkTok TkIdent "foo", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkArithOp "+", mkTok TkIntLiteral "1"
                    , mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "foo" Nothing])
                  [ExBinOp (ExLvalue (Lvalue [LvSegment "x" Nothing])) BopAdd (ExInt "1")]

      , testCase "nested call arg parses into a nested ExCall (Plan 195 Phase C)" $
          parseExpr [ mkTok TkIdent "MessageBox", mkTok TkLParen "("
                    , mkTok TkIdent "title", mkTok TkComma ","
                    , mkTok TkIdent "trn", mkTok TkLParen "("
                    , mkTok TkIntLiteral "157", mkTok TkRParen ")"
                    , mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "MessageBox" Nothing])
                       [ ExLvalue (Lvalue [LvSegment "title" Nothing])
                       , ExCall (Lvalue [LvSegment "trn" Nothing]) [ExInt "157"]
                       ]

      , testCase "nested call arg is reachable via foldExprs (PopMenu blind spot closed)" $
          let expr = parseExpr
                [ mkTok TkIdent "MessageBox", mkTok TkLParen "("
                , mkTok TkIdent "title", mkTok TkComma ","
                , mkTok TkIdent "trn", mkTok TkLParen "("
                , mkTok TkIntLiteral "157", mkTok TkRParen ")"
                , mkTok TkRParen ")" ]
              isCall ExCall{} = [()]
              isCall _        = []
          in countNodes (foldExprs isCall expr) @?= 2
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
          parseExpr [ mkTok TkLBrace "{", mkTok TkIdent "a" ]
            @?= ExRaw ["{", "a"]
      ]

    , testGroup "datatype conversions"
      [ testCase "Integer(x) → ExCall" $
          parseExpr [ mkTok TkDatatype "Integer", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "Integer" Nothing]) [ExLvalue (Lvalue [LvSegment "x" Nothing])]

      , testCase "String(x) → ExCall" $
          parseExpr [ mkTok TkDatatype "String", mkTok TkLParen "("
                    , mkTok TkIdent "myhours", mkTok TkRParen ")" ]
            @?= ExCall (Lvalue [LvSegment "String" Nothing]) [ExLvalue (Lvalue [LvSegment "myhours" Nothing])]

      , testCase "bare Integer → ExLvalue" $
          parseExpr [mkTok TkDatatype "Integer"]
            @?= ExLvalue (Lvalue [LvSegment "Integer" Nothing])

      , testCase "Integer(x) + 1 → ExBinOp BopAdd (call + literal)" $
          parseExpr [ mkTok TkDatatype "Integer", mkTok TkLParen "("
                    , mkTok TkIdent "x", mkTok TkRParen ")"
                    , mkTok TkArithOp "+", mkTok TkIntLiteral "1" ]
            @?= ExBinOp
                  (ExCall (Lvalue [LvSegment "Integer" Nothing]) [ExLvalue (Lvalue [LvSegment "x" Nothing])])
                  BopAdd
                  (ExInt "1")
      ]

    , testGroup "create"
      [ testCase "create ident class → ExCreate" $
          parseExpr [mkTok TkOtherKw "create", mkTok TkIdent "n_service"]
            @?= ExCreate "n_service"

      , testCase "create datatype class → ExCreate" $
          parseExpr [mkTok TkOtherKw "create", mkTok TkDatatype "DataStore"]
            @?= ExCreate "DataStore"

      , testCase "create using variable → ExCreateUsing (ExLvalue)" $
          parseExpr [ mkTok TkOtherKw "create", mkTok TkOtherKw "using"
                    , mkTok TkIdent "ls_wintype" ]
            @?= ExCreateUsing (ExLvalue (Lvalue [LvSegment "ls_wintype" Nothing]))
      ]

    , testGroup "not negation"
      [ testCase "not true → ExNot (ExBool True)" $
          parseExpr [mkTok TkOtherKw "not", mkTok TkBoolTrue "true"]
            @?= ExNot (ExBool True)

      , testCase "not lvalue → ExNot (ExLvalue)" $
          parseExpr [mkTok TkOtherKw "not", mkTok TkIdent "ib_debug"]
            @?= ExNot (ExLvalue (Lvalue [LvSegment "ib_debug" Nothing]))

      , testCase "not call → ExNot (ExCall)" $
          parseExpr [ mkTok TkOtherKw "not", mkTok TkIdent "IsNull"
                    , mkTok TkLParen "(", mkTok TkIdent "x", mkTok TkRParen ")" ]
            @?= ExNot (ExCall (Lvalue [LvSegment "IsNull" Nothing]) [ExLvalue (Lvalue [LvSegment "x" Nothing])])

      , testCase "not ll_rc > 0 → ExNot (ExBinOp BopGt)" $
          parseExpr [ mkTok TkOtherKw "not", mkTok TkIdent "ll_rc"
                    , mkTok TkCompareOp ">", mkTok TkIntLiteral "0" ]
            @?= ExNot (ExBinOp
                        (ExLvalue (Lvalue [LvSegment "ll_rc" Nothing]))
                        BopGt
                        (ExInt "0"))

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
            @?= ExRaw [":", ","]
      ]

    , testGroup "ExMethodCall"
      [ testCase "f().method() → ExMethodCall with no args" $
          parseExpr [ mkTok TkIdent "getparent", mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkDot ".", mkTok TkIdent "TriggerEvent"
                    , mkTok TkLParen "(", mkTok TkStringDouble "\"ie_checkbuttons\"", mkTok TkRParen ")" ]
            @?= ExMethodCall
                  (ExCall (Lvalue [LvSegment "getparent" Nothing]) [])
                  "TriggerEvent"
                  [ExStr "ie_checkbuttons"]

      , testCase "a.b().method(x) — dotted lvalue receiver" $
          parseExpr [ mkTok TkIdent "ParentWindow"
                    , mkTok TkDot ".", mkTok TkIdent "GetActiveSheet"
                    , mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkDot ".", mkTok TkIdent "TriggerEvent"
                    , mkTok TkLParen "(", mkTok TkStringDouble "\"graph_color\"", mkTok TkRParen ")" ]
            @?= ExMethodCall
                  (ExMethodCall
                    (ExLvalue (Lvalue [LvSegment "ParentWindow" Nothing]))
                    "GetActiveSheet" [])
                  "TriggerEvent"
                  [ExStr "graph_color"]

      , testCase "f().a().b() — chain of two → nested ExMethodCall" $
          parseExpr [ mkTok TkIdent "f", mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkDot ".", mkTok TkIdent "a"
                    , mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkDot ".", mkTok TkIdent "b"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall
                  (ExMethodCall
                    (ExCall (Lvalue [LvSegment "f" Nothing]) [])
                    "a" [])
                  "b" []

      , testCase "f().prop — property access on call result → ExMethodCall []" $
          parseExpr [ mkTok TkIdent "f", mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkDot ".", mkTok TkIdent "value" ]
            @?= ExMethodCall
                  (ExCall (Lvalue [LvSegment "f" Nothing]) [])
                  "value" []

      , testCase "obj.cells(1,1).value — call in chain then property → ExMethodCall []" $
          parseExpr [ mkTok TkIdent "obj"
                    , mkTok TkDot ".", mkTok TkIdent "cells"
                    , mkTok TkLParen "(", mkTok TkIntLiteral "1"
                    , mkTok TkComma ",", mkTok TkIntLiteral "1"
                    , mkTok TkRParen ")"
                    , mkTok TkDot ".", mkTok TkIdent "value" ]
            @?= ExMethodCall
                  (ExMethodCall
                    (ExLvalue (Lvalue [LvSegment "obj" Nothing]))
                    "cells" [ExInt "1", ExInt "1"])
                  "value" []
      ]

    , testGroup "ExRaw fallback"
      [ testCase "empty token list → ExRaw []" $
          parseExpr [] @?= ExRaw []

      , testCase "lvalue + literal → ExBinOp BopAdd" $
          parseExpr [mkTok TkIdent "ll_aa", mkTok TkArithOp "+", mkTok TkIntLiteral "1"]
            @?= ExBinOp
                  (ExLvalue (Lvalue [LvSegment "ll_aa" Nothing]))
                  BopAdd
                  (ExInt "1")

      , testCase "unmatched dot-method suffix without args → ExRaw" $
          parseExpr [ mkTok TkIdent "f", mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkDot "." ]
            @?= ExRaw ["f", "(", ")", "."]

      , testCase "unmatched open paren → ExRaw" $
          parseExpr [mkTok TkIdent "f", mkTok TkLParen "(", mkTok TkIdent "x"]
            @?= ExRaw ["f", "(", "x"]
      ]

    , testGroup "binary operators"
      [ testCase "a > 0 → ExBinOp BopGt" $
          parseExpr [ mkTok TkIdent "a", mkTok TkCompareOp ">", mkTok TkIntLiteral "0" ]
            @?= ExBinOp (ExLvalue (Lvalue [LvSegment "a" Nothing])) BopGt (ExInt "0")

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
                  (ExCall (Lvalue [LvSegment "IsNull" Nothing]) [ExLvalue (Lvalue [LvSegment "x" Nothing])])
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
      [ testCase "- x → ExNeg (ExLvalue x)" $
          parseExpr [ mkTok TkArithOp "-", mkTok TkIdent "x" ]
            @?= ExNeg (ExLvalue (Lvalue [LvSegment "x" Nothing]))

      , testCase "- 1 → ExNeg (ExInt)" $
          parseExpr [ mkTok TkArithOp "-", mkTok TkIntLiteral "1" ]
            @?= ExNeg (ExInt "1")
      ]

    , testGroup "dispatch"
      [ testCase "bare Post Event name() → ExDispatch Nothing DmPost isEvent" $
          parseExpr [ mkTok TkOtherKw "Post", mkTok TkDeclKw "Event"
                    , mkTok TkIdent "ue_refresh", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr Nothing DmPost False True "ue_refresh" [])

      , testCase "bare Trigger Event name() → ExDispatch Nothing DmTrigger isEvent" $
          parseExpr [ mkTok TkOtherKw "Trigger", mkTok TkDeclKw "Event"
                    , mkTok TkIdent "ue_retrieve", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr Nothing DmTrigger False True "ue_retrieve" [])

      , testCase "lvalue.Post Event name() → ExDispatch (Just lv) DmPost isEvent" $
          parseExpr [ mkTok TkIdent "iw_Frame", mkTok TkDot "."
                    , mkTok TkOtherKw "Post", mkTok TkDeclKw "Event"
                    , mkTok TkIdent "ue_opensheet", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "iw_Frame" Nothing]))
                  DmPost False True "ue_opensheet" [])

      , testCase "lvalue.Post Dynamic Event name() → DmPost dynamic isEvent" $
          parseExpr [ mkTok TkOtherKw "ParentWindow", mkTok TkDot "."
                    , mkTok TkOtherKw "Post", mkTok TkOtherKw "Dynamic"
                    , mkTok TkDeclKw "Event"
                    , mkTok TkIdent "ue_save", mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "ParentWindow" Nothing]))
                  DmPost True True "ue_save" [])

      , testCase "lvalue.Dynamic method() → DmSync dynamic not-event" $
          parseExpr [ mkTok TkOtherKw "ParentWindow", mkTok TkDot "."
                    , mkTok TkOtherKw "Dynamic"
                    , mkTok TkIdent "of_isprintpreview"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "ParentWindow" Nothing]))
                  DmSync True False "of_isprintpreview" [])

      , testCase "lvalue.Post Dynamic method() → DmPost dynamic not-event" $
          parseExpr [ mkTok TkOtherKw "ParentWindow", mkTok TkDot "."
                    , mkTok TkOtherKw "Post", mkTok TkOtherKw "Dynamic"
                    , mkTok TkIdent "of_new"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "ParentWindow" Nothing]))
                  DmPost True False "of_new" [])

      , testCase "lvalue.Trigger Event name(complex-arg) → arg parses into nested ExMethodCall" $
          parseExpr [ mkTok TkIdent "dw_dept", mkTok TkDot "."
                    , mkTok TkOtherKw "Trigger", mkTok TkDeclKw "Event"
                    , mkTok TkIdent "RowFocusChanged", mkTok TkLParen "("
                    , mkTok TkIdent "dw_dept", mkTok TkDot "."
                    , mkTok TkIdent "GetRow", mkTok TkLParen "(", mkTok TkRParen ")"
                    , mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "dw_dept" Nothing]))
                  DmTrigger False True "RowFocusChanged"
                  [ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_dept" Nothing])) "GetRow" []])

      , testCase "lvalue.Event name() (no qualifier) → DmSync isEvent" $
          parseExpr [ mkTok TkIdent "gb_htick", mkTok TkDot "."
                    , mkTok TkDeclKw "Event"
                    , mkTok TkIdent "ue_ChangeTicks"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "gb_htick" Nothing]))
                  DmSync False True "ue_ChangeTicks" [])

      , testCase "lvalue.Event Trigger Dynamic name(arg) → reversed-order variant" $
          parseExpr [ mkTok TkIdent "MenuID", mkTok TkDot "."
                    , mkTok TkDeclKw "Event", mkTok TkOtherKw "Trigger"
                    , mkTok TkOtherKw "Dynamic"
                    , mkTok TkIdent "ie_checkmenu", mkTok TkLParen "("
                    , mkTok TkIdent "dw"
                    , mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [LvSegment "MenuID" Nothing]))
                  DmTrigger True True "ie_checkmenu" [ExLvalue (Lvalue [LvSegment "dw" Nothing])])

      , testCase "deep-chain lvalue.Post Event name() → all segments in object" $
          parseExpr [ mkTok TkIdent "lm_Menu",    mkTok TkDot "."
                    , mkTok TkIdent "m_buffers",  mkTok TkDot "."
                    , mkTok TkIdent "m_openall",  mkTok TkDot "."
                    , mkTok TkOtherKw "Post",     mkTok TkDeclKw "Event"
                    , mkTok TkIdent "ue_opensheet"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExDispatch (DispatchExpr
                  (Just (Lvalue [ LvSegment "lm_Menu"   Nothing
                                , LvSegment "m_buffers" Nothing
                                , LvSegment "m_openall" Nothing ]))
                  DmPost False True "ue_opensheet" [])

      , testCase "regression: obj.post() with no name → falls through to ExMethodCall" $
          parseExpr [ mkTok TkIdent "obj", mkTok TkDot "."
                    , mkTok TkOtherKw "post"
                    , mkTok TkLParen "(", mkTok TkRParen ")" ]
            @?= ExMethodCall
                  (ExLvalue (Lvalue [LvSegment "obj" Nothing]))
                  "post" []
      ]

    , testGroup "precedence properties"
      [ testProperty "lower-prec op is root" propLowerPrecIsRoot
      , testProperty "left-associative operators chain left" propLeftAssoc
      , testProperty "^ is right-associative" propRightAssocPow
      , testProperty "not binds below comparison" propNotBindsBelowComparison
      , testProperty "not binds tighter than and/or/xor" propNotBindsAboveAnd
      ]
    , testProperty "total: parseExpr never raises" propParseExprTotal
    , testProperty "roundtrip: ExRaw tokens identical to input" propExRawRoundtrip
    ]

  , testGroup "unparse (Plan 14 Phase A)"
    [ testProperty "round-trip: parse . unparse . parse == parse" propUnparseRoundtrip
      -- ExMethodCall/ExDispatch/ExRaw are excluded from genExpr (see propUnparseRoundtrip's
      -- comment) -- pinned here instead so unparseExpr's coverage of them isn't untested.
    , testCase "ExMethodCall renders receiver.method(args)" $
        unparseExpr (ExMethodCall (ExCall (Lvalue [LvSegment "dw_1" Nothing]) []) "rowcount" [])
          @?= "dw_1().rowcount()"
    , testCase "ExDispatch renders [obj.][dynamic ][post|trigger ][event ]name(args)" $
        unparseExpr (ExDispatch (DispatchExpr
          (Just (Lvalue [LvSegment "iw_frame" Nothing])) DmPost True True "ue_close" []))
          @?= "iw_frame.dynamic post event ue_close()"
    , testCase "ExRaw renders space-joined verbatim fragments" $
        unparseExpr (ExRaw ["select", "*", "from", "t"]) @?= "select * from t"
    ]

  , localOption (SmallCheckDepth 3) $ testGroup "unparse exhaustive round-trip (SmallCheck)"
    [ SC.testProperty "round-trip: parse . unparse . parse == parse, exhaustive to depth 3"
        prop_exprSmallCheck
    ]

  , testGroup "exprChildren"
    [ testCase "ExBool -> []" $ exprChildren (ExBool True) @?= []
    , testCase "ExCall -> args (call arguments are Expr children, Plan 195 Phase C)" $
        exprChildren (ExCall (Lvalue [LvSegment "f" Nothing]) [ExInt "1"]) @?= [ExInt "1"]
    , testCase "ExBinOp -> [lhs, rhs]" $
        exprChildren (ExBinOp (ExInt "1") BopAdd (ExInt "2")) @?= [ExInt "1", ExInt "2"]
    , testCase "ExNot -> [e]" $
        exprChildren (ExNot (ExBool True)) @?= [ExBool True]
    , testCase "ExNeg -> [e]" $
        exprChildren (ExNeg (ExInt "1")) @?= [ExInt "1"]
    , testCase "ExMethodCall -> [receiver]" $
        exprChildren (ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "retrieve" [])
          @?= [ExLvalue (Lvalue [LvSegment "dw_1" Nothing])]
    , testCase "ExMethodCall -> receiver : args" $
        exprChildren (ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "retrieve" [ExInt "1"])
          @?= [ExLvalue (Lvalue [LvSegment "dw_1" Nothing]), ExInt "1"]
    , testCase "ExDispatch -> args" $
        exprChildren (ExDispatch (DispatchExpr Nothing DmSync False True "ue_foo" [ExInt "1"]))
          @?= [ExInt "1"]
    , testCase "ExCreateUsing -> [e]" $
        exprChildren (ExCreateUsing (ExLvalue (Lvalue [LvSegment "x" Nothing])))
          @?= [ExLvalue (Lvalue [LvSegment "x" Nothing])]
    , testCase "ExArray -> elements" $
        exprChildren (ExArray [ExInt "1", ExInt "2", ExInt "3"])
          @?= [ExInt "1", ExInt "2", ExInt "3"]
    ]

  , testGroup "foldExprs"
    [ testCase "leaf: ExInt visited once" $
        length (foldExprs (const [()]) (ExInt "1")) @?= 1
    , testCase "ExBinOp (ExInt, ExNot (ExBool)): 4 nodes in pre-order" $
        countNodes (foldExprs (const [()]) (ExBinOp (ExInt "1") BopAdd (ExNot (ExBool True))))
          @?= 4
    , testCase "ExArray [ExBool True, ExBool False]: 3 nodes total (array + 2 elements)" $
        countNodes (foldExprs (const [()]) (ExArray [ExBool True, ExBool False]))
          @?= 3
    , testCase "nested ExMethodCall receiver chain visited: a.b().c() visits both ExMethodCall nodes" $
        let expr = ExMethodCall
              (ExMethodCall (ExLvalue (Lvalue [LvSegment "a" Nothing])) "b" [])
              "c" []
            isMethodCall ExMethodCall{} = [()]
            isMethodCall _              = []
        in countNodes (foldExprs isMethodCall expr) @?= 2
    ]

  , testGroup "LvSegment case-insensitive equality (Plan 178 Phase 2)"
    [ testCase "name differing only in case -> equal (PB identifiers are case-insensitive)" $
        LvSegment "Foo" Nothing @?= LvSegment "foo" Nothing
    , testCase "distinct names -> unequal" $
        (LvSegment "Foo" Nothing == LvSegment "Bar" Nothing) @?= False
    ]

  , testGroup "ExMethodCall/DispatchExpr/ExCreate case-insensitive equality"
    [ testCase "ExMethodCall differing only in method case -> equal" $
        ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "Retrieve" []
          @?= ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "retrieve" []
    , testCase "ExMethodCall differing in method name -> unequal" $
        (ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "Retrieve" []
          == ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_1" Nothing])) "Update" []) @?= False
    , testCase "DispatchExpr differing only in name case -> equal" $
        DispatchExpr Nothing DmPost False True "Ue_Refresh" []
          @?= DispatchExpr Nothing DmPost False True "ue_refresh" []
    , testCase "ExCreate differing only in case -> equal" $
        ExCreate "N_Service" @?= ExCreate "n_service"
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
      , (TkDoubleColon, "::")
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
    ExBool         _ -> True
    ExInt          _ -> True
    ExReal         _ -> True
    ExStr          _ -> True
    ExDate         _ -> True
    ExTime         _ -> True
    ExNull           -> True
    ExEnum         _ -> True
    ExLvalue       _ -> True
    ExCall       {} -> True
    ExCreate       _ -> True
    ExCreateUsing  _ -> True
    ExArray        _ -> True
    ExNot          _ -> True
    ExHostVar      _ -> True
    ExBinOp      {} -> True
    ExNeg          _ -> True
    ExDispatch     _ -> True
    ExMethodCall {} -> True
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
    ExRaw texts -> texts === map tkText ts
    _           -> pure ()

-- ---------------------------------------------------------------------------
-- Precedence properties

-- (op text, token kind, BinOp constructor)
-- max(lowOps prec)=2  <  min(highOps prec)=4, so constraint holds for all pairs
lowOps, highOps :: [(Text, TokenKind, BinOp)]
lowOps  = [ ("or",  TkOtherKw,   BopOr)
          , ("xor", TkOtherKw,   BopXor)
          , ("and", TkOtherKw,   BopAnd)
          ]
highOps = [ (">",   TkCompareOp, BopGt)
          , ("<",   TkCompareOp, BopLt)
          , ("+",   TkArithOp,   BopAdd)
          , ("-",   TkArithOp,   BopSub)
          , ("*",   TkArithOp,   BopMul)
          , ("/",   TkArithOp,   BopDiv)
          ]

leftAssocOps :: [(Text, TokenKind, BinOp)]
leftAssocOps =
  [ ("+",   TkArithOp,   BopAdd), ("-",   TkArithOp,   BopSub)
  , ("*",   TkArithOp,   BopMul), ("/",   TkArithOp,   BopDiv)
  , ("and", TkOtherKw,   BopAnd), ("or",  TkOtherKw,   BopOr)
  , ("xor", TkOtherKw,   BopXor)
  , ("=",   TkAssignOp,  BopEq),  ("<>",  TkCompareOp, BopNe)
  , ("<",   TkCompareOp, BopLt),  (">",   TkCompareOp, BopGt)
  , ("<=",  TkCompareOp, BopLe),  (">=",  TkCompareOp, BopGe)
  ]

comparisonOps :: [(Text, TokenKind, BinOp)]
comparisonOps =
  [ ("=",  TkAssignOp,  BopEq), ("<>", TkCompareOp, BopNe)
  , ("<",  TkCompareOp, BopLt), (">",  TkCompareOp, BopGt)
  , ("<=", TkCompareOp, BopLe), (">=", TkCompareOp, BopGe)
  ]

logicalOps :: [(Text, TokenKind, BinOp)]
logicalOps = [ ("and", TkOtherKw, BopAnd)
             , ("or",  TkOtherKw, BopOr)
             , ("xor", TkOtherKw, BopXor)
             ]

-- | x lowOp y highOp z → lowOp is the root, highOp is the right child's op.
propLowerPrecIsRoot :: Property
propLowerPrecIsRoot = property $ do
  (loTxt, loKind, loBop) <- forAll $ Gen.element lowOps
  (hiTxt, hiKind, hiBop) <- forAll $ Gen.element highOps
  let ts = [ mkTok TkIdent "x", mkTok loKind loTxt
           , mkTok TkIdent "y", mkTok hiKind hiTxt
           , mkTok TkIdent "z" ]
  case parseExpr ts of
    ExBinOp _ root (ExBinOp _ inner _)
      | root == loBop && inner == hiBop -> pure ()
    other -> footnote (show other) >> failure

-- | x op y op z → left-leaning tree for every left-associative operator.
propLeftAssoc :: Property
propLeftAssoc = property $ do
  (opTxt, opKind, bop) <- forAll $ Gen.element leftAssocOps
  let ts = [ mkTok TkIdent "x", mkTok opKind opTxt
           , mkTok TkIdent "y", mkTok opKind opTxt
           , mkTok TkIdent "z" ]
  case parseExpr ts of
    ExBinOp (ExBinOp _ op1 _) op2 _
      | op1 == bop && op2 == bop -> pure ()
    other -> footnote (show other) >> failure

-- | x ^ y ^ z → right-leaning tree (only ^ is right-associative).
propRightAssocPow :: Property
propRightAssocPow = property $ do
  let ts = [ mkTok TkIdent "x", mkTok TkArithOp "^"
           , mkTok TkIdent "y", mkTok TkArithOp "^"
           , mkTok TkIdent "z" ]
  case parseExpr ts of
    ExBinOp _ BopPow (ExBinOp _ BopPow _) -> pure ()
    other -> footnote (show other) >> failure

-- | not a cmpOp b → ExNot wraps the whole comparison.
-- climbPrec 4 inside the not-atom consumes comparison ops (prec 4 >= 4).
propNotBindsBelowComparison :: Property
propNotBindsBelowComparison = property $ do
  (cmpTxt, cmpKind, cmp) <- forAll $ Gen.element comparisonOps
  let ts = [ mkTok TkOtherKw "not", mkTok TkIdent "a"
           , mkTok cmpKind cmpTxt,   mkTok TkIdent "b" ]
  case parseExpr ts of
    ExNot (ExBinOp _ op _) | op == cmp -> pure ()
    other -> footnote (show other) >> failure

-- | not a logicalOp b → ExNot wraps only a; logical op becomes the root.
-- climbPrec 4 stops before and/or/xor (prec 1-2 < 4).
propNotBindsAboveAnd :: Property
propNotBindsAboveAnd = property $ do
  (logTxt, logKind, logBop) <- forAll $ Gen.element logicalOps
  let ts = [ mkTok TkOtherKw "not", mkTok TkIdent "a"
           , mkTok logKind logTxt,   mkTok TkIdent "b" ]
  case parseExpr ts of
    ExBinOp (ExNot _) op _ | op == logBop -> pure ()
    other -> footnote (show other) >> failure

-- ---------------------------------------------------------------------------
-- Unparse round-trip generator (Plan 14 Phase A)

-- Small fixed identifier pool -- avoids PB keywords that parseAtom handles
-- specially (not/and/or/create/true/false/null) so every generated name
-- lexes as a plain TkIdent.
genIdentText :: Gen Text
genIdentText = Gen.element ["foo", "bar", "baz", "ll_row", "idx", "obj", "dw_1", "is_ok", "count", "value"]

genSubscript :: Gen (Maybe [Token])
genSubscript = Gen.maybe (Gen.element
  [ [mkTok TkIntLiteral "0"], [mkTok TkIntLiteral "1"], [mkTok TkIdent "i"] ])

genLvSegment :: Gen LvSegment
genLvSegment = LvSegment <$> (mkIdent <$> genIdentText) <*> genSubscript

genLvalue :: Gen Lvalue
genLvalue = Lvalue <$> Gen.list (Range.linear 1 3) genLvSegment

-- | Single-segment-only lvalue, for 'ExCall's callee generator below --
-- after Plan 195 Phase B, a 2+ segment dotted call parses as 'ExMethodCall',
-- not 'ExCall', so a multi-segment 'ExCall' is not producible by real
-- parsing (same reasoning as the four constructors excluded from 'genExpr'
-- below).
genBareLvalue :: Gen Lvalue
genBareLvalue = Lvalue . (:[]) <$> genLvSegment

allBinOps :: [BinOp]
allBinOps =
  [ BopAdd, BopSub, BopMul, BopDiv, BopPow
  , BopEq, BopNe, BopLt, BopGt, BopLe, BopGe
  , BopAnd, BopOr, BopXor
  ]

genLiteral :: Gen Expr
genLiteral = Gen.choice
  [ ExBool <$> Gen.bool
  , ExInt  <$> Gen.element ["0", "1", "42", "100"]
  , ExReal <$> Gen.element ["0.0", "1.5", "3.14"]
  , ExStr  <$> Gen.element ["hello", "world", "abc123", ""]
  , ExDate <$> Gen.element ["2024-01-01", "1999-12-31"]
  , ExTime <$> Gen.element ["12:00:00", "00:00:01"]
  , pure ExNull
  ]

-- | Terminal (non-recursive) and compound (recursive) generators for a
-- structured Expr, excluding ExRaw/ExMethodCall/ExDispatch/ExHostVar. None
-- of the four are safely nestable here:
--   - ExRaw: re-lexing arbitrary raw fragments isn't guaranteed stable
--     (plan's own documented exclusion), covered by propExRawRoundtrip instead.
--   - ExMethodCall: only arises from PB.Grammar.Body's chainCalls chaining a
--     further ".method()" onto an already call-shaped atom -- a flat
--     ExMethodCall wrapping a bare ExLvalue receiver is not producible by
--     real parsing, so a naive generator would create values whose
--     unparse legitimately fails to round-trip (not a bug).
--   - ExDispatch: a degenerate value (mode=DmSync, dynamic=False,
--     event=False) unparses to plain "name(args)", which reparses as
--     ExCall, not ExDispatch -- same generator-domain mismatch.
--   - ExCall's callee is restricted to a single-segment lvalue
--     ('genBareLvalue', not 'genLvalue'): after Plan 195 Phase B, a 2+
--     segment dotted call reparses as ExMethodCall, not ExCall -- the same
--     generator-domain mismatch as the three above, just on the callee
--     shape rather than the whole constructor.
--   - ExHostVar: parseExpr (PB.Grammar.Body, line ~337) only recognises
--     TkColon as a HostVar when it is the FIRST token of the WHOLE
--     expression being parsed; parseAtom/climbPrec have no TkColon case at
--     all, so ":foo" can never round-trip as an ExBinOp/ExNot/ExNeg/
--     ExCreateUsing operand -- found by this property (see plan/BACKLOG
--     grooming note), not a hypothetical. Safe only at the true top level.
-- All four are pinned instead via hand-built testCase values, or (ExHostVar)
-- generated only at the top level below, never as a recursive sub-term.
genExpr :: Gen Expr
genExpr = Gen.recursive Gen.choice
  [ genLiteral
  , ExEnum <$> Gen.element ["Black", "Red", "White"]
  , ExLvalue <$> genLvalue
  ]
  [ ExCall <$> genBareLvalue <*> Gen.list (Range.linear 0 2) genExpr
  , ExCreate . mkIdent <$> genIdentText
  , ExCreateUsing <$> genExpr
  , ExArray <$> Gen.list (Range.linear 0 2) genExpr
  , ExNot <$> genExpr
  , ExNeg <$> genExpr
  , (\lhs op rhs -> ExBinOp lhs op rhs) <$> genExpr <*> Gen.element allBinOps <*> genExpr
  ]

-- | Zero real token spans on every 'Lvalue' subscript reachable from an
-- 'Expr', mirroring 'BodyStmtTest.normalizeBodyStmt''s 'zeroSpan' for the
-- same reason: a generator can't predict the real column a reparse assigns
-- to a subscript token (unlike a bare identifier's own 'Ident', whose 'Eq'
-- instance already ignores span). Covers exactly the constructors 'genExpr'
-- and 'propUnparseRoundtrip' produce.
normalizeExpr :: Expr -> Expr
normalizeExpr e = case e of
  ExLvalue lv                  -> ExLvalue (normalizeLvalue lv)
  ExHostVar lv                 -> ExHostVar (normalizeLvalue lv)
  ExCall { callee = c, callArgs = as } ->
    ExCall { callee = normalizeLvalue c, callArgs = map normalizeExpr as }
  ExCreateUsing e'              -> ExCreateUsing (normalizeExpr e')
  ExArray es                    -> ExArray (map normalizeExpr es)
  ExNot e'                      -> ExNot (normalizeExpr e')
  ExNeg e'                      -> ExNeg (normalizeExpr e')
  ExBinOp { lhs = l, op = o, rhs = r } ->
    ExBinOp { lhs = normalizeExpr l, op = o, rhs = normalizeExpr r }
  other                          -> other
  where
    normalizeLvalue (Lvalue segs) = Lvalue (map normalizeSeg segs)
    normalizeSeg (LvSegment n sub) = LvSegment n (fmap (map zeroSpan) sub)
    zeroSpan t = t { tkSpan = SourceSpan 0 0 0 0 }

propUnparseRoundtrip :: Property
propUnparseRoundtrip = property $ do
  -- ExHostVar only ever at the top level -- see genExpr's exclusion note.
  expr <- forAll $ Gen.choice [genExpr, ExHostVar <$> genLvalue]
  let text = unparseExpr expr
      ll   = mkLogicalLine text 1
  case lexResult (tokenizeLine ll) of
    Left err   -> footnote ("lex error: " <> show err <> " for unparsed text: " <> show text) >> failure
    Right toks -> normalizeExpr (parseExpr toks) === normalizeExpr expr

-- | Exhaustive counterpart to 'propUnparseRoundtrip': enumerates every
-- 'StructuredExpr' up to the SmallCheck depth (set to 3 at the call site)
-- rather than sampling. A lex failure here is reported via
-- 'Either String ()' -- SmallCheck's own failure message is the
-- counterexample itself, so no extra footnote plumbing is needed the way
-- Hedgehog's forAll/footnote pairing requires.
prop_exprSmallCheck :: StructuredExpr -> Either String String
prop_exprSmallCheck (SE expr) =
  let text = unparseExpr expr
      ll   = mkLogicalLine text 1
  in case lexResult (tokenizeLine ll) of
       Left err   -> Left ("lex error: " <> show err <> " for unparsed text: " <> show text)
       Right toks
         | parseExpr toks == expr -> Right "ok"
         | otherwise -> Left ("round-trip mismatch for unparsed text: " <> show text)
