module C2CTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.AST.Type         (PbType (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Analysis.C2C
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

lv2 :: Text -> Text -> Lvalue
lv2 a b = Lvalue [LvSegment a Nothing, LvSegment b Nothing]

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv
  { steGlobal    = Map.empty
  , steInstance  = Map.empty
  , steLocal     = Map.empty
  , steHierarchy = Map.empty
  }

noFns :: Set.Set Text
noFns = Set.empty

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "C2C"
  [ testGroup "compileToCat"
    [ testCase "empty body → CatSeq []" $
        compileToCat emptyEnv noFns [] @?= CatSeq []

    , testCase "single assign" $
        compileToCat emptyEnv noFns
          [ at 1 (BsAssign (lv1 "x") (ExInt "42")) ]
        @?= CatSeq [CatAssign "x" (ExInt "42")]

    , testCase "multiple assigns compose sequentially" $
        compileToCat emptyEnv noFns
          [ at 1 (BsAssign (lv1 "a") (ExInt "1"))
          , at 2 (BsAssign (lv1 "b") (ExInt "2"))
          ]
        @?= CatSeq [ CatAssign "a" (ExInt "1")
                    , CatAssign "b" (ExInt "2")
                    ]

    , testCase "local var with init → CatLet" $
        compileToCat emptyEnv noFns
          [ at 1 (BsLocalVar [] (PtPrimitive "integer") "count" (Just (ExInt "0"))) ]
        @?= CatSeq [CatLet "count" (ExInt "0") CatNop]

    , testCase "local var without init → CatNop" $
        compileToCat emptyEnv noFns
          [ at 1 (BsLocalVar [] (PtPrimitive "integer") "x" Nothing) ]
        @?= CatSeq [CatNop]

    , testCase "if/then/else" $
        compileToCat emptyEnv noFns
          [ at 1 (BsIf (IfStmt
              (ExBool True)
              [at 2 (BsAssign (lv1 "a") (ExInt "1"))]
              []
              (Just [at 3 (BsAssign (lv1 "b") (ExInt "2"))])))]
        @?= CatSeq [ CatBranch (ExBool True)
                        (CatSeq [CatAssign "a" (ExInt "1")])
                        (CatSeq [CatAssign "b" (ExInt "2")])
                    ]

    , testCase "if/then only (no else)" $
        compileToCat emptyEnv noFns
          [ at 1 (BsIf (IfStmt
              (ExBool True)
              [at 2 (BsAssign (lv1 "a") (ExInt "1"))]
              []
              Nothing))]
        @?= CatSeq [ CatBranch (ExBool True)
                        (CatSeq [CatAssign "a" (ExInt "1")])
                        CatNop
                    ]

    , testCase "for loop" $
        compileToCat emptyEnv noFns
          [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
              [at 2 (BsAssign (lv1 "x") (ExInt "0"))]))]
        @?= CatSeq [CatFor "i" (ExInt "1") (ExInt "10") Nothing
                      (CatSeq [CatAssign "x" (ExInt "0")])]

    , testCase "do while loop" $
        compileToCat emptyEnv noFns
          [ at 1 (BsDo (DoStmt
              (Just (ExBool True))
              [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
              Nothing))]
        @?= CatSeq [CatWhile (ExBool True)
                      (CatSeq [CatAssign "x" (ExInt "0")])]

    , testCase "do loop until → CatWhile with negated cond" $
        compileToCat emptyEnv noFns
          [ at 1 (BsDo (DoStmt
              Nothing
              [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
              (Just (ExBool True))))]
        @?= CatSeq [CatWhile (ExNot (ExBool True))
                      (CatSeq [CatAssign "x" (ExInt "0")])]

    , testCase "destroy → CatAssign with ExNull" $
        compileToCat emptyEnv noFns
          [ at 1 (BsDestroy (lv1 "w")) ]
        @?= CatSeq [CatAssign "w" ExNull]

    , testCase "return" $
        compileToCat emptyEnv noFns
          [ at 1 (BsReturn (Just (ExInt "42"))) ]
        @?= CatSeq [CatReturn (Just (ExInt "42"))]

    , testCase "return nothing" $
        compileToCat emptyEnv noFns
          [ at 1 (BsReturn Nothing) ]
        @?= CatSeq [CatReturn Nothing]

    , testCase "raw → CatNop" $
        compileToCat emptyEnv noFns
          [ at 1 (BsRaw "SELECT 1") ]
        @?= CatSeq [CatNop]

    , testCase "choose case" $
        compileToCat emptyEnv noFns
          [ at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "x"))
              [ CaseClause (Just [Token TkIntLiteral "1" (SourceSpan 1 1 1)])
                  [at 2 (BsAssign (lv1 "a") (ExInt "10"))]
              , CaseClause Nothing
                  [at 3 (BsAssign (lv1 "b") (ExInt "20"))]
              ]))]
        @?= CatSeq [ CatCase (ExLvalue (lv1 "x"))
                        [ (Nothing, CatSeq [CatAssign "b" (ExInt "20")])
                        , (Just (ExInt "1"), CatSeq [CatAssign "a" (ExInt "10")])
                        ]
                    ]

    , testCase "augmented assign" $
        compileToCat emptyEnv noFns
          [ at 1 (BsAugAssign [Token TkIdent "x" (SourceSpan 1 1 1)] AugAdd [Token TkIntLiteral "1" (SourceSpan 1 1 1)]) ]
        @?= CatSeq [CatAssign "x" (ExBinOp (ExLvalue (lv1 "x")) BopAdd (ExInt "1"))]

    , testCase "increment" $
        compileToCat emptyEnv noFns
          [ at 1 (BsInc [Token TkIdent "x" (SourceSpan 1 1 1)]) ]
        @?= CatSeq [CatAssign "x" (ExBinOp (ExLvalue (lv1 "x")) BopAdd (ExInt "1"))]

    , testCase "decrement" $
        compileToCat emptyEnv noFns
          [ at 1 (BsDec [Token TkIdent "x" (SourceSpan 1 1 1)]) ]
        @?= CatSeq [CatAssign "x" (ExBinOp (ExLvalue (lv1 "x")) BopSub (ExInt "1"))]

    , testCase "try/catch" $
        compileToCat emptyEnv noFns
          [ at 1 (BsTry (TryStmt
              [at 2 (BsAssign (lv1 "a") (ExInt "1"))]
              [CatchClause "exception" "ex"
                [at 3 (BsAssign (lv1 "b") (ExInt "2"))]]))]
        @?= CatSeq [ CatTry
                        (CatSeq [CatAssign "a" (ExInt "1")])
                        [("exception", "ex", CatSeq [CatAssign "b" (ExInt "2")])]
                    ]

    , testCase "throw" $
        compileToCat emptyEnv noFns
          [ at 1 (BsThrow (ExLvalue (lv1 "ex"))) ]
        @?= CatSeq [CatThrow (ExLvalue (lv1 "ex"))]

    , testCase "exit in loop context" $
        compileToCat emptyEnv noFns
          [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
              [at 2 (BsExit)]))]
        @?= CatSeq [CatFor "i" (ExInt "1") (ExInt "10") Nothing
                      (CatSeq [CatBreak])]

    , testCase "continue in loop context" $
        compileToCat emptyEnv noFns
          [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
              [at 2 (BsContinue)]))]
        @?= CatSeq [CatFor "i" (ExInt "1") (ExInt "10") Nothing
                      (CatSeq [CatContinue])]

    , testCase "exit outside loop → CatNop" $
        compileToCat emptyEnv noFns
          [ at 1 BsExit ]
        @?= CatSeq [CatNop]

    , testCase "complex: nested if inside for" $
        compileToCat emptyEnv noFns
          [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
              [ at 2 (BsIf (IfStmt (ExLvalue (lv1 "done"))
                  [at 3 (BsExit)]
                  [] Nothing))
              ]))]
        @?= CatSeq [ CatFor "i" (ExInt "1") (ExInt "10") Nothing
                      (CatSeq [ CatBranch (ExLvalue (lv1 "done"))
                                  (CatSeq [CatBreak])
                                  CatNop
                              ])
                    ]
    ]

  , testGroup "CatOp structure"
    [ testCase "CatSeq flattens (no nested CatSeq)" $
        case compileToCat emptyEnv noFns
               [ at 1 (BsAssign (lv1 "a") (ExInt "1"))
               , at 2 (BsAssign (lv1 "b") (ExInt "2"))
               ] of
          CatSeq ops -> length ops @?= 2
          _ -> assertBool "expected CatSeq" False

    , testCase "CatBranch stores both branches" $
        case compileToCat emptyEnv noFns
               [ at 1 (BsIf (IfStmt (ExBool True)
                   [at 2 (BsAssign (lv1 "a") (ExInt "1"))]
                   [] Nothing)) ] of
          CatSeq [CatBranch _ thenOp elseOp] -> do
            thenOp @?= CatSeq [CatAssign "a" (ExInt "1")]
            elseOp @?= CatNop
          _ -> assertBool "expected CatSeq with CatBranch" False
    ]
  ]
