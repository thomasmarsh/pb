module PB.Grammar.Body
  ( classifyBodyStmt
  , parseBodyStmts
  , parseLvalue
  ) where

import PB.Prelude
import PB.AST.BodyStmt    (AugOp (..), BodyStmt (..))
import PB.AST.Expr        (LvSegment (..), Lvalue (..))
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
       []             -> BsCall ts
       (op : rhs)
         | null lhs   -> BsRaw s
         | otherwise  ->
           let opText = T.toLower (tkText op)
           in case opText of
                "="  -> case parseLvalue lhs of
                          Just lv -> BsAssign lv rhs
                          Nothing -> BsRaw s
                "++" -> BsInc       lhs
                "--" -> BsDec       lhs
                _    -> case augOp opText of
                          Just aop -> BsAugAssign lhs aop rhs
                          Nothing  -> BsRaw s

-- ---------------------------------------------------------------------------
-- Lvalue parser

-- | Parse a flat token list as a structured lvalue.
-- Returns Nothing if the tokens don't form a valid dotted-path lvalue
-- (with optional subscripts), or if there are leftover tokens after parsing.
parseLvalue :: [Token] -> Maybe Lvalue
parseLvalue ts = case goSegments ts of
  Just (segs, []) | not (null segs) -> Just (Lvalue segs)
  _                                 -> Nothing
  where
    goSegments []     = Nothing
    goSegments (t:rest)
      | isSegmentName t = do
          (msub, afterSub) <- consumeSubscript rest
          let seg = LvSegment (tkText t) msub
          case afterSub of
            (dot:more) | tkKind dot == TkDot ->
              case goSegments more of
                Just (segs, remaining) -> Just (seg : segs, remaining)
                Nothing                -> Nothing
            _ -> Just ([seg], afterSub)
      | otherwise = Nothing

    consumeSubscript (lb:rest)
      | tkKind lb == TkLBracket =
          case break (\t -> tkKind t == TkRBracket) rest of
            (inner, _rb:after) -> Just (Just inner, after)
            (_,     [])        -> Nothing  -- unmatched [
    consumeSubscript ts' = Just (Nothing, ts')

    isSegmentName t = tkKind t `elem` [TkIdent, TkOtherKw]

-- ---------------------------------------------------------------------------
-- Statement classifier

classifyBodyStmt :: Statement -> BodyStmt
classifyBodyStmt s = case stmtTokens s of
  [] -> BsRaw s
  (t : rest)
    | tkKind t == TkControlKw ->
        if T.toLower (tkText t) == "return"
          then BsReturn (if null rest then Nothing else Just rest)
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
