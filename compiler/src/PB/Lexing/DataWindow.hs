module PB.Lexing.DataWindow
  ( DwBlock (..)
  , DwAttr (..)
  , scanBlocks
  , scanBlockAttrs
  , extractParenBlock
  , resolveDwPos
  ) where

import PB.Prelude
import PB.Lexing.Escape (pbDwStringChunk)

import Data.Char (isAlpha, isAlphaNum, isDigit)
import qualified Data.Text as T
import Text.Megaparsec hiding (Token)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

-- ---------------------------------------------------------------------------

type DwParser = Parsec Void Text

-- | One keyword(content) block extracted from a .srd file. 'dwbLine'\/'dwbCol'
-- are the real position of 'dwbContent''s first character (right after the
-- opening paren), the anchor 'resolveDwPos' composes with a position found
-- by re-parsing 'dwbContent' (e.g. via 'scanBlockAttrs').
data DwBlock = DwBlock
  { dwbKeyword :: Text
  , dwbContent :: Text
  , dwbLine    :: Int
  , dwbCol     :: Int
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
    skipMany (try skipHeaderLine)
    n      <- pRelease
    blocks <- many (try pDwBlock)
    skipMany (satisfy (`elem` (" \t\n\r" :: String)))
    eof
    return (n, blocks)

-- Skip one line that does not begin (after optional whitespace) with "release".
-- Used to consume any number of export-header preamble lines before release N;.
-- The eof guard prevents an infinite loop when skipLine succeeds at EOF
-- consuming zero characters.
skipHeaderLine :: DwParser ()
skipHeaderLine = notFollowedBy (eof <|> releaseKw) >> skipLine
  where releaseKw = skipMany (satisfy (`elem` (" \t\r\n" :: String))) >> void (string' "release")

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
    _ <- optional (char '.' >> takeWhileP Nothing isDigit)
    skipMany (satisfy (\c -> c == ' ' || c == '\t'))
    _ <- char ';'
    _ <- optional (char '\n')
    return n

pDwBlock :: DwParser DwBlock
pDwBlock = do
    skipMany (satisfy (`elem` (" \t\n\r" :: String)))
    kw      <- pDwKeyword
    skipMany (satisfy (`elem` (" \t" :: String)))
    _       <- char '('
    pos     <- getSourcePos
    DwBlock kw <$> pBlockContent <*> pure (unPos (sourceLine pos)) <*> pure (unPos (sourceColumn pos))

-- Dotted identifiers with optional [N] suffix: keyword, export.pdf, header[1], etc.
-- All lower-cased.
pDwKeyword :: DwParser Text
pDwKeyword = do
    h <- satisfy (\c -> isAlpha c || c == '_')
    t <- takeWhileP Nothing (\c -> isAlphaNum c || c == '_' || c == '.')
    bracket <- optional $ do
        _ <- char '['
        ds <- takeWhileP Nothing isDigit
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
-- DwAttr — structured attribute token for block content

-- | One key=value attribute parsed from a DwBlock's content string. The
-- quoted variant's @(Int, Int)@ is the value's own @(line, col)@ relative to
-- whatever text was passed to 'scanBlockAttrs' (1,1-based) -- combine with
-- the source 'DwBlock''s 'dwbLine'\/'dwbCol' via 'resolveDwPos' to get a
-- real position in the original .srd file.
data DwAttr
  = DwAttrUnquoted Text Text  -- key, unquoted value (ends at whitespace)
  | DwAttrQuoted   Text Text (Int, Int)  -- key, quoted value (verbatim, tilde-escapes preserved), value's relative position
  | DwAttrSubBlock Text Text  -- key, raw inner content of key=(...)
  deriving (Eq, Show)

-- | Tokenize a block's content string into structured attributes.
-- Malformed tokens between valid attributes are skipped (error recovery).
scanBlockAttrs :: Text -> [DwAttr]
scanBlockAttrs src =
    case parse pBlockAttrs "" src of
        Left  _ -> []
        Right as -> as

pBlockAttrs :: DwParser [DwAttr]
pBlockAttrs = skipSp *> go
  where
    go = (:) <$> try pOneAttr <* skipSp <*> go
         <|> try (skipBadToken *> skipSp *> go)
         <|> pure []

skipBadToken :: DwParser ()
skipBadToken = void $ takeWhile1P (Just "bad token")
    (\c -> c /= ' ' && c /= '\t' && c /= '\n' && c /= '\r' && c /= ')')

skipSp :: DwParser ()
skipSp = skipMany (satisfy (`elem` (" \t\n\r" :: String)))

pOneAttr :: DwParser DwAttr
pOneAttr = do
    key <- pAttrKey
    skipSp
    _   <- char '='
    skipSp
    pAttrVal key

pAttrKey :: DwParser Text
pAttrKey = takeWhile1P (Just "attr key") (\c -> isAlphaNum c || c == '_' || c == '.')

pAttrVal :: Text -> DwParser DwAttr
pAttrVal key =
    (char '(' >> DwAttrSubBlock key <$> pBlockContent) <|>
    (char '"' >> pQuotedAttr key) <|>
    (DwAttrUnquoted key <$> pUnquotedVal) <|>
    pure (DwAttrUnquoted key "")

pQuotedAttr :: Text -> DwParser DwAttr
pQuotedAttr key = do
    pos <- getSourcePos
    val <- pQuotedContent
    return (DwAttrQuoted key val (unPos (sourceLine pos), unPos (sourceColumn pos)))

pQuotedContent :: DwParser Text
pQuotedContent = do
    chunks <- many (pbDwStringChunk '"')
    _      <- char '"'
    return (T.concat chunks)

-- Reads until whitespace; intentionally does NOT stop at ')' so that
-- type names like char(10) or decimal(0) are captured whole.
pUnquotedVal :: DwParser Text
pUnquotedVal = takeWhile1P (Just "unquoted value")
    (\c -> c /= ' ' && c /= '\t' && c /= '\n' && c /= '\r')

-- | Compose a 'DwBlock''s real anchor position with a relative position
-- captured by re-parsing its content (e.g. a 'DwAttrQuoted' value's own
-- position from 'scanBlockAttrs'). Content is always a verbatim slice of the
-- .srd file, so its own line 1 is the block's real line, and only a
-- relative line-1 position needs the column shifted by the anchor's column.
resolveDwPos :: (Int, Int) -> (Int, Int) -> (Int, Int)
resolveDwPos (baseLine, baseCol) (relLine, relCol)
  | relLine == 1 = (baseLine, baseCol + relCol - 1)
  | otherwise    = (baseLine + relLine - 1, relCol)

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
