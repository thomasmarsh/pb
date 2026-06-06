module PB.Grammar.File
  ( pForwardBlock
  , pVariablesBlock
  , pTypeDecl
  , pVarDecl
  , pEndKw
  ) where

import PB.Prelude
import PB.Grammar.Stream  (FileParser, leadingText, satisfyStmt)
import PB.AST.Object      (ForwardBlock (..), TypeDecl (..), VariablesBlock (..), VarScope (..), VarDecl (..))
import PB.Lexing.Splitter (Statement (..))
import PB.Lexing.Token    (Token (..), TokenKind (..), tkKind, tkText)

import Text.Megaparsec (many, try)
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
