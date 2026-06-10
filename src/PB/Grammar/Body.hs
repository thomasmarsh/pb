module PB.Grammar.Body
  ( classifyBodyStmt
  , parseBodyStmts
  , parseLvalue
  , parseExpr
  ) where

import PB.Prelude
import PB.AST.BodyStmt    (AugOp (..), BodyStmt (..))
import PB.AST.Expr        (CallExpr (..), Expr (..), Literal (..), LvSegment (..), Lvalue (..))
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)

import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Token predicates

isModifier :: Token -> Bool
isModifier t = tkKind t `elem` [TkAccessModifier, TkStorageModifier]

isTypeName :: Token -> Bool
isTypeName t = tkKind t `elem` [TkDatatype, TkIdent]

isOperator :: Token -> Bool
isOperator t = tkKind t == TkAssignOp || tkKind t == TkAugmentOp

-- ---------------------------------------------------------------------------
-- Operator dispatch

augOp :: Text -> Maybe AugOp
augOp "+=" = Just AugAdd
augOp "-=" = Just AugSub
augOp "*=" = Just AugMul
augOp "/=" = Just AugDiv
augOp _    = Nothing

-- | Split at first operator token; build the appropriate BodyStmt.
-- Falls back to BsRaw if lhs is empty or op text is unrecognised.
scanForOp :: Statement -> [Token] -> BodyStmt
scanForOp s ts =
  let (lhs, rest) = span (not . isOperator) ts
  in case rest of
       []             -> BsCall (parseExpr ts)
       (op : rhs)
         | null lhs   -> BsRaw s
         | otherwise  ->
           let opText = T.toLower (tkText op)
           in case opText of
                "="  -> case parseLvalue lhs of
                          Just lv -> BsAssign lv (parseExpr rhs)
                          Nothing -> BsRaw s
                "++" -> BsInc       lhs
                "--" -> BsDec       lhs
                _    -> case augOp opText of
                          Just aop -> BsAugAssign lhs aop rhs
                          Nothing  -> BsRaw s

-- ---------------------------------------------------------------------------
-- Lvalue helpers

isSegmentName :: Token -> Bool
isSegmentName t = tkKind t `elem` [TkIdent, TkOtherKw]

-- | Parse a greedy lvalue prefix; returns (segments, remaining_tokens).
-- Returns Nothing if the first token is not a valid segment name.
lvaluePrefix :: [Token] -> Maybe ([LvSegment], [Token])
lvaluePrefix = goSegs
  where
    goSegs [] = Nothing
    goSegs (t:rest)
      | isSegmentName t = do
          (msub, afterSub) <- consumeSub rest
          let seg = LvSegment (tkText t) msub
          case afterSub of
            (dot:more) | tkKind dot == TkDot ->
              case goSegs more of
                Just (segs, remaining) -> Just (seg : segs, remaining)
                Nothing                -> Nothing
            _ -> Just ([seg], afterSub)
      | otherwise = Nothing

    consumeSub (lb:rest)
      | tkKind lb == TkLBracket =
          case break (\t -> tkKind t == TkRBracket) rest of
            (inner, _rb:after) -> Just (Just inner, after)
            (_,     [])        -> Nothing
    consumeSub ts = Just (Nothing, ts)

-- | Parse a flat token list as a structured lvalue.
-- Returns Nothing if the tokens don't form a valid dotted-path lvalue
-- (with optional subscripts), or if there are leftover tokens after parsing.
parseLvalue :: [Token] -> Maybe Lvalue
parseLvalue ts = case lvaluePrefix ts of
  Just (segs, []) | not (null segs) -> Just (Lvalue segs)
  _                                 -> Nothing

-- ---------------------------------------------------------------------------
-- Expr parser helpers

-- | Find the ')' that matches the implicit open '(' already consumed.
-- Returns (tokens inside, tokens after the close). Tracks only paren depth.
findMatchingClose :: [Token] -> Maybe ([Token], [Token])
findMatchingClose = go (0 :: Int) []
  where
    go _ _ []   = Nothing
    go depth acc (t:ts)
      | tkKind t == TkRParen && depth == 0 = Just (reverse acc, ts)
      | tkKind t == TkRParen               = go (depth - 1) (t:acc) ts
      | tkKind t == TkLParen               = go (depth + 1) (t:acc) ts
      | otherwise                          = go depth       (t:acc) ts

-- | Split a flat token list on ',' at paren/bracket/brace depth 0.
-- Empty input returns no args (not one empty arg).
splitArgs :: [Token] -> [[Token]]
splitArgs [] = []
splitArgs ts = go (0 :: Int) [] ts
  where
    go _ cur []     = [reverse cur]
    go depth cur (t:rest)
      | tkKind t == TkComma && depth == 0 = reverse cur : go 0 [] rest
      | isOpen  t  = go (depth + 1)          (t:cur) rest
      | isClose t  = go (max 0 (depth - 1))  (t:cur) rest
      | otherwise  = go depth                (t:cur) rest
    isOpen  t = tkKind t `elem` [TkLParen, TkLBracket, TkLBrace]
    isClose t = tkKind t `elem` [TkRParen, TkRBracket, TkRBrace]

-- ---------------------------------------------------------------------------
-- Expr parser

-- | Parse a token list as an expression.
-- Total function: unrecognized shapes become ExRaw.
parseExpr :: [Token] -> Expr
parseExpr []  = ExRaw []
parseExpr [t] = parseSingleToken t
parseExpr ts  = fromMaybe (ExRaw ts) (tryLvalueOrCall ts)

parseSingleToken :: Token -> Expr
parseSingleToken t = case tkKind t of
  TkBoolTrue    -> ExLit (LitBool True)
  TkBoolFalse   -> ExLit (LitBool False)
  TkNull        -> ExLit LitNull
  TkIntLiteral  -> ExLit (LitInt  (tkText t))
  TkFloatLiteral-> ExLit (LitReal (tkText t))
  TkStringDouble-> ExLit (LitStr  (tkText t))
  TkStringSingle-> ExLit (LitStr  (tkText t))
  TkDateLiteral -> ExLit (LitDate (tkText t))
  TkTimeLiteral -> ExLit (LitTime (tkText t))
  TkEnumLiteral -> ExEnum (T.dropEnd 1 (tkText t))
  TkIdent       -> ExLvalue (Lvalue [LvSegment (tkText t) Nothing])
  TkOtherKw     -> ExLvalue (Lvalue [LvSegment (tkText t) Nothing])
  _             -> ExRaw [t]

-- | Try to parse as lvalue chain, or lvalue followed by '(' args ')'.
-- Returns Nothing if the tokens don't fit either shape.
tryLvalueOrCall :: [Token] -> Maybe Expr
tryLvalueOrCall ts = do
  (segs, remaining) <- lvaluePrefix ts
  case remaining of
    [] ->
      Just (ExLvalue (Lvalue segs))
    (lp : rest) | tkKind lp == TkLParen -> do
      (inner, after) <- findMatchingClose rest
      case after of
        [] -> Just (ExCall (CallExpr (Lvalue segs) (splitArgs inner)))
        _  -> Nothing   -- tokens after ')': chained call or binary op → ExRaw
    _ -> Nothing        -- non-'(' remainder: binary op or other → ExRaw

-- ---------------------------------------------------------------------------
-- Statement classifier

classifyBodyStmt :: Statement -> BodyStmt
classifyBodyStmt s = case stmtTokens s of
  [] -> BsRaw s
  (t : rest)
    | tkKind t == TkControlKw ->
        if T.toLower (tkText t) == "return"
          then BsReturn (if null rest then Nothing else Just (parseExpr rest))
          else BsRaw s
    | tkKind t `elem` [TkSqlKw, TkDeclKw] -> BsRaw s
    | otherwise ->
        let ts          = stmtTokens s
            (_, skipped) = span isModifier ts
        in case skipped of
             (typeT : nameT : _)
               | isTypeName typeT && tkKind nameT == TkIdent -> BsLocalVar ts
             _ -> scanForOp s ts

-- | Classify a list of raw statements into typed body statements.
parseBodyStmts :: [Statement] -> [BodyStmt]
parseBodyStmts = map classifyBodyStmt
