module PB.Grammar.File
  ( pForwardBlock
  , pTypeDecl
  , pEndKw
  ) where

import PB.Prelude
import PB.Grammar.Stream  (FileParser, leadingText, satisfyStmt)
import PB.AST.Object      (ForwardBlock (..), TypeDecl (..))
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

pForwardBlock :: FileParser ForwardBlock
pForwardBlock = do
  _ <- leadingText "forward"
  types <- many (try pTypeDecl)
  pEndKw "forward"
  return (ForwardBlock types)
