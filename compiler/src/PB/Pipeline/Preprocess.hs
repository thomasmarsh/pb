{-# LANGUAGE StrictData #-}
module PB.Pipeline.Preprocess
  ( normalizeText
  , stripHeaders
  , LogicalLine(..)
  , SourceChunk(..)
  , mkLogicalLine
  , mkLogicalLineAt
  , resolveRawPos
  , advanceThroughText
  ) where

import PB.Prelude
import Data.Bifunctor (second)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T

-- | One contiguous run of 'llText' that came verbatim from a single raw
-- physical line, recording where in the original file it started and
-- where in the joined text it landed -- the provenance 'resolveRawPos'
-- walks to map a joined-text offset back to a true raw (line, col).
data SourceChunk = SourceChunk
  { scRawLine     :: Int  -- ^ Physical line this run came from.
  , scRawCol      :: Int  -- ^ 1-based column on that physical line where the run starts.
  , scJoinedStart :: Int  -- ^ 0-based offset into 'llText' where the run starts.
  , scLength      :: Int  -- ^ Length of the run, in both the raw line and 'llText'.
  } deriving (Show, Eq, Ord)

-- | A logical line after preprocessing.
--   Keeps the original physical line numbers for error reporting, plus
--   per-physical-line provenance ('llChunks') so a joined-text offset
--   (e.g. a token's column) can be mapped back to its true raw position
--   even across a `&` continuation or block-comment join.
data LogicalLine = LogicalLine
  { llText      :: Text
  , llStartLine :: Int         -- ^ First physical line number
  , llEndLine   :: Int         -- ^ Last physical line number
  , llChunks    :: NonEmpty SourceChunk
  } deriving (Show, Eq, Ord)

-- | Build a 'LogicalLine' for text that occupies exactly one physical line
-- (the common case in tests and any call site with no real join to model)
-- -- one chunk, spanning the whole text from column 1.
mkLogicalLine :: Text -> Int -> LogicalLine
mkLogicalLine t lineNo =
  LogicalLine t lineNo lineNo (SourceChunk lineNo 1 0 (T.length t) :| [])

-- | Build a 'LogicalLine' for text that is a verbatim slice of the real
-- source starting at a known @(line, col)@ -- unlike 'mkLogicalLine', the
-- text may itself contain real embedded newlines (e.g. a multi-line quoted
-- value lifted out of a larger file), each starting its own 'SourceChunk'
-- at column 1 so 'resolveRawPos' still maps every offset back to its true
-- raw position.
mkLogicalLineAt :: Int -> Int -> Text -> LogicalLine
mkLogicalLineAt startLine startCol t =
  LogicalLine t startLine endLine (buildChunks startLine startCol 0 (T.split (== '\n') t))
  where
    (endLine, _) = advanceThroughText (startLine, startCol) t

buildChunks :: Int -> Int -> Int -> [Text] -> NonEmpty SourceChunk
buildChunks ln col joinedStart [] = SourceChunk ln col joinedStart 0 :| []
buildChunks ln col joinedStart (p : ps)
  | null ps   = SourceChunk ln col joinedStart (T.length p) :| []
  | otherwise = SourceChunk ln col joinedStart (T.length p)
                  <| buildChunks (ln + 1) 1 (joinedStart + T.length p + 1) ps

-- | Advance a @(line, col)@ position past a run of text, counting any real
-- embedded newlines in that text. Used to compose a base position (e.g. a
-- 'DwBlock'\/attribute anchor) with a further offset inside the text found
-- there, without re-deriving newline-counting logic at each call site.
advanceThroughText :: (Int, Int) -> Text -> (Int, Int)
advanceThroughText (line, col) t =
  case T.breakOnEnd "\n" t of
    (before, after)
      | T.null before -> (line, col + T.length after)
      | otherwise     -> (line + T.count "\n" before, T.length after + 1)

-- | Map a 0-based offset into 'llText' back to the true raw (line, col) it
-- came from, via 'llChunks'. An offset that lands on a synthetic separator
-- character (the single space substituted for a joined `&`/newline/block
-- comment) resolves to one past the end of the preceding chunk -- no real
-- token content starts or ends exactly there.
resolveRawPos :: LogicalLine -> Int -> (Int, Int)
resolveRawPos ll offset =
  let c = findChunk (llChunks ll) offset
  in (scRawLine c, scRawCol c + (offset - scJoinedStart c))

findChunk :: NonEmpty SourceChunk -> Int -> SourceChunk
findChunk (c0 :| cs) offset = foldl' pick c0 cs
  where pick best c = if scJoinedStart c <= offset then c else best

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
    let (joined, endLine, chunks, remaining) = consumeContinuation n t rest
    in LogicalLine joined n endLine chunks : joinContinuations remaining

-- | Fold physical lines into one logical line while the current one ends in
-- a continuation marker. Recurses tail-first (handle this line, recurse on
-- the rest, then splice) so each line's own chunk length is always taken
-- from what that line actually contributes to the joined text -- its full
-- raw text when terminal, or its continuation-marker-stripped text when
-- another line follows -- never computed before that's known.
consumeContinuation
  :: Int            -- ^ this line's physical line number
  -> Text            -- ^ this line's own raw text
  -> [(Int, Text)]   -- ^ remaining physical lines
  -> (Text, Int, NonEmpty SourceChunk, [(Int, Text)])
consumeContinuation lineNo lineText rest
  | endsWithContinuation lineText =
      case rest of
        [] -> (lineText, lineNo, SourceChunk lineNo 1 0 (T.length lineText) :| [], [])
        ((n2, t2) : rest2) ->
          let stripped  = stripContinuationMarker lineText
              thisChunk = SourceChunk lineNo 1 0 (T.length stripped)
              (joinedRest, endLine, restChunks, remaining) =
                consumeContinuation n2 t2 rest2
              offset            = T.length stripped + 1
              shiftedRestChunks = NE.map
                (\c -> c { scJoinedStart = scJoinedStart c + offset }) restChunks
          in ( stripped <> " " <> joinedRest
             , endLine
             , thisChunk <| shiftedRestChunks
             , remaining
             )
  | otherwise =
      (lineText, lineNo, SourceChunk lineNo 1 0 (T.length lineText) :| [], rest)

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
      let (joined, endLine, chunks, remaining) =
            consumeBlockComment (llEndLine ll) (llText ll) (llChunks ll)
                                (lineCommentDepth (llText ll)) rest
      in LogicalLine joined (llStartLine ll) endLine chunks
           : joinBlockComments remaining
  | otherwise = ll : joinBlockComments rest

consumeBlockComment
  :: Int -> Text -> NonEmpty SourceChunk -> Int -> [LogicalLine]
  -> (Text, Int, NonEmpty SourceChunk, [LogicalLine])
consumeBlockComment currentEnd acc chunks _depth [] = (acc, currentEnd, chunks, [])
consumeBlockComment _currentEnd acc chunks depth (ll : rest) =
  let newAcc     = acc <> " " <> llText ll
      offset     = T.length acc + 1
      shifted    = NE.map (\c -> c { scJoinedStart = scJoinedStart c + offset }) (llChunks ll)
      newChunks  = chunks <> shifted
      newDepth   = depth + lineCommentDepth (llText ll)
  in if newDepth > 0
     then consumeBlockComment (llEndLine ll) newAcc newChunks newDepth rest
     else (newAcc, llEndLine ll, newChunks, rest)

-- | Net /* … */ depth contributed by a single line.
--   Scans left-to-right so that */ immediately before // (e.g. "*///")
--   is counted before the // line-comment terminates the scan.
lineCommentDepth :: Text -> Int
lineCommentDepth = go 0
  where
    go !acc t
      | T.null t             = acc
      | T.isPrefixOf "//" t  = acc
      | T.isPrefixOf "/*" t  = go (acc + 1) (T.drop 2 t)
      | T.isPrefixOf "*/" t  = go (acc - 1) (T.drop 2 t)
      | otherwise            = go acc (T.tail t)

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
