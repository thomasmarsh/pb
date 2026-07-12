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
  , callerCountRules
  , deadCodeRowsRules
  , ProcInfo (..)
  , confidenceRel
  , callRefRel
  , resolvedCallEdgeRel
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Aggregate (..), Literal (..), Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb (DuckConn)
import Database.DuckDB.Simple (Query (..), execute_)

-- | A procedure in the workspace.
data ProcInfo = ProcInfo
  { piObject   :: Text
  , piName     :: Text
  , piProcType :: Text   -- "function" | "subroutine" | "event" | "on"
  , piCyclomatic :: Maybe Int
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- liveProcRules

stmtRel, liveProcRel :: Relation
stmtRel     = symRelation "stmt" ["file", "object", "proc", "line"]
liveProcRel = symRelation "live_proc" ["object", "proc"]

-- | @live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !proc_dead(Object,Proc).@
--
-- Stratified negation over 'procDeadRel' (@proc_dead@, materialized by
-- 'deadReachRules'). 'deadReachRules' MUST run before this ruleset -- see
-- 'PB.Pipeline.Passes.runPass11' for the required ordering ('queryTextRows'
-- errors if @proc_dead@ doesn't exist yet when this ruleset exports its
-- EDB facts).
liveProcRules :: RuleSet
liveProcRules = RuleSet
  { rsRelations = [liveProcRel]
  , rsRules =
      [ Rule (Literal liveProcRel ["object", "proc"] False Nothing)
             [ Literal stmtRel ["_", "object", "proc", "_"] False Nothing
             , Literal procDeadRel ["object", "proc"] True Nothing
             ]
      ]
  }

-- ---------------------------------------------------------------------------
-- Reachability: seeds from 'entry', walks 'calls', and folds in inheritance
-- overrides via 'descendant'/'override_edge'. Materializes
-- 'proc_reachable'/'proc_dead'; 'liveProcRules' above and
-- 'callerCountRules'/'deadCodeRowsRules' below all read 'procDeadRel'
-- directly. Confidence and caller-count classification are themselves
-- Datalog now -- see 'callerCountRules'/'deadCodeRowsRules' below;
-- 'dead_code' is populated purely from @dead_code_rows@
-- ('PB.Pipeline.DuckDb.materializeDeadCode'), with no Haskell
-- classification step left.
--
-- @inherits@ is a faithful EDB projection over @objects.ancestor@;
-- @descendant@ (its transitive closure) and @override_edge@ (the derived
-- same-method-different-object triple) are IDB rules below. @descendant@
-- is a reusable shared predicate for any future inheritance-aware
-- analysis (taint, business-rule reachability).

-- | (Re)create the EDB views 'deadReachRules' assumes: @proc@ (every known
-- procedure), @entry@ (event\/on handlers, plus DW-object procedures with
-- outbound calls), @calls@ (same-object case-insensitive name-matched calls,
-- unioned with cross-object resolved calls, both derived from
-- @resolved_calls@), @inherits@ (a faithful thin projection: @object@\/
-- @ancestor@ pairs from @objects@, the source inheritance fact -- no
-- closure, no derivation). Must run after 'PB.Pipeline.DuckDb.initSchema'.
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
      , "CREATE OR REPLACE VIEW call_ref AS \
        \SELECT DISTINCT object AS caller_obj, from_proc AS caller_proc, \
        \LOWER(regexp_extract(to_name, '[^.]*$')) AS callee_name \
        \FROM resolved_calls"
      , "CREATE OR REPLACE VIEW resolved_call_edge AS \
        \SELECT object AS caller_obj, from_proc AS caller_proc, \
        \target_object AS callee_obj, target_proc AS callee_proc, \
        \COALESCE(CAST(line AS VARCHAR), '') AS line \
        \FROM resolved_calls \
        \WHERE target_object IS NOT NULL AND target_proc IS NOT NULL"
      , "CREATE OR REPLACE VIEW proc_meta AS \
        \SELECT object, proc_name AS proc, proc_type, \
        \COALESCE(CAST(cyclomatic AS VARCHAR), '') AS cyclomatic, \
        \LOWER(proc_name) AS proc_lower \
        \FROM procedures WHERE confidence != 'speculative'"
      ]

-- | 'callRefRel' deliberately has NO @line@ column, unlike
-- 'resolvedCallEdgeRel'. Soufflé relations are sets: a witness relation's
-- own column shape determines what counts as a "distinct" fact. Naive
-- caller counts must dedupe by (caller_obj, caller_proc) regardless of how
-- many lines/times that pair references the same callee name (matching the
-- original Haskell @Set.union@/@Set.singleton@ dedup) -- keeping @line@ out
-- of this relation entirely is what makes that dedup happen for free at
-- fact-load time, since a Soufflé @count : { ... }@ aggregate counts
-- matching ROWS of the witness relation regardless of which of its columns
-- are named vs. wildcarded in the query (verified empirically against the
-- @souffle@ CLI: wildcarding a present column does NOT project/dedupe it
-- away). 'resolvedCallEdgeRel' keeps @line@ because the scoped count must
-- NOT dedupe -- it counts every call site, matching the original Haskell
-- @Map.fromListWith (+)@ which added 1 per row with no distinctness check.
callRefRel, resolvedCallEdgeRel :: Relation
callRefRel          = symRelation "call_ref"           ["caller_obj", "caller_proc", "callee_name"]
resolvedCallEdgeRel = symRelation "resolved_call_edge"  ["caller_obj", "caller_proc", "callee_obj", "callee_proc", "line"]

-- ---------------------------------------------------------------------------
-- Plan 166 Stage 4: caller counts as Soufflé aggregates.

hasNaiveCallerRel, hasScopedCallerRel, callerCountNaiveRel, callerCountScopedRel :: Relation
hasNaiveCallerRel    = symRelation "has_naive_caller"    ["callee_name"]
hasScopedCallerRel   = symRelation "has_scoped_caller"   ["callee_obj", "callee_proc"]
callerCountNaiveRel  = Relation "caller_count_naive" [("callee_name", "symbol"), ("n", "number")]
callerCountScopedRel = Relation "caller_count_scoped" [("callee_obj", "symbol"), ("callee_proc", "symbol"), ("n", "number")]

confidenceRel :: Relation
confidenceRel = symRelation "confidence" ["object", "proc", "level"]

-- | @has_naive_caller(CalleeName) :- call_ref(_,_,CalleeName).@
-- @has_scoped_caller(Obj,Proc) :- resolved_call_edge(_,_,Obj,Proc,_).@
-- @caller_count_naive(CalleeName, N) :- has_naive_caller(CalleeName), N = count : { call_ref(_,_,CalleeName) }.@
-- @caller_count_scoped(Obj, Proc, N) :- has_scoped_caller(Obj,Proc), N = count : { resolved_call_edge(_,_,Obj,Proc,L) }.@
--
-- Caller counts and confidence classification, both materialized here --
-- no Haskell classification step remains (see
-- 'PB.Pipeline.DuckDb.materializeDeadCode' for the final projection into
-- @dead_code@). The scoped aggregate's trailing @line@-position column is
-- bound to a real variable @L@ (not @_@) so each call site is a distinct
-- witness row (see 'resolvedCallEdgeRel'\'s doc comment for why this
-- matters and why the naive aggregate has no such column at all).
callerCountRules :: RuleSet
callerCountRules = RuleSet
  { rsRelations = [hasNaiveCallerRel, hasScopedCallerRel, callerCountNaiveRel, callerCountScopedRel, confidenceRel]
  , rsRules =
      [ Rule (Literal hasNaiveCallerRel ["callee_name"] False Nothing)
             [ Literal callRefRel ["_", "_", "callee_name"] False Nothing ]
      , Rule (Literal hasScopedCallerRel ["callee_obj", "callee_proc"] False Nothing)
             [ Literal resolvedCallEdgeRel ["_", "_", "callee_obj", "callee_proc", "_"] False Nothing ]
      , Rule (Literal callerCountNaiveRel ["callee_name", "n"] False Nothing)
             [ Literal hasNaiveCallerRel ["callee_name"] False Nothing
             , Literal callRefRel ["n"] False (Just (Aggregate "count" callRefRel ["_", "_", "callee_name"]))
             ]
      , Rule (Literal callerCountScopedRel ["callee_obj", "callee_proc", "n"] False Nothing)
             [ Literal hasScopedCallerRel ["callee_obj", "callee_proc"] False Nothing
             , Literal resolvedCallEdgeRel ["n"] False (Just (Aggregate "count" resolvedCallEdgeRel ["_", "_", "callee_obj", "callee_proc", "l"]))
             ]
      , Rule (Literal confidenceRel ["object", "proc", "\"high\""] False Nothing)
             [ Literal procRel ["object", "proc"] False Nothing
             , Literal hasNaiveCallerRel ["proc"] True Nothing
             ]
      , Rule (Literal confidenceRel ["object", "proc", "\"medium\""] False Nothing)
             [ Literal procRel ["object", "proc"] False Nothing
             , Literal hasNaiveCallerRel ["proc"] False Nothing
             , Literal hasScopedCallerRel ["object", "proc"] True Nothing
             ]
      , Rule (Literal confidenceRel ["object", "proc", "\"low\""] False Nothing)
             [ Literal procRel ["object", "proc"] False Nothing
             , Literal hasNaiveCallerRel ["proc"] False Nothing
             , Literal hasScopedCallerRel ["object", "proc"] False Nothing
             ]
      ]
  }

-- ---------------------------------------------------------------------------
-- Plan 166 Stage 6: dead-code rows as Soufflé output.

procMetaRel :: Relation
procMetaRel = symRelation "proc_meta" ["object", "proc", "proc_type", "cyclomatic", "proc_lower"]

callerCountNaiveFinalRel, callerCountScopedFinalRel, deadCodeRowsRel :: Relation
callerCountNaiveFinalRel  = Relation "caller_count_naive_final"  [("proc_lower", "symbol"), ("n", "number")]
callerCountScopedFinalRel = Relation "caller_count_scoped_final" [("object", "symbol"), ("proc", "symbol"), ("n", "number")]
deadCodeRowsRel = Relation "dead_code_rows"
  [ ("object", "symbol"), ("proc", "symbol"), ("proc_type", "symbol")
  , ("cyclomatic", "symbol"), ("level", "symbol")
  , ("naive_n", "number"), ("scoped_n", "number")
  ]

-- | @caller_count_naive_final(P, N) :- caller_count_naive(P, N).@
-- @caller_count_naive_final(P, 0) :- proc_meta(_, _, _, _, P), !has_naive_caller(P).@
-- @caller_count_scoped_final(O, P, N) :- caller_count_scoped(O, P, N).@
-- @caller_count_scoped_final(O, P, 0) :- proc(O, P), !has_scoped_caller(O, P).@
-- @dead_code_rows(O, P, PT, Cyc, Lvl, NN, SN) :-
--     proc_dead(O, P), proc_meta(O, P, PT, Cyc, PLower),
--     confidence(O, P, Lvl), caller_count_naive_final(PLower, NN),
--     caller_count_scoped_final(O, P, SN).@
deadCodeRowsRules :: RuleSet
deadCodeRowsRules = RuleSet
  { rsRelations = [callerCountNaiveFinalRel, callerCountScopedFinalRel, deadCodeRowsRel]
  , rsRules =
      [ Rule (Literal callerCountNaiveFinalRel ["p", "n"] False Nothing)
             [ Literal callerCountNaiveRel ["p", "n"] False Nothing ]
      , Rule (Literal callerCountNaiveFinalRel ["p", "0"] False Nothing)
             [ Literal procMetaRel ["_", "_", "_", "_", "p"] False Nothing
             , Literal hasNaiveCallerRel ["p"] True Nothing
             ]
      , Rule (Literal callerCountScopedFinalRel ["o", "p", "n"] False Nothing)
             [ Literal callerCountScopedRel ["o", "p", "n"] False Nothing ]
      , Rule (Literal callerCountScopedFinalRel ["o", "p", "0"] False Nothing)
             [ Literal procRel ["o", "p"] False Nothing
             , Literal hasScopedCallerRel ["o", "p"] True Nothing
             ]
      , Rule (Literal deadCodeRowsRel ["o", "p", "pt", "cyc", "lvl", "nn", "sn"] False Nothing)
             [ Literal procDeadRel ["o", "p"] False Nothing
             , Literal procMetaRel ["o", "p", "pt", "cyc", "plower"] False Nothing
             , Literal confidenceRel ["o", "p", "lvl"] False Nothing
             , Literal callerCountNaiveFinalRel ["plower", "nn"] False Nothing
             , Literal callerCountScopedFinalRel ["o", "p", "sn"] False Nothing
             ]
      ]
  }

procRel, entryRel, callsRel, inheritsRel, descendantRel, overrideEdgeRel, procReachableRel, procDeadRel :: Relation
procRel          = symRelation "proc"           ["object", "proc"]
entryRel         = symRelation "entry"          ["object", "proc"]
callsRel         = symRelation "calls"          ["caller_obj", "caller_proc", "callee_obj", "callee_proc"]
inheritsRel      = symRelation "inherits"       ["child", "parent"]
descendantRel    = symRelation "descendant"     ["child", "parent"]
overrideEdgeRel  = symRelation "override_edge"  ["child_obj", "method", "parent_obj"]
procReachableRel = symRelation "proc_reachable" ["object", "proc"]
procDeadRel      = symRelation "proc_dead"      ["object", "proc"]

-- | @proc_reachable(Object,Proc) :- entry(Object,Proc).@
-- @proc_reachable(Object,Proc) :- proc_reachable(CObj,CProc), calls(CObj,CProc,Object,Proc).@
-- @proc_reachable(ChildObj,Method) :- proc_reachable(ParentObj,Method), override_edge(ChildObj,Method,ParentObj).@
-- @proc_dead(Object,Proc) :- proc(Object,Proc), !proc_reachable(Object,Proc).@
--
-- @descendant(Child,Parent) :- inherits(Child,Parent).@                    -- shared predicate
-- @descendant(Child,GP) :- inherits(Child,Parent), descendant(Parent,GP).@ -- (transitive closure)
-- @override_edge(ChildObj,Method,ParentObj) :- proc(ParentObj,Method), descendant(ChildObj,ParentObj), proc(ChildObj,Method).@
--
-- Seeded-BFS reachability, expressed as Datalog fixpoint rules: seed from
-- 'entry', propagate through 'calls' and through inheritance overrides via
-- 'override_edge'. @proc_dead@ is every known 'proc' not reached. See
-- 'PB.Pipeline.Passes.runPass8' for how this combines with
-- 'callerCountRules'\/'deadCodeRowsRules' into the final @dead_code@ table.
deadReachRules :: RuleSet
deadReachRules = RuleSet
  { rsRelations = [procReachableRel, procDeadRel, descendantRel, overrideEdgeRel]
  , rsRules =
      [ -- Shared predicates: the inheritance transitive closure and the
        -- derived override triple (child object, method name, ancestor
        -- object that declares it).
        Rule (Literal descendantRel ["child", "parent"] False Nothing)
             [ Literal inheritsRel ["child", "parent"] False Nothing ]
      , Rule (Literal descendantRel ["child", "gp"] False Nothing)
             [ Literal inheritsRel ["child", "parent"] False Nothing
             , Literal descendantRel ["parent", "gp"] False Nothing
             ]
      , Rule (Literal overrideEdgeRel ["child_obj", "method", "parent_obj"] False Nothing)
             [ Literal procRel ["parent_obj", "method"] False Nothing
             , Literal descendantRel ["child_obj", "parent_obj"] False Nothing
             , Literal procRel ["child_obj", "method"] False Nothing
             ]
      , -- Reachability: seed from entries, walk calls, fold in override edges.
        Rule (Literal procReachableRel ["object", "proc"] False Nothing)
             [ Literal entryRel ["object", "proc"] False Nothing ]
      , Rule (Literal procReachableRel ["object", "proc"] False Nothing)
             [ Literal procReachableRel ["cobj", "cproc"] False Nothing
             , Literal callsRel ["cobj", "cproc", "object", "proc"] False Nothing
             ]
      , Rule (Literal procReachableRel ["childobj", "method"] False Nothing)
             [ Literal procReachableRel ["parentobj", "method"] False Nothing
             , Literal overrideEdgeRel ["childobj", "method", "parentobj"] False Nothing
             ]
      , Rule (Literal procDeadRel ["object", "proc"] False Nothing)
             [ Literal procRel ["object", "proc"] False Nothing
             , Literal procReachableRel ["object", "proc"] True Nothing
             ]
      ]
  }
