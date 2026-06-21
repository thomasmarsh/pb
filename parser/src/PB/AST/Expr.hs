module PB.AST.Expr
  ( LvSegment (..)
  , Lvalue (..)
  , BinOp (..)
  , DispatchMode (..)
  , DispatchExpr (..)
  , Expr (..)
  ) where

import PB.Prelude
import PB.Lexing.Token (Token (..))
import GHC.Generics (Generic)

-- | One segment of a dotted name, e.g. the `arr[i]` in `obj.arr[i].field`.
-- subscript holds the raw subscript expression tokens when present.
data LvSegment = LvSegment
  { name      :: Text
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
  , name    :: Text
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
  | ExMethodCall  { receiver :: Expr, method :: Text, methodArgs :: [[Token]] }
  | ExDispatch    DispatchExpr      -- inlines DispatchExpr fields into JSON
  -- Object creation
  | ExCreate      Text              -- CREATE ClassName
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
