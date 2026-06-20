module PB.Grammar.File
  ( parseSrFile
  , parseSrFileWithSpans
  , SrSpans (..)
  , pForwardBlock
  , pPrototypesBlock
  , pVariablesBlock
  , pTypeDecl
  , pVarDecl
  , pProtoDecl
  , pEndKw
  , pGlobalInstance
  , pTypeBlock
  , pOnBlock
  , pEventBlock
  , pFunctionBlock
  , pSubroutineBlock
  ) where

import PB.Prelude
import PB.Grammar.Body    (pBodyStmt)
import PB.Grammar.Stream  (FileParser, StmtStream (..), leadingText, satisfyStmt, isModifierToken, currentLine)
import PB.AST.BodyStmt    (BodyStmt)
import PB.AST.Located     (Located)
import PB.AST.SourceFile
  ( ForwardBlock (..), PrototypesBlock (..), ProtoDecl (..)
  , TypeDecl (..), TypeBlock (..)
  , VariablesBlock (..), VarScope (..), VarDecl (..)
  , GlobalInstance (..)
  , FnSig (..), SubSig (..), EventSig (..)
  , FunctionBlock (..), SubroutineBlock (..), EventBlock (..), OnBlock (..)
  , SrFile (..)
  )
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)
import PB.Pipeline.Preprocess (llStartLine, llText)

import Text.Megaparsec (many, manyTill, lookAhead, try, parse, getInput)
import Text.Megaparsec.Error (errorBundlePretty)
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
      in Just TypeDecl { tdName = tkText nameT, tdAncestor = tkText ancT, tdWithin = within }
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

buildVarDecl :: Statement -> VarDecl
buildVarDecl s =
  let (mods, rest) = span isModifierToken (stmtTokens s)
  in case rest of
    (typeT:nameT:_) -> VarDecl
      { vdModifiers = map tkText mods
      , vdType      = tkText typeT
      , vdName      = tkText nameT
      }
    _ -> error "impossible: buildVarDecl called on non-VarDecl statement"

pVarDecl :: FileParser VarDecl
pVarDecl = do
  s <- satisfyStmt isVarDecl
  return (buildVarDecl s)

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
    [_, typT, nameT] -> return (GlobalInstance (tkText typT) (tkText nameT))
    _                -> fail "malformed global instance declaration"

pVariablesBlock :: FileParser VariablesBlock
pVariablesBlock = do
  opener <- satisfyStmt isVarsOpener
  let scope = scopeFromOpener opener
  body <- manyTill anyStmt (pEndKw "variables")
  return (VariablesBlock scope [buildVarDecl s | s <- body, isVarDecl s])

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

parseParamsAndThrows :: [Token] -> (Text, Maybe Text)
parseParamsAndThrows more =
  let (paramToks, afterParams) = break (\t -> tkKind t == TkRParen) more
      params = T.intercalate " " (map tkText paramToks)
      throws = case afterParams of
        (_rparen : throwsKw : exName : _)
          | T.toLower (tkText throwsKw) == "throws" -> Just (tkText exName)
        _ -> Nothing
  in (params, throws)

extractFnSig :: Statement -> Maybe FnSig
extractFnSig s =
  let (modToks, rest) = span isFnMod (stmtTokens s)
      mods = map tkText modToks
      finish retTy name more =
        let (params, throws) = parseParamsAndThrows more
        in Just (FnSig mods (tkText retTy) (tkText name) params throws)
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
        let (params, throws) = parseParamsAndThrows more
        in Just (SubSig mods (tkText name) params throws)
  in case rest of
    (_kw : name : lparen : more)
      | tkKind lparen == TkLParen -> finish name more
    (_kw : name : dot : lparen : more)
      | tkKind dot   == TkDot
      , tkKind lparen == TkLParen -> finish name more
    _ -> Nothing

extractEvSig :: Statement -> Maybe EventSig
extractEvSig s =
  let rest = dropWhile isModifierToken (stmtTokens s)
  in case rest of
    (_kw : name : remainder) ->
        let rawSig = T.intercalate " " (map tkText remainder)
        in Just (EventSig (tkText name) rawSig)
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
  body <- manyTill pBodyStmt (lookAhead (pEndKw kw))
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

extractOnParts :: Statement -> Maybe (Text, Text, Text)
extractOnParts s = case stmtTokens s of
  (_:rest) ->
    let idents = [tkText t | t <- rest, tkKind t /= TkDot]
    in case idents of
      []            -> Nothing
      [ev]          -> Just (ev, "", ev)
      _             -> case reverse idents of
        []            -> Nothing
        (ev:ownerRev) -> Just (T.intercalate "." idents, T.intercalate "." (reverse ownerRev), ev)
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Body-block parsers

pTypeBlock :: FileParser TypeBlock
pTypeBlock = do
  decl        <- pTypeDecl
  (body, _)   <- pBodyUntil "type"
  return (TypeBlock decl body)

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
    go _   (TLType tb      : rest)     = TLType tb : go (Just (tdName (tbDecl tb))) rest
    go ctx (TLEvent s e ev : rest)     = TLEvent s e (ev { evOwner = ctx }) : go ctx rest
    go ctx (other          : rest)     = other      : go ctx rest

pAnyTopLevelBlock :: FileParser TopLevelBlock
pAnyTopLevelBlock =
      TLFwd        <$> try pForwardBlock
  <|> TLProto      <$> try pPrototypesBlock
  <|> TLVars       <$> try pVariablesBlock
  <|> TLGlobalInst <$> try pGlobalInstance
  <|> TLType       <$> try pTypeBlock
  <|> (\(s,e,b) -> TLOn   s e b) <$> try pOnBlockSpanned_
  <|> (\(s,e,b) -> TLEvent s e b) <$> try pEventBlockSpanned_
  <|> (\(s,e,b) -> TLFn   s e b) <$> try pFunctionBlockSpanned_
  <|> (\(s,e,b) -> TLSub  s e b) <$>     pSubroutineBlockSpanned_

parseSrFile :: [Text] -> [Statement] -> Either Text SrFile
parseSrFile headers stmts = fmap fst (parseSrFileWithSpans headers stmts)

parseSrFileWithSpans :: [Text] -> [Statement] -> Either Text (SrFile, SrSpans)
parseSrFileWithSpans headers stmts = case parse pSrFile "" (StmtStream stmts) of
  Right (f, spans) -> Right (f { srHeaders = headers }, spans)
  Left err         -> Left (T.pack (errorBundlePretty err))

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
        , srVariables       = listToMaybe [v  | TLVars       v       <- blocks]
        , srGlobalInstances = [gi | TLGlobalInst gi         <- blocks]
        , srTypeBlocks      = [t  | TLType       t          <- blocks]
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
