module SmallCheckInstances
  ( StructuredExpr (..)
  , StructuredLeafBodyStmt (..)
  ) where

import PB.Prelude

import Data.Foldable   (asum)
import PB.AST.BodyStmt (AugOp (..), BodyStmt (..), PbCall (..))
import PB.AST.Expr     (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident    (mkIdent)
import PB.Lexing.Token (SourceSpan (..), Token (..), TokenKind (..))

import Test.SmallCheck.Series (Serial (..), cons0, cons1, (\/))

-- | Wraps the structured (non-'ExRaw') subset of 'Expr' for exhaustive
-- SmallCheck enumeration. A newtype avoids an orphan instance on 'Expr'
-- itself, and excludes 'ExRaw' (whose @[Text]@ field would make the space
-- unbounded).
newtype StructuredExpr = SE { unSE :: Expr } deriving Show

instance Monad m => Serial m StructuredExpr where
  series = leaves \/ cons1 wrapArray \/ cons1 wrapNot
    where
      leaves = asum (map (cons0 . SE) leafExprs)
      wrapArray (SE e) = SE (ExArray [e])
      wrapNot   (SE e) = SE (ExNot e)

leafExprs :: [Expr]
leafExprs =
  [ ExBool True
  , ExBool False
  , ExNull
  , ExInt "0"
  , ExReal "0.0"
  , ExStr ""
  , ExEnum "Black"
  , ExLvalue simpleLvalue
  , ExCall simpleLvalue []
  , ExCreate (mkIdent "n")
  , ExArray []
  ]

simpleLvalue :: Lvalue
simpleLvalue = Lvalue [LvSegment (mkIdent "x") Nothing]

-- | Wraps the leaf (non-recursive) subset of 'BodyStmt' for exhaustive
-- SmallCheck enumeration. Excludes 'BsRaw' (unbounded raw text),
-- 'BsLocalVar' (declaration shape, not a bare reparseable statement), and
-- every control-flow constructor carrying a nested body -- 'BsIf',
-- 'BsFor', 'BsDo', 'BsChoose', 'BsTry' -- which 'BodyStmtTest' already
-- covers via its own Hedgehog control-flow generator.
newtype StructuredLeafBodyStmt = SLB { unSLB :: BodyStmt } deriving Show

instance Monad m => Serial m StructuredLeafBodyStmt where
  series = asum (map (cons0 . SLB) leafBodyStmts)

leafBodyStmts :: [BodyStmt]
leafBodyStmts =
  [ BsAssign     simpleLvalue simpleExpr
  , BsAugAssign  simpleLvalue AugAdd [augToken]
  , BsInc        simpleLvalue
  , BsDec        simpleLvalue
  , BsCall       simpleExpr
  , BsPbCall     (PbCall "super" "open")
  , BsReturn     Nothing
  , BsReturn     (Just simpleExpr)
  , BsExit
  , BsContinue
  , BsDestroy    simpleLvalue
  , BsThrow      simpleExpr
  , BsAssignExpr complexLhsExpr simpleExpr
  ]
  where
    simpleExpr     = ExInt "0"
    augToken       = Token TkIntLiteral "1" (SourceSpan 0 0 0)
    complexLhsExpr =
      ExMethodCall (ExCall (Lvalue [LvSegment (mkIdent "obj") Nothing]) [])
                   (mkIdent "m") []
