module BodyStmtTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
  ( AugOp (..), BodyStmt (..), CaseClause (..), CatchClause (..)
  , ChooseStmt (..), DoCondition (..), DoStmt (..), ElseIf (..)
  , ForStmt (..), IfStmt (..), PbCall (..), TryStmt (..)
  , foldStmts, stmtChildren
  )
import PB.AST.Expr            (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident           (identOrig, mkIdent)
import PB.AST.Located         (Located (..))
import PB.AST.Type            (PbType (..))
import PB.Grammar.Body        (classifyBodyStmt, parseBodyStmts, parseLvalue, pBodyStmt)
import PB.Grammar.Stream      (StmtStream (..))
import PB.Grammar.Unparse     (unparseBodyStmt)
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Lexer        (tokenize, tokenizeLine, LexLine (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Emit       (collectStatements)
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText)

import Data.List               (nub)
import Hedgehog (Gen, Property, assert, eval, failure, footnote, forAll, property, success, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import qualified Data.Text      as T
import SmallCheckInstances      (StructuredLeafBodyStmt (..))
import Test.Tasty              (TestTree, localOption, testGroup)
import Test.Tasty.HUnit        (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog     (testProperty)
import Test.Tasty.SmallCheck   (SmallCheckDepth (..))
import qualified Test.Tasty.SmallCheck as SC
import Text.Megaparsec         (eof, many, parse)
import Text.Megaparsec.Error   (errorBundlePretty)

-- ---------------------------------------------------------------------------
-- Helpers

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1)

tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk
  _            -> Token TkIdent t (SourceSpan 1 1 1)
  where ll = LogicalLine t 1 1

at :: Int -> BodyStmt -> Located BodyStmt
at = Located

rawTexts :: [Located BodyStmt] -> [Text]
rawTexts = foldStmts classify
  where
    classify (Located _ (BsRaw t)) = [t]
    classify _                     = []

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens    = map (uncurry mkTok) pairs
  , stmtSource    = LogicalLine "" 1 1
  , stmtTerminated = False
  }

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Body"
  [ testGroup "classifyBodyStmt"
    [ testCase "local var: builtin type + name" $
        classifyBodyStmt (mkStmt [(TkDatatype, "long"), (TkIdent, "ll_row")])
          @?= [BsLocalVar [] (PtPrimitive "long") "ll_row" Nothing]

    , testCase "local var: user-defined type + name (both TkIdent)" $
        classifyBodyStmt (mkStmt [(TkIdent, "cb_delete"), (TkIdent, "cb_delete")])
          @?= [BsLocalVar [] (PtUserDefined "cb_delete") "cb_delete" Nothing]

    , testCase "local var: storage modifier + type + name" $
        classifyBodyStmt
          (mkStmt [(TkStorageModifier, "constant"), (TkDatatype, "long"), (TkIdent, "max_val")])
          @?= [BsLocalVar ["constant"] (PtPrimitive "long") "max_val" Nothing]

    , testCase "local var: type + name + initializer (all tokens kept)" $
        classifyBodyStmt
          (mkStmt [(TkDatatype, "long"), (TkIdent, "ll_row"), (TkAssignOp, "="), (TkIntLiteral, "0")])
          @?= [BsLocalVar [] (PtPrimitive "long") "ll_row" (Just (ExInt "0"))]

    , testCase "local var: dec{0} precision specifier → BsLocalVar" $
        classifyBodyStmt
          (mkStmt [(TkDatatype,"dec"),(TkLBrace,"{"),(TkIntLiteral,"0"),(TkRBrace,"}"),(TkIdent,"lc_0")])
          @?= [BsLocalVar [] (PtDecimalPrec 0) "lc_0" Nothing]

    , testCase "local var: dec{10} two-digit precision → BsLocalVar" $
        classifyBodyStmt
          (mkStmt [(TkDatatype,"dec"),(TkLBrace,"{"),(TkIntLiteral,"10"),(TkRBrace,"}"),(TkIdent,"lc_10")])
          @?= [BsLocalVar [] (PtDecimalPrec 10) "lc_10" Nothing]

    , testCase "local var: two comma-separated names, neither initialized" $
        classifyBodyStmt
          (mkStmt [ (TkDatatype, "long"), (TkIdent, "ll_rows")
                  , (TkComma, ","), (TkIdent, "i") ])
          @?= [ BsLocalVar [] (PtPrimitive "long") "ll_rows" Nothing
              , BsLocalVar [] (PtPrimitive "long") "i" Nothing
              ]

    , testCase "local var: three comma-separated names, none initialized" $
        classifyBodyStmt
          (mkStmt [ (TkDatatype, "long"), (TkIdent, "ll_rows")
                  , (TkComma, ","), (TkIdent, "i")
                  , (TkComma, ","), (TkIdent, "n") ])
          @?= [ BsLocalVar [] (PtPrimitive "long") "ll_rows" Nothing
              , BsLocalVar [] (PtPrimitive "long") "i" Nothing
              , BsLocalVar [] (PtPrimitive "long") "n" Nothing
              ]

    , testCase "local var: comma-separated, initializer on first name only" $
        classifyBodyStmt
          (mkStmt [ (TkDatatype, "integer"), (TkIdent, "li_a")
                  , (TkAssignOp, "="), (TkIntLiteral, "5")
                  , (TkComma, ","), (TkIdent, "li_b") ])
          @?= [ BsLocalVar [] (PtPrimitive "integer") "li_a" (Just (ExInt "5"))
              , BsLocalVar [] (PtPrimitive "integer") "li_b" Nothing
              ]

    , testCase "local var: comma-separated, initializer on every name" $
        classifyBodyStmt
          (mkStmt [ (TkDatatype, "integer"), (TkIdent, "li_a")
                  , (TkAssignOp, "="), (TkIntLiteral, "5")
                  , (TkComma, ","), (TkIdent, "li_b")
                  , (TkAssignOp, "="), (TkIntLiteral, "6") ])
          @?= [ BsLocalVar [] (PtPrimitive "integer") "li_a" (Just (ExInt "5"))
              , BsLocalVar [] (PtPrimitive "integer") "li_b" (Just (ExInt "6"))
              ]

    , testCase "assign: simple ident = int literal" $
        classifyBodyStmt (mkStmt [(TkIdent, "ll_row"), (TkAssignOp, "="), (TkIntLiteral, "0")])
          @?= [BsAssign (Lvalue [LvSegment "ll_row" Nothing]) (ExInt "0")]

    , testCase "assign: property set (obj.field = val)" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "idw_main"), (TkDot, "."), (TkIdent, "enabled")
                  , (TkAssignOp, "="), (TkBoolFalse, "false")
                  ])
          @?= [BsAssign
                (Lvalue [LvSegment "idw_main" Nothing, LvSegment "enabled" Nothing])
                (ExBool False)]

    , testCase "assign: rhs is a method call" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "ll_row"), (TkAssignOp, "=")
                  , (TkIdent, "dw_main"), (TkDot, "."), (TkIdent, "getrow")
                  , (TkLParen, "("), (TkRParen, ")")
                  ])
          @?= [BsAssign
                (Lvalue [LvSegment "ll_row" Nothing])
                (ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_main" Nothing])) "getrow" [])]

    , testCase "assign: chained-call LHS → BsAssignExpr" $
        -- obj.cells(1).value = 42 — lvaluePrefix stops at cells; falls back to expr-based assign
        classifyBodyStmt
          (mkStmt [ (TkIdent, "obj"), (TkDot, "."), (TkIdent, "cells")
                  , (TkLParen, "("), (TkIntLiteral, "1"), (TkRParen, ")")
                  , (TkDot, "."), (TkIdent, "value")
                  , (TkAssignOp, "="), (TkIntLiteral, "42") ])
          @?= [BsAssignExpr
                (ExMethodCall
                  (ExMethodCall (ExLvalue (Lvalue [LvSegment "obj" Nothing])) "cells" [ExInt "1"])
                  "value" [])
                (ExInt "42")]

    , testCase "aug_assign: +=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "+="), (TkIntLiteral, "1")])
          @?= [BsAugAssign (Lvalue [LvSegment "n" Nothing]) AugAdd [tok "1"]]

    , testCase "aug_assign: -=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "-="), (TkIntLiteral, "1")])
          @?= [BsAugAssign (Lvalue [LvSegment "n" Nothing]) AugSub [tok "1"]]

    , testCase "aug_assign: *=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "*="), (TkIntLiteral, "2")])
          @?= [BsAugAssign (Lvalue [LvSegment "n" Nothing]) AugMul [tok "2"]]

    , testCase "aug_assign: /=" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "n"), (TkAugmentOp, "/="), (TkIntLiteral, "2")])
          @?= [BsAugAssign (Lvalue [LvSegment "n" Nothing]) AugDiv [tok "2"]]

    , testCase "inc: ++" $
        classifyBodyStmt (mkStmt [(TkIdent, "n"), (TkAugmentOp, "++")])
          @?= [BsInc (Lvalue [LvSegment "n" Nothing])]

    , testCase "dec: --" $
        classifyBodyStmt (mkStmt [(TkIdent, "n"), (TkAugmentOp, "--")])
          @?= [BsDec (Lvalue [LvSegment "n" Nothing])]

    , testCase "BsLocalVar varName is case-insensitive" $
        BsLocalVar [] (PtPrimitive "integer") "Li_Count" Nothing
          @?= BsLocalVar [] (PtPrimitive "integer") "li_count" Nothing

    , testCase "BsInc lvalue is case-insensitive" $
        classifyBodyStmt (mkStmt [(TkIdent, "N"), (TkAugmentOp, "++")])
          @?= classifyBodyStmt (mkStmt [(TkIdent, "n"), (TkAugmentOp, "++")])

    , testCase "aug_assign: member-chain LHS parses to a multi-segment Lvalue" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "this"), (TkDot, "."), (TkIdent, "count")
                  , (TkAugmentOp, "+="), (TkIntLiteral, "1") ])
          @?= [BsAugAssign
                (Lvalue [LvSegment "this" Nothing, LvSegment "count" Nothing])
                AugAdd [tok "1"]]

    , testCase "inc: subscripted LHS parses to a subscripted Lvalue" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "arr"), (TkLBracket, "["), (TkIdent, "i"), (TkRBracket, "]")
                  , (TkAugmentOp, "++") ])
          @?= [BsInc (Lvalue [LvSegment "arr" (Just ["i"])])]

    , testCase "aug_assign: chained-call LHS (not a valid lvalue) falls back to BsRaw" $
        case classifyBodyStmt
               (mkStmt [ (TkIdent, "obj"), (TkDot, "."), (TkIdent, "cells")
                       , (TkLParen, "("), (TkIntLiteral, "1"), (TkRParen, ")")
                       , (TkAugmentOp, "+="), (TkIntLiteral, "1") ]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "call: method call (obj.method())" $
        classifyBodyStmt
          (mkStmt [ (TkIdent, "dw_main"), (TkDot, "."), (TkIdent, "accepttext")
                  , (TkLParen, "("), (TkRParen, ")")
                  ])
          @?= [BsCall
                (ExMethodCall (ExLvalue (Lvalue [LvSegment "dw_main" Nothing])) "accepttext" [])]

    , testCase "call: free function (f(arg))" $
        classifyBodyStmt
          (mkStmt [(TkIdent, "messagebox"), (TkLParen, "("), (TkIdent, "msg"), (TkRParen, ")")])
          @?= [BsCall (ExCall (Lvalue [LvSegment "messagebox" Nothing]) [ExLvalue (Lvalue [LvSegment "msg" Nothing])])]

    , testCase "return: with value" $
        classifyBodyStmt (mkStmt [(TkControlKw, "return"), (TkBoolTrue, "true")])
          @?= [BsReturn (Just (ExBool True))]

    , testCase "return: bare (no expression)" $
        classifyBodyStmt (mkStmt [(TkControlKw, "return")])
          @?= [BsReturn Nothing]

    , testCase "raw: if statement" $
        case classifyBodyStmt
               (mkStmt [(TkControlKw, "if"), (TkIdent, "x"), (TkAssignOp, "="), (TkIntLiteral, "0"), (TkControlKw, "then")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "raw: end if" $
        case classifyBodyStmt (mkStmt [(TkControlKw, "end if")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "raw: sql commit" $
        case classifyBodyStmt
               (mkStmt [(TkSqlKw, "commit"), (TkOtherKw, "using"), (TkOtherKw, "sqlca")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "raw: empty statement" $
        case classifyBodyStmt (mkStmt []) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "call: close(parent) — sql-kw callee no space" $
        classifyBodyStmt
          (mkStmt [(TkSqlKw, "close"), (TkLParen, "("), (TkOtherKw, "parent"), (TkRParen, ")")])
          @?= [BsCall (ExCall (Lvalue [LvSegment "close" Nothing]) [ExLvalue (Lvalue [LvSegment "parent" Nothing])])]

    , testCase "call: Close (lw_sheet) — sql-kw callee with space before paren" $
        classifyBodyStmt
          (mkStmt [(TkSqlKw, "Close"), (TkLParen, "("), (TkIdent, "lw_sheet"), (TkRParen, ")")])
          @?= [BsCall (ExCall (Lvalue [LvSegment "Close" Nothing]) [ExLvalue (Lvalue [LvSegment "lw_sheet" Nothing])])]

    , testCase "call: open(w_main) — single-arg open" $
        classifyBodyStmt
          (mkStmt [(TkSqlKw, "open"), (TkLParen, "("), (TkIdent, "w_main"), (TkRParen, ")")])
          @?= [BsCall (ExCall (Lvalue [LvSegment "open" Nothing]) [ExLvalue (Lvalue [LvSegment "w_main" Nothing])])]

    , testCase "call: open(w_main, this) — two-arg open" $
        classifyBodyStmt
          (mkStmt [ (TkSqlKw, "open"), (TkLParen, "(")
                  , (TkIdent, "w_main"), (TkComma, ","), (TkOtherKw, "this")
                  , (TkRParen, ")")])
          @?= [BsCall (ExCall (Lvalue [LvSegment "open" Nothing])
                [ ExLvalue (Lvalue [LvSegment "w_main" Nothing])
                , ExLvalue (Lvalue [LvSegment "this" Nothing])
                ])]

    , testCase "raw: OPEN DYNAMIC — sql cursor op stays BsRaw" $
        case classifyBodyStmt
               (mkStmt [(TkSqlKw, "OPEN"), (TkOtherKw, "DYNAMIC"), (TkIdent, "lc_dept")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "raw: CLOSE cur — sql cursor close stays BsRaw" $
        case classifyBodyStmt
               (mkStmt [(TkSqlKw, "CLOSE"), (TkIdent, "cur")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testCase "raw: TkLabel access-modifier header → BsRaw" $
        case classifyBodyStmt (mkStmt [(TkLabel, "public:")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

    , testProperty "total: classifyBodyStmt never raises for any token list"
        propClassifyTotal
    ]

  , testGroup "PbCall"
    [ testCase "call super :: open" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkOtherKw, "super")
                  , (TkDoubleColon, "::"), (TkIdent, "open") ])
          @?= [BsPbCall (PbCall "super" "open")]

    , testCase "call named ancestor :: event" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkIdent, "w_ancestor")
                  , (TkDoubleColon, "::"), (TkIdent, "clicked") ])
          @?= [BsPbCall (PbCall "w_ancestor" "clicked")]

    , testCase "call ancestor with backtick control :: event (single ident token)" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkIdent, "w_emp`cb_close")
                  , (TkDoubleColon, "::"), (TkIdent, "clicked") ])
          @?= [BsPbCall (PbCall "w_emp`cb_close" "clicked")]

    , testCase "call where event name is a keyword token (e.g. create)" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkOtherKw, "super")
                  , (TkDoubleColon, "::"), (TkOtherKw, "create") ])
          @?= [BsPbCall (PbCall "super" "create")]

    , testCase "call super::open where 'open' is TkSqlKw → BsPbCall (not BsRaw)" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "call"), (TkOtherKw, "super")
                  , (TkDoubleColon, "::"), (TkSqlKw, "open") ])
          @?= [BsPbCall (PbCall "super" "open")]

    , testCase "call missing :: falls to BsRaw" $
        case classifyBodyStmt
               (mkStmt [(TkOtherKw, "call"), (TkOtherKw, "super"), (TkIdent, "open")]) of
          [BsRaw _] -> return ()
          other     -> assertFailure ("expected [BsRaw _], got: " <> show other)
    ]

  , testGroup "Destroy"
    [ testCase "destroy simple variable" $
        classifyBodyStmt
          (mkStmt [(TkOtherKw, "destroy"), (TkIdent, "obj")])
          @?= [BsDestroy (Lvalue [LvSegment "obj" Nothing])]

    , testCase "destroy dotted lvalue" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "destroy"), (TkIdent, "Category")
                  , (TkDot, "."), (TkIdent, "DispAttr") ])
          @?= [BsDestroy (Lvalue [LvSegment "Category" Nothing, LvSegment "DispAttr" Nothing])]

    , testCase "destroy subscripted lvalue" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "destroy"), (TkIdent, "ids_Data")
                  , (TkLBracket, "["), (TkIdent, "li_Cnt"), (TkRBracket, "]") ])
          @?= [BsDestroy (Lvalue [LvSegment "ids_Data" (Just ["li_Cnt"])])]

    , testCase "destroy with no argument emits BsCall" $
        classifyBodyStmt (mkStmt [(TkOtherKw, "destroy")])
          @?= [BsCall (ExLvalue (Lvalue [LvSegment "destroy" Nothing]))]

    , testCase "destroy function-call form emits BsCall" $
        classifyBodyStmt
          (mkStmt [ (TkOtherKw, "destroy"), (TkLParen, "(")
                  , (TkOtherKw, "this"), (TkDot, "."), (TkIdent, "m_foo")
                  , (TkRParen, ")") ])
          @?= [BsCall (ExCall (Lvalue [LvSegment "destroy" Nothing])
                [ExLvalue (Lvalue [LvSegment "this" Nothing, LvSegment "m_foo" Nothing])])]
    ]

  , testGroup "parseBodyStmts"
    [ testCase "empty list" $
        map locNode (parseBodyStmts []) @?= []

    , testCase "single assign becomes singleton" $
        map locNode (parseBodyStmts [mkStmt [(TkIdent, "x"), (TkAssignOp, "="), (TkIntLiteral, "1")]])
          @?= [BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "1")]

    , testCase "mixed stmts: var decl, assign, return — order preserved" $
        let stmts =
              [ mkStmt [(TkDatatype, "long"), (TkIdent, "n")]
              , mkStmt [(TkIdent, "n"), (TkAssignOp, "="), (TkIntLiteral, "5")]
              , mkStmt [(TkControlKw, "return"), (TkIdent, "n")]
              ]
            tags = map (tag . locNode) (parseBodyStmts stmts)
        in tags @?= ["var", "assign", "return"]

    , testCase "comma-separated var decl expands to multiple BsLocalVar, in order" $
        let stmts =
              [ mkStmt [ (TkDatatype, "long"), (TkIdent, "ll_rows")
                       , (TkComma, ","), (TkIdent, "i")
                       , (TkComma, ","), (TkIdent, "n") ] ]
            names = [ varName v | Located _ v@BsLocalVar{} <- parseBodyStmts stmts ]
        in names @?= ["ll_rows", "i", "n"]

    , testProperty "comma-separated local var decl: one BsLocalVar per name, order preserved"
        propCommaLocalVarNamesPreserved

    , testProperty "comma-separated local var decl: count matches comma count in the statement's own tokens"
        propCommaLocalVarCount
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
            @?= Just (Lvalue [LvSegment "is_steps" (Just ["ii_steps"])])

      , testCase "chain plus subscript on last segment" $
          parseLvalue [ mkTok TkIdent "adw",    mkTok TkDot "."
                      , mkTok TkIdent "object", mkTok TkDot "."
                      , mkTok TkIdent "kodypal"
                      , mkTok TkLBracket "[", mkTok TkIdent "row", mkTok TkRBracket "]" ]
            @?= Just (Lvalue [ LvSegment "adw"     Nothing
                              , LvSegment "object"  Nothing
                              , LvSegment "kodypal" (Just ["row"]) ])

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
                              , LvSegment "Item" (Just (map tkText subTokens)) ])

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
                              , LvSegment "open"   (Just ["i"]) ])
      ]

    , testGroup "classifyBodyStmt BsAssign with Lvalue"
      [ testCase "simple assign produces structured lhs" $
          classifyBodyStmt
            (mkStmt [(TkIdent, "foo"), (TkAssignOp, "="), (TkIntLiteral, "1")])
            @?= [BsAssign (Lvalue [LvSegment "foo" Nothing]) (ExInt "1")]

      , testCase "member chain assign" $
          classifyBodyStmt
            (mkStmt [ (TkIdent, "cb_ok"), (TkDot, "."), (TkIdent, "enabled")
                    , (TkAssignOp, "="), (TkBoolFalse, "false") ])
            @?= [BsAssign
                  (Lvalue [LvSegment "cb_ok" Nothing, LvSegment "enabled" Nothing])
                  (ExBool False)]

      , testCase "array subscript assign" $
          classifyBodyStmt
            (mkStmt [ (TkIdent, "arr"), (TkLBracket, "["), (TkIdent, "i"), (TkRBracket, "]")
                    , (TkAssignOp, "="), (TkIntLiteral, "0") ])
            @?= [BsAssign
                  (Lvalue [LvSegment "arr" (Just ["i"])])
                  (ExInt "0")]

      , testCase "unparseable lhs falls back to BsRaw" $
          case classifyBodyStmt
                 (mkStmt [ (TkAssignOp, "="), (TkIdent, "foo")
                         , (TkAssignOp, "="), (TkIntLiteral, "1") ]) of
            [BsRaw _] -> return ()
            other     -> assertFailure ("expected [BsRaw _], got: " <> show other)

      , testCase "assign: sql-kw segment in dotted lhs (adw.object.open[i] = 0)" $
          classifyBodyStmt
            (mkStmt [ (TkIdent, "adw"), (TkDot, "."), (TkIdent, "object"), (TkDot, ".")
                    , (TkSqlKw, "open")
                    , (TkLBracket, "["), (TkIdent, "i"), (TkRBracket, "]")
                    , (TkAssignOp, "="), (TkIntLiteral, "0") ])
            @?= [BsAssign
                  (Lvalue [ LvSegment "adw"    Nothing
                           , LvSegment "object" Nothing
                           , LvSegment "open"   (Just ["i"]) ])
                  (ExInt "0")]

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
            @?= [BsAssign
                  (Lvalue [ LvSegment "this" Nothing
                           , LvSegment "Item" (Just []) ])
                  (ExArray [ ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                              , LvSegment "m_file" Nothing ])
                           , ExLvalue (Lvalue [ LvSegment "this"   Nothing
                                              , LvSegment "m_edit" Nothing ]) ])]
      ]
    ]

  , testGroup "unparse (Plan 14 Phase B)"
    [ testProperty "round-trip leaf: parse . unparse . parse == parse" propUnparseBodyStmtRoundtrip
    , testCase "BsLocalVar round-trip: constant integer ls_count = 0" $
        let stmt = BsLocalVar ["constant"] (PtPrimitive "integer") (mkIdent "ls_count") (Just (ExInt "0"))
        in reparseBodyStmt (unparseBodyStmt stmt) @?= Right stmt
    , testCase "BsLocalVar round-trip: no initializer" $
        let stmt = BsLocalVar [] (PtPrimitive "string") (mkIdent "ls_name") Nothing
        in reparseBodyStmt (unparseBodyStmt stmt) @?= Right stmt
    , testCase "BsRaw round-trip: verbatim text" $
        let stmt = BsRaw "select * from t"
        in reparseBodyStmt (unparseBodyStmt stmt) @?= Right stmt
    ]

  , localOption (SmallCheckDepth 3) $ testGroup "unparse exhaustive leaf round-trip (SmallCheck)"
    [ SC.testProperty "round-trip leaf: parse . unparse . parse == parse, exhaustive to depth 3"
        prop_leafBodyStmtSmallCheck
    ]

  , testGroup "unparse control-flow (Plan 14 Phase C)"
    [ testProperty "round-trip control-flow: parse . unparse . parse == parse" propUnparseControlFlowRoundtrip
    ]

  , testGroup "stmtChildren"
    [ testCase "BsRaw -> []" $
        stmtChildren (BsRaw "x") @?= []

    , testCase "BsAssign -> []" $
        stmtChildren (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "1")) @?= []

    , testCase "BsIf with no elseifs, no else -> [then]" $
        let th = [at 1 (BsRaw "a")]
        in stmtChildren (BsIf (IfStmt (ExBool True) th [] Nothing)) @?= [th]

    , testCase "BsIf with elseifs and else -> [then, ei1, ei2, else] (4 groups)" $
        let th  = [at 1 (BsRaw "a")]
            ei1 = ElseIf (ExBool True)  [at 2 (BsRaw "b")]
            ei2 = ElseIf (ExBool False) [at 3 (BsRaw "c")]
            el  = [at 4 (BsRaw "d")]
        in stmtChildren (BsIf (IfStmt (ExBool True) th [ei1, ei2] (Just el)))
             @?= [th, eifBody ei1, eifBody ei2, el]

    , testCase "BsFor -> [body]" $
        let body = [at 1 (BsRaw "a")]
        in stmtChildren (BsFor (ForStmt (Lvalue [LvSegment "i" Nothing]) (ExInt "1") (ExInt "10") Nothing body))
             @?= [body]

    , testCase "BsDo -> [body]" $
        let body = [at 1 (BsRaw "a")]
        in stmtChildren (BsDo (DoStmt Nothing body Nothing)) @?= [body]

    , testCase "BsChoose with two clauses -> [c1 body, c2 body]" $
        let c1 = CaseClause Nothing [at 1 (BsRaw "a")]
            c2 = CaseClause Nothing [at 2 (BsRaw "b")]
        in stmtChildren (BsChoose (ChooseStmt (ExInt "1") [c1, c2]))
             @?= [ccBody c1, ccBody c2]

    , testCase "BsTry with two catches -> [body, cat1 body, cat2 body] (3 groups)" $
        let body = [at 1 (BsRaw "a")]
            cat1 = CatchClause "Exception" "e1" [at 2 (BsRaw "b")]
            cat2 = CatchClause "Error"     "e2" [at 3 (BsRaw "c")]
        in stmtChildren (BsTry (TryStmt body [cat1, cat2]))
             @?= [body, catchBody cat1, catchBody cat2]
    ]

  , testGroup "foldStmts"
    [ testCase "flat list collected in order" $
        rawTexts [at 1 (BsRaw "a"), at 2 (BsRaw "b")] @?= ["a", "b"]

    , testCase "BsRaw inside BsFor body found via recursion" $
        rawTexts [at 1 (BsFor (ForStmt (Lvalue [LvSegment "i" Nothing]) (ExInt "1") (ExInt "10") Nothing
                    [at 2 (BsRaw "inner")]))]
          @?= ["inner"]

    , testCase "BsRaw inside BsTry try-body found via recursion" $
        rawTexts [at 1 (BsTry (TryStmt [at 2 (BsRaw "in try")] []))]
          @?= ["in try"]

    , testCase "BsRaw inside BsTry catch-body found via recursion" $
        rawTexts [at 1 (BsTry (TryStmt [] [CatchClause "Exception" "e" [at 2 (BsRaw "in catch")]]))]
          @?= ["in catch"]

    , testCase "BsRaw inside BsIf-then inside BsFor inside BsTry, found at depth 3" $
        let deep = BsTry (TryStmt
              [ at 1 (BsFor (ForStmt (Lvalue [LvSegment "i" Nothing]) (ExInt "1") (ExInt "10") Nothing
                  [ at 2 (BsIf (IfStmt (ExBool True) [at 3 (BsRaw "deepest")] [] Nothing)) ]))
              ] [])
        in rawTexts [at 0 deep] @?= ["deepest"]

    , testCase "visits every node exactly once (no dup, no miss)" $
        let tree =
              [ at 1 (BsRaw "a")
              , at 2 (BsIf (IfStmt (ExBool True)
                  [at 3 (BsRaw "b")]
                  [ElseIf (ExBool False) [at 4 (BsRaw "c")]]
                  (Just [at 5 (BsRaw "d")])))
              , at 6 (BsTry (TryStmt [at 7 (BsRaw "e")] [CatchClause "Exception" "x" [at 8 (BsRaw "f")]]))
              ]
            visited = foldStmts (const [()]) tree
        in length visited @?= 8
    ]

  , testGroup "no-crash fuzzing"
    [ testProperty "classifyBodyStmt never raises on arbitrary token input" propClassifyBodyStmtNoCrash
    , testProperty "pBodyStmt never raises on arbitrary statement input" propPBodyStmtNoCrash
    ]
  ]

tag :: BodyStmt -> Text
tag (BsLocalVar  _ _ _ _) = "var"
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
tag (BsTry        _)    = "try"
tag (BsThrow      _)    = "throw"
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
  assert $ not (null result) && all isValidBodyStmt result

isValidBodyStmt :: BodyStmt -> Bool
isValidBodyStmt stmt = case stmt of
  BsLocalVar  _ _ _ _ -> True
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
  BsTry        _    -> True
  BsThrow      _    -> True
  BsRaw        _    -> True

-- ---------------------------------------------------------------------------
-- Unparse round-trip generator (Plan 14 Phase B)

-- | Feed unparsed text through the real pipeline (normalizeText -> tokenize
-- -> collectStatements -> parseBodyStmts) and classify the first statement.
reparseBodyStmt :: Text -> Either Text BodyStmt
reparseBodyStmt text =
  case collectStatements (tokenize (normalizeText text)) of
    Left err     -> Left err
    Right []     -> Left "no statement parsed"
    Right stmts0 -> case parseBodyStmts stmts0 of
      []                   -> Left "no located BodyStmt produced"
      (Located _ result:_) -> Right result

-- | Zero token spans and nested locLine numbers before comparing a
-- reparsed BodyStmt against the value that generated it. Two things a
-- generator can never predict: (1) real token spans on the one leaf field
-- that carries raw Tokens (BsAugAssign's RHS, CaseClause's ccExpr) -- every
-- other leaf field is span-free (Lvalue's subscript is [Text], not
-- [Token], since Plan 178/179); (2) the real source line numbers pBodyStmt
-- assigns to every nested [Located BodyStmt] body (BsIf/BsFor/BsDo/
-- BsChoose/BsTry and their ElseIf/CaseClause/CatchClause sub-bodies).
-- Recurses into every nested body so a control-flow constructor containing
-- another control-flow constructor is normalized all the way down.
normalizeBodyStmt :: BodyStmt -> BodyStmt
normalizeBodyStmt stmt = case stmt of
  BsAugAssign lv op rhs -> BsAugAssign lv op (map zeroSpan rhs)
  BsIf (IfStmt cond thenB eifs elseB) ->
    BsIf (IfStmt cond (normBody thenB) (map normElseIf eifs) (fmap normBody elseB))
  BsFor (ForStmt lv from to step body) -> BsFor (ForStmt lv from to step (normBody body))
  BsDo (DoStmt cond body loop) -> BsDo (DoStmt cond (normBody body) loop)
  BsChoose (ChooseStmt e clauses) -> BsChoose (ChooseStmt e (map normClause clauses))
  BsTry (TryStmt body catches) -> BsTry (TryStmt (normBody body) (map normCatch catches))
  other -> other
  where
    zeroSpan t = t { tkSpan = SourceSpan 0 0 0 }
    normBody = map (\(Located _ s) -> Located 0 (normalizeBodyStmt s))
    normElseIf (ElseIf cond body) = ElseIf cond (normBody body)
    normClause (CaseClause pat body) = CaseClause (fmap (map zeroSpan) pat) (normBody body)
    normCatch (CatchClause ty var body) = CatchClause ty var (normBody body)

genIdentText :: Gen Text
genIdentText = Gen.element ["foo", "bar", "n", "dw_1", "ls_val", "idx", "obj"]

-- | 2-4 distinct names for a comma-separated declarator list. Deduped with
-- 'nub' (order-preserving first-occurrence dedup), not a Set-based dedup
-- (e.g. 'PB.Prelude.nubOrd') -- the properties below assert the input name
-- order survives the round trip, and a Set-based dedup would sort it away.
genLocalVarNames :: Gen [Text]
genLocalVarNames =
  Gen.filter ((>= 2) . length) (nub <$> Gen.list (Range.linear 2 4) genIdentText)

-- | Tokens for `<datatype> name1, name2, ...` -- the comma-truncation shape
-- 'PB.Grammar.Body.mkLocalVarStmts' splits.
mkCommaVarDeclTokens :: [Text] -> [(TokenKind, Text)]
mkCommaVarDeclTokens names =
  (TkDatatype, "long") : go names
  where
    go []       = []
    go [n]      = [(TkIdent, n)]
    go (n : ns) = (TkIdent, n) : (TkComma, ",") : go ns

propCommaLocalVarNamesPreserved :: Property
propCommaLocalVarNamesPreserved = property $ do
  names <- forAll genLocalVarNames
  let stmts = [mkStmt (mkCommaVarDeclTokens names)]
      got   = [ identOrig (varName v) | Located _ v@BsLocalVar{} <- parseBodyStmts stmts ]
  got === names

-- | Comma count is read back from the generated statement's own tokens
-- (not the generator's 'names' list length) so this checks the parser's
-- behaviour on its actual input, not just the generator's arithmetic.
propCommaLocalVarCount :: Property
propCommaLocalVarCount = property $ do
  names <- forAll genLocalVarNames
  let stmt   = mkStmt (mkCommaVarDeclTokens names)
      commas = length (filter ((== TkComma) . tkKind) (stmtTokens stmt))
  length (parseBodyStmts [stmt]) === commas + 1

genSimpleLvalue :: Gen Lvalue
genSimpleLvalue = Lvalue <$> Gen.list (Range.linear 1 2) (mkSeg <$> genIdentText)
  where mkSeg nm = LvSegment (mkIdent nm) Nothing

genSimpleExpr :: Gen Expr
genSimpleExpr = Gen.choice
  [ ExBool <$> Gen.bool
  , ExInt  <$> Gen.element ["0", "1", "42"]
  , ExReal <$> Gen.element ["1.5", "3.14"]
  , ExStr  <$> Gen.element ["hello", "abc"]
  , ExLvalue <$> genSimpleLvalue
  ]

-- | The only Expr shape that survives real re-parsing as ExMethodCall:
-- chainCalls only recognises a method chain onto an already call-shaped
-- receiver ("dw_1()", not bare "dw_1") -- see ExprTest.hs's genExpr
-- exclusion note for the same finding. Used only for BsAssignExpr's LHS,
-- where the LHS must fail parseLvalue (else it reparses as BsAssign).
genComplexLhsExpr :: Gen Expr
genComplexLhsExpr =
  (\recv m -> ExMethodCall (ExCall (Lvalue [LvSegment (mkIdent recv) Nothing]) []) (mkIdent m) [])
    <$> genIdentText <*> genIdentText

genAugRhsTokens :: Gen [Token]
genAugRhsTokens = (: []) . tok <$> Gen.element ["1", "2", "42"]

genLeafBodyStmt :: Gen BodyStmt
genLeafBodyStmt = Gen.choice
  [ BsAssign     <$> genSimpleLvalue <*> genSimpleExpr
  , BsAugAssign  <$> genSimpleLvalue <*> Gen.element [AugAdd, AugSub, AugMul, AugDiv] <*> genAugRhsTokens
  , BsInc        <$> genSimpleLvalue
  , BsDec        <$> genSimpleLvalue
  , BsCall       <$> genSimpleExpr
  , BsPbCall     <$> (PbCall <$> Gen.element ["super", "w_ancestor"] <*> Gen.element ["open", "clicked", "create"])
  , BsReturn     <$> Gen.maybe genSimpleExpr
  , pure BsExit
  , pure BsContinue
  , BsDestroy    <$> genSimpleLvalue
  , BsThrow      <$> genSimpleExpr
  , BsAssignExpr <$> genComplexLhsExpr <*> genSimpleExpr
  ]

propUnparseBodyStmtRoundtrip :: Property
propUnparseBodyStmtRoundtrip = property $ do
  stmt <- forAll genLeafBodyStmt
  let text = unparseBodyStmt stmt
  case reparseBodyStmt text of
    Left err     -> footnote ("reparse error: " <> show err <> " for unparsed text: " <> show text) >> failure
    Right result -> normalizeBodyStmt result === normalizeBodyStmt stmt

-- | Exhaustive counterpart to 'propUnparseBodyStmtRoundtrip': enumerates
-- every 'StructuredLeafBodyStmt' up to the SmallCheck depth (set to 3 at
-- the call site) rather than sampling.
prop_leafBodyStmtSmallCheck :: StructuredLeafBodyStmt -> Either String String
prop_leafBodyStmtSmallCheck (SLB stmt) =
  let text = unparseBodyStmt stmt
  in case reparseBodyStmt text of
       Left err -> Left ("reparse error: " <> show err <> " for unparsed text: " <> show text)
       Right result
         | normalizeBodyStmt result == normalizeBodyStmt stmt -> Right "ok"
         | otherwise -> Left ("round-trip mismatch for unparsed text: " <> show text)

-- ---------------------------------------------------------------------------
-- Control-flow round-trip generator (Plan 14 Phase C)

-- | Feed unparsed text through the real pipeline (normalizeText -> tokenize
-- -> collectStatements -> pBodyStmt over a StmtStream) and classify the
-- first result. Unlike Phase B's reparseBodyStmt, this does NOT go through
-- parseBodyStmts: that function is a flat map over classifyBodyStmt, whose
-- TkControlKw case only handles return/exit/continue/throw -- if/for/do/
-- choose/try all fall through to its BsRaw default, so it can never
-- recover a control-flow constructor. pBodyStmt (run recursively via
-- manyTill inside the FileParser monad, same as pFunctionBlock/
-- pEventBlock's real pBodyUntil call) is the actual production entry
-- point for these constructors.
reparseControlFlowStmt :: Text -> Either Text BodyStmt
reparseControlFlowStmt text =
  case collectStatements (tokenize (normalizeText text)) of
    Left err     -> Left err
    Right []     -> Left "no statement parsed"
    Right stmts0 -> case parse (many pBodyStmt <* eof) "" (StmtStream stmts0) of
      Left err                      -> Left (T.pack (errorBundlePretty err))
      Right result -> case concat result of
        []               -> Left "no located BodyStmt produced"
        (Located _ r:_)  -> Right r

-- | Depth-bounded: at depth 0, only leaf statements are generated, so
-- recursion into nested control-flow bodies always terminates.
maxControlFlowDepth :: Int
maxControlFlowDepth = 2

genLocatedBody :: Int -> Gen [Located BodyStmt]
genLocatedBody depth = Gen.list (Range.linear 0 2) (Located 1 <$> genControlBodyStmt depth)

genControlBodyStmt :: Int -> Gen BodyStmt
genControlBodyStmt depth
  | depth <= 0 = genLeafBodyStmt
  | otherwise = Gen.choice
      [ genLeafBodyStmt
      , genIfStmt (depth - 1)
      , genForStmt (depth - 1)
      , genDoStmt (depth - 1)
      , genChooseStmt (depth - 1)
      , genTryStmt (depth - 1)
      ]

genIfStmt :: Int -> Gen BodyStmt
genIfStmt depth =
  (\cond thenB eifs elseB -> BsIf (IfStmt cond thenB eifs elseB))
    <$> genSimpleExpr <*> genLocatedBody depth
    <*> Gen.list (Range.linear 0 1) (genElseIf depth)
    <*> Gen.maybe (genLocatedBody depth)

genElseIf :: Int -> Gen ElseIf
genElseIf depth = ElseIf <$> genSimpleExpr <*> genLocatedBody depth

genForStmt :: Int -> Gen BodyStmt
genForStmt depth =
  (\lv from to step body -> BsFor (ForStmt lv from to step body))
    <$> genSimpleLvalue <*> genSimpleExpr <*> genSimpleExpr
    <*> Gen.maybe genSimpleExpr <*> genLocatedBody depth

genDoCondition :: Gen DoCondition
genDoCondition = Gen.choice [DoWhile <$> genSimpleExpr, DoUntil <$> genSimpleExpr]

genDoStmt :: Int -> Gen BodyStmt
genDoStmt depth =
  (\cond body loop -> BsDo (DoStmt cond body loop))
    <$> Gen.maybe genDoCondition <*> genLocatedBody depth <*> Gen.maybe genDoCondition

genChooseStmt :: Int -> Gen BodyStmt
genChooseStmt depth =
  (\e clauses -> BsChoose (ChooseStmt e clauses))
    <$> genSimpleExpr <*> Gen.list (Range.linear 1 2) (genCaseClause depth)

-- | A case pattern token: single-token literals only, re-lexing to exactly
-- one Token so parseCatchSig-style downstream span-stripping stays simple.
genCasePatternToken :: Gen Token
genCasePatternToken = tok <$> Gen.element ["1", "2", "\"a\""]

genCaseClause :: Int -> Gen CaseClause
genCaseClause depth =
  (\pat body -> CaseClause pat body)
    <$> Gen.maybe ((: []) <$> genCasePatternToken) <*> genLocatedBody depth

genTryStmt :: Int -> Gen BodyStmt
genTryStmt depth =
  (\body catches -> BsTry (TryStmt body catches))
    <$> genLocatedBody depth <*> Gen.list (Range.linear 0 2) (genCatchClause depth)

-- | Exception type/var are generated as single-token idents only, since
-- parseCatchSig extracts them by raw token text -- same "flat generator
-- shape must stay reparse-recoverable" constraint Phase B's BsPbCall
-- generator already documented for CALL's ancestor/event.
genCatchClause :: Int -> Gen CatchClause
genCatchClause depth =
  CatchClause <$> genIdentText <*> genIdentText <*> genLocatedBody depth

genControlFlowStmt :: Gen BodyStmt
genControlFlowStmt = Gen.choice
  [ genIfStmt maxControlFlowDepth
  , genForStmt maxControlFlowDepth
  , genDoStmt maxControlFlowDepth
  , genChooseStmt maxControlFlowDepth
  , genTryStmt maxControlFlowDepth
  ]

propUnparseControlFlowRoundtrip :: Property
propUnparseControlFlowRoundtrip = property $ do
  stmt <- forAll genControlFlowStmt
  let text = unparseBodyStmt stmt
  case reparseControlFlowStmt text of
    Left err     -> footnote ("reparse error: " <> show err <> " for unparsed text: " <> show text) >> failure
    Right result -> normalizeBodyStmt result === normalizeBodyStmt stmt

-- ---------------------------------------------------------------------------
-- No-crash fuzzing (BACKLOG "Body parser no-crash property")

-- | Every 'TokenKind' paired with representative text, including every
-- control keyword 'classifyBodyStmt'/'pBodyStmt' branch on (so mismatched
-- kind+text combos, e.g. a "for" spelled with 'TkIdent', and malformed or
-- unterminated control blocks, get generated too) plus punctuation/literal
-- edge cases. 'mkStmt'/'mkTok' build a 'Statement' directly from these
-- pairs with no lexer validation, so any combination is constructible.
genFuzzTokenPair :: Gen (TokenKind, Text)
genFuzzTokenPair = Gen.element
  [ (TkStringDouble,    "\"a\"")
  , (TkStringSingle,    "'a'")
  , (TkBoolTrue,        "true")
  , (TkBoolFalse,       "false")
  , (TkNull,            "null")
  , (TkDateLiteral,     "2020-01-01")
  , (TkTimeLiteral,     "12:00:00")
  , (TkFloatLiteral,    "3.14")
  , (TkIntLiteral,      "1")
  , (TkEnumLiteral,     "red!")
  , (TkDatatype,        "long")
  , (TkAccessModifier,  "public")
  , (TkStorageModifier, "constant")
  , (TkControlKw,       "if")
  , (TkControlKw,       "then")
  , (TkControlKw,       "elseif")
  , (TkControlKw,       "else")
  , (TkControlKw,       "end if")
  , (TkControlKw,       "for")
  , (TkControlKw,       "to")
  , (TkControlKw,       "step")
  , (TkControlKw,       "next")
  , (TkControlKw,       "do")
  , (TkControlKw,       "while")
  , (TkControlKw,       "until")
  , (TkControlKw,       "loop")
  , (TkControlKw,       "choose case")
  , (TkControlKw,       "case")
  , (TkControlKw,       "end choose")
  , (TkControlKw,       "try")
  , (TkControlKw,       "catch")
  , (TkControlKw,       "end try")
  , (TkControlKw,       "return")
  , (TkControlKw,       "exit")
  , (TkControlKw,       "continue")
  , (TkControlKw,       "throw")
  , (TkDeclKw,          "end function")
  , (TkSqlKw,           "select")
  , (TkOtherKw,         "call")
  , (TkOtherKw,         "destroy")
  , (TkOtherKw,         "super")
  , (TkCompareOp,       "<>")
  , (TkAugmentOp,       "+=")
  , (TkAssignOp,        "=")
  , (TkArithOp,         "+")
  , (TkDot,             ".")
  , (TkDoubleColon,     "::")
  , (TkLParen,          "(")
  , (TkRParen,          ")")
  , (TkLBracket,        "[")
  , (TkRBracket,        "]")
  , (TkLBrace,          "{")
  , (TkRBrace,          "}")
  , (TkComma,           ",")
  , (TkSemi,            ";")
  , (TkColon,           ":")
  , (TkLabel,           "public:")
  , (TkIdent,           "foo")
  , (TkIdent,           "if")   -- keyword text under the wrong kind
  , (TkIdent,           "")     -- empty text edge case
  ]

genFuzzStmtTokens :: Gen [(TokenKind, Text)]
genFuzzStmtTokens = Gen.list (Range.linear 0 6) genFuzzTokenPair

genFuzzStmt :: Gen Statement
genFuzzStmt = mkStmt <$> genFuzzStmtTokens

genFuzzStmtStream :: Gen [Statement]
genFuzzStmtStream = Gen.list (Range.linear 0 8) genFuzzStmt

-- | 'length . show' forces the ENTIRE result to full depth, not just the
-- outer constructor -- unlike a bare pattern match/'assert', which only
-- forces WHNF and would miss a crash hiding in a nested field. 'eval'
-- forces its argument and reports any exception as a shrunk test failure
-- instead of crashing the test binary.
propClassifyBodyStmtNoCrash :: Property
propClassifyBodyStmtNoCrash = property $ do
  pairs <- forAll genFuzzStmtTokens
  _ <- eval (length (show (classifyBodyStmt (mkStmt pairs))))
  success

propPBodyStmtNoCrash :: Property
propPBodyStmtNoCrash = property $ do
  stmts <- forAll genFuzzStmtStream
  let outcome = parse (many pBodyStmt <* eof) "" (StmtStream stmts)
  _ <- eval (either (length . show) (length . show) outcome)
  success
