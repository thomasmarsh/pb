{-# LANGUAGE StrictData #-}
module PB.Lexing.Token
  ( TokenKind (..)
  , Token (..)
  , SourceSpan (..)
  ) where

import PB.Prelude
import Control.DeepSeq (NFData)
import GHC.Generics    (Generic)

-- | Source location for a token.
--   ssStartLine/ssEndLine are the physical line numbers from the originating
--   LogicalLine; ssCol is the 1-based column within the joined logical line text.
data SourceSpan = SourceSpan
  { ssStartLine :: Int
  , ssEndLine   :: Int
  , ssCol       :: Int
  } deriving (Eq, Ord, Show, Generic)

instance NFData SourceSpan

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
