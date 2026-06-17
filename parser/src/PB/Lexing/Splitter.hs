module PB.Lexing.Splitter
  ( Statement (..)
  , splitStatements
  ) where

import PB.Prelude
import PB.Lexing.Lexer (LexError, LexLine (..))
import PB.Lexing.Token (Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine)

data Statement = Statement
  { stmtTokens    :: [Token]
  , stmtSource    :: LogicalLine
  , stmtTerminated :: Bool
    -- ^ True when this segment was closed by an actual TkSemi token.
    -- Set authoritatively by segmentOnSemi; used by pSqlBodyStmt to
    -- decide whether to consume continuation lines.
  } deriving (Eq, Ord, Show)

splitStatements :: [LexLine] -> [Either LexError Statement]
splitStatements = concatMap splitLine

splitLine :: LexLine -> [Either LexError Statement]
splitLine (LexLine _ (Left err))  = [Left err]
splitLine (LexLine ll (Right ts)) =
  map (\(term, seg) -> Right (Statement seg ll term)) (segmentOnSemi ts)

-- Partition a token list on TkSemi boundaries.
-- Returns (terminated, tokens) pairs.
-- terminated = True when a TkSemi ended this segment.
-- Always produces at least one segment; a trailing TkSemi yields a final
-- empty (unterminated) segment which Runner.hs filters before parsing.
segmentOnSemi :: [Token] -> [(Bool, [Token])]
segmentOnSemi ts = go ts []
  where
    go [] acc = [(False, reverse acc)]
    go (t:rest) acc
      | tkKind t == TkSemi = (True, reverse acc) : go rest []
      | otherwise          = go rest (t : acc)
