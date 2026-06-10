module PB.Grammar.File
  ( parseSrFile
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
import PB.Grammar.Stream  (FileParser, StmtStream (..), leadingText, satisfyStmt)
import PB.AST.Object
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

import Text.Megaparsec (many, manyTill, try, eof, parse, (<|>))
import Text.Megaparsec.Error (errorBundlePretty)
import qualified Data.Text as T

pEndKw :: Text -> FileParser ()
pEndKw kw = () <$ leadingText ("end " <> kw)

isMod :: Token -> Bool
isMod t = tkKind t `elem` [TkAccessModifier, TkStorageModifier]

isFnMod :: Token -> Bool
isFnMod t = isMod t
         || (tkKind t == TkDeclKw  && T.toLower (tkText t) `elem` ["external", "intrinsic"])
         || (tkKind t == TkOtherKw && T.toLower (tkText t) == "rpcfunc")

isTypeDecl :: Statement -> Bool
isTypeDecl s =
  let rest = dropWhile isMod (stmtTokens s)
  in case rest of
    (t0:_:t2:_) -> T.toLower (tkText t0) == "type" && T.toLower (tkText t2) == "from"
    _            -> False

extractTypeDecl :: Statement -> Maybe TypeDecl
extractTypeDecl s =
  let rest = dropWhile isMod (stmtTokens s)
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
  let rest = dropWhile isMod (stmtTokens s)
  in case rest of
    (t:_:_) -> tkKind t `elem` [TkDatatype, TkIdent]
    _       -> False

buildVarDecl :: Statement -> VarDecl
buildVarDecl s =
  let (mods, rest) = span isMod (stmtTokens s)
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
  let rest = dropWhile isMod (stmtTokens s)
  in case rest of
    (t:_) -> T.toLower (tkText t) == "event"
    _     -> False

extractFnSig :: Statement -> Maybe FnSig
extractFnSig s =
  let (modToks, rest) = span isFnMod (stmtTokens s)
      mods = map tkText modToks
  in case rest of
    (_kw : retTy : name : lparen : more)
      | tkKind lparen == TkLParen ->
          let (paramToks, afterParams) = break (\t -> tkKind t == TkRParen) more
              params = T.intercalate " " (map tkText paramToks)
              throws = case afterParams of
                (_rparen : throwsKw : exName : _)
                  | T.toLower (tkText throwsKw) == "throws" -> Just (tkText exName)
                _ -> Nothing
          in Just (FnSig mods (tkText retTy) (tkText name) params throws)
    _ -> Nothing

extractSubSig :: Statement -> Maybe SubSig
extractSubSig s =
  let (modToks, rest) = span isFnMod (stmtTokens s)
      mods = map tkText modToks
  in case rest of
    (_kw : name : lparen : more)
      | tkKind lparen == TkLParen ->
          let (paramToks, afterParams) = break (\t -> tkKind t == TkRParen) more
              params = T.intercalate " " (map tkText paramToks)
              throws = case afterParams of
                (_rparen : throwsKw : exName : _)
                  | T.toLower (tkText throwsKw) == "throws" -> Just (tkText exName)
                _ -> Nothing
          in Just (SubSig mods (tkText name) params throws)
    _ -> Nothing

extractEvSig :: Statement -> Maybe EventSig
extractEvSig s =
  let rest = dropWhile isMod (stmtTokens s)
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

pPrototypesBlock :: FileParser PrototypesBlock
pPrototypesBlock = do
  _ <- satisfyStmt isProtosOpener
  decls <- many (try pProtoDecl)
  pEndKw "prototypes"
  return (PrototypesBlock decls)

-- ---------------------------------------------------------------------------
-- Body-block helpers

anyStmt :: FileParser Statement
anyStmt = satisfyStmt (const True)

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
  decl <- pTypeDecl
  body <- manyTill anyStmt (pEndKw "type")
  return (TypeBlock decl body)

pOnBlock :: FileParser OnBlock
pOnBlock = do
  s <- satisfyStmt isOnDecl
  case extractOnParts s of
    Nothing              -> fail "malformed on-block opener"
    Just (qual, own, ev) -> do
      body <- manyTill anyStmt (pEndKw "on")
      return (OnBlock qual own ev body)

pEventBlock :: FileParser EventBlock
pEventBlock = do
  s <- satisfyStmt isEvDecl
  case extractEvSig s of
    Nothing  -> fail "malformed event opener"
    Just sig -> do
      body <- manyTill anyStmt (pEndKw "event")
      return (EventBlock sig body)

pFunctionBlock :: FileParser FunctionBlock
pFunctionBlock = do
  s <- satisfyStmt isFnDecl
  case extractFnSig s of
    Nothing  -> fail "malformed function opener"
    Just sig -> do
      body <- manyTill anyStmt (pEndKw "function")
      return (FunctionBlock sig body)

pSubroutineBlock :: FileParser SubroutineBlock
pSubroutineBlock = do
  s <- satisfyStmt isSubDecl
  case extractSubSig s of
    Nothing  -> fail "malformed subroutine opener"
    Just sig -> do
      body <- manyTill anyStmt (pEndKw "subroutine")
      return (SubroutineBlock sig body)

-- ---------------------------------------------------------------------------
-- Top-level entry point

data TopLevelBlock
  = TLFwd        ForwardBlock
  | TLProto      PrototypesBlock
  | TLVars       VariablesBlock
  | TLGlobalInst GlobalInstance
  | TLType       TypeBlock
  | TLOn         OnBlock
  | TLEvent      EventBlock
  | TLFn         FunctionBlock
  | TLSub        SubroutineBlock

pAnyTopLevelBlock :: FileParser TopLevelBlock
pAnyTopLevelBlock =
      TLFwd        <$> try pForwardBlock
  <|> TLProto      <$> try pPrototypesBlock
  <|> TLVars       <$> try pVariablesBlock
  <|> TLGlobalInst <$> try pGlobalInstance
  <|> TLType       <$> try pTypeBlock
  <|> TLOn         <$> try pOnBlock
  <|> TLEvent      <$> try pEventBlock
  <|> TLFn         <$> try pFunctionBlock
  <|> TLSub        <$> pSubroutineBlock

parseSrFile :: [Text] -> [Statement] -> Either Text SrFile
parseSrFile headers stmts = case parse pSrFile "" (StmtStream stmts) of
  Right f  -> Right (f { srHeaders = headers })
  Left err -> Left (T.pack (errorBundlePretty err))

pSrFile :: FileParser SrFile
pSrFile = do
  blocks <- many (try pAnyTopLevelBlock)
  eof
  return SrFile
    { srHeaders         = []
    , srForward         = listToMaybe [f  | TLFwd        f  <- blocks]
    , srPrototypes      = listToMaybe [p  | TLProto      p  <- blocks]
    , srVariables       = listToMaybe [v  | TLVars       v  <- blocks]
    , srGlobalInstances = [gi | TLGlobalInst gi <- blocks]
    , srTypeBlocks      = [t  | TLType       t  <- blocks]
    , srOnBlocks        = [o  | TLOn         o  <- blocks]
    , srEvents          = [e  | TLEvent      e  <- blocks]
    , srFunctions       = [f  | TLFn         f  <- blocks]
    , srSubroutines     = [s  | TLSub        s  <- blocks]
    }
