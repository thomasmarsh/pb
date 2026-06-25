{-# LANGUAGE StrictData #-}
-- | Spike 123: Church-encoded BodyStmt base functor and catamorphism combinators.
--
-- This module is a design spike — not wired into the production pipeline.
-- It demonstrates that:
--   1. GHC can derive Functor for BodyStmtF automatically.
--   2. Pass-5 extractions (local vars, call sites) can be expressed as algebras.
--   3. A product algebra fuses both passes into a single tree traversal.
--
-- Public API:
--   BodyStmtF(..)         -- base functor (Eq, Show, Functor derived)
--   Fix(..)               -- standard fixed-point newtype
--   LocBodyStmtF(..)      -- line-annotated wrapper functor
--   BodyStmtTree          -- Fix LocBodyStmtF (one located statement tree)
--   cata                  -- standard catamorphism over Fix f
--   cataL                 -- catamorphism for BodyStmtTree, exposes line number
--   productAlgebra        -- fuse two cataL algebras into one traversal
--   ProcCtx               -- (file, object, proc_name) context tuple
--   toFix / fromFix       -- convert Located BodyStmt <-> BodyStmtTree
--   extractLocalVarsAlg   -- pass-5 local-var extraction as a cataL algebra
--   extractCallSitesAlg   -- pass-5 call-site extraction as a cataL algebra
--   fusedExtract          -- product of the two algebras over one BodyStmtTree
--   fusedExtractList      -- fusedExtract over [Located BodyStmt]
module PB.Pipeline.Church
  ( BodyStmtF (..)
  , Fix (..)
  , LocBodyStmtF (..)
  , BodyStmtTree
  , cata
  , cataL
  , productAlgebra
  , ProcCtx
  , toFix
  , fromFix
  , extractLocalVarsAlg
  , extractCallSitesAlg
  , fusedExtract
  , fusedExtractList
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr     (Expr (..), Lvalue)
import PB.AST.Located  (Located (..))
import PB.AST.Type     (PbType, renderPbType)
import PB.Lexing.Token (Token)
import PB.Analysis.TypeResolve (CallSite (..), LocalVar (..), callSitesExpr)

-- ---------------------------------------------------------------------------
-- Base functor

-- | BodyStmt with recursive positions replaced by @r@.
-- Non-recursive constructors are copied verbatim; recursive constructors
-- inline the formerly-named sub-record types to avoid embedding
-- [Located BodyStmt] directly (which would block deriving Functor).
data BodyStmtF r
  -- leaf statements (no r positions)
  = BsLocalVarF [Text] PbType Text (Maybe Expr)   -- mods type name init
  | BsAssignF    Lvalue Expr
  | BsAugAssignF [Token] AugOp [Token]
  | BsIncF       [Token]
  | BsDecF       [Token]
  | BsCallF      Expr
  | BsPbCallF    PbCall
  | BsReturnF    (Maybe Expr)
  | BsExitF
  | BsContinueF
  | BsDestroyF   Lvalue
  | BsAssignExprF Expr Expr
  | BsRawF        Text
  -- compound statements: r = result from one child Located BodyStmt
  | BsIfF     Expr [r] [(Expr, [r])] (Maybe [r])          -- cond then elseifs else
  | BsForF    Lvalue Expr Expr (Maybe Expr) [r]            -- var from to step body
  | BsDoF     (Maybe DoCondition) [r] (Maybe DoCondition)  -- precond body postcond
  | BsChooseF Expr [(Maybe [Token], [r])]                  -- expr clauses
  | BsTryF    [r] [(Text, Text, [r])]                      -- body catches(exnType,exnVar,catchBody)
  | BsThrowF  Expr
  deriving (Eq, Show, Functor)

-- ---------------------------------------------------------------------------
-- Fixed-point and line-annotated wrapper

newtype Fix f = Fix { unFix :: f (Fix f) }

-- | Bundles a line number with a BodyStmtF node at each level of the tree.
data LocBodyStmtF r = LocBodyStmtF Int (BodyStmtF r)
  deriving (Eq, Show, Functor)

-- | A single located BodyStmt encoded as a fixed-point tree.
type BodyStmtTree = Fix LocBodyStmtF

-- ---------------------------------------------------------------------------
-- Catamorphisms

-- | Standard bottom-up fold over a fixed-point tree.
cata :: Functor f => (f a -> a) -> Fix f -> a
cata alg = alg . fmap (cata alg) . unFix

-- | Catamorphism for BodyStmtTree, exposing the line annotation to the algebra.
cataL :: (Int -> BodyStmtF a -> a) -> BodyStmtTree -> a
cataL alg (Fix (LocBodyStmtF line node)) = alg line (fmap (cataL alg) node)

-- | Fuse two cataL algebras into one, running both in a single tree traversal.
-- GHC -O2 can often fuse the pair projections into a tight loop.
productAlgebra
  :: (Int -> BodyStmtF a -> a)
  -> (Int -> BodyStmtF b -> b)
  -> (Int -> BodyStmtF (a, b) -> (a, b))
productAlgebra alg1 alg2 line node =
  ( alg1 line (fmap fst node)
  , alg2 line (fmap snd node)
  )

-- ---------------------------------------------------------------------------
-- Conversion: Located BodyStmt <-> BodyStmtTree

toFix :: Located BodyStmt -> BodyStmtTree
toFix (Located line stmt) = Fix (LocBodyStmtF line (stmtToF stmt))

fromFix :: BodyStmtTree -> Located BodyStmt
fromFix (Fix (LocBodyStmtF line node)) = Located line (fToStmt node)

stmtToF :: BodyStmt -> BodyStmtF BodyStmtTree
stmtToF (BsLocalVar ms ty nm ini) = BsLocalVarF ms ty nm ini
stmtToF (BsAssign lv e)           = BsAssignF lv e
stmtToF (BsAugAssign ls op rs)    = BsAugAssignF ls op rs
stmtToF (BsInc ts)                = BsIncF ts
stmtToF (BsDec ts)                = BsDecF ts
stmtToF (BsCall e)                = BsCallF e
stmtToF (BsPbCall pc)             = BsPbCallF pc
stmtToF (BsReturn me)             = BsReturnF me
stmtToF BsExit                    = BsExitF
stmtToF BsContinue                = BsContinueF
stmtToF (BsDestroy lv)            = BsDestroyF lv
stmtToF (BsAssignExpr l r)        = BsAssignExprF l r
stmtToF (BsRaw t)                 = BsRawF t
stmtToF (BsIf (IfStmt cond th eis el)) =
  BsIfF cond
    (map toFix th)
    (map (\(ElseIf c b) -> (c, map toFix b)) eis)
    (fmap (map toFix) el)
stmtToF (BsFor (ForStmt var fr to_ step body)) =
  BsForF var fr to_ step (map toFix body)
stmtToF (BsDo (DoStmt pre body post)) =
  BsDoF pre (map toFix body) post
stmtToF (BsChoose (ChooseStmt expr clauses)) =
  BsChooseF expr (map (\(CaseClause ce cb) -> (ce, map toFix cb)) clauses)
stmtToF (BsTry (TryStmt body catches)) =
  BsTryF (map toFix body) (map (\(CatchClause et ev cb) -> (et, ev, map toFix cb)) catches)
stmtToF (BsThrow e) = BsThrowF e

fToStmt :: BodyStmtF BodyStmtTree -> BodyStmt
fToStmt (BsLocalVarF ms ty nm ini) =
  BsLocalVar { varMods = ms, varType = ty, varName = nm, varInit = ini }
fToStmt (BsAssignF lv e)          = BsAssign lv e
fToStmt (BsAugAssignF ls op rs)   = BsAugAssign ls op rs
fToStmt (BsIncF ts)               = BsInc ts
fToStmt (BsDecF ts)               = BsDec ts
fToStmt (BsCallF e)               = BsCall e
fToStmt (BsPbCallF pc)            = BsPbCall pc
fToStmt (BsReturnF me)            = BsReturn me
fToStmt BsExitF                   = BsExit
fToStmt BsContinueF               = BsContinue
fToStmt (BsDestroyF lv)           = BsDestroy lv
fToStmt (BsAssignExprF l r)       = BsAssignExpr l r
fToStmt (BsRawF t)                = BsRaw t
fToStmt (BsIfF cond th eis el) =
  BsIf $ IfStmt cond
    (map fromFix th)
    (map (\(c, b) -> ElseIf c (map fromFix b)) eis)
    (fmap (map fromFix) el)
fToStmt (BsForF var fr to_ step body) =
  BsFor $ ForStmt var fr to_ step (map fromFix body)
fToStmt (BsDoF pre body post) =
  BsDo $ DoStmt pre (map fromFix body) post
fToStmt (BsChooseF expr clauses) =
  BsChoose $ ChooseStmt expr (map (\(ce, cb) -> CaseClause ce (map fromFix cb)) clauses)
fToStmt (BsTryF body catches) =
  BsTry $ TryStmt (map fromFix body) (map (\(et, ev, cb) -> CatchClause et ev (map fromFix cb)) catches)
fToStmt (BsThrowF e) = BsThrow e

-- ---------------------------------------------------------------------------
-- Algebras: pass-5 TypeResolve extractions as cataL algebras

-- | (file, object, proc_name)
type ProcCtx = (Text, Text, Text)

-- | Algebra that extracts local variable declarations.
-- Mirrors walkStmtLocalVars in PB.Analysis.TypeResolve.
-- In recursive positions, r = [LocalVar] holds already-folded child results —
-- compound constructors only need to concat, never recurse explicitly.
extractLocalVarsAlg :: ProcCtx -> Int -> BodyStmtF [LocalVar] -> [LocalVar]
extractLocalVarsAlg (file, obj, proc_) line node = case node of
  BsLocalVarF _ ty nm _ ->
    [ LocalVar { lvFile = file, lvObject = obj, lvProcName = proc_
               , lvVarName = nm, lvRawType = renderPbType ty
               , lvIsParam = False, lvScopeLine = line, lvPbType = ty } ]
  BsIfF _ th eis el ->
    concat th
    <> concatMap (\(_, b) -> concat b) eis
    <> maybe [] concat el
  BsForF _ _ _ _ body -> concat body
  BsDoF _ body _      -> concat body
  BsChooseF _ clauses -> concatMap (\(_, b) -> concat b) clauses
  _                   -> []

-- | Algebra that extracts call sites from expressions within statements.
-- Mirrors walkStmtCallSites in PB.Analysis.TypeResolve.
extractCallSitesAlg :: ProcCtx -> Int -> BodyStmtF [CallSite] -> [CallSite]
extractCallSitesAlg (file, obj, proc_) line node = case node of
  BsCallF e              -> cs e
  BsAssignF _ rhs        -> cs rhs
  BsAssignExprF l rhs    -> cs l <> cs rhs
  BsReturnF (Just e)     -> cs e
  BsLocalVarF _ _ _ (Just e) -> cs e
  BsIfF cond th eis el ->
    cs cond
    <> concat th
    <> concatMap (\(c, b) -> cs c <> concat b) eis
    <> maybe [] concat el
  BsForF _ fr to_ step body ->
    cs fr <> cs to_ <> maybe [] cs step <> concat body
  BsDoF mPre body mPost ->
    foldMap condCs mPre <> concat body <> foldMap condCs mPost
  BsChooseF expr clauses ->
    cs expr <> concatMap (\(_, b) -> concat b) clauses
  _ -> []
  where
    cs          = callSitesExpr file obj proc_ (Just line)
    condCs (DoWhile e) = cs e
    condCs (DoUntil e) = cs e

-- ---------------------------------------------------------------------------
-- Fused single-pass extraction

-- | Product of extractLocalVarsAlg and extractCallSitesAlg over one statement tree.
fusedExtract :: ProcCtx -> BodyStmtTree -> ([LocalVar], [CallSite])
fusedExtract ctx =
  cataL (productAlgebra (extractLocalVarsAlg ctx) (extractCallSitesAlg ctx))

-- | fusedExtract over a full procedure body (list of located statements).
fusedExtractList :: ProcCtx -> [Located BodyStmt] -> ([LocalVar], [CallSite])
fusedExtractList ctx stmts =
  let results = map (fusedExtract ctx . toFix) stmts
  in (concatMap fst results, concatMap snd results)
