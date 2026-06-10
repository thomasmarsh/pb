module BodyParserTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
  ( BodyStmt (..)
  , IfStmt (..), ForStmt (..), DoCondition (..), DoStmt (..)
  , CaseClause (..), ChooseStmt (..)
  )
import PB.AST.Expr            (BinOp (..), Expr (..), Literal (..), LvSegment (..), Lvalue (..))
import PB.Grammar.Body        (pBodyStmt)
import PB.Grammar.Stream      (StmtStream (..))
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Test.Tasty              (TestTree, testGroup)
import Test.Tasty.HUnit        (testCase, (@?=))
import Text.Megaparsec         (eof, many, parse)
import Text.Megaparsec.Error   (errorBundlePretty)

-- ---------------------------------------------------------------------------
-- Helpers

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1)

mkStmt :: [(TokenKind, Text)] -> Statement
mkStmt pairs = Statement
  { stmtTokens = map (uncurry mkTok) pairs
  , stmtSource = LogicalLine "" 1 1
  }

runBodyStmts :: [Statement] -> Either String [BodyStmt]
runBodyStmts stmts = case parse (many pBodyStmt <* eof) "" (StmtStream stmts) of
  Right bs -> Right bs
  Left err -> Left (errorBundlePretty err)

-- ---------------------------------------------------------------------------
-- Shared token sequences

endIf :: Statement
endIf = mkStmt [(TkControlKw, "end if")]

endChoose :: Statement
endChoose = mkStmt [(TkControlKw, "end choose")]

-- "n = k" as a parsed Expr (ExBinOp BopEq after B2)
condExpr :: Text -> Expr
condExpr k =
  ExBinOp (ExLvalue (Lvalue [LvSegment "n" Nothing])) BopEq (ExLit (LitInt k))

-- y = 1 statement
stmtY1 :: Statement
stmtY1 = mkStmt [(TkIdent, "y"), (TkAssignOp, "="), (TkIntLiteral, "1")]

assignY1 :: BodyStmt
assignY1 = BsAssign (Lvalue [LvSegment "y" Nothing]) (ExLit (LitInt "1"))

-- z = 2 statement / body-stmt
stmtZ2 :: Statement
stmtZ2 = mkStmt [(TkIdent, "z"), (TkAssignOp, "="), (TkIntLiteral, "2")]

assignZ2 :: BodyStmt
assignZ2 = BsAssign (Lvalue [LvSegment "z" Nothing]) (ExLit (LitInt "2"))

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Grammar.Body.Parser"
  [ testGroup "if"
    [ testCase "inline without else" $
        -- "if n = 0 then return"  (single statement)
        runBodyStmts
          [ mkStmt [ (TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0")
                   , (TkControlKw,"then"), (TkControlKw,"return") ] ]
          @?= Right
            [ BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [BsReturn Nothing]
                , ifElseIfs = []
                , ifElse    = Nothing
                }) ]

    , testCase "inline with else" $
        -- "if n = 0 then y = 1 else z = 2"  (single statement)
        runBodyStmts
          [ mkStmt [ (TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0")
                   , (TkControlKw,"then")
                   , (TkIdent,"y"), (TkAssignOp,"="), (TkIntLiteral,"1")
                   , (TkControlKw,"else")
                   , (TkIdent,"z"), (TkAssignOp,"="), (TkIntLiteral,"2") ] ]
          @?= Right
            [ BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [assignY1]
                , ifElseIfs = []
                , ifElse    = Just [assignZ2]
                }) ]

    , testCase "multi-line single branch" $
        -- if n = 0 then / y = 1 / end if
        runBodyStmts
          [ mkStmt [(TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0"), (TkControlKw,"then")]
          , stmtY1
          , endIf ]
          @?= Right
            [ BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [assignY1]
                , ifElseIfs = []
                , ifElse    = Nothing
                }) ]

    , testCase "multi-line with else" $
        -- if n = 0 then / y = 1 / else / z = 2 / end if
        runBodyStmts
          [ mkStmt [(TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0"), (TkControlKw,"then")]
          , stmtY1
          , mkStmt [(TkControlKw,"else")]
          , stmtZ2
          , endIf ]
          @?= Right
            [ BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [assignY1]
                , ifElseIfs = []
                , ifElse    = Just [assignZ2]
                }) ]

    , testCase "multi-line with elseif chain" $
        -- if n = 0 then / y = 1 / elseif n = 1 then / z = 2 / end if
        runBodyStmts
          [ mkStmt [(TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0"), (TkControlKw,"then")]
          , stmtY1
          , mkStmt [(TkControlKw,"elseif"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"1"), (TkControlKw,"then")]
          , stmtZ2
          , endIf ]
          @?= Right
            [ BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [assignY1]
                , ifElseIfs = [(condExpr "1", [assignZ2])]
                , ifElse    = Nothing
                }) ]
    ]

  , testGroup "for"
    [ testCase "basic for-to" $
        -- for i = 1 to 10 / y = 1 / next
        runBodyStmts
          [ mkStmt [ (TkControlKw,"for"), (TkIdent,"i"), (TkAssignOp,"=")
                   , (TkIntLiteral,"1"), (TkControlKw,"to"), (TkIntLiteral,"10") ]
          , stmtY1
          , mkStmt [(TkControlKw,"next")] ]
          @?= Right
            [ BsFor (ForStmt
                { forVar  = Lvalue [LvSegment "i" Nothing]
                , forFrom = ExLit (LitInt "1")
                , forTo   = ExLit (LitInt "10")
                , forStep = Nothing
                , forBody = [assignY1]
                }) ]

    , testCase "for-to-step" $
        -- for i = 0 to 10 step 2 / y = 1 / next
        runBodyStmts
          [ mkStmt [ (TkControlKw,"for"), (TkIdent,"i"), (TkAssignOp,"=")
                   , (TkIntLiteral,"0"), (TkControlKw,"to"), (TkIntLiteral,"10")
                   , (TkControlKw,"step"), (TkIntLiteral,"2") ]
          , stmtY1
          , mkStmt [(TkControlKw,"next")] ]
          @?= Right
            [ BsFor (ForStmt
                { forVar  = Lvalue [LvSegment "i" Nothing]
                , forFrom = ExLit (LitInt "0")
                , forTo   = ExLit (LitInt "10")
                , forStep = Just (ExLit (LitInt "2"))
                , forBody = [assignY1]
                }) ]

    , testCase "nested for loops" $
        -- for i = 1 to 2 / for j = 1 to 3 / y = 1 / next / next
        runBodyStmts
          [ mkStmt [(TkControlKw,"for"),(TkIdent,"i"),(TkAssignOp,"="),(TkIntLiteral,"1"),(TkControlKw,"to"),(TkIntLiteral,"2")]
          , mkStmt [(TkControlKw,"for"),(TkIdent,"j"),(TkAssignOp,"="),(TkIntLiteral,"1"),(TkControlKw,"to"),(TkIntLiteral,"3")]
          , stmtY1
          , mkStmt [(TkControlKw,"next")]
          , mkStmt [(TkControlKw,"next")] ]
          @?= Right
            [ BsFor (ForStmt
                { forVar  = Lvalue [LvSegment "i" Nothing]
                , forFrom = ExLit (LitInt "1")
                , forTo   = ExLit (LitInt "2")
                , forStep = Nothing
                , forBody = [ BsFor (ForStmt
                                { forVar  = Lvalue [LvSegment "j" Nothing]
                                , forFrom = ExLit (LitInt "1")
                                , forTo   = ExLit (LitInt "3")
                                , forStep = Nothing
                                , forBody = [assignY1]
                                }) ]
                }) ]
    ]

  , testGroup "do"
    [ testCase "bare do bare loop" $
        -- do / y = 1 / loop
        runBodyStmts
          [ mkStmt [(TkControlKw,"do")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop")] ]
          @?= Right
            [ BsDo (DoStmt
                { doCond = Nothing
                , doBody = [assignY1]
                , doLoop = Nothing
                }) ]

    , testCase "do while" $
        -- do while n = 0 / y = 1 / loop
        runBodyStmts
          [ mkStmt [(TkControlKw,"do"),(TkControlKw,"while"),(TkIdent,"n"),(TkAssignOp,"="),(TkIntLiteral,"0")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop")] ]
          @?= Right
            [ BsDo (DoStmt
                { doCond = Just (DoWhile (condExpr "0"))
                , doBody = [assignY1]
                , doLoop = Nothing
                }) ]

    , testCase "bare do loop until" $
        -- do / y = 1 / loop until n = 0
        runBodyStmts
          [ mkStmt [(TkControlKw,"do")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop"),(TkControlKw,"until"),(TkIdent,"n"),(TkAssignOp,"="),(TkIntLiteral,"0")] ]
          @?= Right
            [ BsDo (DoStmt
                { doCond = Nothing
                , doBody = [assignY1]
                , doLoop = Just (DoUntil (condExpr "0"))
                }) ]

    , testCase "bare do loop while" $
        -- do / y = 1 / loop while n = 0
        runBodyStmts
          [ mkStmt [(TkControlKw,"do")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop"),(TkControlKw,"while"),(TkIdent,"n"),(TkAssignOp,"="),(TkIntLiteral,"0")] ]
          @?= Right
            [ BsDo (DoStmt
                { doCond = Nothing
                , doBody = [assignY1]
                , doLoop = Just (DoWhile (condExpr "0"))
                }) ]
    ]

  , testGroup "choose"
    [ testCase "single clause" $
        -- choose case x / case 1 / y = 1 / end choose
        runBodyStmts
          [ mkStmt [(TkControlKw,"choose case"),(TkIdent,"x")]
          , mkStmt [(TkControlKw,"case"),(TkIntLiteral,"1")]
          , stmtY1
          , endChoose ]
          @?= Right
            [ BsChoose (ChooseStmt
                { chooseExpr    = ExLvalue (Lvalue [LvSegment "x" Nothing])
                , chooseClauses = [ CaseClause (Just [mkTok TkIntLiteral "1"]) [assignY1] ]
                }) ]

    , testCase "multiple clauses" $
        -- choose case x / case 1 / y = 1 / case 2 / z = 2 / end choose
        runBodyStmts
          [ mkStmt [(TkControlKw,"choose case"),(TkIdent,"x")]
          , mkStmt [(TkControlKw,"case"),(TkIntLiteral,"1")]
          , stmtY1
          , mkStmt [(TkControlKw,"case"),(TkIntLiteral,"2")]
          , stmtZ2
          , endChoose ]
          @?= Right
            [ BsChoose (ChooseStmt
                { chooseExpr    = ExLvalue (Lvalue [LvSegment "x" Nothing])
                , chooseClauses = [ CaseClause (Just [mkTok TkIntLiteral "1"]) [assignY1]
                                  , CaseClause (Just [mkTok TkIntLiteral "2"]) [assignZ2]
                                  ]
                }) ]

    , testCase "case else clause" $
        -- choose case x / case 1 / y = 1 / case else / z = 2 / end choose
        runBodyStmts
          [ mkStmt [(TkControlKw,"choose case"),(TkIdent,"x")]
          , mkStmt [(TkControlKw,"case"),(TkIntLiteral,"1")]
          , stmtY1
          , mkStmt [(TkControlKw,"case"),(TkControlKw,"else")]
          , stmtZ2
          , endChoose ]
          @?= Right
            [ BsChoose (ChooseStmt
                { chooseExpr    = ExLvalue (Lvalue [LvSegment "x" Nothing])
                , chooseClauses = [ CaseClause (Just [mkTok TkIntLiteral "1"]) [assignY1]
                                  , CaseClause Nothing                          [assignZ2]
                                  ]
                }) ]
    ]

  , testGroup "leaf"
    [ testCase "exit becomes BsExit" $
        runBodyStmts [mkStmt [(TkControlKw,"exit")]]
          @?= Right [BsExit]

    , testCase "continue becomes BsContinue" $
        runBodyStmts [mkStmt [(TkControlKw,"continue")]]
          @?= Right [BsContinue]
    ]
  ]
