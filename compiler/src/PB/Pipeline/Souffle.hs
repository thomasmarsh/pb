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
  , sanitizeFactField
  , runRuleSet
  , runRuleSetWith
  , SouffleHooks (..)
  , noSouffleHooks
  , runRuleSetWithStart
  , orderRuleSets
  , runRuleSets
  , runRuleSetsWithStart
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb
  (DuckConn, queryTextRows, recreateTextTable, appendTextRows)
import PB.Pipeline.Progress qualified as Progress
import PB.Pipeline.Progress (msBetween)

import qualified Data.List  as List
import qualified Data.Map.Strict as Map
import qualified Data.Text  as T
import Data.Time.Clock       (getCurrentTime)
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

-- | Soufflé fact files are line- and tab-delimited with no escape syntax:
-- one physical line is one tuple, columns split on tab. Any @\n@, @\r@, or
-- @\t@ inside a field value therefore either splits a tuple (Soufflé aborts
-- with "Values missing ... cannot parse fact file") or shifts the column
-- count. Replace record/column delimiters with a space so every field stays
-- a single token. Object keys are also sanitized at their source in
-- 'PB.Analysis.SchemaCategory.schObjectKey'; this is the catch-all that keeps
-- any other EDB relation from tripping the same failure.
sanitizeFactField :: Text -> Text
sanitizeFactField =
  T.replace "\t" " " . T.replace "\n" " " . T.replace "\r" " "

-- | Materialize every relation in 'rsRelations' as a DuckDB table (dropping
-- any previous table of the same name first).
runRuleSet :: DuckConn -> RuleSet -> IO ()
runRuleSet = runRuleSetWith (\_ -> pure ())

-- | Like 'runRuleSet', but calls the given action just before materializing
-- each IDB relation's result -- a pipeline pass wires this to its own
-- progress-reporting protocol (see 'PB.Pipeline.Passes.runPass11'). A
-- 'SouffleHooks'-based specialization of 'runRuleSetWithStart' below, kept
-- at its original signature so existing callers don't need 'SouffleHooks'.
runRuleSetWith :: (Relation -> IO ()) -> DuckConn -> RuleSet -> IO ()
runRuleSetWith onRelation = runRuleSetWithStart
  noSouffleHooks { onIdbRelation = \rel mn -> when (isNothing mn) (onRelation rel) }

-- | Every callback hook a caller of 'runRuleSetWithStart'\/'runRuleSetsWithStart'
-- can wire into progress reporting. Bundled into a record (rather than
-- growing another positional callback argument each time a new
-- instrumentation point is needed) so 'noSouffleHooks' gives every
-- non-instrumented call site (@runRuleSet@\/@runRuleSets@ below, and every
-- test that calls them) a single no-op value to start from.
data SouffleHooks = SouffleHooks
  { onRuleSetStart :: RuleSet -> [(Relation, Int)] -> IO ()
    -- ^ Fires with this 'RuleSet' and its EDB relations' exact row counts,
    -- right after fact files are written but BEFORE the (possibly
    -- long-running) @souffle@ subprocess starts -- essentially free (the
    -- row count falls out of the fact-file-writing query already being
    -- made), and lets a caller report what is about to run instead of
    -- discovering it only after the fact via process\/temp-dir inspection.
    -- Found necessary in production (2026-07-15): 'onIdbRelation' alone
    -- fires only AFTER a ruleset's single monolithic @souffle@ process
    -- exits, so while a slow ruleset is mid-flight the last-displayed
    -- progress label is whichever relation the PREVIOUS ruleset finished
    -- on -- a live run looked stuck on \"Datalog: leg\" for minutes when
    -- the actually-running ruleset (confirmed via 'orderRuleSets'\'
    -- topological batching -- see 'PB.Pipeline.Passes.souffleProgress'\'s
    -- own note) was 'PB.Analysis.Rules.Taint.taintRules', not
    -- 'PB.Analysis.Rules.Schema.legRules' at all.
  , onEdbFact :: Relation -> Int -> Double -> IO ()
    -- ^ Fires once per EDB relation, immediately after that relation's
    -- facts are queried and written (name, row count, elapsed milliseconds
    -- for that relation alone) -- gives visibility INSIDE the per-relation
    -- fact-writing loop itself, closing the gap a production incident
    -- found: a stall in this loop (suspected on an oversized @reaches@
    -- EDB) produced zero progress events, because 'onRuleSetStart' above
    -- only fires once the whole loop has already finished.
  , onIdbRelation :: Relation -> Maybe (Int, Double) -> IO ()
    -- ^ Fires 'Nothing' right before an IDB relation is materialized (same
    -- timing as the old plain @onRelation@ callback), then 'Just' its row
    -- count and the elapsed milliseconds for the CSV-read +
    -- 'recreateTextTable'\/'appendTextRows' materialization right after --
    -- mirrors 'onEdbFact'\'s per-EDB-relation timing on the IDB side.
  , onHeartbeat :: Double -> IO ()
    -- ^ Fires periodically (with elapsed seconds so far) while the
    -- @souffle@ subprocess itself is running, so a long in-Souffle
    -- evaluation doesn't go dark between 'onRuleSetStart' and
    -- 'onIdbRelation'.
  , onRuleSetFinish :: RuleSet -> Double -> IO ()
    -- ^ Fires once per ruleset, after the @souffle@ subprocess has exited
    -- AND every IDB relation has been read back and materialized into
    -- DuckDB -- the elapsed milliseconds cover the entire span from right
    -- before 'onRuleSetStart' fires to here, i.e. the actual cost of
    -- running this ruleset's Datalog evaluation. Before this hook existed,
    -- that span had NO timing anywhere: 'onEdbFact' only covers the cheap
    -- pre-subprocess fact-writing loop, and 'onHeartbeat' only fires if the
    -- subprocess outlives its 15s tick interval, so a ruleset finishing in
    -- under 15s produced zero duration data at all. Every real production
    -- incident this progress protocol exists to diagnose (@risk_count@,
    -- @implied_fk_pairs@, @taint_reaches@\/@taint_confirmed@) is exactly
    -- this span.
  }

-- | Every hook is a no-op -- the base value every non-instrumented caller
-- (including every existing test) starts from and overrides selectively.
noSouffleHooks :: SouffleHooks
noSouffleHooks = SouffleHooks
  { onRuleSetStart  = \_ _ -> pure ()
  , onEdbFact       = \_ _ _ -> pure ()
  , onIdbRelation   = \_ _ -> pure ()
  , onHeartbeat     = \_ -> pure ()
  , onRuleSetFinish = \_ _ -> pure ()
  }

-- | Export EDB facts, run @souffle@, import IDB output back into DuckDB --
-- see 'SouffleHooks' for the instrumentation points along the way.
runRuleSetWithStart :: SouffleHooks -> DuckConn -> RuleSet -> IO ()
runRuleSetWithStart hooks conn rs =
  withSystemTempDirectory "pb-souffle" $ \dir -> do
    let factsDir = dir </> "facts"
        outDir   = dir </> "out"
        progFile = dir </> "program.dl"
    createDirectoryIfMissing True factsDir
    createDirectoryIfMissing True outDir
    tRs0 <- getCurrentTime
    counts <- mapM (\rel -> do
      t0 <- getCurrentTime
      rows <- queryTextRows conn (relName rel) (colNames rel)
      writeFile (factsDir </> T.unpack (relName rel) <> ".facts")
        (T.unlines [ T.intercalate "\t" (map sanitizeFactField row) | row <- rows ])
      t1 <- getCurrentTime
      onEdbFact hooks rel (length rows) (msBetween t0 t1)
      pure (rel, length rows)) (edbRelations rs)
    onRuleSetStart hooks rs counts
    writeFile progFile (compileProgram rs)
    (exitCode, _out, err) <- Progress.withHeartbeat 15 (onHeartbeat hooks) $
      readProcessWithExitCode "souffle" ["-F", factsDir, "-D", outDir, progFile] ""
    case exitCode of
      ExitFailure code -> error ("PB.Pipeline.Souffle.runRuleSet: souffle exited "
                                    <> show code <> ": " <> err)
      ExitSuccess -> pure ()
    for_ (rsRelations rs) $ \rel -> do
      onIdbRelation hooks rel Nothing
      tIdb0 <- getCurrentTime
      contents <- readFile (outDir </> T.unpack (relName rel) <> ".csv")
      -- T.lines correctly excludes the spurious trailing entry a final
      -- newline would otherwise produce, so no line filter is needed for
      -- that -- but a naive "drop empty lines" filter (the previous
      -- version of this code) is wrong: for a single-column relation, a
      -- row whose one field is the empty string IS an empty line, and
      -- gets silently dropped along with any real trailing blank. Only the
      -- whole-file-empty case (relCols has >=1 columns but Soufflé wrote
      -- zero output rows) needs special-casing, since T.lines "" == [""]
      -- would otherwise fabricate one phantom zero-width row.
      let rows = if T.null contents then []
                 else [ T.splitOn "\t" line | line <- T.lines contents ]
      recreateTextTable conn (relName rel) (colNames rel)
      appendTextRows conn (relName rel) rows
      tIdb1 <- getCurrentTime
      onIdbRelation hooks rel (Just (length rows, msBetween tIdb0 tIdb1))
    tRs1 <- getCurrentTime
    onRuleSetFinish hooks rs (msBetween tRs0 tRs1)


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
runRuleSets onRelation = runRuleSetsWithStart
  noSouffleHooks { onIdbRelation = \rel mn -> when (isNothing mn) (onRelation rel) }

-- | Like 'runRuleSets', but wires 'runRuleSetWithStart'\'s full 'SouffleHooks'
-- through each ruleset in the resolved order -- see that function's own doc
-- comment for why this exists.
runRuleSetsWithStart :: SouffleHooks -> DuckConn -> [RuleSet] -> IO ()
runRuleSetsWithStart hooks conn ruleSets =
  case orderRuleSets ruleSets of
    Left cyclic ->
      let cyclicNames = [ T.unpack (relName rel) | rs' <- cyclic, rel <- rsRelations rs' ]
      in error ("PB.Pipeline.Souffle.runRuleSets: dependency cycle among rule sets (IDB relations: "
                <> show cyclicNames <> ")")
    Right ordered -> for_ ordered (runRuleSetWithStart hooks conn)