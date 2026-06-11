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
import PB.AST.Expr        ( BinOp (..), CallExpr (..), CreateExpr (..), Expr (..)
                          , DispatchExpr (..), DispatchMode (..)
                          , Literal (..), LvSegment (..), Lvalue (..) )
import PB.Grammar.Stream  (FileParser, satisfyStmt, isModifierToken)
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)
import PB.Pipeline.Preprocess (LogicalLine (..))

import Text.Megaparsec (lookAhead, many, manyTill, optional, try)
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
                          Nothing ->
                            let lhsExpr = parseExpr lhs
                            in case lhsExpr of
                                 ExRaw _ -> BsRaw s
                                 _       -> BsAssignExpr lhsExpr (parseExpr rhs)
                "++" -> BsInc       lhs
                "--" -> BsDec       lhs
                _    -> case augOp opText of
                          Just aop -> BsAugAssign lhs aop rhs
                          Nothing  -> BsRaw s

-- ---------------------------------------------------------------------------
-- Lvalue helpers

isSegmentName :: Token -> Bool
isSegmentName t = tkKind t `elem` [TkIdent, TkOtherKw, TkSqlKw, TkDatatype]

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
-- Dispatch parser helpers

-- | True for tokens that introduce or qualify a dispatch expression:
-- TkOtherKw "post"/"trigger"/"dynamic" or TkDeclKw "event".
isDispatchKw :: Token -> Bool
isDispatchKw t =
  (tkKind t == TkOtherKw && lw `elem` ["post", "trigger", "dynamic"]) ||
  (tkKind t == TkDeclKw  && lw == "event")
  where lw = T.toLower (tkText t)

-- | Find the leftmost dispatch keyword at paren/bracket/brace depth 0.
-- Returns (tokens before it, from-that-token onward), or Nothing.
findDispatchSplit :: [Token] -> Maybe ([Token], [Token])
findDispatchSplit = go (0 :: Int) []
  where
    go _ _   []     = Nothing
    go d acc (t:ts)
      | d == 0 && isDispatchKw t = Just (reverse acc, t:ts)
      | tkKind t `elem` [TkLParen, TkLBracket, TkLBrace] = go (d+1) (t:acc) ts
      | tkKind t `elem` [TkRParen, TkRBracket, TkRBrace] = go (max 0 (d-1)) (t:acc) ts
      | otherwise = go d (t:acc) ts

-- | Validate the pre-dispatch token slice (tokens before the first dispatch kw).
-- [] → Nothing (no object, implicit self)
-- [lv_tokens…, TkDot] → Just (lvalue) after stripping the trailing dot
-- anything else → Nothing (not a valid object prefix)
parseObjFromPre :: [Token] -> Maybe (Maybe Lvalue)
parseObjFromPre [] = Just Nothing
parseObjFromPre toks =
  case reverse toks of
    (dot:revLv) | tkKind dot == TkDot -> fmap Just (parseLvalue (reverse revLv))
    _                                 -> Nothing

-- | Consume dispatch qualifiers (post/trigger/dynamic/event) then a name then
-- parenthesised args. Accepts qualifiers in any order. Returns Nothing if the
-- next non-qualifier token is not a name, or there is no '(' after the name.
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
                  Just (ExDispatch (DispatchExpr objLv mode dyn isEv (tkText t) (splitArgs inner)), after)
            _ -> Nothing
      | otherwise = Nothing
    kwIs kw tok = tkKind tok `elem` [TkOtherKw, TkDeclKw]
               && T.toLower (tkText tok) == kw

-- | Try to parse a full token list as a dispatch expression.
-- Locates the first dispatch keyword at depth 0, validates the preceding
-- tokens as an optional object lvalue, then parses the dispatch body.
tryDispatchAtom :: [Token] -> Maybe (Expr, [Token])
tryDispatchAtom ts = do
  (preToks, dispToks) <- findDispatchSplit ts
  objLv               <- parseObjFromPre preToks
  parseDispBodyTokens objLv dispToks

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
-- Precedence-climbing expression parser

-- | Map a token to its binary-operator info: (constructor, precedence, isRightAssoc).
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

-- | After parsing a call or paren-group, greedily consume .name(args) chains.
-- Returns the original expression unchanged if no chain is present.
chainCalls :: Expr -> [Token] -> (Expr, [Token])
chainCalls e (dot : name : lp : rest)
  | tkKind dot  == TkDot
  , isSegmentName name
  , tkKind lp   == TkLParen
  = case findMatchingClose rest of
      Nothing             -> (e, dot : name : lp : rest)
      Just (inner, after) ->
        chainCalls (ExMethodCall e (tkText name) (splitArgs inner)) after
chainCalls e (dot : name : rest)
  | tkKind dot == TkDot
  , isSegmentName name
  = chainCalls (ExMethodCall e (tkText name) []) rest
chainCalls e ts = (e, ts)

-- | Parse one atom: a leaf expression that can appear as an operand.
-- Returns (parsed-expr, remaining-tokens), or Nothing if no atom starts here.
parseAtom :: [Token] -> Maybe (Expr, [Token])
parseAtom [] = Nothing
parseAtom (t:rest)
  | tkKind t == TkLParen = do
      (inner, after) <- findMatchingClose rest
      let (e', r') = chainCalls (parseExpr inner) after
      pure (e', r')

  | tkKind t == TkArithOp && tkText t == "-" = do
      (e, r) <- parseAtom rest
      pure (ExUnaryMinus e, r)

  | tkKind t == TkOtherKw && T.toLower (tkText t) == "not"
  = case parseAtom rest of
      Nothing     -> Just (ExNot (ExRaw rest), [])
      Just (e, r) -> let (e', r') = climbPrec 4 e r in Just (ExNot e', r')

  | tkKind t == TkOtherKw && T.toLower (tkText t) == "create"
  = case rest of
      (uT:r) | tkKind uT == TkOtherKw && T.toLower (tkText uT) == "using" -> do
        (e, r') <- parseAtom r
        pure (ExCreate (CreateUsing e), r')
      (cls:r) | tkKind cls `elem` [TkIdent, TkOtherKw, TkDatatype]
        -> Just (ExCreate (CreateClass (tkText cls)), r)
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
          let (e', r') = chainCalls (ExCall (CallExpr (Lvalue segs) (splitArgs inner))) after
          pure (e', r')
        _ -> pure (ExLvalue (Lvalue segs), remaining)

  | otherwise
  = case parseSingleToken t of
      ExRaw _ -> Nothing
      atom    -> Just (atom, rest)

-- | Consume binary operators at precedence >= minPrec, building a left-fold.
-- Never fails: returns (result-expr, remaining-tokens).
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
                (lhs', r')     = climbPrec minPrec (ExBinOp lhs bop rhs) r
            in (lhs', r')
  _ -> (lhs, ts)

-- ---------------------------------------------------------------------------
-- Expr parser

-- | Parse a token list as an expression.
-- Total function: unrecognized shapes become ExRaw.
parseExpr :: [Token] -> Expr
parseExpr [] = ExRaw []
parseExpr ts@(t:rest)
  -- Host variable: keep greedy lvalue parse, discarding tokens after it.
  -- This preserves the :varname, form used in embedded SQL arguments.
  | tkKind t == TkColon
  = case lvaluePrefix rest of
      Just (segs, _) | not (null segs) -> ExHostVar (Lvalue segs)
      _                                -> ExRaw ts
  | otherwise
  = case parseAtom ts of
      Nothing     -> ExRaw ts
      Just (e, r) ->
        let (e', leftover) = climbPrec 0 e r
        in if null leftover then e' else ExRaw ts

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
  TkDatatype    -> ExLvalue (Lvalue [LvSegment (tkText t) Nothing])
  _             -> ExRaw [t]

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

-- ---------------------------------------------------------------------------
-- Statement classifier

classifyBodyStmt :: Statement -> BodyStmt
classifyBodyStmt s = case stmtTokens s of
  [] -> BsRaw s
  (t : _)
    | tkKind t == TkLabel -> BsRaw s
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
             (typeT : lb : _ : rb : nameT : _)
               | isTypeName typeT
               , tkKind lb   == TkLBrace
               , tkKind rb   == TkRBrace
               , tkKind nameT == TkIdent -> BsLocalVar ts
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

-- | Consume a SQL body statement, merging multi-line SQL (no & continuations)
-- into a single BsRaw. Detects end by checking whether the source line text
-- ends with ';' (which segmentOnSemi strips from stmtTokens but leaves in
-- stmtSource.llText).
pSqlBodyStmt :: FileParser BodyStmt
pSqlBodyStmt = do
  first <- satisfyStmt isSqlStart
  conts <- if endsWithSemi first then return [] else moreConts
  return (BsRaw (foldl mergeStmt first conts))
  where
    -- Exclude TkSqlKw followed by '(' — those are function calls (open/close/etc.),
    -- not embedded SQL statements. Real SQL always uses keyword + non-paren continuation.
    isSqlStart s = case stmtTokens s of
      (t:lp:_) -> tkKind t == TkSqlKw && tkKind lp /= TkLParen
      (t:_)    -> tkKind t == TkSqlKw
      []       -> False
    endsWithSemi s = ";" `T.isSuffixOf` T.stripEnd (llText (stmtSource s))
    mergeStmt acc s = acc
      { stmtTokens = stmtTokens acc <> stmtTokens s
      , stmtSource = (stmtSource acc) { llEndLine = llEndLine (stmtSource s) }
      }
    moreConts = do
      s <- satisfyStmt (const True)
      if endsWithSemi s then return [s] else (s:) <$> moreConts

-- | Parse one body statement from the statement stream, handling control-flow
-- constructs recursively. Falls through to 'classifyBodyStmt' for leaf forms.
pBodyStmt :: FileParser BodyStmt
pBodyStmt =
      try pSqlBodyStmt
  <|> try pIfStmt
  <|> try pForStmt
  <|> try pDoStmt
  <|> try pChooseStmt
  <|> (classifyBodyStmt <$> satisfyStmt (const True))
