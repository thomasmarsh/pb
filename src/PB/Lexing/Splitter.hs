module PB.Lexing.Splitter
  ( Statement (..)
  , splitStatements
  ) where

import PB.Prelude
import PB.Lexing.Lexer (LexError, LexLine (..))
import PB.Lexing.Token (Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine)

data Statement = Statement
  { stmtTokens :: [Token]
  , stmtSource :: LogicalLine
  } deriving (Eq, Ord, Show)

splitStatements :: [LexLine] -> [Either LexError Statement]
splitStatements = concatMap splitLine

splitLine :: LexLine -> [Either LexError Statement]
splitLine (LexLine _ (Left err))  = [Left err]
splitLine (LexLine ll (Right ts)) =
  map (\seg -> Right (Statement seg ll)) (segmentOnSemi ts)

-- Partition a token list on TkSemi boundaries.
-- Always produces at least one segment; a trailing TkSemi yields a final
-- empty segment.
segmentOnSemi :: [Token] -> [[Token]]
segmentOnSemi ts = go ts []
  where
    go [] acc = [reverse acc]
    go (t:rest) acc
      | tkKind t == TkSemi = reverse acc : go rest []
      | otherwise          = go rest (t : acc)
