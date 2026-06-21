module PB.Lexing.Escape
  ( pbStringChunk
  , pbDwStringChunk
  , pbSelectTildeStr
  ) where

import PB.Prelude
import qualified Data.Text as T
import Text.Megaparsec hiding (Token)
import Text.Megaparsec.Char

-- | One PB escape sequence beginning with '~'.
pbEscape :: Parsec Void Text Text
pbEscape = do
  _ <- char '~'
  c <- anySingle
  case c of
    'o' -> do { d1 <- anySingle; d2 <- anySingle; d3 <- anySingle
              ; return (T.pack ['~','o',d1,d2,d3]) }
    'h' -> do { d1 <- anySingle; d2 <- anySingle
              ; return (T.pack ['~','h',d1,d2]) }
    _   -> return (T.pack ['~', c])

-- | One chunk inside a PB string: escape or a single non-delimiter, non-newline char.
pbStringChunk :: Char -> Parsec Void Text Text
pbStringChunk delim =
  pbEscape <|> fmap T.singleton (satisfy (\c -> c /= delim && c /= '\n'))

-- | Like 'pbStringChunk' but allows newlines (for multi-line DW retrieve strings).
pbDwStringChunk :: Char -> Parsec Void Text Text
pbDwStringChunk delim =
  pbEscape <|> fmap T.singleton (satisfy (/= delim))

-- | Parse a PBSELECT tilde-quoted string ~"..."~" and return the raw content.
-- Handles ~~" (3-char unit for escaped ~") and ~~ (2-char unit for escaped ~)
-- so that embedded ~" sequences never prematurely close the string.
pbSelectTildeStr :: Parsec Void Text Text
pbSelectTildeStr = do
    _ <- string "~\""
    chunks <- manyTill pChunk (string "~\"")
    return (T.concat chunks)
  where
    pChunk =
        try (string "~~\"") <|>
        try (string "~~")   <|>
        fmap T.singleton anySingle
