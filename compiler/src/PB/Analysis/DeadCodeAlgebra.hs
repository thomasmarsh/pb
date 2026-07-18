{-# LANGUAGE StrictData #-}
-- | Dead-code reachability PoC over 'PB.Algebra.Closure.reachFrom' (sparse
-- worklist relaxation), mirroring 'PB.Analysis.Rules.DeadCode.deadReachRules'
-- exactly — NOT 'PB.Algebra.Closure.star''s all-pairs closure (which is
-- asymptotically wrong for this large/sparse graph with a small seed set;
-- see doc/plan/182-algebraic-analysis.md Section 11 / §12 item 6).
--
-- This module is a PROOF-OF-CONCEPT only. It is NOT wired into
-- 'PB.Pipeline.Passes.runPass67' (or any production pass) this session — the
-- Souffle 'deadReachRules' IDB step remains the hot-path source until the
-- oracle-diff + wall-clock gates below prove parity (per the de-oracle
-- discipline, §12 item 7 CORRECTION). The gate harness lives in
-- 'DeadCodeAlgebraTest' (fixtures) and 'DeadCodeCorpusBench' (real corpus).
--
-- Faithful re-statement of 'deadReachRules' as a pure Haskell closure:
--
--   * 'descendant' (transitive closure of @inherits@) is a small auxiliary
--     fixpoint — Souffle computes it the same way (its own Datalog fixpoint),
--     not via 'reachFrom'.
--   * 'override_edge' is the same 3-way join
--     (@proc(parent,method) ∧ descendant(child,parent) ∧ proc(child,method)@).
--   * 'proc_reachable' is the seeded 'reachFrom' from @entry@ over the call
--     graph + override edges — the sparse primitive 'star' was wrongly used
--     for in the taint cutover's first pass.
--   * 'proc_dead' = every 'proc' not in 'proc_reachable'.
--
-- The EDB construction ('procRows'/'entryRows'/'callsRows'/...) is already
-- Haskell (see 'PB.Analysis.Rules.DeadCode.initDeadReachEdbViews'); only the
-- IDB fixpoint is swapped here — exactly the §1 "surgical cut" the plan
-- describes.
--
-- See doc/plan/182-algebraic-analysis.md §12 item 6.
module PB.Analysis.DeadCodeAlgebra
  ( deadReachAlgebraic
  ) where

import PB.Prelude
import PB.Analysis.Rules.DeadCode
  ( entryRows, callRefRows, resolvedCallEdgeRows, callsRows
  , CallEdge (..)
  )
import PB.Analysis.Taint qualified as Taint (ResolvedCallRow)
import PB.Pipeline.DuckDb (ProcSummaryRow (..))
import PB.Algebra.Semiring (Boolean (..))
import PB.Algebra.Closure
  ( Interner (..)
  , emptyInterner
  , intern
  , unintern
  , internByVal
  , fromEdges
  , reachFrom
  , reachableSet
  )

import qualified Data.HashMap.Strict as HM
import qualified Data.List          as L
import qualified Data.Map.Strict    as Map
import qualified Data.Set           as Set
import           Data.Set           (Set)

-- | Dead-code reachability via 'reachFrom': given the same raw inputs
-- 'PB.Analysis.Rules.DeadCode.initDeadReachEdbViews' reads (procedures,
-- resolved calls, object ancestors, DW objects), return the set of
-- (object, proc) pairs Souffle's @proc_dead@ would contain — content-exact.
--
-- The confidence filter ('procRows'/'entryRows' exclude @speculative@
-- procedures) is applied exactly as 'initDeadReachEdbViews' does, so the
-- algebraic path agrees with the Souffle EDB layer it replaces.
deadReachAlgebraic
  :: [ProcSummaryRow]          -- ^ procedures (confidence-filtered by 'procRows')
  -> [Taint.ResolvedCallRow]   -- ^ resolved calls
  -> [(Text, Text)]            -- ^ inherits (child, parent)
  -> [Text]                    -- ^ DW object names
  -> Set (Text, Text)          -- ^ proc_dead
deadReachAlgebraic procs calls inherits dwObjs =
  let procPairs   = Set.fromList
        [ (psrObject p, psrProcName p)
        | p <- procs
        , psrConfidence p /= "speculative"
        ]
      entryPairs  = Set.fromList [ (o, p) | [o, p] <- entryRows procs calls dwObjs ]
      inheritsSet = Set.fromList inherits
      refs        = callRefRows calls
      edges       = resolvedCallEdgeRows calls
      callEdges   = callsRows refs procs edges
      descendant  = descendantClosure inheritsSet
      procByObj   = Map.fromListWith Set.union
        [ (o, Set.singleton p) | (o, p) <- Set.toList procPairs ]
      override    = overrideEdges procByObj descendant
      -- Reachability graph over (object, proc) nodes:
      --   * calls(caller, callee)  -> edge (caller) -> (callee)
      --   * override_edge(child, method, parent) -> edge (parent, method) -> (child, method)
      graphEdges =
        [ ((ceCallerObj e, ceCallerProc e), (ceCalleeObj e, ceCalleeProc e)) | e <- callEdges ]
        ++ [ ((parentObj, method), (childObj, method))
           | (childObj, method, parentObj) <- override ]
      -- Intern every node that appears in an edge or as an entry seed.
      nodes = Set.fromList (concatMap (\(a, b) -> [a, b]) graphEdges)
                `Set.union` entryPairs
      interner = L.foldl' (\acc t -> snd (intern t acc)) emptyInterner (Set.toList nodes)
      idOf t = HM.lookup t (internByVal interner)
      rawArcs = [ (i, j, Boolean True)
                | (a, b) <- graphEdges
                , Just i <- [idOf a]
                , Just j <- [idOf b]
                ]
      rel = fromEdges rawArcs
      seedIds = [ i | e <- Set.toList entryPairs, Just i <- [idOf e] ]
      reachRel = reachFrom rel seedIds
      reachable = Set.fromList
        [ dst
        | srcId <- seedIds
        , dstId <- Set.toList (reachableSet reachRel srcId)
        , Just dst <- [unintern dstId interner]
        ]
  in procPairs `Set.difference` reachable

-- | Transitive closure of @inherits@: @descendant(child, parent)@ holds when
-- @parent@ is an ancestor of @child@. Mirrors Souffle's two
-- 'deadReachRules' rules:
--
-- @
--   descendant(child, parent) :- inherits(child, parent).
--   descendant(child, gp) :- inherits(child, parent), descendant(parent, gp).
-- @
--
-- A small auxiliary fixpoint (the object graph is tiny); Souffle computes it
-- the same way, not via 'reachFrom'.
descendantClosure :: Set (Text, Text) -> Set (Text, Text)
descendantClosure inherits =
  let step d = d `Set.union` Set.fromList
        [ (c, gp)
        | (c, p) <- Set.toList inherits
        , (p', gp) <- Set.toList d
        , p == p'
        ]
      fixpoint d = let d' = step d in if d' == d then d else fixpoint d'
  in fixpoint inherits

-- | The derived @override_edge(child_obj, method, parent_obj)@ triple: a
-- method declared in both a parent and a child, where the child inherits
-- (transitively) from the parent. Mirrors 'deadReachRules''s rule:
--
-- @
--   override_edge(child_obj, method, parent_obj) :-
--     proc(parent_obj, method), descendant(child_obj, parent_obj), proc(child_obj, method).
-- @
--
-- In the reachability graph this becomes an edge from @(parent_obj, method)@
-- to @(child_obj, method)@ — reaching a parent's method reaches the child's
-- override.
overrideEdges
  :: Map.Map Text (Set.Set Text)  -- ^ object -> declared methods (proc names)
  -> Set (Text, Text)             -- ^ descendant (child, ancestor)
  -> [(Text, Text, Text)]         -- ^ (child_obj, method, parent_obj)
overrideEdges procByObj descendant =
  [ (childObj, method, parentObj)
  | (childObj, parentObj) <- Set.toList descendant
  , method <- Set.toList (Map.findWithDefault Set.empty parentObj procByObj)
  , Set.member method (Map.findWithDefault Set.empty childObj procByObj)
  ]
