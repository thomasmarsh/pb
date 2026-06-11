module PB.Lexing.DataWindow
  ( DwBlock (..)
  , scanBlocks
  , extractParenBlock
  ) where

import PB.Prelude
import PB.Lexing.Escape (pbDwStringChunk)

import Data.Char (isAlpha, isAlphaNum)
import qualified Data.Text as T
import Text.Megaparsec hiding (Token)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

-- ---------------------------------------------------------------------------

type DwParser = Parsec Void Text

-- | One keyword(content) block extracted from a .srd file.
data DwBlock = DwBlock
  { dwbKeyword :: Text
  , dwbContent :: Text
  } deriving (Show)

-- ---------------------------------------------------------------------------
-- Top-level scanner

-- | Scan a raw .srd file into (release_number, [DwBlock]).
-- Strips the two export-header lines, parses 'release N;', then loops
-- over keyword(content) blocks.
scanBlocks :: Text -> Either Text (Int, [DwBlock])
scanBlocks src =
    case parse pFile "" src of
        Left  bundle -> Left (T.pack (errorBundlePretty bundle))
        Right result -> Right result

pFile :: DwParser (Int, [DwBlock])
pFile = do
    skipLine   -- HA$PBExportHeader$...
    skipLine   -- $PBExportComments$
    n      <- pRelease
    blocks <- many (try pDwBlock)
    skipMany (satisfy (`elem` (" \t\n\r" :: String)))
    eof
    return (n, blocks)

skipLine :: DwParser ()
skipLine = do
    _ <- takeWhileP Nothing (/= '\n')
    _ <- optional (char '\n')
    pure ()

pRelease :: DwParser Int
pRelease = do
    skipMany (satisfy (`elem` (" \t\r\n" :: String)))
    _ <- string' "release"
    skipMany (satisfy (\c -> c == ' ' || c == '\t'))
    n <- L.decimal
    _ <- optional (char '.' >> takeWhileP Nothing (\c -> c >= '0' && c <= '9'))
    skipMany (satisfy (\c -> c == ' ' || c == '\t'))
    _ <- char ';'
    _ <- optional (char '\n')
    return n

pDwBlock :: DwParser DwBlock
pDwBlock = do
    skipMany (satisfy (`elem` (" \t\n\r" :: String)))
    kw      <- pDwKeyword
    _       <- char '('
    content <- pBlockContent
    return (DwBlock kw content)

-- Dotted identifiers with optional [N] suffix: keyword, export.pdf, header[1], etc.
-- All lower-cased.
pDwKeyword :: DwParser Text
pDwKeyword = do
    h <- satisfy (\c -> isAlpha c || c == '_')
    t <- takeWhileP Nothing (\c -> isAlphaNum c || c == '_' || c == '.')
    bracket <- optional $ do
        _ <- char '['
        ds <- takeWhileP Nothing (\c -> c >= '0' && c <= '9')
        _ <- char ']'
        return ("[" <> ds <> "]")
    return (T.toLower (T.cons h t <> fromMaybe "" bracket))

-- ---------------------------------------------------------------------------
-- Paren-content parser (shared with extractParenBlock)

pBlockContent :: DwParser Text
pBlockContent = do
    chunks <- many pAtom
    _      <- char ')'
    return (T.concat chunks)

pAtom :: DwParser Text
pAtom = try pNestedParens <|> pDwString <|> pNonCloseParen

pNestedParens :: DwParser Text
pNestedParens = do
    _ <- char '('
    inner <- many pAtom
    _ <- char ')'
    return ("(" <> T.concat inner <> ")")

pDwString :: DwParser Text
pDwString = do
    _ <- char '"'
    chunks <- many (pbDwStringChunk '"')
    _ <- char '"'
    return ("\"" <> T.concat chunks <> "\"")

pNonCloseParen :: DwParser Text
pNonCloseParen = T.singleton <$> satisfy (/= ')')

-- ---------------------------------------------------------------------------
-- extractParenBlock — exported for unit testing

-- | Extract content between a matched pair of parentheses.
-- The Int is the char offset of the opening '(' in the Text argument.
-- Returns (content-without-parens, offset-of-char-after-closing-paren).
-- Quote-aware via pbDwStringChunk; handles nested parens.
extractParenBlock :: Text -> Int -> Either Text (Text, Int)
extractParenBlock txt startOffset =
    case T.drop startOffset txt of
        rest | T.null rest ->
                Left "extractParenBlock: offset past end of input"
             | T.head rest /= '(' ->
                Left "extractParenBlock: offset does not point to '('"
        rest ->
            case parse pExtract "" (T.tail rest) of
                Left  bundle -> Left (T.pack (errorBundlePretty bundle))
                Right (content, innerEnd) ->
                    Right (content, startOffset + 1 + innerEnd)
  where
    pExtract :: DwParser (Text, Int)
    pExtract = do
        chunks <- many pAtom
        _      <- char ')'
        off    <- getOffset
        return (T.concat chunks, off)
