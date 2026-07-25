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
  , stmtChildren
  , foldStmts
  ) where

import PB.Prelude
import PB.AST.Expr        (Expr, Lvalue)
import PB.AST.Ident       (Ident)
import PB.AST.Located     (Located (..))
import PB.AST.Type        (PbType)
import PB.Lexing.Token    (Token (..))
import Control.DeepSeq    (NFData)
import GHC.Generics       (Generic)

data AugOp = AugAdd | AugSub | AugMul | AugDiv
  deriving (Eq, Show, Generic)

-- | PB CALL statement: CALL ancestorobject [`controlname] :: event
data PbCall = PbCall
  { pbcAncestor :: Ident
  , pbcEvent    :: Ident
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
  | BsHalt      { haltClose :: Bool }  -- HALT [CLOSE]
  | BsDestroy   Lvalue
  | BsAssignExpr Expr Expr            -- complex LHS = rhs (method-call chain . property)
  | BsTry        TryStmt
  | BsThrow      Expr
  | BsRaw       Text                  -- SQL, event decls, unclassified (source text)
  deriving (Eq, Show, Generic)

-- | All direct child statement groups of a compound BodyStmt. Returns []
-- for leaf statements. This is the single authoritative place that
-- describes which constructors recurse and into which fields -- a new
-- compound constructor added here without an arm keeps returning [] from
-- the catch-all, which is a deliberate hole, not a warning.
stmtChildren :: BodyStmt -> [[Located BodyStmt]]
stmtChildren (BsIf (IfStmt _ th eis mel)) =
  th : map eifBody eis ++ maybeToList mel
stmtChildren (BsFor    (ForStmt _ _ _ _ body)) = [body]
stmtChildren (BsDo     (DoStmt _ body _))       = [body]
stmtChildren (BsChoose (ChooseStmt _ clauses)) = map ccBody clauses
stmtChildren (BsTry    (TryStmt body catches)) = body : map catchBody catches
stmtChildren _                                  = []

-- | Monoidal pre-order fold over every node in a statement tree. Applies f
-- to each Located BodyStmt and recurses into compound forms via
-- 'stmtChildren' -- callers cannot forget to recurse, since the recursion
-- lives in this combinator rather than in each analysis.
foldStmts :: Monoid m => (Located BodyStmt -> m) -> [Located BodyStmt] -> m
foldStmts f = foldMap go
  where go ls@(Located _ s) = f ls <> foldStmts f (concat (stmtChildren s))

instance NFData AugOp
instance NFData PbCall
instance NFData ElseIf
instance NFData IfStmt
instance NFData ForStmt
instance NFData DoCondition
instance NFData DoStmt
instance NFData CaseClause
instance NFData ChooseStmt
instance NFData CatchClause
instance NFData TryStmt
instance NFData BodyStmt
