{-# LANGUAGE StrictData #-}
module PB.AST.Expr
  ( LvSegment (..)
  , Lvalue (..)
  , BinOp (..)
  , DispatchMode (..)
  , DispatchExpr (..)
  , Expr (..)
  , exprChildren
  , foldExprs
  ) where

import PB.Prelude
import PB.AST.Ident (Ident)
import PB.Lexing.Token (Token (..))
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

-- | One segment of a dotted name, e.g. the `arr[i]` in `obj.arr[i].field`.
-- subscript holds the raw subscript expression tokens when present. name's
-- derived Eq compares only Ident's canonical form, so two LvSegments
-- differing only in case are equal (PB identifiers are case-insensitive).
data LvSegment = LvSegment
  { name      :: Ident
  , subscript :: Maybe [Text]
  } deriving (Eq, Show, Generic)

newtype Lvalue = Lvalue
  { segments :: [LvSegment]
  } deriving (Eq, Show, Generic)

data BinOp
  = BopAdd | BopSub | BopMul | BopDiv | BopPow
  | BopEq  | BopNe  | BopLt  | BopGt  | BopLe | BopGe
  | BopAnd | BopOr  | BopXor
  deriving (Eq, Show, Generic)

data DispatchMode = DmPost | DmTrigger | DmSync
  deriving (Eq, Show, Generic)

data DispatchExpr = DispatchExpr
  { object  :: Maybe Lvalue
  , mode    :: DispatchMode
  , dynamic :: Bool
  , event   :: Bool
  , name    :: Ident
  , args    :: [[Token]]
  } deriving (Eq, Show, Generic)

-- | Expression AST.
--
-- Single-argument constructors use positional syntax; Aeson serialises them
-- as @{"tag":"…","contents":…}@.  Multi-argument constructors use record
-- syntax with unique field names.  Token lists are stored as Text at
-- parse time.
data Expr
  -- Literals (positional → "contents" in JSON)
  = ExBool        Bool
  | ExInt         Text
  | ExReal        Text
  | ExStr         Text
  | ExDate        Text
  | ExTime        Text
  | ExNull
  -- Identifiers
  | ExEnum        Text              -- enum constant (without trailing '!')
  | ExLvalue      Lvalue            -- inlines Lvalue.segments into JSON
  -- Calls (record constructors with unique field names)
  | ExCall        { callee :: Lvalue,  callArgs :: [[Token]] }
  | ExMethodCall  { receiver :: Expr, method :: Ident, methodArgs :: [[Token]] }
  | ExDispatch    DispatchExpr      -- inlines DispatchExpr fields into JSON
  -- Object creation
  | ExCreate      Ident             -- CREATE ClassName
  | ExCreateUsing Expr              -- CREATE USING expr
  -- Compound
  | ExArray       [Expr]
  | ExBinOp       { lhs :: Expr, op :: BinOp, rhs :: Expr }
  | ExNot         Expr
  | ExNeg         Expr              -- unary minus
  -- Special
  | ExHostVar     Lvalue            -- SQL host variable :varname
  | ExRaw         [Text]            -- unrecognised / SQL fragment tokens
  deriving (Eq, Show, Generic)

-- | Direct child expressions of a compound Expr. Note: callArgs/methodArgs/
-- dispatchArgs are [[Token]], not [Expr], so ExCall/ExDispatch have no Expr
-- children here -- recovering typed Expr nodes from those token lists is
-- 'PB.Grammar.Body.parseExpr''s job, not this traversal's.
exprChildren :: Expr -> [Expr]
exprChildren (ExBinOp l _ r)      = [l, r]
exprChildren (ExNot e)            = [e]
exprChildren (ExNeg e)            = [e]
exprChildren (ExMethodCall r _ _) = [r]
exprChildren (ExCreateUsing e)    = [e]
exprChildren (ExArray es)         = es
exprChildren _                    = []

-- | Monoidal pre-order fold over every Expr node in an expression tree.
foldExprs :: Monoid m => (Expr -> m) -> Expr -> m
foldExprs f e = f e <> foldMap (foldExprs f) (exprChildren e)

instance NFData LvSegment
instance NFData Lvalue
instance NFData BinOp
instance NFData DispatchMode
instance NFData DispatchExpr
instance NFData Expr
