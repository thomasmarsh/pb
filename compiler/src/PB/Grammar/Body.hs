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
  , ElseIf (..)
  , IfStmt (..), ForStmt (..), DoCondition (..), DoStmt (..)
  , CaseClause (..), ChooseStmt (..)
  , CatchClause (..), TryStmt (..)
  )
import PB.AST.Expr        ( BinOp (..), Expr (..)
                          , DispatchExpr (..), DispatchMode (..)
                          , LvSegment (..), Lvalue (..) )
import PB.AST.Ident       (mkIdent)
import PB.AST.Located     (Located (..))
import PB.AST.Type         (PbType (..))
import PB.Grammar.Stream  (FileParser, satisfyStmt, isModifierToken, currentLine)
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)
import PB.Pipeline.Preprocess (LogicalLine (..), llText, llStartLine)

import Text.Megaparsec (lookAhead, many, manyTill, optional, try)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Token predicates

isTypeName :: Token -> Bool
isTypeName t = tkKind t `elem` [TkDatatype, TkIdent]

isOperator :: Token -> Bool
isOperator t = tkKind t == TkAssignOp || tkKind t == TkAugmentOp

-- ---------------------------------------------------------------------------
-- Local variable parsing helpers

-- | Parse a PbType from a token and the following tokens (for precision spec).
parseTypeFromTokens :: Token -> [Token] -> PbType
parseTypeFromTokens t _
  | tkKind t == TkDatatype, T.toLower (tkText t) == "any" = PtAny
  | tkKind t == TkDatatype = PtPrimitive (T.toLower (tkText t))
  | otherwise = PtUserDefined (tkText t)

-- | Parse a PbType with precision specification (e.g., decimal{10}).
parseTypeWithPrecision :: Token -> Token -> PbType
parseTypeWithPrecision t prec =
  case reads (T.unpack (tkText prec)) of
    [(n, "")] -> PtDecimalPrec n
    _         -> PtPrimitive (T.toLower (tkText t))

-- | Parse an optional initializer from tokens after the variable name.
parseInit :: [Token] -> Maybe Expr
parseInit [] = Nothing
parseInit (t:rest)
  | tkKind t == TkAssignOp = Just (parseExpr rest)
  | otherwise = Nothing

-- | Parse modifiers from the beginning of a token list.
parseModifiers :: [Token] -> [Text]
parseModifiers = map tkText . takeWhile isModifierToken

-- ---------------------------------------------------------------------------
-- Operator dispatch

augOp :: Text -> Maybe AugOp
augOp "+=" = Just AugAdd
augOp "-=" = Just AugSub
augOp "*=" = Just AugMul
augOp "/=" = Just AugDiv
augOp _    = Nothing

classifyByOp :: Statement -> [Token] -> BodyStmt
classifyByOp s ts =
  let (lhs, rest) = break isOperator ts
  in case rest of
       []             -> BsCall (parseExpr ts)
       (op : rhs)
         | null lhs   -> BsRaw (llText (stmtSource s))
         | otherwise  ->
           let opText = T.toLower (tkText op)
           in case opText of
                "="  -> case parseLvalue lhs of
                          Just lv -> BsAssign lv (parseExpr rhs)
                          Nothing ->
                            let lhsExpr = parseExpr lhs
                            in case lhsExpr of
                                 ExRaw _ -> BsRaw (llText (stmtSource s))
                                 _       -> BsAssignExpr lhsExpr (parseExpr rhs)
                "++" -> BsInc       lhs
                "--" -> BsDec       lhs
                _    -> case augOp opText of
                           Just aop -> BsAugAssign lhs aop rhs
                           Nothing  -> BsRaw (llText (stmtSource s))

-- ---------------------------------------------------------------------------
-- Lvalue helpers

isSegmentName :: Token -> Bool
isSegmentName t = tkKind t `elem` [TkIdent, TkOtherKw, TkSqlKw, TkDatatype]

lvaluePrefix :: [Token] -> Maybe ([LvSegment], [Token])
lvaluePrefix = goSegs
  where
    goSegs [] = Nothing
    goSegs (t:rest)
      | isSegmentName t = do
          (msub, afterSub) <- consumeSub rest
          let seg = LvSegment (mkIdent (tkText t)) msub
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
            (inner, _rb:after) -> Just (Just (map tkText inner), after)
            (_,     [])        -> Nothing
    consumeSub ts = Just (Nothing, ts)

parseLvalue :: [Token] -> Maybe Lvalue
parseLvalue ts = case lvaluePrefix ts of
  Just (segs, []) | not (null segs) -> Just (Lvalue segs)
  _                                 -> Nothing

-- ---------------------------------------------------------------------------
-- Dispatch parser helpers

isDispatchKw :: Token -> Bool
isDispatchKw t =
  (tkKind t == TkOtherKw && lw `elem` ["post", "trigger", "dynamic"]) ||
  (tkKind t == TkDeclKw  && lw == "event")
  where lw = T.toLower (tkText t)

findDispatchSplit :: [Token] -> Maybe ([Token], [Token])
findDispatchSplit = go (0 :: Int) []
  where
    go _ _   []     = Nothing
    go d acc (t:ts)
      | d == 0 && isDispatchKw t = Just (reverse acc, t:ts)
      | tkKind t `elem` [TkLParen, TkLBracket, TkLBrace] = go (d+1) (t:acc) ts
      | tkKind t `elem` [TkRParen, TkRBracket, TkRBrace] = go (max 0 (d-1)) (t:acc) ts
      | otherwise = go d (t:acc) ts

parseObjFromPre :: [Token] -> Maybe (Maybe Lvalue)
parseObjFromPre [] = Just Nothing
parseObjFromPre toks =
  case reverse toks of
    (dot:revLv) | tkKind dot == TkDot -> fmap Just (parseLvalue (reverse revLv))
    _                                 -> Nothing

parseDispBodyTokens :: Maybe Lvalue -> [Token] -> Maybe (Expr, [Token])
parseDispBodyTokens objLv = go DmSync False False
  where
    go _    _   _    []     = Nothing
    go mode dyn isEv (t:ts)
      | kwIs "post"    t = go DmPost    dyn  isEv  ts
      | kwIs "trigger" t = go DmTrigger dyn  isEv  ts
      | kwIs "dynamic" t = go mode      True isEv  ts
      | kwIs "event"   t = go mode      dyn  True  ts
      | tkKind t `elem` [TkIdent, TkOtherKw, TkDatatype] =
          case ts of
            (lp:r) | tkKind lp == TkLParen ->
              case findMatchingClose r of
                Nothing             -> Nothing
                Just (inner, after) ->
                  Just (ExDispatch DispatchExpr
                    { object  = objLv
                    , mode    = mode
                    , dynamic = dyn
                    , event   = isEv
                    , name    = mkIdent (tkText t)
                    , args    = splitArgs inner
                    }, after)
            _ -> Nothing
      | otherwise = Nothing
    kwIs kw tok = tkKind tok `elem` [TkOtherKw, TkDeclKw]
               && T.toLower (tkText tok) == kw

tryDispatchAtom :: [Token] -> Maybe (Expr, [Token])
tryDispatchAtom ts = do
  (preToks, dispToks) <- findDispatchSplit ts
  objLv               <- parseObjFromPre preToks
  parseDispBodyTokens objLv dispToks

-- ---------------------------------------------------------------------------
-- Expr parser helpers

findMatchingClose :: [Token] -> Maybe ([Token], [Token])
findMatchingClose = go (0 :: Int) []
  where
    go _ _ []   = Nothing
    go depth acc (t:ts)
      | tkKind t == TkRParen && depth == 0 = Just (reverse acc, ts)
      | tkKind t == TkRParen               = go (depth - 1) (t:acc) ts
      | tkKind t == TkLParen               = go (depth + 1) (t:acc) ts
      | otherwise                          = go depth       (t:acc) ts

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
-- Precedence-climbing expression parser

lookupBinOp :: Token -> Maybe (BinOp, Int, Bool)
lookupBinOp t = case (tkKind t, T.toLower (tkText t)) of
  (TkOtherKw,   "or" ) -> Just (BopOr,  1, False)
  (TkOtherKw,   "xor") -> Just (BopXor, 1, False)
  (TkOtherKw,   "and") -> Just (BopAnd, 2, False)
  (TkAssignOp,  "="  ) -> Just (BopEq,  4, False)
  (TkCompareOp, "<>" ) -> Just (BopNe,  4, False)
  (TkCompareOp, "<"  ) -> Just (BopLt,  4, False)
  (TkCompareOp, ">"  ) -> Just (BopGt,  4, False)
  (TkCompareOp, "<=" ) -> Just (BopLe,  4, False)
  (TkCompareOp, ">=" ) -> Just (BopGe,  4, False)
  (TkArithOp,   "+"  ) -> Just (BopAdd, 5, False)
  (TkArithOp,   "-"  ) -> Just (BopSub, 5, False)
  (TkArithOp,   "*"  ) -> Just (BopMul, 6, False)
  (TkArithOp,   "/"  ) -> Just (BopDiv, 6, False)
  (TkArithOp,   "^"  ) -> Just (BopPow, 7, True)
  _                    -> Nothing

chainCalls :: Expr -> [Token] -> (Expr, [Token])
chainCalls e (dot : nm : lp : rest)
  | tkKind dot  == TkDot
  , isSegmentName nm
  , tkKind lp   == TkLParen
  = case findMatchingClose rest of
      Nothing             -> (e, dot : nm : lp : rest)
      Just (inner, after) ->
        chainCalls ExMethodCall
          { receiver   = e
          , method     = mkIdent (tkText nm)
          , methodArgs = splitArgs inner
          } after
chainCalls e (dot : nm : rest)
  | tkKind dot == TkDot
  , isSegmentName nm
  = chainCalls ExMethodCall { receiver = e, method = mkIdent (tkText nm), methodArgs = [] } rest
chainCalls e ts = (e, ts)

parseAtom :: [Token] -> Maybe (Expr, [Token])
parseAtom [] = Nothing
parseAtom (t:rest)
  | tkKind t == TkLParen = do
      (inner, after) <- findMatchingClose rest
      let (e', r') = chainCalls (parseExpr inner) after
      pure (e', r')

  | tkKind t == TkArithOp && tkText t == "-" = do
      (e, r) <- parseAtom rest
      pure (ExNeg e, r)

  | tkKind t == TkOtherKw && T.toLower (tkText t) == "not"
  = case parseAtom rest of
      Nothing     -> Just (ExNot (ExRaw (map tkText rest)), [])
      Just (e, r) -> let (e', r') = climbPrec 4 e r in Just (ExNot e', r')

  | tkKind t == TkOtherKw && T.toLower (tkText t) == "create"
  = case rest of
      (uT:r) | tkKind uT == TkOtherKw && T.toLower (tkText uT) == "using" -> do
        (e, r') <- parseAtom r
        pure (ExCreateUsing e, r')
      (cls:r) | tkKind cls `elem` [TkIdent, TkOtherKw, TkDatatype]
        -> Just (ExCreate (mkIdent (tkText cls)), r)
      _ -> Nothing

  | tkKind t == TkLBrace
  = let go _     _   []     = Nothing
        go depth acc (x:xs)
          | tkKind x == TkRBrace && depth == 0
          = Just (ExArray (map parseExpr (splitArgs (reverse acc))), xs)
          | tkKind x == TkRBrace = go (depth - 1) (x:acc) xs
          | tkKind x == TkLBrace = go (depth + 1) (x:acc) xs
          | otherwise            = go depth        (x:acc) xs
    in go (0 :: Int) [] rest

  | isSegmentName t
  = tryDispatchAtom (t:rest) <|> do
      (segs, remaining) <- lvaluePrefix (t:rest)
      case remaining of
        (lp:r) | tkKind lp == TkLParen -> do
          (inner, after) <- findMatchingClose r
          let (e', r') = chainCalls ExCall
                { callee   = Lvalue segs
                , callArgs = splitArgs inner
                } after
          pure (e', r')
        _ -> pure (ExLvalue (Lvalue segs), remaining)

  | otherwise
  = case parseSingleToken t of
      ExRaw _ -> Nothing
      atom    -> Just (atom, rest)

climbPrec :: Int -> Expr -> [Token] -> (Expr, [Token])
climbPrec minPrec lhs ts = case ts of
  (op:rest)
    | Just (bop, prec, rightAssoc) <- lookupBinOp op
    , prec >= minPrec ->
        case parseAtom rest of
          Nothing         -> (lhs, ts)
          Just (rhs0, r0) ->
            let nextMinPrec    = if rightAssoc then prec else prec + 1
                (rhs, r)       = climbPrec nextMinPrec rhs0 r0
                (lhs', r')     = climbPrec minPrec ExBinOp { lhs = lhs, op = bop, rhs = rhs } r
            in (lhs', r')
  _ -> (lhs, ts)

-- ---------------------------------------------------------------------------
-- Expr parser

parseExpr :: [Token] -> Expr
parseExpr [] = ExRaw []
parseExpr ts@(t:rest)
  | tkKind t == TkColon
  = case lvaluePrefix rest of
      Just (segs, _) | not (null segs) -> ExHostVar (Lvalue segs)
      _                                -> ExRaw (map tkText ts)
  | otherwise
  = case parseAtom ts of
      Nothing     -> ExRaw (map tkText ts)
      Just (e, r) ->
        let (e', leftover) = climbPrec 0 e r
        in if null leftover then e' else ExRaw (map tkText ts)

parseSingleToken :: Token -> Expr
parseSingleToken t = case tkKind t of
  TkBoolTrue    -> ExBool True
  TkBoolFalse   -> ExBool False
  TkNull        -> ExNull
  TkIntLiteral  -> ExInt  (tkText t)
  TkFloatLiteral-> ExReal (tkText t)
  TkStringDouble-> ExStr  (T.dropEnd 1 (T.drop 1 (tkText t)))
  TkStringSingle-> ExStr  (T.dropEnd 1 (T.drop 1 (tkText t)))
  TkDateLiteral -> ExDate (tkText t)
  TkTimeLiteral -> ExTime (tkText t)
  TkEnumLiteral -> ExEnum (T.dropEnd 1 (tkText t))
  TkIdent       -> ExLvalue (Lvalue [LvSegment (mkIdent (tkText t)) Nothing])
  TkOtherKw     -> ExLvalue (Lvalue [LvSegment (mkIdent (tkText t)) Nothing])
  TkDatatype    -> ExLvalue (Lvalue [LvSegment (mkIdent (tkText t)) Nothing])
  _             -> ExRaw [tkText t]

-- ---------------------------------------------------------------------------
-- PB CALL parser

parsePbCall :: [Token] -> Maybe PbCall
parsePbCall [callT, ancT, sepT, evT]
  | tkKind callT == TkOtherKw
  , tkKind ancT  `elem` [TkIdent, TkOtherKw]
  , tkKind sepT  == TkDoubleColon
  = Just (PbCall (tkText ancT) (tkText evT))
parsePbCall _ = Nothing

-- ---------------------------------------------------------------------------
-- Statement classifier

classifyBodyStmt :: Statement -> BodyStmt
classifyBodyStmt s = case stmtTokens s of
  [] -> BsRaw (llText (stmtSource s))
  (t : _)
    | tkKind t == TkLabel -> BsRaw (llText (stmtSource s))
  (t : rest)
    | tkKind t == TkControlKw ->
        case T.toLower (tkText t) of
          "return"   -> BsReturn (if null rest then Nothing else Just (parseExpr rest))
          "exit"     -> BsExit
          "continue" -> BsContinue
          "throw"    -> BsThrow (parseExpr rest)
          _          -> BsRaw (llText (stmtSource s))
    | tkKind t `elem` [TkSqlKw, TkDeclKw] ->
        case rest of
          (lp:_) | tkKind lp == TkLParen -> classifyByOp s (stmtTokens s)
          _                              -> BsRaw (llText (stmtSource s))
    | tkKind t == TkOtherKw ->
        case T.toLower (tkText t) of
          "call"    -> maybe (BsRaw (llText (stmtSource s))) BsPbCall (parsePbCall (stmtTokens s))
          "destroy" -> maybe (classifyByOp s (stmtTokens s)) BsDestroy (parseLvalue rest)
          _         ->
            let ts           = stmtTokens s
                mods         = parseModifiers ts
                (_, skipped) = span isModifierToken ts
            in case skipped of
                 (typeT : nameT : rest')
                   | isTypeName typeT && tkKind nameT == TkIdent ->
                       let ty    = parseTypeFromTokens typeT rest'
                           name  = tkText nameT
                           initE = parseInit rest'
                       in BsLocalVar mods ty name initE
                 _ -> classifyByOp s ts
    | otherwise ->
        let ts           = stmtTokens s
            mods         = parseModifiers ts
            (_, skipped) = span isModifierToken ts
        in case skipped of
             (typeT : nameT : rest')
               | isTypeName typeT && tkKind nameT == TkIdent ->
                   let ty    = parseTypeFromTokens typeT rest'
                       name  = tkText nameT
                       initE = parseInit rest'
                   in BsLocalVar mods ty name initE
             (typeT : lb : prec : rb : nameT : rest')
               | isTypeName typeT
               , tkKind lb   == TkLBrace
               , tkKind rb   == TkRBrace
               , tkKind nameT == TkIdent ->
                   let ty    = parseTypeWithPrecision typeT prec
                       name  = tkText nameT
                       initE = parseInit rest'
                   in BsLocalVar mods ty name initE
             _ -> classifyByOp s ts

parseBodyStmts :: [Statement] -> [Located BodyStmt]
parseBodyStmts = map (\s -> Located (llStartLine (stmtSource s)) (classifyBodyStmt s))

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

splitAtThen :: [Token] -> Maybe ([Token], [Token])
splitAtThen = go []
  where
    go _   []     = Nothing
    go acc (t:ts)
      | isCtrl "then" t = Just (reverse acc, ts)
      | otherwise       = go (t:acc) ts

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
  let ts = drop 1 (stmtTokens s)
  case splitAtThen ts of
    Nothing -> return (BsRaw (llText (stmtSource s)))
    Just (condToks, afterThen) ->
      let cond = parseExpr condToks
      in if null afterThen
         then do
           thenBody <- manyTill pBodyStmt (lookAhead (satisfyStmt isElseOrEndIf))
           elseIfs  <- many (try pElseIfClause)
           elseBody <- optional $ do
             _ <- satisfyStmt (leadingCtrl "else")
             manyTill pBodyStmt (lookAhead (satisfyStmt (leadingCtrl "end if")))
           _ <- satisfyStmt (leadingCtrl "end if")
           return (BsIf (IfStmt cond thenBody elseIfs elseBody))
         else do
           let (thenToks, elseM) = splitAtElse afterThen
               ln = llStartLine (stmtSource s)
               mkSub toks = Located ln (classifyBodyStmt (Statement toks (stmtSource s) False))
               thenBody = [mkSub thenToks]
               elseBody = fmap (\eToks -> [mkSub eToks]) elseM
           return (BsIf (IfStmt cond thenBody [] elseBody))

splitAtElse :: [Token] -> ([Token], Maybe [Token])
splitAtElse = go []
  where
    go acc []     = (reverse acc, Nothing)
    go acc (t:ts)
      | isCtrl "else" t = (reverse acc, Just ts)
      | otherwise       = go (t:acc) ts

pElseIfClause :: FileParser ElseIf
pElseIfClause = do
  s <- satisfyStmt (leadingCtrl "elseif")
  let condToks = takeWhile (not . isCtrl "then") (drop 1 (stmtTokens s))
      cond     = parseExpr condToks
  body <- manyTill pBodyStmt (lookAhead (satisfyStmt isElseOrEndIf))
  return (ElseIf cond body)

pForStmt :: FileParser BodyStmt
pForStmt = do
  s <- satisfyStmt (leadingCtrl "for")
  case splitForParts (stmtTokens s) of
    Nothing -> return (BsRaw (llText (stmtSource s)))
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

pTryStmt :: FileParser BodyStmt
pTryStmt = do
  _ <- satisfyStmt (leadingCtrl "try")
  body <- manyTill pBodyStmt (lookAhead (satisfyStmt isCatchOrEndTry))
  catches <- many (try pCatchClause)
  _ <- satisfyStmt (leadingCtrl "end try")
  return (BsTry (TryStmt body catches))

pCatchClause :: FileParser CatchClause
pCatchClause = do
  s <- satisfyStmt (leadingCtrl "catch")
  let (exnType, exnVar) = parseCatchSig (stmtTokens s)
  body <- manyTill pBodyStmt (lookAhead (satisfyStmt isCatchOrEndTry))
  return (CatchClause exnType exnVar body)

-- | Parse the exception type and variable name from a catch statement's tokens.
-- Expected shape: catch ( TypeName varName ) or catch TypeName varName
parseCatchSig :: [Token] -> (Text, Text)
parseCatchSig ts =
  let inner = dropWhile (isCtrl "catch") ts
      stripped = filter (\t -> tkKind t `notElem` [TkLParen, TkRParen]) inner
  in case stripped of
       (typT : varT : _) -> (tkText typT, tkText varT)
       (typT : _)        -> (tkText typT, "")
       []                -> ("", "")

isCatchOrEndTry :: Statement -> Bool
isCatchOrEndTry s = case stmtTokens s of
  (t:_) -> tkKind t == TkControlKw
        && T.toLower (tkText t) `elem` ["catch", "end try"]
  _ -> False

-- ---------------------------------------------------------------------------
-- SQL body statement

pSqlBodyStmt :: FileParser BodyStmt
pSqlBodyStmt = do
  first <- satisfyStmt isSqlStart
  if stmtTerminated first
    then return (BsRaw (llText (stmtSource first)))
    else do
      conts <- moreConts (parenDelta (stmtTokens first))
      let texts = map (llText . stmtSource) (first : conts)
      return (BsRaw (T.intercalate "\n" texts))
  where
    isSqlStart s = case stmtTokens s of
      (t:lp:_) -> tkKind t == TkSqlKw && tkKind lp /= TkLParen
      (t:_)    -> tkKind t == TkSqlKw
      []       -> False
    parenDelta toks =
      length (filter ((== TkLParen) . tkKind) toks) -
      length (filter ((== TkRParen) . tkKind) toks)
    -- Stop at block terminators and control-flow headers. Stop at new SQL
    -- starts only when paren depth is 0 — inside an open paren, a SELECT
    -- is a subquery continuation, not a new top-level statement.
    -- TkDeclKw is NOT in the stop set: PB's lexer classifies SQL keywords
    -- like FROM as TkDeclKw; use isBlockTerminator for "end function" etc.
    isContinuable depth s = not (isBlockTerminator s) && case stmtTokens s of
      (t:_) -> tkKind t /= TkControlKw
            && (depth > 0 || tkKind t /= TkSqlKw)
      []    -> False
    moreConts depth = do
      ms <- optional (satisfyStmt (isContinuable depth))
      case ms of
        Nothing -> return []
        Just s  ->
          let newDepth = depth + parenDelta (stmtTokens s)
          in if stmtTerminated s then return [s] else (s:) <$> moreConts newDepth

isBlockTerminator :: Statement -> Bool
isBlockTerminator s = case stmtTokens s of
  (t:_) -> (tkKind t == TkDeclKw
              && T.toLower (tkText t) `elem`
                   ["end function", "end subroutine", "end event", "end on"])
        || (tkKind t == TkControlKw && T.toLower (tkText t) == "end try")
  _     -> False

pBodyStmt :: FileParser (Located BodyStmt)
pBodyStmt = do
  ln <- currentLine
  stmt <-   try pSqlBodyStmt
        <|> try pIfStmt
        <|> try pForStmt
        <|> try pDoStmt
        <|> try pChooseStmt
        <|> try pTryStmt
        <|> (classifyBodyStmt <$> satisfyStmt (not . isBlockTerminator))
  pure (Located ln stmt)
