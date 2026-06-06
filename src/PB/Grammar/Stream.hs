{-# LANGUAGE TypeFamilies #-}
module PB.Grammar.Stream
  ( StmtStream (..)
  , FileParser
  , satisfyStmt
  , leadingKind
  , leadingText
  ) where

import PB.Prelude
import PB.Lexing.Splitter     (Statement (..))
import PB.Lexing.Token        (TokenKind, tkKind, tkText)
import PB.Pipeline.Preprocess (LogicalLine (..), llText, llStartLine)

import Data.List.NonEmpty (toList)
import qualified Data.Set  as Set
import qualified Data.Text as T

import Text.Megaparsec
  ( Parsec, Stream (..), VisualStream (..), TraversableStream (..)
  , PosState (..), SourcePos (..), token
  )
import Text.Megaparsec.Pos (mkPos, unPos)

newtype StmtStream = StmtStream [Statement]
  deriving (Show)

instance Stream StmtStream where
  type Token  StmtStream = Statement
  type Tokens StmtStream = [Statement]
  tokenToChunk  _ s  = [s]
  tokensToChunk _ ss = ss
  chunkToTokens _ ss = ss
  chunkLength   _ ss = length ss
  chunkEmpty    _    = null
  take1_ (StmtStream [])     = Nothing
  take1_ (StmtStream (s:ss)) = Just (s, StmtStream ss)
  takeN_ n (StmtStream ss)
    | n <= 0    = Just ([], StmtStream ss)
    | null ss   = Nothing
    | otherwise = let (h, t) = splitAt n ss in Just (h, StmtStream t)
  takeWhile_ f (StmtStream ss) =
    let (h, t) = span f ss in (h, StmtStream t)

instance VisualStream StmtStream where
  showTokens _ stmts =
    T.unpack $ T.intercalate " | " $
      map (llText . stmtSource) (toList stmts)

instance TraversableStream StmtStream where
  reachOffset o pst =
    let StmtStream ss = pstateInput pst
        n             = o - pstateOffset pst
        remaining     = drop n ss
        lineNo        = case remaining of
          (s:_) -> llStartLine (stmtSource s)
          []    -> unPos (sourceLine (pstateSourcePos pst))
        sp            = pstateSourcePos pst
        newSp         = sp { sourceLine = mkPos lineNo }
        linePreview   = fmap (T.unpack . llText . stmtSource) (listToMaybe remaining)
    in ( linePreview
       , pst { pstateInput     = StmtStream remaining
             , pstateOffset    = o
             , pstateSourcePos = newSp
             }
       )

type FileParser = Parsec Void StmtStream

satisfyStmt :: (Statement -> Bool) -> FileParser Statement
satisfyStmt f = token (\s -> if f s then Just s else Nothing) Set.empty

leadingKind :: TokenKind -> FileParser Statement
leadingKind k = satisfyStmt matchesKind
  where
    matchesKind s = case stmtTokens s of
      (t:_) -> tkKind t == k
      []    -> False

leadingText :: Text -> FileParser Statement
leadingText txt = satisfyStmt matchesText
  where
    matchesText s = case stmtTokens s of
      (t:_) -> T.toLower (tkText t) == txt
      []    -> False
