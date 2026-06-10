module PB.Grammar.Body
  ( classifyBodyStmt
  , parseBodyStmts
  , parseLvalue
  , parseExpr
  , pBodyStmt
  ) where

import PB.Prelude
import PB.AST.BodyStmt
  ( AugOp (..), BodyStmt (..), PbCall (..)
  , IfStmt (..), ForStmt (..), DoCondition (..), DoStmt (..)
  , CaseClause (..), ChooseStmt (..)
  )
import PB.AST.Expr        (CallExpr (..), CreateExpr (..), Expr (..), Literal (..), LvSegment (..), Lvalue (..))
import PB.Grammar.Stream  (FileParser, satisfyStmt, isModifierToken)
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)

import Text.Megaparsec (lookAhead, many, manyTill, optional, try, (<|>))
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Token predicates

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
classifyByOp :: Statement -> [Token] -> BodyStmt
classifyByOp s ts =
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
isSegmentName t = tkKind t `elem` [TkIdent, TkOtherKw, TkSqlKw]

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

-- | Parse a { e1, e2, ... } array literal.
-- Returns Nothing if the tokens don't start with '{' or the closing '}' is missing.
parseArrayExpr :: [Token] -> Maybe Expr
parseArrayExpr ts = case ts of
  (lb : rest)
    | tkKind lb == TkLBrace
    -> case reverse rest of
         (rb : revInner) | tkKind rb == TkRBrace ->
           Just (ExArray (map parseExpr (splitArgs (reverse revInner))))
         _ -> Nothing
  _ -> Nothing

-- | Parse a token list as an expression.
-- Total function: unrecognized shapes become ExRaw.
parseExpr :: [Token] -> Expr
parseExpr []  = ExRaw []
parseExpr (t:rest)
  | tkKind t == TkOtherKw && T.toLower (tkText t) == "not"
  = ExNot (parseExpr rest)
parseExpr [t] = parseSingleToken t
parseExpr ts@(t:_)
  | tkKind t == TkOtherKw && T.toLower (tkText t) == "create"
  = maybe (ExRaw ts) ExCreate (parseCreateExpr ts)
parseExpr ts@(t:_)
  | tkKind t == TkLBrace
  = maybe (ExRaw ts) id (parseArrayExpr ts)
parseExpr (t:rest)
  | tkKind t == TkColon
  = case lvaluePrefix rest of
      Just (segs, _) | not (null segs) -> ExHostVar (Lvalue segs)
      _                                -> ExRaw (t:rest)
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
-- PB CALL and DESTROY parsers

-- | Parse a CALL statement token list: [call, ancestor, ::, event] (exactly 4).
-- Accepts TkIdent and TkOtherKw for both ancestor and event positions.
parsePbCall :: [Token] -> Maybe PbCall
parsePbCall [callT, ancT, sepT, evT]
  | tkKind callT == TkOtherKw
  , tkKind ancT  `elem` [TkIdent, TkOtherKw]
  , tkKind sepT  == TkDoubleColon
  , tkKind evT   `elem` [TkIdent, TkOtherKw]
  = Just (PbCall (tkText ancT) (tkText evT))
parsePbCall _ = Nothing

-- | Parse a CREATE expression token list starting with the "create" token.
-- Syntax 1: [create, ClassName]  → CreateClass
-- Syntax 2: [create, using, ...] → CreateUsing
parseCreateExpr :: [Token] -> Maybe CreateExpr
parseCreateExpr [_, cls]
  | tkKind cls `elem` [TkIdent, TkOtherKw, TkDatatype]
  = Just (CreateClass (tkText cls))
parseCreateExpr (_ : usingT : rest)
  | tkKind usingT == TkOtherKw
  , T.toLower (tkText usingT) == "using"
  , not (null rest)
  = Just (CreateUsing (parseExpr rest))
parseCreateExpr _ = Nothing

-- ---------------------------------------------------------------------------
-- Statement classifier

classifyBodyStmt :: Statement -> BodyStmt
classifyBodyStmt s = case stmtTokens s of
  [] -> BsRaw s
  (t : rest)
    | tkKind t == TkControlKw ->
        case T.toLower (tkText t) of
          "return"   -> BsReturn (if null rest then Nothing else Just (parseExpr rest))
          "exit"     -> BsExit
          "continue" -> BsContinue
          _          -> BsRaw s
    | tkKind t `elem` [TkSqlKw, TkDeclKw] ->
        case rest of
          (lp:_) | tkKind lp == TkLParen -> classifyByOp s (stmtTokens s)
          _                              -> BsRaw s
    | tkKind t == TkOtherKw ->
        case T.toLower (tkText t) of
          "call"    -> maybe (BsRaw s) BsPbCall (parsePbCall (stmtTokens s))
          "destroy" -> maybe (classifyByOp s (stmtTokens s)) BsDestroy (parseLvalue rest)
          _         ->
            let ts           = stmtTokens s
                (_, skipped) = span isModifierToken ts
            in case skipped of
                 (typeT : nameT : _)
                   | isTypeName typeT && tkKind nameT == TkIdent -> BsLocalVar ts
                 _ -> classifyByOp s ts
    | otherwise ->
        let ts           = stmtTokens s
            (_, skipped) = span isModifierToken ts
        in case skipped of
             (typeT : nameT : _)
               | isTypeName typeT && tkKind nameT == TkIdent -> BsLocalVar ts
             _ -> classifyByOp s ts

-- | Classify a list of raw statements into typed body statements.
parseBodyStmts :: [Statement] -> [BodyStmt]
parseBodyStmts = map classifyBodyStmt

-- ---------------------------------------------------------------------------
-- Control-flow predicates

isCtrl :: Text -> Token -> Bool
isCtrl txt t = tkKind t == TkControlKw && T.toLower (tkText t) == txt

leadingCtrl :: Text -> Statement -> Bool
leadingCtrl txt s = case stmtTokens s of
  (t:_) -> isCtrl txt t
  []    -> False

isElseOrEndIf :: Statement -> Bool
isElseOrEndIf s =
  leadingCtrl "elseif" s || leadingCtrl "else" s || leadingCtrl "end if" s

isCaseOrEndChoose :: Statement -> Bool
isCaseOrEndChoose s = leadingCtrl "case" s || leadingCtrl "end choose" s

-- ---------------------------------------------------------------------------
-- Control-flow token extractors

-- | Split tokens [if, cond..., then, rest...] into (condToks, rest).
-- Returns Nothing if no "then" found.
splitAtThen :: [Token] -> Maybe ([Token], [Token])
splitAtThen = go []
  where
    go _   []     = Nothing
    go acc (t:ts)
      | isCtrl "then" t = Just (reverse acc, ts)
      | otherwise       = go (t:acc) ts

-- | Parse "for VAR = FROM to TO [step STEP]" token list.
-- Input must start with the "for" token.
splitForParts :: [Token] -> Maybe (Lvalue, Expr, Expr, Maybe Expr)
splitForParts ts = do
  rest <- case ts of { (t:r) | isCtrl "for" t -> Just r; _ -> Nothing }
  let (varToks, rest1) = break (\t -> tkKind t == TkAssignOp) rest
  rest2 <- case rest1 of { (_:r) -> Just r; [] -> Nothing }
  lv    <- parseLvalue varToks
  let (fromToks, rest3) = break (isCtrl "to") rest2
  rest4 <- case rest3 of { (_:r) -> Just r; [] -> Nothing }
  let (toToks, rest5) = break (isCtrl "step") rest4
      stepM = case rest5 of
        (_:stepRest) -> Just (parseExpr stepRest)
        []           -> Nothing
  return (lv, parseExpr fromToks, parseExpr toToks, stepM)

-- | Parse an optional do/loop condition: [while/until EXPR] → DoCondition.
parseDoCondition :: [Token] -> Maybe DoCondition
parseDoCondition (t:rest)
  | isCtrl "while" t = Just (DoWhile (parseExpr rest))
  | isCtrl "until" t = Just (DoUntil (parseExpr rest))
parseDoCondition _ = Nothing

-- ---------------------------------------------------------------------------
-- Control-flow parsers

pIfStmt :: FileParser BodyStmt
pIfStmt = do
  s <- satisfyStmt (leadingCtrl "if")
  let ts = drop 1 (stmtTokens s)   -- strip leading "if"
  case splitAtThen ts of
    Nothing -> return (BsRaw s)     -- malformed: no "then"
    Just (condToks, afterThen) ->
      let cond = parseExpr condToks
      in if null afterThen
         -- multi-line block: ends with bare "then"
         then do
           thenBody <- manyTill pBodyStmt (lookAhead (satisfyStmt isElseOrEndIf))
           elseIfs  <- many (try pElseIfClause)
           elseBody <- optional $ do
             _ <- satisfyStmt (leadingCtrl "else")
             manyTill pBodyStmt (lookAhead (satisfyStmt (leadingCtrl "end if")))
           _ <- satisfyStmt (leadingCtrl "end if")
           return (BsIf (IfStmt cond thenBody elseIfs elseBody))
         -- inline: tokens after "then" form the body (and optional else)
         else do
           let (thenToks, elseM) = splitAtElse afterThen
               mkSub toks = classifyBodyStmt (Statement toks (stmtSource s))
               thenBody = [mkSub thenToks]
               elseBody = fmap (\eToks -> [mkSub eToks]) elseM
           return (BsIf (IfStmt cond thenBody [] elseBody))

-- | Split inline [thenToks..., else, elseToks...] into (thenToks, Just elseToks)
-- or (thenToks, Nothing) if no "else".
splitAtElse :: [Token] -> ([Token], Maybe [Token])
splitAtElse = go []
  where
    go acc []     = (reverse acc, Nothing)
    go acc (t:ts)
      | isCtrl "else" t = (reverse acc, Just ts)
      | otherwise       = go (t:acc) ts

pElseIfClause :: FileParser (Expr, [BodyStmt])
pElseIfClause = do
  s <- satisfyStmt (leadingCtrl "elseif")
  let condToks = takeWhile (not . isCtrl "then") (drop 1 (stmtTokens s))
      cond     = parseExpr condToks
  body <- manyTill pBodyStmt (lookAhead (satisfyStmt isElseOrEndIf))
  return (cond, body)

pForStmt :: FileParser BodyStmt
pForStmt = do
  s <- satisfyStmt (leadingCtrl "for")
  case splitForParts (stmtTokens s) of
    Nothing -> return (BsRaw s)
    Just (lv, from, to, step) -> do
      body <- manyTill pBodyStmt (lookAhead (satisfyStmt (leadingCtrl "next")))
      _ <- satisfyStmt (leadingCtrl "next")
      return (BsFor (ForStmt lv from to step body))

pDoStmt :: FileParser BodyStmt
pDoStmt = do
  s <- satisfyStmt (leadingCtrl "do")
  let cond = parseDoCondition (drop 1 (stmtTokens s))
  body <- manyTill pBodyStmt (lookAhead (satisfyStmt (leadingCtrl "loop")))
  loopS <- satisfyStmt (leadingCtrl "loop")
  let loopCond = parseDoCondition (drop 1 (stmtTokens loopS))
  return (BsDo (DoStmt cond body loopCond))

pChooseStmt :: FileParser BodyStmt
pChooseStmt = do
  s <- satisfyStmt (leadingCtrl "choose case")
  let expr = parseExpr (drop 1 (stmtTokens s))
  clauses <- many (try pCaseClause)
  _ <- satisfyStmt (leadingCtrl "end choose")
  return (BsChoose (ChooseStmt expr clauses))

pCaseClause :: FileParser CaseClause
pCaseClause = do
  s <- satisfyStmt (leadingCtrl "case")
  let patToks = drop 1 (stmtTokens s)
      pat = case patToks of
        (t:_) | isCtrl "else" t -> Nothing
        _                       -> Just patToks
  body <- manyTill pBodyStmt (lookAhead (satisfyStmt isCaseOrEndChoose))
  return (CaseClause pat body)

-- ---------------------------------------------------------------------------
-- FileParser body-statement entry point

-- | Parse one body statement from the statement stream, handling control-flow
-- constructs recursively. Falls through to 'classifyBodyStmt' for leaf forms.
pBodyStmt :: FileParser BodyStmt
pBodyStmt =
      try pIfStmt
  <|> try pForStmt
  <|> try pDoStmt
  <|> try pChooseStmt
  <|> (classifyBodyStmt <$> satisfyStmt (const True))
