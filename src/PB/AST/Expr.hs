module PB.AST.Expr
  ( LvSegment (..)
  , Lvalue (..)
  , Literal (..)
  , CallExpr (..)
  , CreateExpr (..)
  , Expr (..)
  ) where

import PB.Prelude
import PB.Lexing.Token (Token)

data LvSegment = LvSegment
  { lvsName      :: Text
  , lvsSubscript :: Maybe [Token]
  } deriving (Eq, Show)

data Lvalue = Lvalue
  { lvSegments :: [LvSegment]
  } deriving (Eq, Show)

data Literal
  = LitBool Bool
  | LitInt  Text
  | LitReal Text
  | LitStr  Text
  | LitDate Text
  | LitTime Text
  | LitNull
  deriving (Eq, Show)

-- | A function or method call expression.
-- ceCallee is the dotted name chain before '('; ceArgs splits the argument
-- list on commas at paren depth 0, keeping each argument as raw tokens.
data CallExpr = CallExpr
  { ceCallee :: Lvalue
  , ceArgs   :: [[Token]]
  } deriving (Eq, Show)

-- | The object type argument to a CREATE expression.
data CreateExpr
  = CreateClass Text   -- CREATE ClassName  (static)
  | CreateUsing Expr   -- CREATE USING expr (dynamic)
  deriving (Eq, Show)

data Expr
  = ExLit    Literal    -- boolean, numeric, string, date/time, null
  | ExEnum   Text       -- PowerBuilder enum constant; name without trailing '!'
  | ExLvalue Lvalue     -- bare variable / dotted member chain / subscript
  | ExCall   CallExpr   -- function or method call
  | ExCreate CreateExpr -- CREATE ClassName / CREATE USING expr
  | ExArray  [Expr]     -- { e1, e2, ... } array literal
  | ExNot    Expr       -- NOT expr (unary boolean negation)
  | ExRaw    [Token]    -- binary ops, chained calls, or anything unrecognized
  deriving (Eq, Show)
