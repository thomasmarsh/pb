-- | Plan 166 Stage 1+2 -- the dead-code Datalog programs, split out of
-- 'PB.Pipeline.Souffle'. Holds 'deadReachRules' (the seeded-BFS
-- reachability core that materializes @proc_reachable@\/@proc_dead@) and
-- 'liveProcRules' (stratified-negation over @proc_dead@), plus the
-- @proc@\/@entry@\/@calls@\/@inherits@ EDB views those rules assume.
--
-- Plan 166 Stage 2: inheritance is now a faithful EDB projection
-- (@inherits@ over @objects.ancestor@); the transitive @descendant@ closure
-- and the derived @override_edge@ triple are IDB rules here, not a
-- Haskell-computed @procedure_overrides@ table frozen into the EDB layer.
module PB.Analysis.Rules.DeadCode
  ( initDeadReachEdbViews
  , deadReachRules
  , liveProcRules
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), Literal (..), Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb (DuckConn)
import Database.DuckDB.Simple (Query (..), execute_)

-- ---------------------------------------------------------------------------
-- liveProcRules

stmtRel, liveProcRel :: Relation
stmtRel     = Relation "stmt" ["file", "object", "proc", "line"]
liveProcRel = Relation "live_proc" ["object", "proc"]

-- | @live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !proc_dead(Object,Proc).@
--
-- Real stratified-negation demonstration answering Plan 161's Open
-- Question 4. Reads 'procDeadRel' (@proc_dead@, 'deadReachRules') directly
-- -- Plan 161 Phase 2b cutover, 2026-07-11: used to read a @dead@ EDB view
-- over the Haskell-computed @dead_code@ table (populated by Pass 8) until
-- real-corpus parity between @proc_dead@ and @dead_code@ was confirmed
-- exact (104/104 rows, openpay corpus). 'deadReachRules' MUST run before
-- this ruleset -- see 'PB.Pipeline.Passes.runPass11' for the required
-- ordering ('queryTextRows' errors if @proc_dead@ doesn't exist yet when
-- this ruleset exports its EDB facts).
liveProcRules :: RuleSet
liveProcRules = RuleSet
  { rsRelations = [liveProcRel]
  , rsRules =
      [ Rule (Literal liveProcRel ["object", "proc"] False)
             [ Literal stmtRel ["_", "object", "proc", "_"] False
             , Literal procDeadRel ["object", "proc"] True
             ]
      ]
  }

-- ---------------------------------------------------------------------------
-- Plan 161 Phase 2b: port of the seeded-BFS reachability core that used to
-- live in 'PB.Analysis.DeadCode.computeDeadProcedures' (deleted once
-- parity was proven -- see 'PB.Analysis.DeadCode.classifyDeadProcedures',
-- its replacement, which now takes the dead set as an input instead of
-- computing it). Materializes to 'proc_reachable'/'proc_dead';
-- 'liveProcRules' above reads 'procDeadRel' directly (the cutover, done
-- once real-corpus parity against the Haskell BFS was confirmed exact --
-- see that ruleset's doc comment). 'dead_code' itself is untouched: it
-- still carries confidence/cyclomatic/caller-count fields with no Datalog
-- equivalent, for the Dead Code Explorer API.
--
-- Plan 166 Stage 2: the @overrides@ EDB relation (a Haskell-computed
-- @procedure_overrides@ closure) is gone. Inheritance is now a faithful
-- @inherits@ EDB projection over @objects.ancestor@, and the transitive
-- @descendant@ closure + the derived @override_edge@ triple are IDB rules
-- below. @descendant@ is a reusable shared predicate for any future
-- inheritance-aware analysis (taint, business-rule reachability).

-- | (Re)create the EDB views 'deadReachRules' assumes: @proc@ (every known
-- procedure), @entry@ (event\/on handlers, plus DW-object procedures with
-- outbound calls), @calls@ (same-object case-insensitive name-matched calls
-- union cross-object resolved calls -- mirrors 'PB.Pipeline.Passes.runPass8'\'s
-- @rawCalls@\/@resolvedCalls@ split, both derived from @resolved_calls@),
-- @inherits@ (a faithful thin projection: @object@\/@ancestor@ pairs from
-- @objects@, the source inheritance fact -- no closure, no derivation).
-- Must run after 'PB.Pipeline.DuckDb.initSchema'.
--
-- Every read of @procedures@ below excludes @confidence = 'speculative'@
-- rows -- synthetic stub procedures registered for PB base classes
-- (@dwobject@\/@powerobject@\/@window@\/... method resolution), never real
-- workspace code. 'PB.Pipeline.DuckDb.queryProcInfos' already applies this
-- filter; a real openpay @--db@ run caught the gap when a naive unfiltered
-- @proc@ view here inflated @proc_dead@ by 45 rows, all builtin stub
-- methods, versus the real @dead_code@ table.
initDeadReachEdbViews :: DuckConn -> IO ()
initDeadReachEdbViews conn = for_ views (void . execute_ conn)
  where
    views :: [Query]
    views =
      [ "CREATE OR REPLACE VIEW proc AS \
        \SELECT object, proc_name AS proc FROM procedures WHERE confidence != 'speculative'"
      , "CREATE OR REPLACE VIEW entry AS \
        \SELECT object, proc_name AS proc FROM procedures \
        \WHERE proc_type IN ('event', 'on') AND confidence != 'speculative' \
        \UNION \
        \SELECT DISTINCT r.object, r.from_proc \
        \FROM resolved_calls r JOIN dw_objects d ON d.object = r.object"
      , "CREATE OR REPLACE VIEW calls AS \
        \SELECT DISTINCT r.object AS caller_obj, r.from_proc AS caller_proc, \
        \p.object AS callee_obj, p.proc_name AS callee_proc \
        \FROM resolved_calls r \
        \JOIN procedures p ON p.object = r.object AND p.confidence != 'speculative' \
        \  AND LOWER(p.proc_name) = LOWER(regexp_extract(r.to_name, '[^.]*$')) \
        \UNION \
        \SELECT DISTINCT r.object, r.from_proc, r.target_object, r.target_proc \
        \FROM resolved_calls r \
        \WHERE r.target_object IS NOT NULL AND r.target_proc IS NOT NULL"
      , "CREATE OR REPLACE VIEW inherits AS \
        \SELECT object AS child, ancestor AS parent FROM objects WHERE ancestor IS NOT NULL"
      ]

procRel, entryRel, callsRel, inheritsRel, descendantRel, overrideEdgeRel, procReachableRel, procDeadRel :: Relation
procRel          = Relation "proc"           ["object", "proc"]
entryRel         = Relation "entry"          ["object", "proc"]
callsRel         = Relation "calls"          ["caller_obj", "caller_proc", "callee_obj", "callee_proc"]
inheritsRel      = Relation "inherits"       ["child", "parent"]
descendantRel    = Relation "descendant"     ["child", "parent"]
overrideEdgeRel  = Relation "override_edge"  ["child_obj", "method", "parent_obj"]
procReachableRel = Relation "proc_reachable" ["object", "proc"]
procDeadRel      = Relation "proc_dead"      ["object", "proc"]

-- | @proc_reachable(Object,Proc) :- entry(Object,Proc).@
-- @proc_reachable(Object,Proc) :- proc_reachable(CObj,CProc), calls(CObj,CProc,Object,Proc).@
-- @proc_reachable(ChildObj,Method) :- proc_reachable(ParentObj,Method), override_edge(ChildObj,Method,ParentObj).@
-- @proc_dead(Object,Proc) :- proc(Object,Proc), !proc_reachable(Object,Proc).@
--
-- @descendant(Child,Parent) :- inherits(Child,Parent).@                    -- shared predicate
-- @descendant(Child,GP) :- inherits(Child,Parent), descendant(Parent,GP).@ -- (transitive closure)
-- @override_edge(ChildObj,Method,ParentObj) :- proc(ParentObj,Method), descendant(ChildObj,ParentObj), proc(ChildObj,Method).@
--
-- The Plan 161 Phase 2b port of the seeded-BFS reachability core that used
-- to live in Haskell as 'PB.Analysis.DeadCode.computeDeadProcedures' (now
-- deleted -- see 'PB.Analysis.DeadCode.classifyDeadProcedures' for what
-- replaced it, and 'PB.Pipeline.Passes.runPass8' for how the two combine).
-- Plan 166 Stage 2 adds @descendant@\/@override_edge@ as IDB relations,
-- replacing the Haskell-computed @procedure_overrides@ closure that used to
-- feed the (now-removed) @overrides@ EDB relation.
deadReachRules :: RuleSet
deadReachRules = RuleSet
  { rsRelations = [procReachableRel, procDeadRel, descendantRel, overrideEdgeRel]
  , rsRules =
      [ -- Shared predicates: the inheritance transitive closure and the
        -- derived override triple. descendant replaces the private BFS that
        -- used to live in PB.Analysis.DeadCode.computeOverrideEdges;
        -- override_edge is the join that BFS's output encoded.
        Rule (Literal descendantRel ["child", "parent"] False)
             [ Literal inheritsRel ["child", "parent"] False ]
      , Rule (Literal descendantRel ["child", "gp"] False)
             [ Literal inheritsRel ["child", "parent"] False
             , Literal descendantRel ["parent", "gp"] False
             ]
      , Rule (Literal overrideEdgeRel ["child_obj", "method", "parent_obj"] False)
             [ Literal procRel ["parent_obj", "method"] False
             , Literal descendantRel ["child_obj", "parent_obj"] False
             , Literal procRel ["child_obj", "method"] False
             ]
      , -- Reachability: seed from entries, walk calls, fold in override edges.
        Rule (Literal procReachableRel ["object", "proc"] False)
             [ Literal entryRel ["object", "proc"] False ]
      , Rule (Literal procReachableRel ["object", "proc"] False)
             [ Literal procReachableRel ["cobj", "cproc"] False
             , Literal callsRel ["cobj", "cproc", "object", "proc"] False
             ]
      , Rule (Literal procReachableRel ["childobj", "method"] False)
             [ Literal procReachableRel ["parentobj", "method"] False
             , Literal overrideEdgeRel ["childobj", "method", "parentobj"] False
             ]
      , Rule (Literal procDeadRel ["object", "proc"] False)
             [ Literal procRel ["object", "proc"] False
             , Literal procReachableRel ["object", "proc"] True
             ]
      ]
  }
