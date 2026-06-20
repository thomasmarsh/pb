module PrettyPrintTest (tests) where

import Prelude
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Data.Text        (Text)

import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located         (Located (..))
import PB.AST.Type            (PbType (..))
import PB.Pipeline.PrettyPrint

-- ── Helpers ───────────────────────────────────────────────────────────────────

lv :: Text -> Lvalue
lv n = Lvalue [LvSegment n Nothing]

lvDot :: [Text] -> Lvalue
lvDot ns = Lvalue [LvSegment n Nothing | n <- ns]

loc1 :: a -> Located a
loc1 = Located 1

-- ── Tests ─────────────────────────────────────────────────────────────────────

tests :: TestTree
tests = testGroup "PrettyPrint"
  [ testGroup "Expr"
    [ testGroup "Literals"
      [ testCase "bool true"  $ prettyExpr (ExBool True)    @?= "true"
      , testCase "bool false" $ prettyExpr (ExBool False)   @?= "false"
      , testCase "int"        $ prettyExpr (ExInt "42")     @?= "42"
      , testCase "real"       $ prettyExpr (ExReal "3.14")  @?= "3.14"
      , testCase "str"        $ prettyExpr (ExStr "hi") @?= "\"hi\""
      , testCase "null"       $ prettyExpr ExNull            @?= "null"
      , testCase "enum"       $ prettyExpr (ExEnum "fileexists") @?= "fileexists!"
      ]
    , testGroup "Lvalue"
      [ testCase "simple"   $ prettyLvalue (lv "x")                         @?= "x"
      , testCase "dotted"   $ prettyLvalue (lvDot ["a", "b", "c"])          @?= "a.b.c"
      , testCase "subscript"       $ prettyLvalue (Lvalue [LvSegment "arr" (Just ["i"])])    @?= "arr[i]"
      , testCase "subscript multi" $ prettyLvalue (Lvalue [LvSegment "m"   (Just ["r","c"])]) @?= "m[r, c]"
      , testCase "subscript in chain" $
          prettyLvalue (Lvalue [LvSegment "obj" Nothing, LvSegment "arr" (Just ["i"]), LvSegment "field" Nothing])
          @?= "obj.arr[i].field"
      ]
    , testGroup "Compound"
      [ testCase "binop add"  $ prettyExpr (ExBinOp (ExInt "1") BopAdd (ExInt "2"))          @?= "1 + 2"
      , testCase "binop ne"   $ prettyExpr (ExBinOp (ExInt "1") BopNe  (ExInt "2"))          @?= "1 <> 2"
      , testCase "binop le"   $ prettyExpr (ExBinOp (ExInt "1") BopLe  (ExInt "2"))          @?= "1 <= 2"
      , testCase "binop pow"  $ prettyExpr (ExBinOp (ExInt "2") BopPow (ExInt "8"))          @?= "2 ^ 8"
      , testCase "binop and"  $ prettyExpr (ExBinOp (ExBool True) BopAnd (ExBool False))     @?= "true and false"
      , testCase "binop or"   $ prettyExpr (ExBinOp (ExBool True) BopOr  (ExBool False))     @?= "true or false"
      , testCase "binop xor"  $ prettyExpr (ExBinOp (ExBool True) BopXor (ExBool False))     @?= "true xor false"
      , testCase "not"        $ prettyExpr (ExNot (ExBool True))                              @?= "not true"
      , testCase "neg"        $ prettyExpr (ExNeg (ExInt "1"))                               @?= "-1"
      , testCase "call noargs" $ prettyExpr ExCall { callee = lv "f", callArgs = [] }        @?= "f()"
      , testCase "call args"   $ prettyExpr ExCall { callee = lv "f", callArgs = [["x"], ["y", "+", "1"]] }
                                 @?= "f(x, y + 1)"
      , testCase "method call" $ prettyExpr ExMethodCall { receiver = ExLvalue (lv "obj"), method = "DoStuff", methodArgs = [] }
                                 @?= "obj.DoStuff()"
      , testCase "method call args" $ prettyExpr ExMethodCall { receiver = ExLvalue (lv "dw"), method = "Retrieve", methodArgs = [["n"]] }
                                      @?= "dw.Retrieve(n)"
      , testCase "create"       $ prettyExpr (ExCreate "w_main")               @?= "create w_main"
      , testCase "create using" $ prettyExpr (ExCreateUsing (ExLvalue (lv "cls"))) @?= "create using cls"
      , testCase "array empty"  $ prettyExpr (ExArray [])                      @?= "{}"
      , testCase "array items"  $ prettyExpr (ExArray [ExInt "1", ExInt "2"])  @?= "{1, 2}"
      , testCase "host var"     $ prettyExpr (ExHostVar (lv "sqlca"))          @?= ":sqlca"
      , testCase "raw tokens"   $ prettyExpr (ExRaw ["SQLCA", ".", "SQLErrText"]) @?= "SQLCA . SQLErrText"
      ]
    ]

  , testGroup "Stmt"
    [ testCase "return nothing" $ prettyStmt (BsReturn Nothing)                     @?= "return"
    , testCase "return expr"    $ prettyStmt (BsReturn (Just (ExInt "0")))          @?= "return 0"
    , testCase "exit"           $ prettyStmt BsExit                                 @?= "exit"
    , testCase "continue"       $ prettyStmt BsContinue                             @?= "continue"
    , testCase "local var"      $ prettyStmt (BsLocalVar [] (PtPrimitive "integer") "i" Nothing)  @?= "integer i"
    , testCase "assign"         $ prettyStmt (BsAssign (lv "x") (ExInt "1"))       @?= "x = 1"
    , testCase "augassign +="   $ prettyStmt (BsAugAssign ["x"] AugAdd ["1"])      @?= "x += 1"
    , testCase "augassign -="   $ prettyStmt (BsAugAssign ["x"] AugSub ["y"])      @?= "x -= y"
    , testCase "augassign *="   $ prettyStmt (BsAugAssign ["x"] AugMul ["2"])      @?= "x *= 2"
    , testCase "augassign /="   $ prettyStmt (BsAugAssign ["x"] AugDiv ["n"])      @?= "x /= n"
    , testCase "inc"            $ prettyStmt (BsInc ["i"])                          @?= "i++"
    , testCase "dec"            $ prettyStmt (BsDec ["i"])                          @?= "i--"
    , testCase "call"           $ prettyStmt (BsCall ExCall { callee = lv "Open", callArgs = [["w_main"]] })
                                  @?= "Open(w_main)"
    , testCase "pb call"        $ prettyStmt (BsPbCall (PbCall "w_main" "ue_postopen"))
                                  @?= "call w_main :: ue_postopen"
    , testCase "destroy"        $ prettyStmt (BsDestroy (lv "lo_obj"))             @?= "destroy lo_obj"
    , testCase "assign expr"    $ prettyStmt (BsAssignExpr (ExLvalue (lvDot ["this","tag"])) (ExStr "foo"))
                                  @?= "this.tag = \"foo\""
    , testCase "raw"            $ prettyStmt (BsRaw "SELECT 1")                    @?= "SELECT 1"
    , testCase "raw strips"     $ prettyStmt (BsRaw "  SELECT 1  ")                @?= "SELECT 1"
    ]

  , testGroup "Compound"
    [ testCase "if then only" $
        prettyStmt (BsIf (IfStmt (ExBool True) [loc1 (BsReturn Nothing)] [] Nothing))
        @?= "if true then\n    return\nend if"

    , testCase "if elseif else" $
        prettyStmt (BsIf (IfStmt
          (ExBinOp (ExLvalue (lv "x")) BopEq (ExInt "1"))
          [loc1 BsExit]
          [ElseIf (ExBinOp (ExLvalue (lv "x")) BopEq (ExInt "2")) [loc1 BsContinue]]
          (Just [loc1 (BsReturn (Just (ExInt "0")))])))
        @?= "if x = 1 then\n    exit\nelseif x = 2 then\n    continue\nelse\n    return 0\nend if"

    , testCase "for no step" $
        prettyStmt (BsFor ForStmt { forVar = lv "i", forFrom = ExInt "1", forTo = ExInt "10"
                                  , forStep = Nothing, forBody = [loc1 BsContinue] })
        @?= "for i = 1 to 10\n    continue\nnext"

    , testCase "for with step" $
        prettyStmt (BsFor ForStmt { forVar = lv "i", forFrom = ExInt "0", forTo = ExInt "100"
                                  , forStep = Just (ExInt "5"), forBody = [loc1 BsContinue] })
        @?= "for i = 0 to 100 step 5\n    continue\nnext"

    , testCase "do while top" $
        prettyStmt (BsDo DoStmt { doCond = Just (DoWhile (ExBool True))
                                , doBody = [loc1 BsExit], doLoop = Nothing })
        @?= "do while true\n    exit\nloop"

    , testCase "do until bottom" $
        prettyStmt (BsDo DoStmt { doCond = Nothing
                                , doBody = [loc1 BsExit], doLoop = Just (DoUntil (ExBool True)) })
        @?= "do\n    exit\nloop until true"

    , testCase "do bare" $
        prettyStmt (BsDo DoStmt { doCond = Nothing, doBody = [loc1 BsExit], doLoop = Nothing })
        @?= "do\n    exit\nloop"

    , testCase "choose case" $
        prettyStmt (BsChoose ChooseStmt
          { chooseExpr = ExLvalue (lv "x")
          , chooseClauses =
              [ CaseClause (Just ["1"]) [loc1 (BsReturn (Just (ExInt "1")))]
              , CaseClause Nothing      [loc1 (BsReturn (Just (ExInt "0")))]
              ]
          })
        @?= "choose case x\ncase 1\n    return 1\ncase else\n    return 0\nend choose"
    ]

  , testGroup "Body"
    [ testCase "empty"              $ prettyBodyStmts []                                           @?= ""
    , testCase "single stmt"        $ prettyBodyStmts [loc1 BsExit]                               @?= "exit"
    , testCase "multi stmt"         $ prettyBodyStmts [loc1 BsExit, loc1 BsContinue]              @?= "exit\ncontinue"
    , testCase "raw empty filtered" $ prettyBodyStmts [loc1 (BsRaw ""), loc1 BsExit, loc1 (BsRaw "   ")] @?= "exit"
    , testCase "nested indent" $
        prettyStmt (BsFor ForStmt
          { forVar = lv "i", forFrom = ExInt "1", forTo = ExInt "10"
          , forStep = Nothing
          , forBody = [loc1 (BsIf (IfStmt (ExBinOp (ExLvalue (lv "i")) BopEq (ExInt "5"))
                                          [loc1 BsExit] [] Nothing))]
          })
        @?= "for i = 1 to 10\n    if i = 5 then\n        exit\n    end if\nnext"
    ]
  ]
