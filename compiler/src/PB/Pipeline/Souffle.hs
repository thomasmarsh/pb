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
-- @leg@ over 'schema_morphisms', @dead@ over 'dead_code', @stmt@ over the
-- 'StmtObj' rows of 'schema_objects'. Must run after
-- 'PB.Pipeline.DuckDb.initSchema'.
initEdbViews :: DuckConn -> IO ()
initEdbViews conn = for_ views (void . execute_ conn)
  where
    views :: [Query]
    views =
      [ "CREATE OR REPLACE VIEW leg AS \
        \SELECT from_key AS x, to_key AS y, leg_kind FROM schema_morphisms"
      , "CREATE OR REPLACE VIEW dead AS \
        \SELECT object, proc_name AS proc FROM dead_code"
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

stmtRel, deadRel, liveProcRel :: Relation
stmtRel     = Relation "stmt" ["file", "object", "proc", "line"]
deadRel     = Relation "dead" ["object", "proc"]
liveProcRel = Relation "live_proc" ["object", "proc"]

-- | @live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !dead(Object,Proc).@
--
-- Real stratified-negation demonstration answering Plan 161's Open
-- Question 4: 'dead' (from 'PB.Analysis.DeadCode', materialized by Pass 8)
-- is fully computed before this program ever runs, so no cross-run
-- ordering is needed here -- Souffle only has to confirm 'live_proc' itself
-- isn't negatively self-referential (it is not).
liveProcRules :: RuleSet
liveProcRules = RuleSet
  { rsRelations = [liveProcRel]
  , rsRules =
      [ Rule (Literal liveProcRel ["object", "proc"] False)
             [ Literal stmtRel ["_", "object", "proc", "_"] False
             , Literal deadRel ["object", "proc"] True
             ]
      ]
  }
