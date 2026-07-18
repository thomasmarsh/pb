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
  -- Pairs `var` (the def) with every free identifier of `e` (the uses),
  -- excluding a self-referencing use/def (`x = x + 1`) -- matches
  -- 'PB.Analysis.TaintAlgebra.taintSuccessorsIx''s existing
  -- @newVar /= var@ exclusion in its intra-proc rule.
  --
  -- KNOWN SOUNDNESS GAP (documented, NOT silently shipped — see
  -- doc/plan/182b-move2-intra.md §3): this RHS-only walk drops LHS-subscript
  -- reads. Real-corpus validation on `example/openpay-0.1.1b-extract` found
  -- the fold emits 2635 intra edges vs the old same-line join's 2841 —
  -- 338 missing, 0 extra. All 338 missing are edges whose `use_var` is a
  -- free identifier of an LHS-subscript expression (e.g.
  -- `this.Item[UpperBound(this.Item)+1] = this.m_edit_delrec` should also
  -- yield `(Item→this)` and `(UpperBound→this)`). Root cause: the subscript
  -- is erased *before SSA exists* — 'PB.Compile.SSA.stmtToAssigns' reduces a
  -- subscripted Lvalue to its root var via 'lvHead'/'assignTarget'
  -- ('PB.Compile.SSA.hs:139-141,220-221,241-242'), so 'EAssignWithRhs'
  -- carries only the RHS 'Expr', whose 'walkExprIdents' returns only
  -- 'lvRoot' ('PB.Analysis.Dataflow.hs:120'). The fold therefore cannot
  -- recover LHS-subscript reads.
  --
  -- Decision (doc/plan/182b-move2-intra.md §3.4, Option C): ship the
  -- RHS-only fold now — proven zero confirmed taint findings lost on the
  -- validation corpus (old_confirmed = new_confirmed = 18). The gap is a
  -- real soundness hole (strictly *less complete* than the row path for
  -- subscripted-LHS assignments), so it is tracked, not hidden.
  --
  -- DEFERRED Stage-1 (Option A, sibling to the deferred 'EReturn' payload
  -- change): extend 'assignWithRhs'/'EAssignWithRhs' from `(Text, Expr)` to
  -- `(Text, Expr, Expr)` (defVar, lhsExpr, rhsExpr) so this method can walk
  -- `walkExprIdents rhs <> lvalueSubscriptIdents lhs`. That is an
  -- 'Effectful'-class signature change touching all four instances
  -- ('Interp'/'NGB'/'WB'/'SchFootprint' ignore the extra arg) — scoped as
  -- its own Stage-1 proposal, NOT folded into this session.
  assignWithRhs var e = TaintEdges $ Set.fromList
    [ (identOrig u, var)
    | u <- Set.toList (walkExprIdents e)
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
