{-# LANGUAGE StrictData #-}
module PB.Lexing.Token
  ( TokenKind (..)
  , Token (..)
  , SourceSpan (..)
  ) where

import PB.Prelude
import Control.DeepSeq (NFData)
import Data.Aeson      (ToJSON (..), object, (.=))
import GHC.Generics    (Generic)

-- | Source location for a token, resolved back to the true raw file
--   position via 'PB.Pipeline.Preprocess.resolveRawPos' -- meaningful
--   against the original source even when the token was produced by a
--   `&`-continuation or block-comment join. ssStartLine/ssStartCol and
--   ssEndLine/ssEndCol can differ (e.g. a two-word keyword split across a
--   continuation, `end &\n if`) since a join can land inside a single token.
data SourceSpan = SourceSpan
  { ssStartLine :: Int
  , ssStartCol  :: Int
  , ssEndLine   :: Int
  , ssEndCol    :: Int
  } deriving (Eq, Ord, Show, Generic)

instance NFData SourceSpan

instance ToJSON SourceSpan where
  toJSON sp = object
    [ "startLine" .= ssStartLine sp
    , "startCol"  .= ssStartCol  sp
    , "endLine"   .= ssEndLine   sp
    , "endCol"    .= ssEndCol    sp
    ]

data TokenKind
  = TkStringDouble
  | TkStringSingle
  | TkBoolTrue
  | TkBoolFalse
  | TkNull
  | TkDateLiteral
  | TkTimeLiteral
  | TkFloatLiteral
  | TkIntLiteral
  | TkEnumLiteral
  | TkDatatype
  | TkAccessModifier
  | TkStorageModifier
  | TkControlKw
  | TkDeclKw
  | TkSqlKw
  | TkOtherKw
  | TkCompareOp
  | TkAugmentOp
  | TkAssignOp
  | TkArithOp
  | TkDot
  | TkDoubleColon
  | TkLParen
  | TkRParen
  | TkLBracket
  | TkRBracket
  | TkLBrace
  | TkRBrace
  | TkComma
  | TkSemi
  | TkColon
  | TkLabel
  | TkIdent
  deriving (Eq, Ord, Show, Generic)

instance NFData TokenKind

data Token = Token
  { tkKind :: TokenKind
  , tkText :: Text
  , tkSpan :: SourceSpan
  } deriving (Eq, Ord, Show, Generic)

instance NFData Token
