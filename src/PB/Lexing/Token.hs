module PB.Lexing.Token
  ( TokenKind (..)
  , Token (..)
  , SourceSpan (..)
  ) where

import PB.Prelude

-- | Source location for a token.
--   ssStartLine/ssEndLine are the physical line numbers from the originating
--   LogicalLine; ssCol is the 1-based column within the joined logical line text.
data SourceSpan = SourceSpan
  { ssStartLine :: Int
  , ssEndLine   :: Int
  , ssCol       :: Int
  } deriving (Eq, Show)

data TokenKind
  = TkHeaderLine
  | TkLineComment
  | TkBlockComment
  | TkStringDouble
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
  | TkContinuation
  | TkDot
  | TkDoubleColon
  | TkLParen
  | TkRParen
  | TkLBracket
  | TkRBracket
  | TkComma
  | TkSemi
  | TkColon
  | TkLabel
  | TkIdent
  deriving (Eq, Show)

data Token = Token
  { tkKind :: TokenKind
  , tkText :: Text
  , tkSpan :: SourceSpan
  } deriving (Eq, Show)
