module PB.AST.Expr
  ( LvSegment (..)
  , Lvalue (..)
  ) where

import PB.Prelude
import PB.Lexing.Token (Token)

-- | One segment in a dotted lvalue path: the identifier name plus an optional
-- array subscript `[tokens]`.
data LvSegment = LvSegment
  { lvsName      :: Text
  , lvsSubscript :: Maybe [Token]
  } deriving (Eq, Show)

-- | A structured lvalue: a non-empty dot-separated sequence of segments.
-- Covers: simple ident, member chains, array subscripts, and combinations.
data Lvalue = Lvalue
  { lvSegments :: [LvSegment]
  } deriving (Eq, Show)
