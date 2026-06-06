module PB.Grammar.File
  ( parseSrFile
  , pForwardBlock
  , pPrototypesBlock
  , pVariablesBlock
  , pTypeDecl
  , pVarDecl
  , pProtoDecl
  , pEndKw
  ) where

import PB.Prelude
import PB.Grammar.Stream  (FileParser, StmtStream (..), leadingText, satisfyStmt)
import PB.AST.Object
  ( ForwardBlock (..), PrototypesBlock (..), ProtoDecl (..)
  , TypeDecl (..), VariablesBlock (..), VarScope (..), VarDecl (..)
  , FnSig (..), SubSig (..), EventSig (..)
  , SrFile (..)
  )
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)

import Text.Megaparsec (many, try, optional, eof, parse, (<|>))
import Text.Megaparsec.Error (errorBundlePretty)
import qualified Data.Text as T

pEndKw :: Text -> FileParser ()
pEndKw kw = () <$ leadingText ("end " <> kw)

isMod :: Token -> Bool
isMod t = tkKind t `elem` [TkAccessModifier, TkStorageModifier]

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

pVariablesBlock :: FileParser VariablesBlock
pVariablesBlock = do
  opener <- satisfyStmt isVarsOpener
  let scope = scopeFromOpener opener
  decls <- many (try pVarDecl)
  pEndKw "variables"
  return (VariablesBlock scope decls)

pForwardBlock :: FileParser ForwardBlock
pForwardBlock = do
  _ <- leadingText "forward"
  types <- many (try pTypeDecl)
  pEndKw "forward"
  return (ForwardBlock types)

-- ---------------------------------------------------------------------------
-- Prototypes block

isProtosOpener :: Statement -> Bool
isProtosOpener s = case stmtTokens s of
  (t:_) -> T.toLower (tkText t)
             `elem` ["forward prototypes", "type prototypes", "prototypes"]
  []    -> False

isFnDecl :: Statement -> Bool
isFnDecl s =
  let rest = dropWhile isMod (stmtTokens s)
  in case rest of
    (t:_) -> T.toLower (tkText t) == "function"
    _     -> False

isSubDecl :: Statement -> Bool
isSubDecl s =
  let rest = dropWhile isMod (stmtTokens s)
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
  let (modToks, rest) = span isMod (stmtTokens s)
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
  let (modToks, rest) = span isMod (stmtTokens s)
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
-- Top-level entry point

parseSrFile :: [Text] -> [Statement] -> Either Text SrFile
parseSrFile headers stmts = case parse pFile "" (StmtStream stmts) of
  Right f  -> Right f
  Left err -> Left (T.pack (errorBundlePretty err))
  where
    pFile = do
      fwd   <- optional (try pForwardBlock)
      proto <- optional (try pPrototypesBlock)
      vars  <- optional (try pVariablesBlock)
      eof
      return SrFile
        { srHeaders     = headers
        , srForward     = fwd
        , srPrototypes  = proto
        , srVariables   = vars
        , srTypeBlocks  = []
        , srOnBlocks    = []
        , srEvents      = []
        , srFunctions   = []
        , srSubroutines = []
        }
