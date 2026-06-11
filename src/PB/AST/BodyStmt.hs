module PB.AST.BodyStmt
  ( BodyStmt (..)
  , AugOp (..)
  , PbCall (..)
  , IfStmt (..)
  , ForStmt (..)
  , DoCondition (..)
  , DoStmt (..)
  , CaseClause (..)
  , ChooseStmt (..)
  ) where

import PB.Prelude
import PB.AST.Expr        (Expr, Lvalue)
import PB.Lexing.Splitter (Statement)
import PB.Lexing.Token    (Token)

data AugOp = AugAdd | AugSub | AugMul | AugDiv
  deriving (Eq, Show)

-- | PB CALL statement: CALL ancestorobject [`controlname] :: event
data PbCall = PbCall
  { pbcAncestor :: Text   -- "super", "parent", or named ancestor (backtick form is one ident)
  , pbcEvent    :: Text   -- event name
  } deriving (Eq, Show)

-- | if/elseif/else/end if — covers both inline and multi-line forms.
-- Inline: ifThen is a singleton derived from the tokens after "then";
--         ifElseIfs is []; ifElse is Nothing or a singleton.
-- Multi-line: ifThen / elseif chains / else are full [BodyStmt] bodies.
data IfStmt = IfStmt
  { ifCond    :: Expr
  , ifThen    :: [BodyStmt]
  , ifElseIfs :: [(Expr, [BodyStmt])]
  , ifElse    :: Maybe [BodyStmt]
  } deriving (Eq, Show)

-- | for VAR = FROM to TO [step STEP] … next
data ForStmt = ForStmt
  { forVar  :: Lvalue
  , forFrom :: Expr
  , forTo   :: Expr
  , forStep :: Maybe Expr
  , forBody :: [BodyStmt]
  } deriving (Eq, Show)

-- | Condition attached to a do or loop line.
data DoCondition = DoWhile Expr | DoUntil Expr
  deriving (Eq, Show)

-- | do [while/until COND] … loop [while/until COND]
data DoStmt = DoStmt
  { doCond :: Maybe DoCondition   -- condition on `do` line
  , doBody :: [BodyStmt]
  , doLoop :: Maybe DoCondition   -- condition on `loop` line
  } deriving (Eq, Show)

-- | One branch inside a choose case block.
-- ccExpr = Nothing means "case else".
data CaseClause = CaseClause
  { ccExpr :: Maybe [Token]
  , ccBody :: [BodyStmt]
  } deriving (Eq, Show)

-- | choose case EXPR … end choose
data ChooseStmt = ChooseStmt
  { chooseExpr    :: Expr
  , chooseClauses :: [CaseClause]
  } deriving (Eq, Show)

data BodyStmt
  = BsLocalVar  [Token]               -- Type Name [= init …]
  | BsAssign    Lvalue Expr           -- lhs = rhs
  | BsAugAssign [Token] AugOp [Token] -- lhs_tokens op= rhs_tokens
  | BsInc       [Token]               -- lhs_tokens ++
  | BsDec       [Token]               -- lhs_tokens --
  | BsCall      Expr                  -- standalone call expression
  | BsPbCall    PbCall                -- CALL ancestor[`ctrl] :: event
  | BsReturn    (Maybe Expr)          -- return [expr]
  | BsIf        IfStmt                -- if/elseif/else/end if
  | BsFor       ForStmt               -- for … next
  | BsDo        DoStmt                -- do … loop
  | BsChoose    ChooseStmt            -- choose case … end choose
  | BsExit                            -- exit
  | BsContinue                        -- continue
  | BsDestroy   Lvalue                -- DESTROY objectvariable
  | BsAssignExpr Expr Expr            -- complex LHS = rhs (method-call chain . property)
  | BsRaw       Statement             -- SQL, event decls, unclassified
  deriving (Eq, Show)
