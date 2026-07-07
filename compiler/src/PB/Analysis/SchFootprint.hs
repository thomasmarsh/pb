-- | Plan 148 Phase 3 (infra slice): the functor @F : CatOp -> Sch_|_@,
-- implemented as another instance of 'PB.Analysis.CatOp's
-- 'Category'\/'Cartesian'\/'Cocartesian'\/'Effectful' classes rather than a
-- hand-written match over the GADT (see
-- doc\/plan\/148-db-schema-category.md's "(a) Categorical structure" design
-- amendment). 'PB.Analysis.CatOp.foldCat' folds any compiled 'CatOp' term
-- into this instance for free.
--
-- This module lands the category skeleton only: every 'Effectful' method
-- is a constant empty footprint, so 'foldSchFootprint' always returns the
-- empty set this session. Wiring up real morphism detection (e.g.
-- recognizing a DataWindow @SetItem@ call, or an @ExHostVar@ naming a SQL
-- host variable) is deferred to a follow-up session pending the
-- DW-control -> DW-object binding extraction this session's Stage 0 found
-- missing (see the plan file's Phase 3 section).
module PB.Analysis.SchFootprint
  ( FunctorCtx (..)
  , SchFootprint (..)
  , foldSchFootprint
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.Analysis.CatOp (Category (..), Cartesian (..), Cocartesian (..), Effectful (..), CatOp, foldCat)
import PB.Analysis.SchemaCategory (SchMorphism, StmtId)
import PB.Analysis.TypeEnv (ScopedTypeEnv)
import PB.Pipeline.SqlParse (TableRef)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | Context 'SchFootprint' closes over. 'CatOp' terms carry no source
-- line\/statement identity of their own, so any edge this functor derives
-- is necessarily anchored at procedure granularity ('fcStmtObj'), coarser
-- than Phase 1b's per-line 'StmtId's. 'fcDwColumns' (DW object name ->
-- its known @(table, column)@ targets) is deliberately left for callers to
-- populate once the DW-control -> DW-object binding extraction lands — an
-- empty 'Map.Map' is a legal, total input.
data FunctorCtx = FunctorCtx
  { fcStmtObj   :: StmtId
  , fcTypeEnv   :: ScopedTypeEnv
  , fcDwColumns :: Map.Map Text [(TableRef, Text)]
  }

-- | The constant-annotation category (Elliott's "compiling to categories"
-- static-analysis move): erase the object-language types @a@\/@b@ entirely
-- and just accumulate the set of 'SchMorphism's a term touches, as a
-- function of 'FunctorCtx'. 'id' is the empty footprint; composition,
-- '(&&&)', and '(|||)' are all pointwise union — the 'Category' laws hold
-- by construction since set union is an associative monoid with 'mempty'
-- as identity.
newtype SchFootprint a b = SchFootprint { runSchFootprint :: FunctorCtx -> Set.Set SchMorphism }

instance Category SchFootprint where
  id = SchFootprint (const Set.empty)
  SchFootprint f . SchFootprint g = SchFootprint (\ctx -> f ctx <> g ctx)

instance Cartesian SchFootprint where
  exl = SchFootprint (const Set.empty)
  exr = SchFootprint (const Set.empty)
  SchFootprint f &&& SchFootprint g = SchFootprint (\ctx -> f ctx <> g ctx)

instance Cocartesian SchFootprint where
  inl = SchFootprint (const Set.empty)
  inr = SchFootprint (const Set.empty)
  -- Static over-approximation: a fold has already forgotten which branch a
  -- real execution would take, so the footprint of a branch is the union of
  -- both arms' footprints, not a runtime choice between them.
  SchFootprint f ||| SchFootprint g = SchFootprint (\ctx -> f ctx <> g ctx)

-- | Every method is a constant empty footprint this session (Plan 148
-- Phase 3 infra slice) — 'suspend'\/'callProc' are where real
-- DW-write\/host-var detection will attach once the DW-control ->
-- DW-object binding gap closes. 'loopK' still propagates the loop body's
-- own footprint (not a constant empty one) since a static,
-- iteration-count-oblivious analysis must count whatever the body touches
-- regardless of how many times it would actually run.
instance Effectful SchFootprint where
  eval _       = SchFootprint (const Set.empty)
  assign _     = SchFootprint (const Set.empty)
  lookup _     = SchFootprint (const Set.empty)
  suspend _ _  = SchFootprint (const Set.empty)
  callProc _ _ = SchFootprint (const Set.empty)
  splitValue   = SchFootprint (const Set.empty)
  ret          = SchFootprint (const Set.empty)
  loopK (SchFootprint f) = SchFootprint f

-- | Run a compiled 'CatOp' term through the 'SchFootprint' functor.
foldSchFootprint :: FunctorCtx -> CatOp a b -> Set.Set SchMorphism
foldSchFootprint ctx op = runSchFootprint (foldCat op) ctx
