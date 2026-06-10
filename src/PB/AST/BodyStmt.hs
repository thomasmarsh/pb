module PB.AST.BodyStmt
  ( BodyStmt (..)
  , AugOp (..)
  ) where

import PB.Prelude
import PB.AST.Expr        (Lvalue)
import PB.Lexing.Splitter (Statement)
import PB.Lexing.Token    (Token)

data AugOp = AugAdd | AugSub | AugMul | AugDiv
  deriving (Eq, Show)

data BodyStmt
  = BsLocalVar  [Token]               -- Type Name [= init …]
  | BsAssign    Lvalue [Token]        -- lhs = rhs_tokens
  | BsAugAssign [Token] AugOp [Token] -- lhs_tokens op= rhs_tokens
  | BsInc       [Token]               -- lhs_tokens ++
  | BsDec       [Token]               -- lhs_tokens --
  | BsCall      [Token]               -- standalone call expression
  | BsReturn    (Maybe [Token])       -- return [expr_tokens]
  | BsRaw       Statement             -- control flow, SQL, unclassified
  deriving (Eq, Show)
