module BodyStmtTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt        (AugOp (..), BodyStmt (..), PbCall (..))
import PB.AST.Expr            (CallExpr (..), Expr (..), Literal (..), LvSegment (..), Lvalue (..))
import PB.Grammar.Body        (classifyBodyStmt, parseBodyStmts, parseLvalue)
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Hedgehog (Property, assert, forAll, property)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty              (TestTree, testGroup)
import Test.Tasty.HUnit        (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog     (testProperty)

-- ---------------------------------------------------------------------------
-- Helpers

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1)

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens = map (uncurry mkTok) pairs
  , stmtSource = LogicalLine "" 1 1
  }

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Body"
  [ testGroup "classifyBodyStmt"
    [ testCase "local var: builtin type + name" $
        classifyBodyStmt (mkStmt [(TkDatatype, "long"), (TkIdent, "ll_row")])
          @?= BsLocalVar [mkTok TkDatatype "long", mkTok TkIdent "ll_row"]

    , testCase "local var: user-defined type + name (both TkIdent)" $
        classifyBodyStmt (mkStmt [(TkIdent, "cb_delete"), (TkIdent, "cb_delete")])
          @?= BsLocalVar [mkTok TkIdent "cb_delete", mkTok TkIdent "cb_delete"]

    , testCase "local var: storage modifier + type + name" $
        classifyBodyStmt
          (mkStmt [(TkStorageModifier, "constant"), (TkDatatype, "long"), (TkIdent, "max_val")])
          @?= BsLocalVar [ mkTok TkStorageModifier "constant"
                         , mkTok TkDatatype "long"
                         , mkTok TkIdent "max_val"
                         ]

    , testCase "local var: type + name + initializer (all tokens kept)" $
        classifyBodyStmt
          (mkStmt [(TkDatatype, "long"), (TkIdent, "ll_row"), (TkAssignOp, "="), (TkIntLiteral, "0")])
          @?= BsLocalVar [ mkTok TkDatatype "long", mkTok TkIdent "ll_row"
                         , mkTok TkAssignOp "=",   mkTok TkIntLiteral "0"
                         ]

    , testCase "local var: dec{0} precision specifier → BsLocalVar" $
        classifyBodyStmt
          (mkStmt [(TkDatatype,"dec"),(TkLBrace,"{"),(TkIntLiteral,"0"),(TkRBrace,"}"),(TkIdent,"lc_0")])
          @?= BsLocalVar [ mkTok TkDatatype "dec", mkTok TkLBrace "{"
                         , mkTok TkIntLiteral "0",  mkTok TkRBrace "}"
                         , mkTok TkIdent "lc_0" ]

    , testCase "local var: dec{10} two-digit precision → BsLocalVar" $
        classifyBodyStmt
          (mkStmt [(TkDatatype,"dec"),(TkLBrace,"{"),(TkIntLiteral,"10"),(TkRBrace,"}"),(TkIdent,"lc_10")])
          @?= BsLocalVar [ mkTok TkDatatype "dec", mkTok TkLBrace "{"
                         , mkTok TkIntLiteral "10", mkTok TkRBrace "}"
                         , mkTok TkIdent "lc_10" ]

    , testCase "assign: simple ident = int literal" $
        classifyBodyStmt (mkStmt [(TkIdent, "ll_row"), (TkAssignOp, "="), (TkIntLiteral, "0")])
          @?= BsAssign (Lvalue [LvSegment "ll_row" Nothing]) (ExLit (LitInt "0"))

    , testCase "assign: property set (obj.field = val)" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "idw_main"), (TkDot, "."), (TkIdent, "enabled")
                  , (TkAssignOp, "="), (TkBoolFalse, "false")
                  ])
          @?= BsAssign
                (Lvalue [LvSegment "idw_main" Nothing, LvSegment "enabled" Nothing])
                (ExLit (LitBool False))

    , testCase "assign: rhs is a method call" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "ll_row"), (TkAssignOp, "=")
                  , (TkIdent, "dw_main"), (TkDot, "."), (TkIdent, "getrow")
                  , (TkLParen, "("), (TkRParen, ")")
                  ])
          @?= BsAssign
                (Lvalue [LvSegment "ll_row" Nothing])
                (ExCall (CallExpr
                  (Lvalue [LvSegment "dw_main" Nothing, LvSegment "getrow" Nothing])
                  []))

    , testCase "assign: chained-call LHS → BsAssignExpr" $
        -- obj.cells(1).value = 42 — lvaluePrefix stops at cells; falls back to expr-based assign
        classifyBodyStmt
          (mkStmt [ (TkIdent, "obj"), (TkDot, "."), (TkIdent, "cells")
                  , (TkLParen, "("), (TkIntLiteral, "1"), (TkRParen, ")")
                  , (TkDot, "."), (TkIdent, "value")
                  , (TkAssignOp, "="), (TkIntLiteral, "42") ])
          @?= BsAssignExpr
                (ExMethodCall
                  (ExCall (CallExpr
                    (Lvalue [LvSegment "obj" Nothing, LvSegment "cells" Nothing])
                    [[mkTok TkIntLiteral "1"]]))
                  "value" [])
                (ExLit (LitInt "42"))

    , testCase "aug_assign: +=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "+="), (TkIntLiteral, "1")])
          @?= BsAugAssign [mkTok TkIdent "n"] AugAdd [mkTok TkIntLiteral "1"]

    , testCase "aug_assign: -=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "-="), (TkIntLiteral, "1")])
          @?= BsAugAssign [mkTok TkIdent "n"] AugSub [mkTok TkIntLiteral "1"]

    , testCase "aug_assign: *=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "*="), (TkIntLiteral, "2")])
          @?= BsAugAssign [mkTok TkIdent "n"] AugMul [mkTok TkIntLiteral "2"]

    , testCase "aug_assign: /=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "/="), (TkIntLiteral, "2")])
          @?= BsAugAssign [mkTok TkIdent "n"] AugDiv [mkTok TkIntLiteral "2"]

    , testCase "inc: ++" $
        classifyBodyStmt (mkStmt [(TkIdent, "n"), (TkAugmentOp, "++")])
          @?= BsInc [mkTok TkIdent "n"]

    , testCase "dec: --" $
        classifyBodyStmt (mkStmt [(TkIdent, "n"), (TkAugmentOp, "--")])
          @?= BsDec [mkTok TkIdent "n"]

    , testCase "call: method call (obj.method())" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "dw_main"), (TkDot, "."), (TkIdent, "accepttext")
                  , (TkLParen, "("), (TkRParen, ")")
                  ])
          @?= BsCall
                (ExCall (CallExpr
                  (Lvalue [LvSegment "dw_main" Nothing, LvSegment "accepttext" Nothing])
                  []))

    , testCase "call: free function (f(arg))" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "messagebox"), (TkLParen, "("), (TkIdent, "msg"), (TkRParen, ")")])
          @?= BsCall
                (ExCall (CallExpr
                  (Lvalue [LvSegment "messagebox" Nothing])
                  [[mkTok TkIdent "msg"]]))

    , testCase "return: with value" $
        classifyBodyStmt (mkStmt [(TkControlKw, "return"), (TkBoolTrue, "true")])
          @?= BsReturn (Just (ExLit (LitBool True)))

    , testCase "return: bare (no expression)" $
        classifyBodyStmt (mkStmt [(TkControlKw, "return")])
          @?= BsReturn Nothing

    , testCase "raw: if statement" $
        case classifyBodyStmt
               (mkStmt [(TkControlKw, "if"), (TkIdent, "x"), (TkAssignOp, "="), (TkIntLiteral, "0"), (TkControlKw, "then")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testCase "raw: end if" $
        case classifyBodyStmt (mkStmt [(TkControlKw, "end if")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testCase "raw: sql commit" $
        case classifyBodyStmt
               (mkStmt [(TkSqlKw, "commit"), (TkOtherKw, "using"), (TkOtherKw, "sqlca")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testCase "raw: empty statement" $
        case classifyBodyStmt (mkStmt []) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testCase "call: close(parent) — sql-kw callee no space" $
        classifyBodyStmt
          (mkStmt [(TkSqlKw, "close"), (TkLParen, "("), (TkIdent, "parent"), (TkRParen, ")")])
          @?= BsCall (ExCall (CallExpr
                (Lvalue [LvSegment "close" Nothing])
                [[mkTok TkIdent "parent"]]))

    , testCase "call: Close (lw_sheet) — sql-kw callee with space before paren" $
        classifyBodyStmt
          (mkStmt [(TkSqlKw, "Close"), (TkLParen, "("), (TkIdent, "lw_sheet"), (TkRParen, ")")])
          @?= BsCall (ExCall (CallExpr
                (Lvalue [LvSegment "Close" Nothing])
                [[mkTok TkIdent "lw_sheet"]]))

    , testCase "call: open(w_main) — single-arg open" $
        classifyBodyStmt
          (mkStmt [(TkSqlKw, "open"), (TkLParen, "("), (TkIdent, "w_main"), (TkRParen, ")")])
          @?= BsCall (ExCall (CallExpr
                (Lvalue [LvSegment "open" Nothing])
                [[mkTok TkIdent "w_main"]]))

    , testCase "call: open(w_main, this) — two-arg open" $
        classifyBodyStmt
          (mkStmt [ (TkSqlKw, "open"), (TkLParen, "(")
                  , (TkIdent, "w_main"), (TkComma, ","), (TkOtherKw, "this")
                  , (TkRParen, ")")])
          @?= BsCall (ExCall (CallExpr
                (Lvalue [LvSegment "open" Nothing])
                [[mkTok TkIdent "w_main"], [mkTok TkOtherKw "this"]]))

    , testCase "raw: OPEN DYNAMIC — sql cursor op stays BsRaw" $
        case classifyBodyStmt
               (mkStmt [(TkSqlKw, "OPEN"), (TkOtherKw, "DYNAMIC"), (TkIdent, "lc_dept")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testCase "raw: CLOSE cur — sql cursor close stays BsRaw" $
        case classifyBodyStmt
               (mkStmt [(TkSqlKw, "CLOSE"), (TkIdent, "cur")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testCase "raw: TkLabel access-modifier header → BsRaw" $
        case classifyBodyStmt (mkStmt [(TkLabel, "public:")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)

    , testProperty "total: classifyBodyStmt never raises for any token list"
        propClassifyTotal
    ]

  , testGroup "PbCall"
    [ testCase "call super :: open" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkOtherKw, "super")
                  , (TkDoubleColon, "::"), (TkIdent, "open") ])
          @?= BsPbCall (PbCall "super" "open")

    , testCase "call named ancestor :: event" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkIdent, "w_ancestor")
                  , (TkDoubleColon, "::"), (TkIdent, "clicked") ])
          @?= BsPbCall (PbCall "w_ancestor" "clicked")

    , testCase "call ancestor with backtick control :: event (single ident token)" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkIdent, "w_emp`cb_close")
                  , (TkDoubleColon, "::"), (TkIdent, "clicked") ])
          @?= BsPbCall (PbCall "w_emp`cb_close" "clicked")

    , testCase "call where event name is a keyword token (e.g. create)" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkOtherKw, "super")
                  , (TkDoubleColon, "::"), (TkOtherKw, "create") ])
          @?= BsPbCall (PbCall "super" "create")

    , testCase "call missing :: falls to BsRaw" $
        case classifyBodyStmt
               (mkStmt [(TkOtherKw, "call"), (TkOtherKw, "super"), (TkIdent, "open")]) of
          BsRaw _ -> return ()
          other   -> assertFailure ("expected BsRaw, got: " <> show other)
    ]

  , testGroup "Destroy"
    [ testCase "destroy simple variable" $
        classifyBodyStmt
          (mkStmt [(TkOtherKw, "destroy"), (TkIdent, "obj")])
          @?= BsDestroy (Lvalue [LvSegment "obj" Nothing])

    , testCase "destroy dotted lvalue" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "destroy"), (TkIdent, "Category")
                  , (TkDot, "."), (TkIdent, "DispAttr") ])
          @?= BsDestroy (Lvalue [LvSegment "Category" Nothing, LvSegment "DispAttr" Nothing])

    , testCase "destroy subscripted lvalue" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "destroy"), (TkIdent, "ids_Data")
                  , (TkLBracket, "["), (TkIdent, "li_Cnt"), (TkRBracket, "]") ])
          @?= BsDestroy (Lvalue [LvSegment "ids_Data" (Just [mkTok TkIdent "li_Cnt"])])

    , testCase "destroy with no argument emits BsCall" $
        classifyBodyStmt (mkStmt [(TkOtherKw, "destroy")])
          @?= BsCall (ExLvalue (Lvalue [LvSegment "destroy" Nothing]))

    , testCase "destroy function-call form emits BsCall" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "destroy"), (TkLParen, "(")
                  , (TkOtherKw, "this"), (TkDot, "."), (TkIdent, "m_foo")
                  , (TkRParen, ")") ])
          @?= BsCall (ExCall (CallExpr
                (Lvalue [LvSegment "destroy" Nothing])
                [[mkTok TkOtherKw "this", mkTok TkDot ".", mkTok TkIdent "m_foo"]]))
    ]

  , testGroup "parseBodyStmts"
    [ testCase "empty list" $
        parseBodyStmts [] @?= []

    , testCase "single assign becomes singleton" $
        parseBodyStmts [mkStmt [(TkIdent, "x"), (TkAssignOp, "="), (TkIntLiteral, "1")]]
          @?= [BsAssign (Lvalue [LvSegment "x" Nothing]) (ExLit (LitInt "1"))]

    , testCase "mixed stmts: var decl, assign, return — order preserved" $
        let stmts =
              [ mkStmt [(TkDatatype, "long"), (TkIdent, "n")]
              , mkStmt [(TkIdent, "n"), (TkAssignOp, "="), (TkIntLiteral, "5")]
              , mkStmt [(TkControlKw, "return"), (TkIdent, "n")]
              ]
            tags = map tag (parseBodyStmts stmts)
        in tags @?= ["var", "assign", "return"]
    ]

  , testGroup "Lvalue"
    [ testGroup "parseLvalue"
      [ testCase "simple identifier" $
          parseLvalue [mkTok TkIdent "foo"]
            @?= Just (Lvalue [LvSegment "foo" Nothing])

      , testCase "single member access" $
          parseLvalue [mkTok TkIdent "cb_ok", mkTok TkDot ".", mkTok TkIdent "enabled"]
            @?= Just (Lvalue [LvSegment "cb_ok" Nothing, LvSegment "enabled" Nothing])

      , testCase "three-level chain" $
          parseLvalue [ mkTok TkIdent "tab1", mkTok TkDot "."
                      , mkTok TkIdent "page1", mkTok TkDot "."
                      , mkTok TkIdent "text" ]
            @?= Just (Lvalue [ LvSegment "tab1"  Nothing
                              , LvSegment "page1" Nothing
                              , LvSegment "text"  Nothing ])

      , testCase "array subscript only" $
          parseLvalue [ mkTok TkIdent "is_steps"
                      , mkTok TkLBracket "["
                      , mkTok TkIdent "ii_steps"
                      , mkTok TkRBracket "]" ]
            @?= Just (Lvalue [LvSegment "is_steps" (Just [mkTok TkIdent "ii_steps"])])

      , testCase "chain plus subscript on last segment" $
          parseLvalue [ mkTok TkIdent "adw",    mkTok TkDot "."
                      , mkTok TkIdent "object", mkTok TkDot "."
                      , mkTok TkIdent "kodypal"
                      , mkTok TkLBracket "[", mkTok TkIdent "row", mkTok TkRBracket "]" ]
            @?= Just (Lvalue [ LvSegment "adw"     Nothing
                              , LvSegment "object"  Nothing
                              , LvSegment "kodypal" (Just [mkTok TkIdent "row"]) ])

      , testCase "TkOtherKw head (this.member)" $
          parseLvalue [mkTok TkOtherKw "this", mkTok TkDot ".", mkTok TkIdent "enabled"]
            @?= Just (Lvalue [LvSegment "this" Nothing, LvSegment "enabled" Nothing])

      , testCase "complex subscript expression" $ do
          let subTokens = [ mkTok TkIdent "UpperBound", mkTok TkLParen "("
                          , mkTok TkOtherKw "this", mkTok TkDot "."
                          , mkTok TkIdent "Item", mkTok TkRParen ")"
                          , mkTok TkArithOp "+", mkTok TkIntLiteral "1" ]
              input = [ mkTok TkOtherKw "this", mkTok TkDot "."
                      , mkTok TkIdent "Item", mkTok TkLBracket "[" ]
                      <> subTokens
                      <> [mkTok TkRBracket "]"]
          parseLvalue input
            @?= Just (Lvalue [ LvSegment "this" Nothing
                              , LvSegment "Item" (Just subTokens) ])

      , testCase "empty tokens returns Nothing" $
          parseLvalue [] @?= Nothing

      , testCase "starts with dot returns Nothing" $
          parseLvalue [mkTok TkDot ".", mkTok TkIdent "foo"] @?= Nothing

      , testCase "two adjacent idents (no dot) returns Nothing" $
          parseLvalue [mkTok TkIdent "foo", mkTok TkIdent "bar"] @?= Nothing

      , testCase "unmatched open bracket returns Nothing" $
          parseLvalue [mkTok TkIdent "arr", mkTok TkLBracket "[", mkTok TkIdent "i"]
            @?= Nothing

      , testCase "TkSqlKw segment in dotted path (obj.object.open[i])" $
          parseLvalue [ mkTok TkIdent "adw", mkTok TkDot "."
                      , mkTok TkIdent "object", mkTok TkDot "."
                      , mkTok TkSqlKw "open"
                      , mkTok TkLBracket "[", mkTok TkIdent "i", mkTok TkRBracket "]" ]
            @?= Just (Lvalue [ LvSegment "adw"    Nothing
                              , LvSegment "object" Nothing
                              , LvSegment "open"   (Just [mkTok TkIdent "i"]) ])
      ]

    , testGroup "classifyBodyStmt BsAssign with Lvalue"
      [ testCase "simple assign produces structured lhs" $
          classifyBodyStmt
            (mkStmt [(TkIdent, "foo"), (TkAssignOp, "="), (TkIntLiteral, "1")])
            @?= BsAssign (Lvalue [LvSegment "foo" Nothing]) (ExLit (LitInt "1"))

      , testCase "member chain assign" $
          classifyBodyStmt
            (mkStmt [ (TkIdent, "cb_ok"), (TkDot, "."), (TkIdent, "enabled")
                    , (TkAssignOp, "="), (TkBoolFalse, "false") ])
            @?= BsAssign
                  (Lvalue [LvSegment "cb_ok" Nothing, LvSegment "enabled" Nothing])
                  (ExLit (LitBool False))

      , testCase "array subscript assign" $
          classifyBodyStmt
            (mkStmt [ (TkIdent, "arr"), (TkLBracket, "["), (TkIdent, "i"), (TkRBracket, "]")
                    , (TkAssignOp, "="), (TkIntLiteral, "0") ])
            @?= BsAssign
                  (Lvalue [LvSegment "arr" (Just [mkTok TkIdent "i"])])
                  (ExLit (LitInt "0"))

      , testCase "unparseable lhs falls back to BsRaw" $
          case classifyBodyStmt
                 (mkStmt [ (TkAssignOp, "="), (TkIdent, "foo")
                         , (TkAssignOp, "="), (TkIntLiteral, "1") ]) of
            BsRaw _ -> return ()
            other   -> assertFailure ("expected BsRaw, got: " <> show other)

      , testCase "assign: sql-kw segment in dotted lhs (adw.object.open[i] = 0)" $
          classifyBodyStmt
            (mkStmt [ (TkIdent, "adw"), (TkDot, "."), (TkIdent, "object"), (TkDot, ".")
                    , (TkSqlKw, "open")
                    , (TkLBracket, "["), (TkIdent, "i"), (TkRBracket, "]")
                    , (TkAssignOp, "="), (TkIntLiteral, "0") ])
            @?= BsAssign
                  (Lvalue [ LvSegment "adw"    Nothing
                           , LvSegment "object" Nothing
                           , LvSegment "open"   (Just [mkTok TkIdent "i"]) ])
                  (ExLit (LitInt "0"))

      , testCase "array literal rhs: this.Item[]={this.m_file, this.m_edit}" $
          classifyBodyStmt
            (mkStmt [ (TkOtherKw, "this"), (TkDot, "."), (TkIdent, "Item")
                    , (TkLBracket, "["), (TkRBracket, "]")
                    , (TkAssignOp, "=")
                    , (TkLBrace, "{")
                    , (TkOtherKw, "this"), (TkDot, "."), (TkIdent, "m_file")
                    , (TkComma, ",")
                    , (TkOtherKw, "this"), (TkDot, "."), (TkIdent, "m_edit")
                    , (TkRBrace, "}") ])
            @?= BsAssign
                  (Lvalue [ LvSegment "this" Nothing
                           , LvSegment "Item" (Just []) ])
                  (ExArray [ ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                              , LvSegment "m_file" Nothing ])
                           , ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                              , LvSegment "m_edit" Nothing ]) ])
      ]
    ]
  ]

tag :: BodyStmt -> Text
tag (BsLocalVar  _)     = "var"
tag (BsAssign    _ _)   = "assign"
tag (BsAugAssign _ _ _) = "aug_assign"
tag (BsInc       _)     = "inc"
tag (BsDec       _)     = "dec"
tag (BsCall      _)     = "call"
tag (BsPbCall    _)     = "pb_call"
tag (BsReturn    _)     = "return"
tag (BsIf        _)     = "if"
tag (BsFor       _)     = "for"
tag (BsDo        _)     = "do"
tag (BsChoose    _)     = "choose"
tag BsExit              = "exit"
tag BsContinue          = "continue"
tag (BsDestroy    _)    = "destroy"
tag (BsAssignExpr _ _)  = "assign_expr"
tag (BsRaw        _)    = "raw"

propClassifyTotal :: Property
propClassifyTotal = property $ do
  pairs <- forAll $ Gen.list (Range.linear 0 10)
    (Gen.element
      [ (TkIdent,          "foo")
      , (TkDatatype,       "long")
      , (TkControlKw,      "if")
      , (TkControlKw,      "return")
      , (TkAssignOp,       "=")
      , (TkAugmentOp,      "++")
      , (TkAugmentOp,      "+=")
      , (TkDot,            ".")
      , (TkLParen,         "(")
      , (TkRParen,         ")")
      , (TkIntLiteral,     "1")
      , (TkBoolTrue,       "true")
      , (TkSqlKw,          "commit")
      , (TkStorageModifier,"constant")
      ])
  let stmt   = mkStmt pairs
      result = classifyBodyStmt stmt
  assert $ case result of
    BsLocalVar  _     -> True
    BsAssign    _ _   -> True
    BsAugAssign _ _ _ -> True
    BsInc       _     -> True
    BsDec       _     -> True
    BsCall      _     -> True
    BsPbCall    _     -> True
    BsReturn    _     -> True
    BsIf        _     -> True
    BsFor       _     -> True
    BsDo        _     -> True
    BsChoose    _     -> True
    BsExit            -> True
    BsContinue        -> True
    BsDestroy    _    -> True
    BsAssignExpr _ _  -> True
    BsRaw        _    -> True
