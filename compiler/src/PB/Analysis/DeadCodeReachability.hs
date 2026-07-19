{-# LANGUAGE StrictData #-}
-- | Dead-code reachability via 'PB.Algebra.Closure.reachFrom' (sparse
-- worklist relaxation) — production's sole source for @proc_dead@.
--
-- This is deliberately NOT 'PB.Algebra.Closure.star''s all-pairs closure:
-- for this large/sparse call graph with a small entry-point seed set, the
-- all-pairs variant is asymptotically wrong (quadratic in node count where a
-- seeded single-source relaxation is near-linear).
--
-- 'materializeDeadCodeClosure' is called from
-- 'PB.Pipeline.Passes.materializeAllRelationsViews', writing @proc_dead@ as a real
-- DuckDB table before the downstream materializers that consume it
-- ('PB.Pipeline.DuckDb.materializeDeadCodeRows',
-- 'PB.Pipeline.DuckDb.materializeLiveProc') run — those read it as an ordinary
-- input relation, the same mechanism
-- 'PB.Pipeline.DuckDb.Relations.initDeadCodeRelations' uses for
-- @proc@\/@entry@\/@calls@\/etc. Unit-level regression coverage lives entirely
-- in 'DeadCodeReachabilityTest'.
--
-- The reachability is a pure Haskell closure over the raw input relations:
--
--   * 'descendant' (transitive closure of @inherits@) is a small auxiliary
--     fixpoint over the object-ancestor graph, not via 'reachFrom'.
--   * 'override_edge' is the same 3-way join
--     (@proc(parent,method) ∧ descendant(child,parent) ∧ proc(child,method)@).
--   * 'proc_reachable' is the seeded 'reachFrom' from @entry@ over the call
--     graph + override edges — the all-pairs 'star' primitive is unsound here
--     (it computes a different, un-seeded relation).
--   * 'proc_dead' = every 'proc' not in 'proc_reachable'.
--
-- The input construction ('procRows'/'entryRows'/'callsRows'/...) is already
-- Haskell (see 'PB.Pipeline.DuckDb.Relations.initDeadCodeRelations'); only the
-- derived fixpoint is computed here.
module PB.Analysis.DeadCodeReachability
  ( deadReach
  , materializeDeadCodeClosure
  ) where

import PB.Prelude
import PB.Pipeline.DuckDb.Relations
  ( entryRows, callRefRows, resolvedCallEdgeRows, callsRows
  , CallEdge (..)
  )
import PB.Analysis.Taint qualified as Taint (ResolvedCallRow)
import PB.Pipeline.DuckDb
  ( ProcSummaryRow (..), Handle
  , queryProcedures, queryResolvedCalls, queryObjectAncestors, queryDwObjects
  , recreateTextTable, appendTextRows
  )
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
-- 'PB.Pipeline.DuckDb.Relations.initDeadCodeRelations' reads (procedures,
-- resolved calls, object ancestors, DW objects), return the set of
-- (object, proc) pairs the @proc_dead@ table would contain — content-exact.
--
-- The confidence filter ('procRows'/'entryRows' exclude @speculative@
-- procedures) is applied exactly as 'initDeadCodeRelations' does, so the
-- algebraic path agrees with the downstream @proc_dead@ consumers.
deadReach
  :: [ProcSummaryRow]          -- ^ procedures (confidence-filtered by 'procRows')
  -> [Taint.ResolvedCallRow]   -- ^ resolved calls
  -> [(Text, Text)]            -- ^ inherits (child, parent)
  -> [Text]                    -- ^ DW object names
  -> Set (Text, Text)          -- ^ proc_dead
deadReach procs calls inherits dwObjs =
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

-- | Materialize @proc_dead@ as a real DuckDB table, computed by
-- 'deadReach' over the same raw input relations
-- 'PB.Pipeline.DuckDb.Relations.initDeadCodeRelations' reads. Must run after
-- @procedures@\/@resolved_calls@\/@objects@\/@dw_objects@ are populated
-- (same prerequisite as 'PB.Pipeline.DuckDb.Relations.initDeadCodeRelations');
-- called from 'PB.Pipeline.Passes.materializeAllRelationsViews', before the
-- downstream materializers that read @proc_dead@ as an input relation
-- ('PB.Pipeline.DuckDb.materializeDeadCodeRows',
-- 'PB.Pipeline.DuckDb.materializeLiveProc') run.
materializeDeadCodeClosure :: Handle -> IO ()
materializeDeadCodeClosure conn = do
  procs    <- queryProcedures conn
  calls    <- queryResolvedCalls conn
  inherits <- queryObjectAncestors conn
  dwObjs   <- queryDwObjects conn
  let dead = deadReach procs calls inherits dwObjs
  recreateTextTable conn "proc_dead" ["object", "proc"]
  appendTextRows conn "proc_dead" [ [o, p] | (o, p) <- Set.toList dead ]

-- | Transitive closure of @inherits@: @descendant(child, parent)@ holds when
-- @parent@ is an ancestor of @child@. Mirrors the two-rule transitive-closure
-- definition:
--
-- @
--   descendant(child, parent) :- inherits(child, parent).
--   descendant(child, gp) :- inherits(child, parent), descendant(parent, gp).
-- @
--
-- A small auxiliary fixpoint (the object graph is tiny), not via 'reachFrom'.
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
