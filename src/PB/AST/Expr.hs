module PB.AST.Expr
  ( LvSegment (..)
  , Lvalue (..)
  , Literal (..)
  , CallExpr (..)
  , CreateExpr (..)
  , BinOp (..)
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

-- | Binary operators, lowest precedence first within each group.
-- Precedence (lowest → highest):
--   1  or   xor          TkOtherKw          left
--   2  and               TkOtherKw          left
--   3  not               TkOtherKw          prefix (handled in parseAtom)
--   4  = <> < > <= >=    TkAssignOp / TkCompareOp  left
--   5  + -               TkArithOp          left
--   6  * /               TkArithOp          left
--   7  ^                 TkArithOp          right
data BinOp
  = BopAdd | BopSub | BopMul | BopDiv | BopPow   -- +  -  *  /  ^
  | BopEq  | BopNe  | BopLt  | BopGt  | BopLe | BopGe  -- =  <>  <  >  <=  >=
  | BopAnd | BopOr  | BopXor                      -- and  or  xor
  deriving (Eq, Show)

data Expr
  = ExLit     Literal    -- boolean, numeric, string, date/time, null
  | ExEnum    Text       -- PowerBuilder enum constant; name without trailing '!'
  | ExLvalue  Lvalue     -- bare variable / dotted member chain / subscript
  | ExCall    CallExpr   -- function or method call
  | ExCreate  CreateExpr -- CREATE ClassName / CREATE USING expr
  | ExArray   [Expr]     -- { e1, e2, ... } array literal
  | ExNot        Expr          -- NOT expr (unary boolean negation)
  | ExHostVar    Lvalue        -- SQL host variable: :varname or :struct.field
  | ExBinOp      Expr BinOp Expr  -- left op right
  | ExUnaryMinus Expr          -- unary - expr
  | ExRaw        [Token]       -- unrecognized or dynamic-dispatch
  deriving (Eq, Show)
