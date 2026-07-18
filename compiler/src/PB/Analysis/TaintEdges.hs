-- | The functor @F : EffTerm -> TaintEdges@: folds a compiled 'EffTerm'
-- directly into the set of intra-procedural def-use edges
-- 'PB.Analysis.TaintAlgebra' needs, replacing the same-line
-- 'PB.Analysis.Taint.DefRow'\/'PB.Analysis.Taint.UseRow' join
-- ('PB.Analysis.TaintAlgebra' formerly built via @tiUsesByTriple@\/
-- @tiDefsByLine@) with a direct read of 'EAssignWithRhs''s already-paired
-- (defVar, rhsExpr).
--
-- Unlike 'PB.Analysis.SchFootprint', this carrier closes over no external
-- context ('EAssignWithRhs' already carries everything an edge needs), so
-- 'foldTaintEdgesEff' is a bare 'PB.Compile.IR.foldFreyd' specialization —
-- 'foldFreyd''s own 'ELetRef' memo (keyed on blockId) is sufficient on its
-- own here; unlike 'PB.Analysis.SchFootprint.foldSchFootprintEff', no
-- hand-rolled force-time-memoized traversal is needed, since a cached
-- 'TaintEdges' value is already a forced 'Set.Set', not an unapplied
-- function of a context.
--
-- Arg\/return\/global-write edges are NOT covered here — they are
-- inherently cross-procedure (they need call resolution, which only
-- exists after workspace-wide linking in Phase B) and stay sourced from
-- 'PB.Analysis.Taint.InterprocEdge'. See doc/plan/182-algebraic-analysis.md
-- Section 13/14 for the scope decision.
module PB.Analysis.TaintEdges
  ( TaintEdges (..)
  , foldTaintEdgesEff
  , TaintIntraEdgeRow (..)
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.AST.Ident (identOrig, identCanon, mkIdent)
import PB.Analysis.Dataflow (walkExprIdents)
import PB.Compile.IR (Category (..), Cartesian (..), Cocartesian (..), Effectful (..), EffTerm, foldFreyd)

import qualified Data.Set as Set

-- | The constant-annotation category (Elliott's "compiling to categories"
-- static-analysis move, same move 'PB.Analysis.SchFootprint' makes): erase
-- @a@\/@b@ entirely and accumulate the set of intra-proc @(useVar, defVar)@
-- pairs a term touches. Unlike 'PB.Analysis.SchFootprint.SchFootprint',
-- this carries no context — every edge is fully determined by the
-- 'EAssignWithRhs' node that produces it.
newtype TaintEdges a b = TaintEdges { runTaintEdges :: Set.Set (Text, Text) }

instance Category TaintEdges where
  id = TaintEdges Set.empty
  TaintEdges f . TaintEdges g = TaintEdges (f <> g)

instance Cartesian TaintEdges where
  exl = TaintEdges Set.empty
  exr = TaintEdges Set.empty
  TaintEdges f &&& TaintEdges g = TaintEdges (f <> g)

instance Cocartesian TaintEdges where
  inl = TaintEdges Set.empty
  inr = TaintEdges Set.empty
  -- Static over-approximation, same as 'PB.Analysis.SchFootprint': a fold
  -- has already forgotten which branch a real execution would take, so a
  -- branch's edge set is the union of both arms', not a runtime choice.
  TaintEdges f ||| TaintEdges g = TaintEdges (f <> g)

instance Effectful TaintEdges where
  eval _      = TaintEdges Set.empty
  assign _    = TaintEdges Set.empty
  lookup _    = TaintEdges Set.empty
  suspend _ _ = TaintEdges Set.empty
  callProc _ _ = TaintEdges Set.empty
  splitValue  = TaintEdges Set.empty
  ret         = TaintEdges Set.empty
  loopK (TaintEdges f) = TaintEdges f
  -- No default exists for 'branchK' (PB.Compile.IR's Effectful class has
  -- none — a Cartesian-constrained default is unsound for 'Eff', which has
  -- no Cartesian instance; see that class's own doc comment). Both arms
  -- share the same @a c@ type here (unlike '(|||)', which forks over
  -- @Either a b@), so this unions the underlying sets directly rather than
  -- routing through '(|||)'/'splitValue'/'eval'/'(&&&)'.
  branchK _cond (TaintEdges t) (TaintEdges f) = TaintEdges (t <> f)
  -- Pairs `var` (the def) with every free identifier of the RHS, plus every
  -- free identifier of 'PB.Compile.SSA.saLhs' -- a subscripted LHS's own
  -- subscript expression (e.g. `arr[i+1] = x` also reads `i` to address the
  -- write) or a `for` loop's bounds (`for i = 1 to n` also reads `n`),
  -- neither of which is part of the def's real assigned value. The def
  -- var's own root ident always appears in `walkExprIdents lhs` too (an
  -- ordinary self-reference for a plain LHS, or 'BsFor''s own loop var for
  -- the loop-bounds case) -- harmless, since the self-guard below excludes
  -- it either way. Matches 'PB.Analysis.TaintAlgebra.taintSuccessorsIx''s
  -- existing @newVar /= var@ exclusion in its intra-proc rule.
  assignWithRhs var lhs rhs = TaintEdges $ Set.fromList
    [ (identOrig u, var)
    | u <- Set.toList (walkExprIdents rhs <> walkExprIdents lhs)
    , identCanon u /= identCanon (mkIdent var)
    ]

-- | Fold a compiled 'EffTerm' directly into its intra-proc @(useVar,
-- defVar)@ edge set. THE PRODUCTION ENTRY POINT.
foldTaintEdgesEff :: EffTerm a b -> Set.Set (Text, Text)
foldTaintEdgesEff term = runTaintEdges (foldFreyd term)

-- | One intra-proc def-use edge, fully qualified with the owning
-- procedure — attached by the caller ('PB.Pipeline.Runner.compileOne'),
-- which already knows @(object, procName)@ for the 'EffTerm' it just
-- compiled. Mirrors 'PB.Analysis.Taint.DefRow'\/'UseRow' (an
-- Analysis-owned row type, not a 'PB.Pipeline.DuckDb' write-shape type).
data TaintIntraEdgeRow = TaintIntraEdgeRow
  { tierObject   :: Text
  , tierProcName :: Text
  , tierUseVar   :: Text
  , tierDefVar   :: Text
  } deriving (Eq, Ord, Show)
