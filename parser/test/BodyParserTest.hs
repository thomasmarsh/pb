module BodyParserTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
  ( BodyStmt (..)
  , ElseIf (..)
  , IfStmt (..), ForStmt (..), DoCondition (..), DoStmt (..)
  , CaseClause (..), ChooseStmt (..)
  )
import PB.AST.Expr            (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located         (Located (..))
import PB.Grammar.Body        (pBodyStmt)
import PB.Grammar.Stream      (StmtStream (..))
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Test.Tasty              (TestTree, testGroup)
import Test.Tasty.HUnit        (assertFailure, testCase, (@?=))
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

mkStmtAt :: Int -> [(TokenKind, Text)] -> Statement
mkStmtAt ln pairs = Statement
  { stmtTokens = map (uncurry mkTok) pairs
  , stmtSource = LogicalLine "" ln ln
  }

-- | Like mkStmt but with a source-text string, used to test ';'-detection.
mkStmtSrc :: Text -> [(TokenKind, Text)] -> Statement
mkStmtSrc src pairs = Statement
  { stmtTokens = map (uncurry mkTok) pairs
  , stmtSource = LogicalLine src 1 1
  }

-- | Wrap a BodyStmt with line 1 (matching mkStmt's LogicalLine).
loc1 :: a -> Located a
loc1 = Located 1

runBodyStmts :: [Statement] -> Either String [Located BodyStmt]
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
  ExBinOp (ExLvalue (Lvalue [LvSegment "n" Nothing])) BopEq (ExInt k)

-- y = 1 statement
stmtY1 :: Statement
stmtY1 = mkStmt [(TkIdent, "y"), (TkAssignOp, "="), (TkIntLiteral, "1")]

assignY1 :: BodyStmt
assignY1 = BsAssign (Lvalue [LvSegment "y" Nothing]) (ExInt "1")

-- z = 2 statement / body-stmt
stmtZ2 :: Statement
stmtZ2 = mkStmt [(TkIdent, "z"), (TkAssignOp, "="), (TkIntLiteral, "2")]

assignZ2 :: BodyStmt
assignZ2 = BsAssign (Lvalue [LvSegment "z" Nothing]) (ExInt "2")

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
            [ loc1 (BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [loc1 (BsReturn Nothing)]
                , ifElseIfs = []
                , ifElse    = Nothing
                })) ]

    , testCase "inline with else" $
        -- "if n = 0 then y = 1 else z = 2"  (single statement)
        runBodyStmts
          [ mkStmt [ (TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0")
                   , (TkControlKw,"then")
                   , (TkIdent,"y"), (TkAssignOp,"="), (TkIntLiteral,"1")
                   , (TkControlKw,"else")
                   , (TkIdent,"z"), (TkAssignOp,"="), (TkIntLiteral,"2") ] ]
          @?= Right
            [ loc1 (BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [loc1 assignY1]
                , ifElseIfs = []
                , ifElse    = Just [loc1 assignZ2]
                })) ]

    , testCase "multi-line single branch" $
        -- if n = 0 then / y = 1 / end if
        runBodyStmts
          [ mkStmt [(TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0"), (TkControlKw,"then")]
          , stmtY1
          , endIf ]
          @?= Right
            [ loc1 (BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [loc1 assignY1]
                , ifElseIfs = []
                , ifElse    = Nothing
                })) ]

    , testCase "multi-line with else" $
        -- if n = 0 then / y = 1 / else / z = 2 / end if
        runBodyStmts
          [ mkStmt [(TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0"), (TkControlKw,"then")]
          , stmtY1
          , mkStmt [(TkControlKw,"else")]
          , stmtZ2
          , endIf ]
          @?= Right
            [ loc1 (BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [loc1 assignY1]
                , ifElseIfs = []
                , ifElse    = Just [loc1 assignZ2]
                })) ]

    , testCase "multi-line with elseif chain" $
        -- if n = 0 then / y = 1 / elseif n = 1 then / z = 2 / end if
        runBodyStmts
          [ mkStmt [(TkControlKw,"if"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"0"), (TkControlKw,"then")]
          , stmtY1
          , mkStmt [(TkControlKw,"elseif"), (TkIdent,"n"), (TkAssignOp,"="), (TkIntLiteral,"1"), (TkControlKw,"then")]
          , stmtZ2
          , endIf ]
          @?= Right
            [ loc1 (BsIf (IfStmt
                { ifCond    = condExpr "0"
                , ifThen    = [loc1 assignY1]
                , ifElseIfs = [ElseIf (condExpr "1") [loc1 assignZ2]]
                , ifElse    = Nothing
                })) ]
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
            [ loc1 (BsFor (ForStmt
                { forVar  = Lvalue [LvSegment "i" Nothing]
                , forFrom = ExInt "1"
                , forTo   = ExInt "10"
                , forStep = Nothing
                , forBody = [loc1 assignY1]
                })) ]

    , testCase "for-to-step" $
        -- for i = 0 to 10 step 2 / y = 1 / next
        runBodyStmts
          [ mkStmt [ (TkControlKw,"for"), (TkIdent,"i"), (TkAssignOp,"=")
                   , (TkIntLiteral,"0"), (TkControlKw,"to"), (TkIntLiteral,"10")
                   , (TkControlKw,"step"), (TkIntLiteral,"2") ]
          , stmtY1
          , mkStmt [(TkControlKw,"next")] ]
          @?= Right
            [ loc1 (BsFor (ForStmt
                { forVar  = Lvalue [LvSegment "i" Nothing]
                , forFrom = ExInt "0"
                , forTo   = ExInt "10"
                , forStep = Just (ExInt "2")
                , forBody = [loc1 assignY1]
                })) ]

    , testCase "nested for loops" $
        -- for i = 1 to 2 / for j = 1 to 3 / y = 1 / next / next
        runBodyStmts
          [ mkStmt [(TkControlKw,"for"),(TkIdent,"i"),(TkAssignOp,"="),(TkIntLiteral,"1"),(TkControlKw,"to"),(TkIntLiteral,"2")]
          , mkStmt [(TkControlKw,"for"),(TkIdent,"j"),(TkAssignOp,"="),(TkIntLiteral,"1"),(TkControlKw,"to"),(TkIntLiteral,"3")]
          , stmtY1
          , mkStmt [(TkControlKw,"next")]
          , mkStmt [(TkControlKw,"next")] ]
          @?= Right
            [ loc1 (BsFor (ForStmt
                { forVar  = Lvalue [LvSegment "i" Nothing]
                , forFrom = ExInt "1"
                , forTo   = ExInt "2"
                , forStep = Nothing
                , forBody = [ loc1 (BsFor (ForStmt
                                { forVar  = Lvalue [LvSegment "j" Nothing]
                                , forFrom = ExInt "1"
                                , forTo   = ExInt "3"
                                , forStep = Nothing
                                , forBody = [loc1 assignY1]
                                })) ]
                })) ]
    ]

  , testGroup "do"
    [ testCase "bare do bare loop" $
        -- do / y = 1 / loop
        runBodyStmts
          [ mkStmt [(TkControlKw,"do")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop")] ]
          @?= Right
            [ loc1 (BsDo (DoStmt
                { doCond = Nothing
                , doBody = [loc1 assignY1]
                , doLoop = Nothing
                })) ]

    , testCase "do while" $
        -- do while n = 0 / y = 1 / loop
        runBodyStmts
          [ mkStmt [(TkControlKw,"do"),(TkControlKw,"while"),(TkIdent,"n"),(TkAssignOp,"="),(TkIntLiteral,"0")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop")] ]
          @?= Right
            [ loc1 (BsDo (DoStmt
                { doCond = Just (DoWhile (condExpr "0"))
                , doBody = [loc1 assignY1]
                , doLoop = Nothing
                })) ]

    , testCase "bare do loop until" $
        -- do / y = 1 / loop until n = 0
        runBodyStmts
          [ mkStmt [(TkControlKw,"do")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop"),(TkControlKw,"until"),(TkIdent,"n"),(TkAssignOp,"="),(TkIntLiteral,"0")] ]
          @?= Right
            [ loc1 (BsDo (DoStmt
                { doCond = Nothing
                , doBody = [loc1 assignY1]
                , doLoop = Just (DoUntil (condExpr "0"))
                })) ]

    , testCase "bare do loop while" $
        -- do / y = 1 / loop while n = 0
        runBodyStmts
          [ mkStmt [(TkControlKw,"do")]
          , stmtY1
          , mkStmt [(TkControlKw,"loop"),(TkControlKw,"while"),(TkIdent,"n"),(TkAssignOp,"="),(TkIntLiteral,"0")] ]
          @?= Right
            [ loc1 (BsDo (DoStmt
                { doCond = Nothing
                , doBody = [loc1 assignY1]
                , doLoop = Just (DoWhile (condExpr "0"))
                })) ]
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
            [ loc1 (BsChoose (ChooseStmt
                { chooseExpr    = ExLvalue (Lvalue [LvSegment "x" Nothing])
                , chooseClauses = [ CaseClause (Just ["1"]) [loc1 assignY1] ]
                })) ]

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
            [ loc1 (BsChoose (ChooseStmt
                { chooseExpr    = ExLvalue (Lvalue [LvSegment "x" Nothing])
                , chooseClauses = [ CaseClause (Just ["1"]) [loc1 assignY1]
                                  , CaseClause (Just ["2"]) [loc1 assignZ2]
                                  ]
                })) ]

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
            [ loc1 (BsChoose (ChooseStmt
                { chooseExpr    = ExLvalue (Lvalue [LvSegment "x" Nothing])
                , chooseClauses = [ CaseClause (Just ["1"]) [loc1 assignY1]
                                  , CaseClause Nothing       [loc1 assignZ2]
                                  ]
                })) ]
    ]

  , testGroup "leaf"
    [ testCase "exit becomes BsExit" $
        runBodyStmts [mkStmt [(TkControlKw,"exit")]]
          @?= Right [loc1 BsExit]

    , testCase "continue becomes BsContinue" $
        runBodyStmts [mkStmt [(TkControlKw,"continue")]]
          @?= Right [loc1 BsContinue]
    ]

  , testGroup "SQL body statement joining"
    [ testCase "single-line SQL: no joining needed (regression)" $
        -- COMMIT USING sqlca; — complete on one line
        let s = mkStmtSrc "COMMIT USING sqlca;" [(TkSqlKw,"commit"),(TkOtherKw,"using"),(TkOtherKw,"sqlca")]
        in runBodyStmts [s] @?= Right [loc1 (BsRaw "COMMIT USING sqlca;")]

    , testCase "multi-line SELECT joined into one BsRaw" $
        -- SELECT count(*)
        --   INTO :li_rc
        --   FROM ole
        --   WHERE id = :var;
        let sel  = mkStmtSrc "SELECT count(*)"
                     [(TkSqlKw,"select"),(TkIdent,"count"),(TkLParen,"("),(TkArithOp,"*"),(TkRParen,")")]
            into = mkStmtSrc "  INTO :li_rc"
                     [(TkOtherKw,"into"),(TkColon,":"),(TkIdent,"li_rc")]
            frm  = mkStmtSrc "  FROM ole"
                     [(TkDeclKw,"from"),(TkIdent,"ole")]
            whr  = mkStmtSrc "  WHERE id = :var;"
                     [(TkIdent,"where"),(TkIdent,"id"),(TkAssignOp,"="),(TkColon,":"),(TkIdent,"var")]
        in runBodyStmts [sel, into, frm, whr]
             @?= Right [loc1 (BsRaw "SELECT count(*)\n  INTO :li_rc\n  FROM ole\n  WHERE id = :var;")]

    , testCase "multi-line INSERT joined into one BsRaw" $
        -- INSERT INTO ole
        --   ( id, description )
        --   VALUES ( :var1, :var2 );
        let ins  = mkStmtSrc "INSERT INTO ole"
                     [(TkSqlKw,"insert"),(TkOtherKw,"into"),(TkIdent,"ole")]
            cols = mkStmtSrc "  ( id, description )"
                     [(TkLParen,"("),(TkIdent,"id"),(TkComma,","),(TkIdent,"description"),(TkRParen,")")]
            vals = mkStmtSrc "  VALUES ( :var1, :var2 );"
                     [(TkIdent,"values"),(TkLParen,"("),(TkColon,":"),(TkIdent,"var1"),(TkComma,","),(TkColon,":"),(TkIdent,"var2"),(TkRParen,")")]
        in runBodyStmts [ins, cols, vals]
             @?= Right [loc1 (BsRaw "INSERT INTO ole\n  ( id, description )\n  VALUES ( :var1, :var2 );")]

    , testCase "SQL block followed by non-SQL statement" $
        -- SELECT x FROM t;   (single-line)
        -- y = 1
        let sqlS = mkStmtSrc "SELECT x FROM t;"
                     [(TkSqlKw,"select"),(TkIdent,"x"),(TkDeclKw,"from"),(TkIdent,"t")]
        in runBodyStmts [sqlS, stmtY1] @?= Right [loc1 (BsRaw "SELECT x FROM t;"), loc1 assignY1]
    ]

  , testGroup "line anchors"
    [ testCase "locLine of leaf stmt matches stmtSource llStartLine" $ do
        let s = mkStmtAt 42 [(TkIdent,"x"),(TkAssignOp,"="),(TkIntLiteral,"1")]
        case parse (many pBodyStmt <* eof) "" (StmtStream [s]) of
          Right [ls] -> locLine ls @?= 42
          other      -> assertFailure ("unexpected result: " <> show other)

    , testCase "locLine of compound for stmt is the for-line" $ do
        let forS  = mkStmtAt 10 [(TkControlKw,"for"),(TkIdent,"i"),(TkAssignOp,"="),(TkIntLiteral,"1"),(TkControlKw,"to"),(TkIntLiteral,"3")]
            bodyS = mkStmtAt 11 [(TkIdent,"y"),(TkAssignOp,"="),(TkIntLiteral,"1")]
            nextS = mkStmtAt 12 [(TkControlKw,"next")]
        case parse (many pBodyStmt <* eof) "" (StmtStream [forS, bodyS, nextS]) of
          Right [ls] -> do
            locLine ls @?= 10
            case locNode ls of
              BsFor fs -> case forBody fs of
                [inner] -> locLine inner @?= 11
                other   -> assertFailure ("unexpected body: " <> show other)
              other -> assertFailure ("expected BsFor, got: " <> show other)
          other -> assertFailure ("unexpected result: " <> show other)
    ]
  ]
