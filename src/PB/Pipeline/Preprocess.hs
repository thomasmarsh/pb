module PB.Pipeline.Preprocess
  ( normalizeText
  , LogicalLine(..)
  ) where

import PB.Prelude
import qualified Data.Text as T

-- | A logical line after preprocessing.
--   Keeps the original physical line numbers for error reporting.
data LogicalLine = LogicalLine
  { llText      :: Text        -- ^ The joined logical line
  , llStartLine :: Int         -- ^ First physical line number
  , llEndLine   :: Int         -- ^ Last physical line number
  } deriving (Show, Eq)

-- | Normalize newlines, strip trailing spaces, and join continuation lines.
normalizeText :: Text -> [LogicalLine]
normalizeText =
    joinContinuations
  . stripTrailing
  . splitNormalized

splitNormalized :: Text -> [(Int, Text)]
splitNormalized txt =
  let normalized = T.replace "\r\n" "\n" txt
      ls = T.splitOn "\n" normalized
  in zip [1..] ls

stripTrailing :: [(Int, Text)] -> [(Int, Text)]
stripTrailing = map (\(n, t) -> (n, T.dropWhileEnd isSpace t))
  where
    isSpace c = c == ' ' || c == '\t'

joinContinuations :: [(Int, Text)] -> [LogicalLine]
joinContinuations [] = []
joinContinuations ((n, t) : rest) =
    let (joined, endLine, remaining) = consumeContinuation n n t rest
    in LogicalLine joined n endLine : joinContinuations remaining

consumeContinuation
  :: Int           -- ^ startLine (first physical line of this logical line)
  -> Int           -- ^ currentEnd (last physical line consumed so far)
  -> Text
  -> [(Int, Text)]
  -> (Text, Int, [(Int, Text)])
consumeContinuation _startLine currentEnd current [] =
  (current, currentEnd, [])
consumeContinuation startLine currentEnd current ((n, t) : rest)
  | endsWithContinuation current =
      let stripped = stripContinuationMarker current
          newText  = stripped <> " " <> t
      in consumeContinuation startLine n newText rest
  | otherwise =
      (current, currentEnd, (n, t) : rest)

-- | True if the last non-space character is '&' AND it is not inside a string.
endsWithContinuation :: Text -> Bool
endsWithContinuation t =
  case lastNonSpace t of
    Nothing  -> False
    Just '&' -> not (insideString t)
    _        -> False

stripContinuationMarker :: Text -> Text
stripContinuationMarker =
  T.dropWhileEnd (\c -> c == ' ' || c == '\t')
  >>> T.dropEnd 1

lastNonSpace :: Text -> Maybe Char
lastNonSpace =
  fmap snd
  . T.unsnoc
  . T.dropWhileEnd (\c -> c == ' ' || c == '\t')

-- | Heuristic: count unescaped quotes to detect whether '&' is inside a string.
insideString :: Text -> Bool
insideString t =
  let stripped = removeEscapedQuotes t
      quoteCount = T.count "\"" stripped
  in odd quoteCount

removeEscapedQuotes :: Text -> Text
removeEscapedQuotes = T.replace "\\\"" ""
