-- | The dead-code Datalog programs: 'deadReachRules' (the seeded-BFS
-- reachability core that materializes @proc_reachable@\/@proc_dead@) and
-- 'liveProcRules' (stratified negation over @proc_dead@), plus the typed
-- Haskell functions that materialize the @proc@\/@entry@\/@calls@\/
-- @inherits@\/@call_ref@\/@resolved_call_edge@\/@proc_meta@ EDB relations
-- those rules assume.
--
-- @inherits@ is a faithful projection of @objects.ancestor@; the transitive
-- @descendant@ closure and the derived @override_edge@ triple (same method,
-- different object) are IDB rules below.
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
  -- Pure EDB-relation-construction functions (exported for unit tests)
  , procRows
  , procMetaRows
  , inheritsRows
  , callRefRows
  , resolvedCallEdgeRows
  , entryRows
  , callsRows
  , CallRef (..)
  , ResolvedCallEdge (..)
  , CallEdge (..)
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb
  ( DuckConn, ProcSummaryRow (..)
  , queryObjectAncestors, queryProcedures, queryDwObjects, queryResolvedCalls
  , recreateTextTable, appendTextRows
  )
import PB.Analysis.Taint qualified as Taint

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

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
      [ Rule "live_proc(object, proc) :- stmt(_, object, proc, _), !proc_dead(object, proc)"
             [liveProcRel, stmtRel, procDeadRel]
      ]
  , rsChoiceDomains = []
  }

-- ---------------------------------------------------------------------------
-- Reachability: seeds from 'entry', walks 'calls', and folds in inheritance
-- overrides via 'descendant'/'override_edge'. Materializes
-- 'proc_reachable'/'proc_dead'; 'liveProcRules' above and
-- 'callerCountRules'/'deadCodeRowsRules' below all read 'procDeadRel'
-- directly. Confidence and caller-count classification are Datalog rules
-- (see 'callerCountRules'\/'deadCodeRowsRules' below); @dead_code@ is
-- populated from @dead_code_rows@ via 'PB.Pipeline.DuckDb.materializeDeadCode'.
--
-- @descendant@ is a reusable shared predicate for any future
-- inheritance-aware analysis (taint, business-rule reachability).

-- | Materializes the EDB relations 'deadReachRules' assumes: @proc@ (every
-- known procedure), @entry@ (event\/on handlers, plus DW-object procedures
-- with outbound calls), @calls@ (same-object case-insensitive name-matched
-- calls, unioned with cross-object resolved calls, both derived from
-- @resolved_calls@), @inherits@ (a faithful thin projection: @object@\/
-- @ancestor@ pairs from @objects@, the source inheritance fact -- no
-- closure, no derivation), @call_ref@\/@resolved_call_edge@ (the two
-- @resolved_calls@-derived relations @calls@ is itself built from -- see
-- 'callsRows'), and @proc_meta@ (procedure metadata for the caller-count\/
-- confidence classification in 'callerCountRules'). Must run after
-- 'PB.Pipeline.DuckDb.initSchema' and after @objects@\/@procedures@\/
-- @resolved_calls@\/@dw_objects@ have been populated.
--
-- @calls@ is computed by joining 'callRefRows'\/'resolvedCallEdgeRows''s
-- output directly in memory, so the order the relations below are
-- materialized in is cosmetic.
--
-- Every read of @procedures@ excludes @confidence = 'speculative'@ rows --
-- synthetic stub procedures registered for PB base classes
-- (@dwobject@\/@powerobject@\/@window@\/... method resolution), never real
-- workspace code. An unfiltered @proc@ relation inflates @proc_dead@ with
-- every one of these builtin stub methods.
initDeadReachEdbViews :: DuckConn -> IO ()
initDeadReachEdbViews conn = do
  procs     <- queryProcedures conn
  calls0    <- queryResolvedCalls conn
  ancestors <- queryObjectAncestors conn
  dwObjs    <- queryDwObjects conn
  let refs      = callRefRows calls0
      edges     = resolvedCallEdgeRows calls0
      callEdges = callsRows refs procs edges
  materialize "proc"     ["object", "proc"] (procRows procs)
  materialize "entry"    ["object", "proc"] (entryRows procs calls0 dwObjs)
  materialize "inherits" ["child", "parent"] (inheritsRows ancestors)
  materialize "call_ref" ["caller_obj", "caller_proc", "callee_name"]
    (map (\r -> [crCallerObj r, crCallerProc r, crCalleeName r]) refs)
  materialize "resolved_call_edge"
    ["caller_obj", "caller_proc", "callee_obj", "callee_proc", "line"]
    (map (\e -> [rceCallerObj e, rceCallerProc e, rceCalleeObj e, rceCalleeProc e, rceLine e]) edges)
  materialize "calls" ["caller_obj", "caller_proc", "callee_obj", "callee_proc"]
    (map (\e -> [ceCallerObj e, ceCallerProc e, ceCalleeObj e, ceCalleeProc e]) callEdges)
  materialize "proc_meta" ["object", "proc", "proc_type", "cyclomatic", "proc_lower"]
    (procMetaRows procs)
  where
    materialize name cols rows = do
      recreateTextTable conn name cols
      appendTextRows conn name rows

-- | @proc@: every known procedure, excluding speculative (synthetic
-- builtin-class stub) rows.
procRows :: [ProcSummaryRow] -> [[Text]]
procRows procs =
  [ [psrObject r, psrProcName r]
  | r <- procs, psrConfidence r /= "speculative"
  ]

-- | @proc_meta@: procedure metadata for caller-count\/confidence
-- classification, same speculative filter as 'procRows'.
procMetaRows :: [ProcSummaryRow] -> [[Text]]
procMetaRows procs =
  [ [ psrObject r, psrProcName r, psrProcType r
    , maybe "" (T.pack . show) (psrCyclomatic r)
    , T.toLower (psrProcName r)
    ]
  | r <- procs, psrConfidence r /= "speculative"
  ]

-- | @inherits@: (object,ancestor) pairs renamed to (child,parent).
-- 'PB.Pipeline.DuckDb.queryObjectAncestors' already excludes NULL ancestors.
inheritsRows :: [(Text, Text)] -> [[Text]]
inheritsRows = map (\(child, parent) -> [child, parent])

-- | A @call_ref@ row: same-object case-insensitive callee-name reference,
-- derived from @resolved_calls@.
data CallRef = CallRef
  { crCallerObj  :: !Text
  , crCallerProc :: !Text
  , crCalleeName :: !Text
  } deriving (Eq, Ord, Show)

-- | A @resolved_call_edge@ row: a fully cross-object-resolved call site.
data ResolvedCallEdge = ResolvedCallEdge
  { rceCallerObj  :: !Text
  , rceCallerProc :: !Text
  , rceCalleeObj  :: !Text
  , rceCalleeProc :: !Text
  , rceLine       :: !Text
  } deriving (Eq, Ord, Show)

-- | A @calls@ row: the union 'callsRows' produces from 'CallRef'\/
-- 'ResolvedCallEdge' (no @line@ column -- 'calls' is a pure reachability
-- edge, unlike 'ResolvedCallEdge', which keeps @line@ so the scoped caller
-- count doesn't dedupe distinct call sites).
data CallEdge = CallEdge
  { ceCallerObj  :: !Text
  , ceCallerProc :: !Text
  , ceCalleeObj  :: !Text
  , ceCalleeProc :: !Text
  } deriving (Eq, Ord, Show)

-- | @call_ref@: same-object case-insensitive callee references, deduped to
-- one row per distinct (caller_obj,caller_proc,callee_name). The callee
-- name is the text after the last @.@ in @to_name@ (a control-qualified
-- call like @dw_1.retrieve()@), lowercased.
callRefRows :: [Taint.ResolvedCallRow] -> [CallRef]
callRefRows calls = Set.toList . Set.fromList $
  [ CallRef (Taint.rcrObject c) (Taint.rcrFromProc c)
            (T.toLower (lastDotSegment (Taint.rcrToName c)))
  | c <- calls
  ]

-- | The text after the last @.@ in @t@, or @t@ itself if it has none. Uses
-- @reverse@-then-case-match rather than list 'last' ('PB.Prelude' hides
-- partial functions) -- the same pattern 'PB.Analysis.CallClassify' uses for
-- its own dotted-chain splits.
lastDotSegment :: Text -> Text
lastDotSegment t = case reverse (T.splitOn "." t) of
  (x:_) -> x
  []    -> t

-- | @resolved_call_edge@: fully cross-object-resolved call sites (both a
-- target object and proc), with a missing line coalesced to @""@.
-- Deliberately not deduped (unlike 'callRefRows') -- see
-- 'resolvedCallEdgeRel'\'s own doc comment: the scoped caller count must
-- count every call site, not collapse duplicates sharing the same
-- (caller,callee).
resolvedCallEdgeRows :: [Taint.ResolvedCallRow] -> [ResolvedCallEdge]
resolvedCallEdgeRows calls =
  [ ResolvedCallEdge (Taint.rcrObject c) (Taint.rcrFromProc c) to tp
      (maybe "" (T.pack . show) (Taint.rcrCallLine c))
  | c <- calls
  , Just to <- [Taint.rcrTargetObject c]
  , Just tp <- [Taint.rcrTargetProc c]
  ]

-- | @entry@: the union of (a) event\/on handlers (confidence-filtered, same
-- as 'procRows') and (b) every distinct (object,from_proc) pair from
-- @resolved_calls@ whose object is a known DW object.
entryRows :: [ProcSummaryRow] -> [Taint.ResolvedCallRow] -> [Text] -> [[Text]]
entryRows procs calls dwObjs =
  [ [o, p] | (o, p) <- Set.toList (Set.union fromProcs fromCalls) ]
  where
    dwObjSet = Set.fromList dwObjs
    fromProcs = Set.fromList
      [ (psrObject r, psrProcName r)
      | r <- procs
      , psrProcType r `elem` ["event", "on"]
      , psrConfidence r /= "speculative"
      ]
    fromCalls = Set.fromList
      [ (Taint.rcrObject c, Taint.rcrFromProc c)
      | c <- calls
      , Taint.rcrObject c `Set.member` dwObjSet
      ]

-- | @calls@: same-object case-insensitive name matches ('CallRef' joined
-- against @procedures@ by lowercased name, confidence-filtered) unioned
-- with 'ResolvedCallEdge' (its @line@ column dropped), deduped across the
-- combined result.
callsRows :: [CallRef] -> [ProcSummaryRow] -> [ResolvedCallEdge] -> [CallEdge]
callsRows refs procs edges =
  Set.toList . Set.fromList $ viaCallRef ++ viaResolved
  where
    procIndex = Map.fromListWith (++)
      [ ((psrObject p, T.toLower (psrProcName p)), [psrProcName p])
      | p <- procs, psrConfidence p /= "speculative"
      ]
    viaCallRef =
      [ CallEdge (crCallerObj r) (crCallerProc r) (crCallerObj r) calleeName
      | r <- refs
      , calleeName <- fromMaybe [] (Map.lookup (crCallerObj r, crCalleeName r) procIndex)
      ]
    viaResolved =
      [ CallEdge (rceCallerObj e) (rceCallerProc e) (rceCalleeObj e) (rceCalleeProc e)
      | e <- edges
      ]

-- | 'callRefRel' deliberately has NO @line@ column, unlike
-- 'resolvedCallEdgeRel'. Soufflé relations are sets: a witness relation's
-- own column shape determines what counts as a "distinct" fact. Naive
-- caller counts must dedupe by (caller_obj, caller_proc) regardless of how
-- many lines/times that pair references the same callee name -- keeping
-- @line@ out of this relation entirely is what makes that dedup happen for
-- free at fact-load time, since a Soufflé @count : { ... }@ aggregate
-- counts matching ROWS of the witness relation regardless of which of its
-- columns are named vs. wildcarded in the query (verified empirically
-- against the @souffle@ CLI: wildcarding a present column does NOT
-- project/dedupe it away). 'resolvedCallEdgeRel' keeps @line@ because the
-- scoped count must NOT dedupe -- it counts every call site.
callRefRel, resolvedCallEdgeRel :: Relation
callRefRel          = symRelation "call_ref"           ["caller_obj", "caller_proc", "callee_name"]
resolvedCallEdgeRel = symRelation "resolved_call_edge"  ["caller_obj", "caller_proc", "callee_obj", "callee_proc", "line"]

-- ---------------------------------------------------------------------------
-- Caller counts as Soufflé aggregates.

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
-- Caller counts and confidence classification are materialized here; see
-- 'PB.Pipeline.DuckDb.materializeDeadCode' for the final projection into
-- @dead_code@. The scoped aggregate's trailing @line@-position column is
-- bound to a real variable @L@ (not @_@) so each call site is a distinct
-- witness row (see 'resolvedCallEdgeRel'\'s doc comment for why this
-- matters and why the naive aggregate has no such column at all).
--
-- Confidence joins through 'procMetaRel' (not 'procRel') specifically to
-- get its lowercased @proc_lower@ column: 'hasNaiveCallerRel'\'s facts are
-- always lowercase ('callRefRows' lowercases @callee_name@), but
-- PowerBuilder identifiers are case-insensitive, so a raw-case @proc@
-- variable from 'procRel' would only
-- unify with a naive-caller fact when the declared name happens to already
-- be all-lowercase. A dead proc declared e.g. @of_Calculate@ with a real
-- unresolved caller @of_calculate()@ would otherwise never match
-- @has_naive_caller@, silently misclassifying it @high@ (no callers) while
-- @dead_code_rows@\'s own @naive_n@ (correctly joined through
-- @proc_meta@\'s @proc_lower@) reports a nonzero count for the same row --
-- a mutually inconsistent confidence/count pair. 'hasScopedCallerRel' stays
-- keyed on raw-case @object@\/@proc@: its facts come from
-- 'resolvedCallEdgeRel', whose @callee_obj@\/@callee_proc@ are resolved
-- (case-correct) target identifiers, already the same case as
-- 'procMetaRel'\'s @object@\/@proc@.
callerCountRules :: RuleSet
callerCountRules = RuleSet
  { rsRelations = [hasNaiveCallerRel, hasScopedCallerRel, callerCountNaiveRel, callerCountScopedRel, confidenceRel]
  , rsRules =
      [ Rule "has_naive_caller(callee_name) :- call_ref(_, _, callee_name)"
             [hasNaiveCallerRel, callRefRel]
      , Rule "has_scoped_caller(callee_obj, callee_proc) :- resolved_call_edge(_, _, callee_obj, callee_proc, _)"
             [hasScopedCallerRel, resolvedCallEdgeRel]
      , Rule "caller_count_naive(callee_name, n) :- has_naive_caller(callee_name), n = count : { call_ref(_, _, callee_name) }"
             [callerCountNaiveRel, hasNaiveCallerRel, callRefRel]
      , Rule "caller_count_scoped(callee_obj, callee_proc, n) :- has_scoped_caller(callee_obj, callee_proc), n = count : { resolved_call_edge(_, _, callee_obj, callee_proc, l) }"
             [callerCountScopedRel, hasScopedCallerRel, resolvedCallEdgeRel]
      , Rule "confidence(object, proc, \"high\") :- proc_meta(object, proc, _, _, plower), !has_naive_caller(plower)"
             [confidenceRel, procMetaRel, hasNaiveCallerRel]
      , Rule "confidence(object, proc, \"medium\") :- proc_meta(object, proc, _, _, plower), has_naive_caller(plower), !has_scoped_caller(object, proc)"
             [confidenceRel, procMetaRel, hasNaiveCallerRel, hasScopedCallerRel]
      , Rule "confidence(object, proc, \"low\") :- proc_meta(object, proc, _, _, plower), has_naive_caller(plower), has_scoped_caller(object, proc)"
             [confidenceRel, procMetaRel, hasNaiveCallerRel, hasScopedCallerRel]
      ]
  , rsChoiceDomains = []
  }

-- ---------------------------------------------------------------------------
-- Dead-code rows as Soufflé output.

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
      [ Rule "caller_count_naive_final(p, n) :- caller_count_naive(p, n)"
             [callerCountNaiveFinalRel, callerCountNaiveRel]
      , Rule "caller_count_naive_final(p, 0) :- proc_meta(_, _, _, _, p), !has_naive_caller(p)"
             [callerCountNaiveFinalRel, procMetaRel, hasNaiveCallerRel]
      , Rule "caller_count_scoped_final(o, p, n) :- caller_count_scoped(o, p, n)"
             [callerCountScopedFinalRel, callerCountScopedRel]
      , Rule "caller_count_scoped_final(o, p, 0) :- proc(o, p), !has_scoped_caller(o, p)"
             [callerCountScopedFinalRel, procRel, hasScopedCallerRel]
      , Rule "dead_code_rows(o, p, pt, cyc, lvl, nn, sn) :- proc_dead(o, p), proc_meta(o, p, pt, cyc, plower), confidence(o, p, lvl), caller_count_naive_final(plower, nn), caller_count_scoped_final(o, p, sn)"
             [deadCodeRowsRel, procDeadRel, procMetaRel, confidenceRel, callerCountNaiveFinalRel, callerCountScopedFinalRel]
      ]
  , rsChoiceDomains = []
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
        Rule "descendant(child, parent) :- inherits(child, parent)"
             [descendantRel, inheritsRel]
      , Rule "descendant(child, gp) :- inherits(child, parent), descendant(parent, gp)"
             [descendantRel, inheritsRel]
      , Rule "override_edge(child_obj, method, parent_obj) :- proc(parent_obj, method), descendant(child_obj, parent_obj), proc(child_obj, method)"
             [overrideEdgeRel, procRel, descendantRel]
      , -- Reachability: seed from entries, walk calls, fold in override edges.
        Rule "proc_reachable(object, proc) :- entry(object, proc)"
             [procReachableRel, entryRel]
      , Rule "proc_reachable(object, proc) :- proc_reachable(cobj, cproc), calls(cobj, cproc, object, proc)"
             [procReachableRel, callsRel]
      , Rule "proc_reachable(childobj, method) :- proc_reachable(parentobj, method), override_edge(childobj, method, parentobj)"
             [procReachableRel, overrideEdgeRel]
      , Rule "proc_dead(object, proc) :- proc(object, proc), !proc_reachable(object, proc)"
             [procDeadRel, procRel, procReachableRel]
      ]
  , rsChoiceDomains = []
  }
