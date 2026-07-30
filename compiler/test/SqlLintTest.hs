module SqlLintTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt     (BodyStmt (..), DoStmt (..), ForStmt (..), IfStmt (..))
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident        (mkIdent)
import PB.AST.Located      (Located (..))
import PB.Analysis.SqlLint

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment (mkIdent n) Nothing]

issueCodes :: [LintIssue] -> [Text]
issueCodes = map liIssueCode

tests :: TestTree
tests = testGroup "SqlLint"
  [ testGroup "lintStmt — select_star"
    [ testCase "SELECT * is flagged" $
        issueCodes (lintStmt 1 (Just "SELECT") "SELECT * FROM customer") @?= ["select_star"]
    , testCase "SELECT DISTINCT * is flagged" $
        issueCodes (lintStmt 1 (Just "SELECT") "SELECT DISTINCT * FROM customer") @?= ["select_star"]
    , testCase "qualified alias.* is flagged" $
        issueCodes (lintStmt 1 (Just "SELECT") "SELECT c.* FROM customer c") @?= ["select_star"]
    , testCase "SELECT with explicit columns is clean" $
        issueCodes (lintStmt 1 (Just "SELECT") "SELECT id, name FROM customer") @?= []
    , testCase "arithmetic multiply is not a false positive" $
        issueCodes (lintStmt 1 (Just "SELECT") "SELECT quantity*price FROM orders") @?= []
    ]
  , testGroup "lintStmt — write_no_where"
    [ testCase "UPDATE without WHERE is flagged, severity error" $
        lintStmt 1 (Just "UPDATE") "UPDATE customer SET name = :n" @?=
          [LintIssue 1 "write_no_where" "error"]
    , testCase "DELETE without WHERE is flagged" $
        issueCodes (lintStmt 1 (Just "DELETE") "DELETE FROM customer") @?= ["write_no_where"]
    , testCase "UPDATE with WHERE is clean" $
        issueCodes (lintStmt 1 (Just "UPDATE") "UPDATE customer SET name = :n WHERE id = :id") @?= []
    , testCase "SELECT is never checked for write_no_where" $
        issueCodes (lintStmt 1 (Just "SELECT") "SELECT * FROM customer") @?= ["select_star"]
    ]
  , testGroup "sqlInLoopLines"
    [ testCase "SQL directly in a BsFor body is detected" $
        let body  = [at 2 (BsRaw "SELECT * FROM customer")]
            stmts = [at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing body))]
        in sqlInLoopLines stmts @?= [2]
    , testCase "SQL directly in a BsDo body is detected" $
        let body  = [at 2 (BsRaw "DELETE FROM customer WHERE id = :id")]
            stmts = [at 1 (BsDo (DoStmt Nothing body Nothing))]
        in sqlInLoopLines stmts @?= [2]
    , testCase "SQL nested in a BsIf inside a BsFor is still detected" $
        let inner = [at 3 (BsRaw "UPDATE customer SET seen = 1 WHERE id = :id")]
            ifS   = at 2 (BsIf (IfStmt (ExBool True) inner [] Nothing))
            stmts = [at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing [ifS]))]
        in sqlInLoopLines stmts @?= [3]
    , testCase "SQL outside any loop is not detected" $
        let stmts = [at 1 (BsRaw "SELECT * FROM customer")]
        in sqlInLoopLines stmts @?= []
    , testCase "FETCH/OPEN/CLOSE/DECLARE inside a loop are not flagged (cursor idiom)" $
        let body  = [ at 2 (BsRaw "DECLARE cur CURSOR FOR SELECT id FROM customer")
                    , at 3 (BsRaw "OPEN cur")
                    , at 4 (BsRaw "FETCH cur INTO :ll_id")
                    , at 5 (BsRaw "CLOSE cur")
                    ]
            stmts = [at 1 (BsDo (DoStmt Nothing body Nothing))]
        in sqlInLoopLines stmts @?= []
    ]
  , testCase "lintLoopSql wraps sqlInLoopLines as sql_in_loop/warning" $
      let body  = [at 2 (BsRaw "SELECT * FROM customer")]
          stmts = [at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing body))]
      in lintLoopSql stmts @?= [LintIssue 2 "sql_in_loop" "warning"]
  ]
