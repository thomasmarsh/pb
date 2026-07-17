{-# LANGUAGE StrictData #-}
module PB.AST.BodyStmt
  ( BodyStmt (..)
  , AugOp (..)
  , PbCall (..)
  , ElseIf (..)
  , IfStmt (..)
  , ForStmt (..)
  , DoCondition (..)
  , DoStmt (..)
  , CaseClause (..)
  , ChooseStmt (..)
  , CatchClause (..)
  , TryStmt (..)
  ) where

import PB.Prelude
import PB.AST.Expr        (Expr, Lvalue)
import PB.AST.Ident       (Ident)
import PB.AST.Located     (Located)
import PB.AST.Type        (PbType)
import PB.Lexing.Token    (Token (..))
import GHC.Generics       (Generic)

data AugOp = AugAdd | AugSub | AugMul | AugDiv
  deriving (Eq, Show, Generic)

-- | PB CALL statement: CALL ancestorobject [`controlname] :: event
data PbCall = PbCall
  { pbcAncestor :: Text
  , pbcEvent    :: Text
  } deriving (Eq, Show, Generic)

-- | One elseif branch: condition + body.
data ElseIf = ElseIf
  { eifCond :: Expr
  , eifBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | if/elseif/else/end if
data IfStmt = IfStmt
  { ifCond    :: Expr
  , ifThen    :: [Located BodyStmt]
  , ifElseIfs :: [ElseIf]
  , ifElse    :: Maybe [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | for VAR = FROM to TO [step STEP] … next
data ForStmt = ForStmt
  { forVar  :: Lvalue
  , forFrom :: Expr
  , forTo   :: Expr
  , forStep :: Maybe Expr
  , forBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | Condition attached to a do or loop line.
data DoCondition = DoWhile Expr | DoUntil Expr
  deriving (Eq, Show, Generic)

-- | do [while/until COND] … loop [while/until COND]
data DoStmt = DoStmt
  { doCond :: Maybe DoCondition
  , doBody :: [Located BodyStmt]
  , doLoop :: Maybe DoCondition
  } deriving (Eq, Show, Generic)

-- | One branch inside a choose case block.
-- ccExpr = Nothing means "case else".
data CaseClause = CaseClause
  { ccExpr :: Maybe [Token]
  , ccBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | choose case EXPR … end choose
data ChooseStmt = ChooseStmt
  { chooseExpr    :: Expr
  , chooseClauses :: [CaseClause]
  } deriving (Eq, Show, Generic)

-- | One catch clause: catch (ExceptionType varName)
data CatchClause = CatchClause
  { catchExnType :: Text
  , catchExnVar  :: Text
  , catchBody    :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | try … catch … end try
data TryStmt = TryStmt
  { tryBody    :: [Located BodyStmt]
  , tryCatches :: [CatchClause]
  } deriving (Eq, Show, Generic)

data BodyStmt
  = BsLocalVar
      { varMods  :: [Text]        -- ["constant", "public", etc.]
      , varType  :: PbType        -- the declared type
      , varName  :: Ident         -- variable name
      , varInit  :: Maybe Expr    -- optional initializer
      }
  | BsAssign    Lvalue Expr           -- lhs = rhs
  | BsAugAssign Lvalue AugOp [Token]  -- lhs op= rhs_tokens
  | BsInc       Lvalue                -- lhs++
  | BsDec       Lvalue                -- lhs--
  | BsCall      Expr                  -- standalone call expression
  | BsPbCall    PbCall                -- CALL ancestor[`ctrl] :: event
  | BsReturn    (Maybe Expr)          -- return [expr]
  | BsIf        IfStmt
  | BsFor       ForStmt
  | BsDo        DoStmt
  | BsChoose    ChooseStmt
  | BsExit
  | BsContinue
  | BsDestroy   Lvalue
  | BsAssignExpr Expr Expr            -- complex LHS = rhs (method-call chain . property)
  | BsTry        TryStmt
  | BsThrow      Expr
  | BsRaw       Text                  -- SQL, event decls, unclassified (source text)
  deriving (Eq, Show, Generic)
