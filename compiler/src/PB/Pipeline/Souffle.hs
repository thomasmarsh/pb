-- | Plan 161 (reopened Phase 0, 2026-07-11) -- Souffle-backed replacement
-- for the DuckDB-native rule compiler this module used to be
-- ('PB.Pipeline.Datalog', deleted). Same engine-agnostic
-- 'Relation'\/'Literal'\/'Rule'\/'RuleSet' IR; the backend now emits a
-- Souffle @.dl@ program, shells out to the @souffle@ CLI (interpreted mode)
-- against exported EDB fact files, and reads its IDB output back into
-- DuckDB tables. Stratification, negation, and recursion are Souffle's own
-- job now -- there is no Haskell-level stratifier/rule-to-SQL compiler left
-- to test (see the plan's reopened Phase 0 for why: a realistic
-- Phase-3-shaped aggregate rule had no home in the old IR's compiler at
-- all, confirming the expressiveness gap the DuckDB-native path would have
-- required building out by hand).
module PB.Pipeline.Souffle
  ( Relation (..)
  , Literal (..)
  , Rule (..)
  , RuleSet (..)
  , edbRelations
  , compileProgram
  , runRuleSet
  , runRuleSetWith
  , initEdbViews
  , reachesRules
  , liveProcRules
  , initDeadReachEdbViews
  , deadReachRules
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb
  (DuckConn, queryTextRows, recreateTextTable, appendTextRows)

import Database.DuckDB.Simple (Query (..), execute_)

import qualified Data.List  as List
import qualified Data.Text  as T
import System.Directory     (createDirectoryIfMissing)
import System.Exit          (ExitCode (..))
import System.FilePath      ((</>))
import System.IO.Temp        (withSystemTempDirectory)
import System.Process        (readProcessWithExitCode)

-- ---------------------------------------------------------------------------
-- Rule IR (unchanged from the old DuckDB-native module -- see Plan 161)

-- | A named relation with its column names, in positional order. For an IDB
-- relation this also names the DuckDB table 'runRuleSet' creates; for an
-- EDB relation it names an existing table or a view 'initEdbViews' creates
-- over one.
data Relation = Relation
  { relName :: Text
  , relCols :: [Text]
  } deriving (Eq, Ord, Show)

-- | One literal in a rule body (or the head). 'litArgs' are variable names
-- or the wildcard @"_"@, positionally aligned to 'relCols' of 'litRelation'
-- (same arity -- mismatched lengths are a malformed 'Rule').
data Literal = Literal
  { litRelation :: Relation
  , litArgs     :: [Text]
  , litNegated  :: Bool
  } deriving (Eq, Show)

-- | One Horn clause: @ruleHead :- ruleBody@. 'litNegated' on 'ruleHead' is
-- always 'False'.
data Rule = Rule
  { ruleHead :: Literal
  , ruleBody :: [Literal]
  } deriving (Eq, Show)

-- | A whole program: every derived (IDB) relation it defines, and every
-- rule (a relation may have several alternative rules, unioned together).
data RuleSet = RuleSet
  { rsRelations :: [Relation]
  , rsRules     :: [Rule]
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Program generation

-- | Every relation referenced anywhere in a 'RuleSet' -- head or body of any
-- rule -- that is NOT itself one of 'rsRelations' (the derived/IDB set).
-- These are the EDB relations the program assumes are already populated;
-- Souffle needs a @.facts@ file for each one, even an empty one (a missing
-- fact file for a declared @.input@ relation is a hard Souffle error).
edbRelations :: RuleSet -> [Relation]
edbRelations rs = List.nub
  [ litRelation lit
  | r <- rsRules rs
  , lit <- ruleHead r : ruleBody r
  , litRelation lit `notElem` rsRelations rs
  ]

-- | Render one literal as Souffle syntax: @relName(arg1, arg2, ...)@,
-- negated literals prefixed with @!@. The wildcard @"_"@ passes through
-- unchanged -- Souffle uses the same convention for anonymous variables
-- this IR already does.
renderLiteral :: Literal -> Text
renderLiteral (Literal rel args neg) =
  (if neg then "!" else "") <> relName rel <> "(" <> T.intercalate ", " args <> ")"

renderRule :: Rule -> Text
renderRule (Rule hd body) =
  renderLiteral hd <> " :- " <> T.intercalate ", " (map renderLiteral body) <> "."

-- | Every column is declared @symbol@ (Souffle's string type) -- every
-- value this project currently feeds through (schema keys, kinds, object
-- names) is already string-shaped; see this module's own header comment.
declOf :: Relation -> Text
declOf rel = ".decl " <> relName rel <> "("
  <> T.intercalate ", " [ c <> ": symbol" | c <- relCols rel ] <> ")"

-- | Render a full @.dl@ program: @.decl@/@.input@ for every EDB relation,
-- @.decl@/@.output@ + translated rules for every IDB relation
-- ('rsRelations'). Souffle stratifies and evaluates the whole program
-- itself -- no ordering is needed from the caller.
compileProgram :: RuleSet -> Text
compileProgram rs = T.unlines $
  [ declOf rel | rel <- edbs ] <>
  [ ".input " <> relName rel | rel <- edbs ] <>
  [ declOf rel | rel <- rsRelations rs ] <>
  [ ".output " <> relName rel | rel <- rsRelations rs ] <>
  [ renderRule r | r <- rsRules rs ]
  where
    edbs = edbRelations rs

-- ---------------------------------------------------------------------------
-- Execution: export facts -> run souffle -> import results

-- | Materialize every relation in 'rsRelations' as a DuckDB table (dropping
-- any previous table of the same name first).
runRuleSet :: DuckConn -> RuleSet -> IO ()
runRuleSet = runRuleSetWith (\_ -> pure ())

-- | Like 'runRuleSet', but calls the given action just before materializing
-- each IDB relation's result -- a pipeline pass wires this to its own
-- progress-reporting protocol (see 'PB.Pipeline.Passes.runPass11').
runRuleSetWith :: (Relation -> IO ()) -> DuckConn -> RuleSet -> IO ()
runRuleSetWith onRelation conn rs =
  withSystemTempDirectory "pb-souffle" $ \dir -> do
    let factsDir = dir </> "facts"
        outDir   = dir </> "out"
        progFile = dir </> "program.dl"
    createDirectoryIfMissing True factsDir
    createDirectoryIfMissing True outDir
    for_ (edbRelations rs) $ \rel -> do
      rows <- queryTextRows conn (relName rel) (relCols rel)
      writeFile (factsDir </> T.unpack (relName rel) <> ".facts")
        (T.unlines [ T.intercalate "\t" row | row <- rows ])
    writeFile progFile (compileProgram rs)
    (exitCode, _out, err) <- readProcessWithExitCode "souffle"
      ["-F", factsDir, "-D", outDir, progFile] ""
    case exitCode of
      ExitFailure code -> error ("PB.Pipeline.Souffle.runRuleSet: souffle exited "
                                    <> show code <> ": " <> err)
      ExitSuccess -> pure ()
    for_ (rsRelations rs) $ \rel -> do
      onRelation rel
      contents <- readFile (outDir </> T.unpack (relName rel) <> ".csv")
      let rows = [ T.splitOn "\t" line | line <- T.lines contents, not (T.null line) ]
      recreateTextTable conn (relName rel) (relCols rel)
      appendTextRows conn (relName rel) rows

-- ---------------------------------------------------------------------------
-- EDB views over existing DuckDB tables (no fact marshalling in DuckDB
-- itself -- 'queryTextRows' reads these directly)

-- | (Re)create the EDB views every 'RuleSet' below assumes already exist:
-- @leg@ over 'schema_morphisms', @stmt@ over the 'StmtObj' rows of
-- 'schema_objects'. Must run after 'PB.Pipeline.DuckDb.initSchema'.
--
-- No @dead@ view here (Plan 161 Phase 2b cutover, 2026-07-11): 'liveProcRules'
-- used to read a @dead@ view over the Haskell-computed @dead_code@ table;
-- once real-corpus parity between @proc_dead@ (Datalog, 'deadReachRules')
-- and @dead_code@ (Haskell BFS) was confirmed exact (104/104 rows, openpay
-- corpus), it was switched to read the @proc_dead@ table directly --
-- closing the half-Haskell/half-Datalog gap Phase 1 left. A passthrough
-- view here would have to be created eagerly (DuckDB validates a view's
-- referenced table at @CREATE VIEW@ time, not lazily at query time) even
-- in tests\/passes that only run 'reachesRules' and never touch dead-code
-- at all -- reading @proc_dead@ straight from 'liveProcRules' avoids that
-- ordering coupling entirely. @dead_code@ itself is unchanged and still
-- Haskell-computed: it carries confidence/cyclomatic/caller-count fields
-- ('PB.Analysis.DeadCode.DeadProcedure') with no Datalog equivalent, and is
-- still the sole source for the Dead Code Explorer API (@get_dead_code@).
initEdbViews :: DuckConn -> IO ()
initEdbViews conn = for_ views (void . execute_ conn)
  where
    views :: [Query]
    views =
      [ "CREATE OR REPLACE VIEW leg AS \
        \SELECT from_key AS x, to_key AS y, leg_kind FROM schema_morphisms"
      , -- 'dw_retrieve'-kind schema_objects rows are deliberately excluded: their
        -- stmt_proc is always NULL (a DW retrieve isn't a procedure), which would
        -- make `dead(Object,Proc)` vacuously never match and every DW retrieve
        -- unconditionally "live" -- confirmed against the real openpay corpus
        -- (114/115 stmt rows were dw_retrieve noise before this restriction).
        "CREATE OR REPLACE VIEW stmt AS \
        \SELECT stmt_file AS file, stmt_object AS object, stmt_proc AS proc, stmt_line AS line \
        \FROM schema_objects WHERE kind = 'stmt'"
      ]

-- ---------------------------------------------------------------------------
-- Concrete programs

legRel, reachesRel :: Relation
legRel     = Relation "leg" ["x", "y", "leg_kind"]
reachesRel = Relation "reaches" ["x", "y"]

-- | @reaches(X,Y) :- leg(X,Y,_).@
-- @reaches(X,Z) :- reaches(X,Y), leg(Y,Z,_).@
--
-- The Phase 0-validated port of 'PB.Analysis.SchemaCategory.blastRadius'/
-- 'validationWalkBack''s existence-only core: both functions' reachable-set
-- reprojects off this single relation (see Plan 161's Design section).
reachesRules :: RuleSet
reachesRules = RuleSet
  { rsRelations = [reachesRel]
  , rsRules =
      [ Rule (Literal reachesRel ["x", "y"] False)
             [ Literal legRel ["x", "y", "_"] False ]
      , Rule (Literal reachesRel ["x", "z"] False)
             [ Literal reachesRel ["x", "y"] False
             , Literal legRel ["y", "z", "_"] False
             ]
      ]
  }

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

-- | (Re)create the EDB views 'deadReachRules' assumes: @proc@ (every known
-- procedure), @entry@ (event\/on handlers, plus DW-object procedures with
-- outbound calls), @calls@ (same-object case-insensitive name-matched calls
-- union cross-object resolved calls -- mirrors 'PB.Pipeline.Passes.runPass8'\'s
-- @rawCalls@\/@resolvedCalls@ split, both derived from @resolved_calls@),
-- @overrides@ (a thin passthrough view over @procedure_overrides@, the
-- table 'PB.Analysis.DeadCode.computeOverrideEdges'\' flattened output is
-- persisted to -- that flattening itself stays Haskell-computed, same
-- treatment @leg@ gets over @schema_morphisms@). Must run after
-- 'PB.Pipeline.DuckDb.initSchema'.
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
      , "CREATE OR REPLACE VIEW overrides AS \
        \SELECT child_object AS child_obj, method, parent_object AS parent_obj \
        \FROM procedure_overrides"
      ]

procRel, entryRel, callsRel, overridesRel, procReachableRel, procDeadRel :: Relation
procRel          = Relation "proc"           ["object", "proc"]
entryRel         = Relation "entry"          ["object", "proc"]
callsRel         = Relation "calls"          ["caller_obj", "caller_proc", "callee_obj", "callee_proc"]
overridesRel     = Relation "overrides"      ["child_obj", "method", "parent_obj"]
procReachableRel = Relation "proc_reachable" ["object", "proc"]
procDeadRel      = Relation "proc_dead"      ["object", "proc"]

-- | @proc_reachable(Object,Proc) :- entry(Object,Proc).@
-- @proc_reachable(Object,Proc) :- proc_reachable(CObj,CProc), calls(CObj,CProc,Object,Proc).@
-- @proc_reachable(ChildObj,Method) :- proc_reachable(ParentObj,Method), overrides(ChildObj,Method,ParentObj).@
-- @proc_dead(Object,Proc) :- proc(Object,Proc), !proc_reachable(Object,Proc).@
--
-- The Plan 161 Phase 2b port of the seeded-BFS reachability core that used
-- to live in Haskell as 'PB.Analysis.DeadCode.computeDeadProcedures' (now
-- deleted -- see 'PB.Analysis.DeadCode.classifyDeadProcedures' for what
-- replaced it, and 'PB.Pipeline.Passes.runPass8' for how the two combine).
deadReachRules :: RuleSet
deadReachRules = RuleSet
  { rsRelations = [procReachableRel, procDeadRel]
  , rsRules =
      [ Rule (Literal procReachableRel ["object", "proc"] False)
             [ Literal entryRel ["object", "proc"] False ]
      , Rule (Literal procReachableRel ["object", "proc"] False)
             [ Literal procReachableRel ["cobj", "cproc"] False
             , Literal callsRel ["cobj", "cproc", "object", "proc"] False
             ]
      , Rule (Literal procReachableRel ["childobj", "method"] False)
             [ Literal procReachableRel ["parentobj", "method"] False
             , Literal overridesRel ["childobj", "method", "parentobj"] False
             ]
      , Rule (Literal procDeadRel ["object", "proc"] False)
             [ Literal procRel ["object", "proc"] False
             , Literal procReachableRel ["object", "proc"] True
             ]
      ]
  }
