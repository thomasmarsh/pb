-- | Engine adapter for Datalog rule sets: the engine-agnostic
-- 'Relation'\/'Rule'\/'RuleSet' IR (rules are literal Souffle text plus an
-- explicit relation-reference list, not a typed literal AST -- see 'Rule'),
-- plus a Souffle CLI backend
-- ('compileProgram' renders a @.dl@ program; 'runRuleSet'\/'runRuleSetWith'
-- export EDB facts, shell out to @souffle@ interpreted mode, and import IDB
-- output back into DuckDB tables; 'orderRuleSets'\/'runRuleSets'
-- topologically order and run a collection of rule sets). Concrete domain
-- rule sets (dead-code, schema reachability, ...) live in
-- @PB.Analysis.Rules.*@, not here -- this module owns only the IR and the
-- execution mechanics.
module PB.Pipeline.Souffle
  ( Relation (..)
  , symRelation
  , colNames
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
import qualified Data.Map.Strict as Map
import qualified Data.Text  as T
import System.Directory     (createDirectoryIfMissing)
import System.Exit          (ExitCode (..))
import System.FilePath      ((</>))
import System.IO.Temp        (withSystemTempDirectory)
import System.Process        (readProcessWithExitCode)

import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- Rule IR

-- | A named relation with its column names, in positional order. For an IDB
-- relation this also names the DuckDB table 'runRuleSet' creates; for an
-- EDB relation it names an existing table or a view 'initEdbViews' creates
-- over one. Each column is a @(name, type)@ pair -- type defaults to
-- @"symbol"@ for every existing caller; use @(name, \"unsigned\")@ for
-- aggregate-output columns.
data Relation = Relation
  { relName :: Text
  , relCols :: [(Text, Text)]
  } deriving (Eq, Ord, Show)

-- | Convenience constructor: all columns are @symbol@.
symRelation :: Text -> [Text] -> Relation
symRelation name cols = Relation name [ (c, "symbol") | c <- cols ]

-- | Extract column names only (dropping types).
colNames :: Relation -> [Text]
colNames = map fst . relCols

-- | One Horn clause, as literal Souffle syntax (no trailing @.@ --
-- 'renderRule' appends it) -- e.g. @"reaches(x, z) :- reaches(x, y), leg(y,
-- z, _)"@, or, using Souffle's own aggregate/negation/arithmetic syntax
-- directly, @"n = count : { call_ref(_, _, callee_name) }"@ or
-- @"!has_scoped_caller(object, proc)"@ in a body position.
--
-- 'ruleRefs' names every relation the clause mentions -- head, body, and
-- any aggregate witness. 'edbRelations' and 'orderRuleSets' read this list
-- (not 'ruleText') to infer EDB/IDB membership and cross-'RuleSet'
-- dependency edges, so it must be kept in sync with 'ruleText' by the
-- caller: a relation mentioned only in a negated, aggregated, or otherwise
-- non-head position still belongs here.
data Rule = Rule
  { ruleText :: Text
  , ruleRefs :: [Relation]
  } deriving (Eq, Show)

-- | A whole program: every derived (IDB) relation it defines, and every
-- rule (a relation may have several alternative rules, unioned together).
-- 'rsChoiceDomains' names, per IDB relation (by 'relName'), the column
-- subset Souffle should treat as a functional-dependency key via its
-- @choice-domain@ declaration modifier: once any tuple with a given key is
-- derived, further tuples sharing that key are dropped rather than added.
-- @[]@ (the default for every relation not listed) means no choice-domain.
-- This is Souffle's documented idiom for a shortest-distance/BFS-style
-- relation on a cyclic graph -- see 'PB.Analysis.Rules.Schema.cosliceRules'
-- for why plain recursion diverges there without it.
data RuleSet = RuleSet
  { rsRelations      :: [Relation]
  , rsRules          :: [Rule]
  , rsChoiceDomains  :: [(Text, [Text])]
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
  [ rel
  | r <- rsRules rs
  , rel <- ruleRefs r
  , rel `notElem` rsRelations rs
  ]

-- | Append Souffle's clause-terminating @.@ to a rule's literal text.
renderRule :: Rule -> Text
renderRule (Rule t _) = t <> "."

-- | Every column is declared with its explicit type (default @symbol@ for
-- most relations; @unsigned@ for aggregate-output columns like @count@).
-- A non-empty 'choiceDomain' column list renders Souffle's
-- @choice-domain (col, ...)@ decl modifier (see 'rsChoiceDomains').
declOf :: [Text] -> Relation -> Text
declOf choiceDomain rel = ".decl " <> relName rel <> "("
  <> T.intercalate ", " [ n <> ": " <> t | (n, t) <- relCols rel ] <> ")"
  <> (if null choiceDomain then ""
      else " choice-domain (" <> T.intercalate ", " choiceDomain <> ")")

-- | Render a full @.dl@ program: @.decl@/@.input@ for every EDB relation,
-- @.decl@/@.output@ + translated rules for every IDB relation
-- ('rsRelations'). Souffle stratifies and evaluates the whole program
-- itself -- no ordering is needed from the caller.
compileProgram :: RuleSet -> Text
compileProgram rs = T.unlines $
  [ declOf [] rel | rel <- edbs ] <>
  [ ".input " <> relName rel | rel <- edbs ] <>
  [ declOf (choiceDomainFor rel) rel | rel <- rsRelations rs ] <>
  [ ".output " <> relName rel | rel <- rsRelations rs ] <>
  [ renderRule r | r <- rsRules rs ]
  where
    edbs = edbRelations rs
    choiceDomainFor rel = fromMaybe [] (lookup (relName rel) (rsChoiceDomains rs))

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
      rows <- queryTextRows conn (relName rel) (colNames rel)
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
      recreateTextTable conn (relName rel) (colNames rel)
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
    -- 'byIndex'/'at' replace a partial 'List.!!' lookup: every index used
    -- below is drawn from 'indexed' itself, so the lookup can never
    -- actually miss -- but that invariant lives in the shape of this
    -- function's own recursion, not in a type, so a total lookup here
    -- turns a future bookkeeping slip into a labelled crash instead of an
    -- uncaught "index too large" (CLAUDE.md bans partial functions
    -- including @(!!)@ for exactly this reason).
    byIndex = Map.fromList indexed
    at i    = Map.findWithDefault
                (error ("impossible: orderRuleSets index " <> show i <> " out of range"))
                i byIndex
    outs i  = idbNames  (at i)
    ins  i  = edbNames  (at i)
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
          Left [ at i | (i, _) <- indexed, i `Set.member` pending ]
      | otherwise        =
          go (acc <> [ at i | i <- ready ])
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