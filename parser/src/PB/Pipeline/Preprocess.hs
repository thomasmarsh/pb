module PB.Pipeline.Preprocess
  ( normalizeText
  , stripHeaders
  , LogicalLine(..)
  ) where

import PB.Prelude
import Data.Bifunctor (second)
import qualified Data.Text as T

-- | A logical line after preprocessing.
--   Keeps the original physical line numbers for error reporting.
data LogicalLine = LogicalLine
  { llText      :: Text        -- ^ The joined logical line
  , llStartLine :: Int         -- ^ First physical line number
  , llEndLine   :: Int         -- ^ Last physical line number
  } deriving (Show, Eq, Ord)

-- | Normalize newlines, strip trailing spaces, join continuation lines,
--   and merge physical lines that span a block comment /* … */.
normalizeText :: Text -> [LogicalLine]
normalizeText =
    joinBlockComments
  . joinContinuations
  . stripTrailing
  . splitNormalized

splitNormalized :: Text -> [(Int, Text)]
splitNormalized txt =
  let normalized = T.replace "\r\n" "\n" txt
      ls = T.splitOn "\n" normalized
  in zip [1..] ls

stripTrailing :: [(Int, Text)] -> [(Int, Text)]
stripTrailing = map (second (T.dropWhileEnd isSpace))
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

-- | True if the last non-space character is '&'.
-- PowerBuilder allows & continuation both outside strings (statement
-- continuation) and inside open string literals (string continuation);
-- both cases require joining with the next physical line.
endsWithContinuation :: Text -> Bool
endsWithContinuation t =
  case lastNonSpace t of
    Just '&' -> True
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

-- | Join physical lines that span a /* … */ block comment.
--   Tracks open/close depth per line (stripping // suffixes first) so that
--   // line comments containing /* or */ do not confuse the count.
joinBlockComments :: [LogicalLine] -> [LogicalLine]
joinBlockComments [] = []
joinBlockComments (ll : rest)
  | lineCommentDepth (llText ll) > 0 =
      let (joined, endLine, remaining) =
            consumeBlockComment (llEndLine ll) (llText ll)
                                (lineCommentDepth (llText ll)) rest
      in LogicalLine joined (llStartLine ll) endLine
           : joinBlockComments remaining
  | otherwise = ll : joinBlockComments rest

consumeBlockComment
  :: Int -> Text -> Int -> [LogicalLine] -> (Text, Int, [LogicalLine])
consumeBlockComment currentEnd acc _depth [] = (acc, currentEnd, [])
consumeBlockComment _currentEnd acc depth (ll : rest) =
  let newAcc   = acc <> " " <> llText ll
      newDepth = depth + lineCommentDepth (llText ll)
  in if newDepth > 0
     then consumeBlockComment (llEndLine ll) newAcc newDepth rest
     else (newAcc, llEndLine ll, rest)

-- | Net /* … */ depth contributed by a single line.
--   Strips the // line-comment suffix first so that // comments containing
--   /* or */ tokens do not affect the count.
lineCommentDepth :: Text -> Int
lineCommentDepth t =
  let code = fst (T.breakOn "//" t)
  in T.count "/*" code - T.count "*/" code

-- | Strip leading $PBExport*$ header lines (SPEC §2.11).
-- Handles the real-world "HA$PBExportHeader$" form: the two leading "HA" bytes
-- are a PowerBuilder marker and are dropped before storing the header text.
stripHeaders :: [LogicalLine] -> ([Text], [LogicalLine])
stripHeaders lls =
  let (headers, rest) = span (isHeaderText . llText) lls
  in (map (T.dropWhile (/= '$') . llText) headers, rest)

isHeaderText :: Text -> Bool
isHeaderText t =
  let t' = T.dropWhile (/= '$') t
  in T.isPrefixOf "$PBExport" t' && T.isInfixOf "$" (T.drop 1 t')
