module PB.Grammar.File
  ( parseSrFile
  , parseSrFileWithSpans
  , SrSpans (..)
  , pForwardBlock
  , pPrototypesBlock
  , pVariablesBlock
  , pTypeDecl
  , pVarDecl
  , pGlobalInstance
  , pTypeBlock
  , pStructureBlock
  , pOnBlock
  , pEventBlock
  , pFunctionBlock
  , pSubroutineBlock
  , parseParamsAndThrows
  ) where

import PB.Prelude
import PB.Grammar.Body    (pBodyStmt, splitArgs)
import PB.Grammar.Stream  (FileParser, StmtStream (..), leadingText, satisfyStmt, isModifierToken, currentLine)
import PB.AST.BodyStmt    (BodyStmt)
import PB.AST.Ident       (Ident, identOrig, mkIdentAt, mkIdentDerived)
import PB.AST.Located     (Located)
import PB.AST.SourceFile
  ( ForwardBlock (..), PrototypesBlock (..), ProtoDecl (..)
  , TypeDecl (..), TypeBlock (..), StructureBlock (..), mkTypeDeclAt
  , VariablesBlock (..), VarScope (..), VarDecl (..)
  , GlobalInstance (..)
  , Param (..)
  , FnSig (..), SubSig (..), EventSig (..)
  , FunctionBlock (..), SubroutineBlock (..), EventBlock (..), OnBlock (..)
  , SrFile (..), ParseError (..)
  )
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText, tkSpan)
import PB.Pipeline.Preprocess (llStartLine, llText)

import Text.Megaparsec (many, manyTill, lookAhead, try, parse, getInput, bundlePosState, reachOffset, sourceLine, unPos, pstateSourcePos)
import Text.Megaparsec.Error (errorBundlePretty, errorOffset, bundleErrors)
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T

pEndKw :: Text -> FileParser ()
pEndKw kw = void (leadingText ("end " <> kw))

isFnMod :: Token -> Bool
isFnMod t = isModifierToken t
         || (tkKind t == TkDeclKw  && T.toLower (tkText t) `elem` ["external", "intrinsic"])
         || (tkKind t == TkOtherKw && T.toLower (tkText t) == "rpcfunc")

isTypeDecl :: Statement -> Bool
isTypeDecl s =
  let rest = dropWhile isModifierToken (stmtTokens s)
  in case rest of
    (t0:_:t2:_) -> T.toLower (tkText t0) == "type" && T.toLower (tkText t2) == "from"
    _            -> False

extractTypeDecl :: Statement -> Maybe TypeDecl
extractTypeDecl s =
  let rest = dropWhile isModifierToken (stmtTokens s)
  in case rest of
    (_:nameT:_:ancT:remainder) ->
      let within = case remainder of
            (w:cT:_) | T.toLower (tkText w) == "within" -> Just (tkText cT)
            _                                            -> Nothing
      in Just (mkTypeDeclAt (tkSpan nameT) (tkSpan ancT) (tkText nameT) (tkText ancT) within)
    _ -> Nothing

pTypeDecl :: FileParser TypeDecl
pTypeDecl = do
  s <- satisfyStmt isTypeDecl
  case extractTypeDecl s of
    Just td -> return td
    Nothing -> fail "malformed type declaration"

isVarsOpener :: Statement -> Bool
isVarsOpener s = case stmtTokens s of
  (t:_)    | T.toLower (tkText t) `elem` ["type variables", "variables"] -> True
  (t1:t2:_) | tkKind t1 == TkAccessModifier
             , T.toLower (tkText t1) `elem` ["global", "shared"]
             , T.toLower (tkText t2) == "variables"                       -> True
  _         -> False

scopeFromOpener :: Statement -> VarScope
scopeFromOpener s = case stmtTokens s of
  (t:_) | T.toLower (tkText t) == "global" -> GlobalVars
  _                                         -> TypeVars

isVarDecl :: Statement -> Bool
isVarDecl s =
  let rest = dropWhile isModifierToken (stmtTokens s)
  in case rest of
    (t:_:_) -> tkKind t `elem` [TkDatatype, TkIdent]
    _       -> False

-- | Split a comma-separated declarator list (name, name2, ...) sharing one
-- type/mods into one VarDecl per name, reusing 'PB.Grammar.Body.splitArgs'
-- so a subscript or paren-nested expression in a later name's segment
-- doesn't misfire the split. VarDecl has no initializer field, so a
-- trailing '= value' on any name is discarded.
buildVarDecls :: Statement -> [VarDecl]
buildVarDecls s =
  let (mods, rest) = span isModifierToken (stmtTokens s)
  in case rest of
    (typeT : nameT : rest') -> mapMaybe (declFor mods typeT) (splitArgs (nameT : rest'))
    _ -> error "impossible: buildVarDecls called on non-VarDecl statement"
  where
    declFor mods typeT (n : _) | tkKind n == TkIdent =
      Just VarDecl
        { vdModifiers = map tkText mods
        , vdType      = tkText typeT
        , vdTypeSpan  = tkSpan typeT
        , vdName      = mkIdentAt (tkSpan n) (tkText n)
        }
    declFor _ _ _ = Nothing

pVarDecl :: FileParser [VarDecl]
pVarDecl = do
  s <- satisfyStmt isVarDecl
  return (buildVarDecls s)

isGlobalInstance :: Statement -> Bool
isGlobalInstance s = case stmtTokens s of
  [t0, t1, t2]
    | T.toLower (tkText t0) == "global"
    , tkKind t0 == TkAccessModifier
    , tkKind t1 `elem` [TkIdent, TkOtherKw]
    , tkKind t2 `elem` [TkIdent, TkOtherKw]
    -> True
  _ -> False

pGlobalInstance :: FileParser GlobalInstance
pGlobalInstance = do
  s <- satisfyStmt isGlobalInstance
  case stmtTokens s of
    [_, typT, nameT] -> return (GlobalInstance (tkText typT) (tkSpan typT) (mkIdentAt (tkSpan nameT) (tkText nameT)))
    _                -> fail "malformed global instance declaration"

pVariablesBlock :: FileParser VariablesBlock
pVariablesBlock = do
  opener <- satisfyStmt isVarsOpener
  let scope = scopeFromOpener opener
  body <- manyTill anyStmt (pEndKw "variables")
  return (VariablesBlock scope (concatMap buildVarDecls (filter isVarDecl body)))

pFwdTypeEntry :: FileParser TypeDecl
pFwdTypeEntry = tbDecl <$> pTypeBlock

data FwdEntry = FwdTy TypeDecl | FwdGI GlobalInstance

pFwdEntry :: FileParser FwdEntry
pFwdEntry = (FwdTy <$> try pFwdTypeEntry) <|> (FwdGI <$> pGlobalInstance)

pForwardBlock :: FileParser ForwardBlock
pForwardBlock = do
  _ <- leadingText "forward"
  entries <- many (try pFwdEntry)
  pEndKw "forward"
  return ForwardBlock
    { fwdTypes     = [d | FwdTy d <- entries]
    , fwdInstances = [g | FwdGI g <- entries]
    }

-- ---------------------------------------------------------------------------
-- Prototypes block

isProtosOpener :: Statement -> Bool
isProtosOpener s = case stmtTokens s of
  (t:_) -> T.toLower (tkText t)
             `elem` ["forward prototypes", "type prototypes", "prototypes"]
  []    -> False

isFnDecl :: Statement -> Bool
isFnDecl s =
  let rest = dropWhile isFnMod (stmtTokens s)
  in case rest of
    (t:_) -> T.toLower (tkText t) == "function"
    _     -> False

isSubDecl :: Statement -> Bool
isSubDecl s =
  let rest = dropWhile isFnMod (stmtTokens s)
  in case rest of
    (t:_) -> T.toLower (tkText t) == "subroutine"
    _     -> False

isEvDecl :: Statement -> Bool
isEvDecl s =
  let rest = dropWhile isModifierToken (stmtTokens s)
  in case rest of
    (t:_) -> T.toLower (tkText t) == "event"
    _     -> False

-- | Split a token span between a signature's '(' and ')' into typed
-- 'Param's -- 'splitArgs' (bracket-depth aware, already used by
-- 'buildVarDecls' for a declarator list) handles the top-level comma split,
-- so an array param's '[' ']' never misfires the split.  Each segment is
-- @mods* type name (array-brackets)?@; leftover tokens after the last
-- recognized (mods, type, name) triple -- i.e. dimension brackets -- carry
-- no further dimension expression in a signature, so they are discarded.
parseParamsAndThrows :: [Token] -> ([Param], Maybe Text, Maybe Text, Maybe Text)
parseParamsAndThrows more =
  let (paramToks, afterParams) = break (\t -> tkKind t == TkRParen) more
      params = mapMaybe paramFor (splitArgs paramToks)
      rest = drop 1 afterParams  -- skip the ')'
      (throws, library, aliasFor) = extractTrailingClauses rest
  in (params, throws, library, aliasFor)
  where
    paramFor toks = case span isModifierToken toks of
      (mods, typeT : nameT : _) | tkKind nameT == TkIdent ->
        Just Param
          { paramMods     = map tkText mods
          , paramType     = tkText typeT
          , paramTypeSpan = tkSpan typeT
          , paramName     = mkIdentAt (tkSpan nameT) (tkText nameT)
          }
      _ -> Nothing
    -- Scan the trailing token span after ')' for THROWS, LIBRARY, and ALIAS FOR
    -- clauses.  These can appear in any order; each keyword is prefixed and the
    -- parser is lenient — a malformed clause is silently ignored.
    extractTrailingClauses :: [Token] -> (Maybe Text, Maybe Text, Maybe Text)
    extractTrailingClauses = go Nothing Nothing Nothing
      where
        go t l a [] = (t, l, a)
        go t l a (tok : rest)
          | T.toLower (tkText tok) == "throws"
          = case rest of
              (name : _) | tkKind name == TkIdent -> go (Just (tkText name)) l a (drop 1 rest)
              _ -> go t l a rest
          | T.toLower (tkText tok) == "library"
          = case rest of
              (libStr : _) | tkKind libStr `elem` [TkStringDouble, TkStringSingle] -> go t (Just (unquote libStr)) a (drop 1 rest)
              _ -> go t l a rest
          | T.toLower (tkText tok) == "alias"
          = case rest of
              (forKw : aliasStr : more')
                | T.toLower (tkText forKw) == "for"
                , tkKind aliasStr `elem` [TkStringDouble, TkStringSingle] -> go t l (Just (unquote aliasStr)) more'
              _ -> go t l a rest
          | otherwise = go t l a rest
        -- Strip the surrounding quote delimiters, matching how 'ExStr' converts
        -- a string-literal token's raw text elsewhere in the grammar.
        unquote tok = T.dropEnd 1 (T.drop 1 (tkText tok))

extractFnSig :: Statement -> Maybe FnSig
extractFnSig s =
  let (modToks, rest) = span isFnMod (stmtTokens s)
      mods = map tkText modToks
      finish retTy name more =
        let (params, throws, library, aliasFor) = parseParamsAndThrows more
        in Just (FnSig mods (tkText retTy) (tkSpan retTy) (mkIdentAt (tkSpan name) (tkText name)) params throws library aliasFor)
  in case rest of
    (_kw : retTy : name : lparen : more)
      | tkKind lparen == TkLParen -> finish retTy name more
    (_kw : retTy : name : dot : lparen : more)
      | tkKind dot   == TkDot
      , tkKind lparen == TkLParen -> finish retTy name more
    _ -> Nothing

extractSubSig :: Statement -> Maybe SubSig
extractSubSig s =
  let (modToks, rest) = span isFnMod (stmtTokens s)
      mods = map tkText modToks
      finish name more =
        let (params, throws, library, aliasFor) = parseParamsAndThrows more
        in Just (SubSig mods (mkIdentAt (tkSpan name) (tkText name)) params throws library aliasFor)
  in case rest of
    (_kw : name : lparen : more)
      | tkKind lparen == TkLParen -> finish name more
    (_kw : name : dot : lparen : more)
      | tkKind dot   == TkDot
      , tkKind lparen == TkLParen -> finish name more
    _ -> Nothing

-- | An event's declared param list is optionally parenthesized -- a system
-- event (e.g. @event ue_keypress pbm_char@) names a Windows message ID
-- instead, which is not a param list at all and yields no 'Param's.
extractEvSig :: Statement -> Maybe EventSig
extractEvSig s =
  let rest = dropWhile isModifierToken (stmtTokens s)
  in case rest of
    (_kw : name : remainder) ->
        let params = case remainder of
              (lp : more) | tkKind lp == TkLParen -> let (ps, _, _, _) = parseParamsAndThrows more in ps
              _ -> []
        in Just (EventSig (mkIdentAt (tkSpan name) (tkText name)) params)
    _ -> Nothing

pFnProto :: FileParser ProtoDecl
pFnProto = do
  s <- satisfyStmt isFnDecl
  case extractFnSig s of
    Just sig -> return (ProtoFn sig)
    Nothing  -> fail "malformed function prototype"

pSubProto :: FileParser ProtoDecl
pSubProto = do
  s <- satisfyStmt isSubDecl
  case extractSubSig s of
    Just sig -> return (ProtoSub sig)
    Nothing  -> fail "malformed subroutine prototype"

pEvProto :: FileParser ProtoDecl
pEvProto = do
  s <- satisfyStmt isEvDecl
  case extractEvSig s of
    Just sig -> return (ProtoEv sig)
    Nothing  -> fail "malformed event prototype"

pProtoDecl :: FileParser ProtoDecl
pProtoDecl = try pFnProto <|> try pSubProto <|> pEvProto

isAccessModifierHeader :: Statement -> Bool
isAccessModifierHeader s = case stmtTokens s of
  [t] -> tkKind t == TkLabel
      && T.toLower (tkText t) `elem` ["public:", "protected:", "private:"]
  _ -> False

pProtoDeclOrSkip :: FileParser (Maybe ProtoDecl)
pProtoDeclOrSkip =
  (Just <$> try pProtoDecl) <|> (Nothing <$ satisfyStmt isAccessModifierHeader)

pPrototypesBlock :: FileParser PrototypesBlock
pPrototypesBlock = do
  _ <- satisfyStmt isProtosOpener
  items <- many (try pProtoDeclOrSkip)
  pEndKw "prototypes"
  return (PrototypesBlock (catMaybes items))

-- ---------------------------------------------------------------------------
-- Body-block helpers

anyStmt :: FileParser Statement
anyStmt = satisfyStmt (const True)

pBodyUntil :: Text -> FileParser ([Located BodyStmt], Int)
pBodyUntil kw = do
  body <- concat <$> manyTill pBodyStmt (lookAhead (pEndKw kw))
  end  <- currentLine
  _    <- pEndKw kw
  return (body, end)

isOnDecl :: Statement -> Bool
isOnDecl s = case stmtTokens s of
  (t:t2:_) -> T.toLower (tkText t) == "on"
              && tkKind t2 `elem` [ TkIdent, TkDeclKw, TkControlKw, TkOtherKw
                                  , TkDatatype, TkAccessModifier, TkStorageModifier
                                  , TkBoolTrue, TkBoolFalse, TkSqlKw ]
  _         -> False

extractOnParts :: Statement -> Maybe (Ident, Ident, Ident)
extractOnParts s = case stmtTokens s of
  (_:rest) ->
    let identToks = [t | t <- rest, tkKind t /= TkDot]
    in case identToks of
      []            -> Nothing
      [evT]         ->
        let ev = mkIdentAt (tkSpan evT) (tkText evT)
        in Just (ev, ev, ev)
      _             -> case reverse identToks of
        []            -> Nothing
        (evT:ownerRevToks) ->
          let ev    = mkIdentAt (tkSpan evT) (tkText evT)
              ownerToks = reverse ownerRevToks
              owner = mkIdentDerived (NE.fromList (map tkSpan ownerToks))
                                     (T.intercalate "." (map tkText ownerToks))
              qual  = mkIdentDerived (NE.fromList (map tkSpan identToks))
                                     (T.intercalate "." (map tkText identToks))
          in Just (qual, owner, ev)
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Body-block parsers

pTypeBlock :: FileParser TypeBlock
pTypeBlock = do
  decl        <- pTypeDecl
  (body, _)   <- pBodyUntil "type"
  return (TypeBlock decl body)

-- | @type NAME from structure ... end type@ -- checks 'tdAncestor' once,
-- here, so no downstream consumer needs its own ancestor-string match.
-- Fields reuse 'buildVarDecls' (the same declarator-list parser
-- 'pVariablesBlock' uses), not the generic body-statement classifier, since
-- a structure's field lines are plain @[mods] type name@ declarators, never
-- executable statements.
pStructureBlock :: FileParser StructureBlock
pStructureBlock = do
  decl <- pTypeDecl
  if T.toLower (tdAncestor decl) /= "structure"
    then fail "not a structure declaration"
    else do
      body <- manyTill anyStmt (pEndKw "type")
      return (StructureBlock (tdName decl) (concatMap buildVarDecls (filter isVarDecl body)))

pBlockSpanned :: (Statement -> Bool) -> (Statement -> Maybe sig) -> (sig -> [Located BodyStmt] -> blk) -> Text -> FileParser (Int, Int, blk)
pBlockSpanned isDecl extractSig mkBlock endKw = do
  start <- currentLine
  s     <- satisfyStmt isDecl
  case extractSig s of
    Nothing  -> fail "malformed block opener"
    Just sig -> do
      (body, end) <- pBodyUntil endKw
      return (start, end, mkBlock sig body)

pOnBlockSpanned_ :: FileParser (Int, Int, OnBlock)
pOnBlockSpanned_ = pBlockSpanned isOnDecl extractOnParts (\(q, o, e) -> OnBlock q o e) "on"

pOnBlock :: FileParser OnBlock
pOnBlock = (\(_, _, b) -> b) <$> pOnBlockSpanned_

pEventBlockSpanned_ :: FileParser (Int, Int, EventBlock)
pEventBlockSpanned_ = pBlockSpanned isEvDecl extractEvSig
    (\sig body -> EventBlock sig Nothing body) "event"

pEventBlock :: FileParser EventBlock
pEventBlock = (\(_, _, b) -> b) <$> pEventBlockSpanned_

pFunctionBlockSpanned_ :: FileParser (Int, Int, FunctionBlock)
pFunctionBlockSpanned_ = pBlockSpanned isFnDecl extractFnSig FunctionBlock "function"

pFunctionBlock :: FileParser FunctionBlock
pFunctionBlock = (\(_, _, b) -> b) <$> pFunctionBlockSpanned_

pSubroutineBlockSpanned_ :: FileParser (Int, Int, SubroutineBlock)
pSubroutineBlockSpanned_ = pBlockSpanned isSubDecl extractSubSig SubroutineBlock "subroutine"

pSubroutineBlock :: FileParser SubroutineBlock
pSubroutineBlock = (\(_, _, b) -> b) <$> pSubroutineBlockSpanned_

-- ---------------------------------------------------------------------------
-- Top-level entry point

data SrSpans = SrSpans
  { spOnBlocks    :: [(Int, Int)]
  , spEvents      :: [(Int, Int)]
  , spFunctions   :: [(Int, Int)]
  , spSubroutines :: [(Int, Int)]
  }

data TopLevelBlock
  = TLFwd        ForwardBlock
  | TLProto      PrototypesBlock
  | TLVars       VariablesBlock
  | TLGlobalInst GlobalInstance
  | TLType       TypeBlock
  | TLStructure  StructureBlock
  | TLOn         Int Int OnBlock
  | TLEvent      Int Int EventBlock
  | TLFn         Int Int FunctionBlock
  | TLSub        Int Int SubroutineBlock

-- | Walk the ordered block list and annotate each TLEvent with the name of
-- the most recently closed TypeBlock. Other block kinds do not update context.
resolveEventOwners :: [TopLevelBlock] -> [TopLevelBlock]
resolveEventOwners = go Nothing
  where
    go _   []                          = []
    go _   (TLType tb      : rest)     = TLType tb : go (Just (identOrig (tdName (tbDecl tb)))) rest
    go ctx (TLEvent s e ev : rest)     = TLEvent s e (ev { evOwner = ctx }) : go ctx rest
    go ctx (other          : rest)     = other      : go ctx rest

pAnyTopLevelBlock :: FileParser TopLevelBlock
pAnyTopLevelBlock =
      TLFwd        <$> try pForwardBlock
  <|> TLProto      <$> try pPrototypesBlock
  <|> TLVars       <$> try pVariablesBlock
  <|> TLGlobalInst <$> try pGlobalInstance
  <|> TLStructure  <$> try pStructureBlock
  <|> TLType       <$> try pTypeBlock
  <|> (\(s,e,b) -> TLOn   s e b) <$> try pOnBlockSpanned_
  <|> (\(s,e,b) -> TLEvent s e b) <$> try pEventBlockSpanned_
  <|> (\(s,e,b) -> TLFn   s e b) <$> try pFunctionBlockSpanned_
  <|> (\(s,e,b) -> TLSub  s e b) <$>     pSubroutineBlockSpanned_

parseSrFile :: [Text] -> [Statement] -> Either Text SrFile
parseSrFile headers stmts = case parseSrFileWithSpans headers stmts of
  Left err -> Left (peMessage err)
  Right (sf, _) -> Right sf

parseSrFileWithSpans :: [Text] -> [Statement] -> Either ParseError (SrFile, SrSpans)
parseSrFileWithSpans headers stmts = case parse pSrFile "" (StmtStream stmts) of
  Right (f, spans) -> Right (f { srHeaders = headers }, spans)
  Left err         ->
    let errMsg = T.pack (errorBundlePretty err)
        posState = bundlePosState err
        errOff = errorOffset (NE.head (bundleErrors err))
        (_, newPos) = reachOffset errOff posState
        errLine = Just (unPos (sourceLine (pstateSourcePos newPos)))
    in Left (ParseError errMsg errLine)

pSrFile :: FileParser (SrFile, SrSpans)
pSrFile = do
  rawBlocks <- many (try pAnyTopLevelBlock)
  let blocks = resolveEventOwners rawBlocks
  StmtStream remaining <- getInput
  case remaining of
    (s:_) -> fail $
      "parser stuck at line " <> show (llStartLine (stmtSource s))
      <> " after parsing " <> show (length blocks) <> " top-level block(s)\n"
      <> "  unrecognized construct: " <> T.unpack (T.take 200 (llText (stmtSource s)))
    [] -> return ()
  let sf = SrFile
        { srHeaders         = []
        , srForward         = listToMaybe [f  | TLFwd        f       <- blocks]
        , srPrototypes      = listToMaybe [p  | TLProto      p       <- blocks]
        , srVariables       = [v  | TLVars       v       <- blocks]
        , srGlobalInstances = [gi | TLGlobalInst gi         <- blocks]
        , srTypeBlocks      = [t  | TLType       t          <- blocks]
        , srStructureBlocks = [t  | TLStructure  t          <- blocks]
        , srOnBlocks        = [o  | TLOn    _ _ o           <- blocks]
        , srEvents          = [e  | TLEvent _ _ e           <- blocks]
        , srFunctions       = [f  | TLFn    _ _ f           <- blocks]
        , srSubroutines     = [s  | TLSub   _ _ s           <- blocks]
        }
      spans = SrSpans
        { spOnBlocks    = [(s, e) | TLOn    s e _ <- blocks]
        , spEvents      = [(s, e) | TLEvent s e _ <- blocks]
        , spFunctions   = [(s, e) | TLFn    s e _ <- blocks]
        , spSubroutines = [(s, e) | TLSub   s e _ <- blocks]
        }
  return (sf, spans)
