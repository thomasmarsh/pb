module PB.AST.BodyStmt
  ( BodyStmt (..)
  , AugOp (..)
  ) where

import PB.Prelude
import PB.Lexing.Splitter (Statement)
import PB.Lexing.Token    (Token)

data AugOp = AugAdd | AugSub | AugMul | AugDiv
  deriving (Eq, Show)

-- | A classified body statement.  Expression content is kept as raw token
-- lists until a future session adds Lvalue / Expr parsers.
data BodyStmt
  = BsLocalVar  [Token]                -- Type Name [= init …]
  | BsAssign    [Token] [Token]        -- lhs_tokens = rhs_tokens
  | BsAugAssign [Token] AugOp [Token]  -- lhs_tokens op= rhs_tokens
  | BsInc       [Token]                -- lhs_tokens ++
  | BsDec       [Token]                -- lhs_tokens --
  | BsCall      [Token]                -- standalone call expression
  | BsReturn    (Maybe [Token])        -- return [expr_tokens]
  | BsRaw       Statement              -- control flow, SQL, unclassified
  deriving (Eq, Show)
