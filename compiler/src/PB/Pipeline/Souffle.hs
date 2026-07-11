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
  , orderRuleSets
  , runRuleSets
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb
  (DuckConn, queryTextRows, recreateTextTable, appendTextRows)

import qualified Data.List  as List
import qualified Data.Text  as T
import System.Directory     (createDirectoryIfMissing)
import System.Exit          (ExitCode (..))
import System.FilePath      ((</>))
import System.IO.Temp        (withSystemTempDirectory)
import System.Process        (readProcessWithExitCode)

import qualified Data.Set as Set

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
-- Multi-rule-set execution (Plan 166 Stage 8)

-- | The relation NAMES a 'RuleSet' derives (its IDB outputs).
idbNames :: RuleSet -> Set.Set Text
idbNames rs = Set.fromList [ relName rel | rel <- rsRelations rs ]

-- | The relation NAMES a 'RuleSet' consumes but does not derive (its EDB
-- inputs).
edbNames :: RuleSet -> Set.Set Text
edbNames rs = Set.fromList [ relName rel | rel <- edbRelations rs ]

-- | Topologically order rule sets by their EDB\/IDB dependency: A precedes B
-- when A produces a relation B consumes as an EDB input (A's IDB outputs ∩
-- B's EDB inputs, nonempty). External EDBs (DuckDB tables\/views no rule set
-- in the collection derives) impose no ordering. Duplicate rule sets are
-- preserved in the output but do not add edges.
--
-- Returns @Left cycle@ with the names of the rule-set relations involved in
-- a dependency cycle (or, when rule sets are structurally identical and the
-- cycle is between two copies of the same one, both sides), or @Right ordered@
-- with a dependency-respecting order. The order is NOT unique: independent
-- rule sets keep their input order (stable), as does this whole function's
-- contract with 'runRuleSets' below.
--
-- This is the pure, testable core. It inspects only relation NAMES (via
-- 'relName'), so two rule sets that reference the same-named relation
-- agree on that edge regardless of column-shape differences (the shapes
-- must in practice agree for the downstream Souffle run to typecheck).
orderRuleSets :: [RuleSet] -> Either [RuleSet] [RuleSet]
orderRuleSets ruleSets = go [] (Set.fromList [0..length ruleSets - 1])
  where
    -- Stable insertion order for emitting results.
    indexed = List.zip [0 :: Int ..] ruleSets
    outs i  = idbNames  (ruleSets List.!! i)
    ins  i  = edbNames  (ruleSets List.!! i)
    -- i depends on j when j produces a relation i consumes.
    deps i  = [ j | (j, _) <- indexed
                  , i /= j
                  , not (Set.null (outs j `Set.intersection` ins i)) ]

    go :: [RuleSet] -> Set.Set Int -> Either [RuleSet] [RuleSet]
    go acc pending
      | Set.null pending = Right acc
      | null ready       =
          -- No ready node => cycle among the pending. Return the cyclic
          -- rule sets themselves (in stable input order) so the caller can
          -- diagnose which programs are involved.
          Left [ ruleSets List.!! i | (i, _) <- indexed, i `Set.member` pending ]
      | otherwise        =
          go (acc <> [ ruleSets List.!! i | i <- ready ])
             (pending `Set.difference` Set.fromList ready)
      where
        -- A pending index is "ready" if none of its dependencies are still
        -- pending. Emission order follows `indexed` (input order), so
        -- independent rule sets keep their relative input order (stable).
        ready = [ i | (i, _) <- indexed
                    , i `Set.member` pending
                    , all (`notElem` pending) (deps i) ]

-- | Run a collection of rule sets in dependency order: 'orderRuleSets'
-- resolves the order, then each rule set runs via 'runRuleSetWith' (exporting
-- its EDB facts, shelling out to @souffle@, materializing its IDB outputs
-- back to DuckDB) so the next rule set can read those outputs as EDB.
--
-- @onRelation@ fires once per IDB relation just before it is materialized,
-- same contract as 'runRuleSetWith'. A dependency cycle is raised via
-- 'error' naming the cyclic rule sets' IDB relations -- this is a static,
-- programmer-visible configuration error, not a runtime data condition.
runRuleSets :: (Relation -> IO ()) -> DuckConn -> [RuleSet] -> IO ()
runRuleSets onRelation conn ruleSets =
  case orderRuleSets ruleSets of
    Left cyclic ->
      let cyclicNames = [ T.unpack (relName rel) | rs' <- cyclic, rel <- rsRelations rs' ]
      in error ("PB.Pipeline.Souffle.runRuleSets: dependency cycle among rule sets (IDB relations: "
                <> show cyclicNames <> ")")
    Right ordered -> for_ ordered (runRuleSetWith onRelation conn)