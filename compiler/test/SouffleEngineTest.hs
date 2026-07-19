module SouffleEngineTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
  ( Relation (..), symRelation, colNames, Rule (..), RuleSet (..)
  , orderRuleSets, edbRelations, compileProgram
  , SouffleHooks (..), noSouffleHooks, runRuleSetWithStart
  )
import PB.Pipeline.DuckDb (withWriteConn, recreateTextTable, appendTextRows)
import PB.Analysis.Rules.DeadCode qualified as DeadCode
  ( callerCountRules, deadCodeRowsRules, liveProcRules
  )

import Data.IORef        (modifyIORef, newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, assertFailure, testCase)

-- Small helpers to build rule sets by relation name, keeping the dependency
-- tests readable. A rule set "produces" its rsRelations and "consumes" any
-- relation in a rule body that is not an rsRelation. ruleText here is a
-- placeholder never rendered/run by these tests -- only ruleRefs (what
-- orderRuleSets/edbRelations actually read) needs to be accurate.
mkRel :: Text -> Relation
mkRel n = symRelation n ["x"]

-- | A rule set that derives @outs@ from @ins@ (one body literal per input).
rs :: [Text] -> [Text] -> RuleSet
rs outs ins = RuleSet
  { rsRelations = map mkRel outs
  , rsRules     = [ Rule (relName (mkRel o) <> " :- " <> T.intercalate ", " (map relName (map mkRel ins)))
                          (mkRel o : map mkRel ins)
                  | o <- outs ]
  , rsChoiceDomains = []
  }

tests :: TestTree
tests = testGroup "SouffleEngine"
  [ orderRuleSetsTests, productionOrderTests, compileProgramTests, souffleHooksTests ]

-- | @out(c1) :- in(c1)@ against a real @souffle@ CLI run, used to exercise
-- 'SouffleHooks' end to end (the pure IR tests above never actually invoke
-- the CLI).
identityRuleSet :: Relation -> RuleSet
identityRuleSet rel =
  let outRel = rel { relName = relName rel <> "_out" }
  in RuleSet
       { rsRelations = [outRel]
       , rsRules =
           [ Rule (relName outRel <> "(" <> T.intercalate ", " (colNames rel) <> ") :- "
                     <> relName rel <> "(" <> T.intercalate ", " (colNames rel) <> ")")
                    [outRel, rel]
           ]
       , rsChoiceDomains = []
       }

souffleHooksTests :: TestTree
souffleHooksTests = testGroup "SouffleHooks"
  [ testCase "onEdbFact fires once per EDB relation carrying that relation's own row count" $
      withWriteConn ":memory:" $ \conn -> do
        let rel = symRelation "hook_in" ["c1"]
        recreateTextTable conn (relName rel) (colNames rel)
        appendTextRows conn (relName rel) [["a"], ["b"], ["c"]]
        ref <- newIORef []
        let hooks = noSouffleHooks
              { onEdbFact = \r n _ms -> modifyIORef ref (++ [(relName r, n)]) }
        runRuleSetWithStart hooks conn (identityRuleSet rel)
        fired <- readIORef ref
        fired @?= [("hook_in", 3)]

  , testCase "onIdbRelation fires Nothing before materialization and Just (rowCount, elapsedMs) after" $
      withWriteConn ":memory:" $ \conn -> do
        let rel = symRelation "hook_in2" ["c1"]
        recreateTextTable conn (relName rel) (colNames rel)
        appendTextRows conn (relName rel) [["x"], ["y"]]
        ref <- newIORef []
        let hooks = noSouffleHooks
              { onIdbRelation = \r mn -> modifyIORef ref (++ [(relName r, mn)]) }
        runRuleSetWithStart hooks conn (identityRuleSet rel)
        fired <- readIORef ref
        case fired of
          [("hook_in2_out", Nothing), ("hook_in2_out", Just (n, ms))] -> do
            n @?= 2
            assertBool "elapsed ms should be non-negative" (ms >= 0)
          other -> assertFailure ("unexpected hook firings: " <> show other)

  , testCase "onRuleSetFinish fires once, after every onIdbRelation call, with a non-negative elapsed time" $
      withWriteConn ":memory:" $ \conn -> do
        let rel = symRelation "hook_in3" ["c1"]
        recreateTextTable conn (relName rel) (colNames rel)
        appendTextRows conn (relName rel) [["x"]]
        order <- newIORef []
        elapsedRef <- newIORef Nothing
        let hooks = noSouffleHooks
              { onIdbRelation  = \r _ -> modifyIORef order (++ [relName r])
              , onRuleSetFinish = \_ ms -> do
                  modifyIORef order (++ ["finish"])
                  writeIORef elapsedRef (Just ms)
              }
        runRuleSetWithStart hooks conn (identityRuleSet rel)
        firedOrder <- readIORef order
        firedOrder @?= ["hook_in3_out", "hook_in3_out", "finish"]
        mMs <- readIORef elapsedRef
        case mMs of
          Just ms -> assertBool "elapsed ms should be non-negative" (ms >= 0)
          Nothing -> assertFailure "onRuleSetFinish never fired"
  ]

orderRuleSetsTests :: TestTree
orderRuleSetsTests = testGroup "orderRuleSets"
  [ testCase "empty collection orders to empty" $
      orderRuleSets [] @?= Right []

  , testCase "single independent rule set is unchanged" $
      orderRuleSets [rs ["a"] []] @?= Right [rs ["a"] []]

  , testCase "two independent rule sets keep input order (stable)" $
      orderRuleSets [rs ["a"] [], rs ["b"] []]
        @?= Right [rs ["a"] [], rs ["b"] []]

  , testCase "consumer runs after producer (b consumes a's output)" $
      orderRuleSets [rs ["b"] ["a"], rs ["a"] []]
        @?= Right [rs ["a"] [], rs ["b"] ["a"]]

  , testCase "transitive chain: c->b->a ordered a,b,c" $
      orderRuleSets [rs ["c"] ["b"], rs ["b"] ["a"], rs ["a"] []]
        @?= Right [rs ["a"] [], rs ["b"] ["a"], rs ["c"] ["b"]]

  , testCase "diamond: d consumes b and c, both consume a" $
      -- Input order is [d, c, b, a] (indices 0,1,2,3). 'a' has no deps and
      -- goes first; then 'c' and 'b' (both depend only on 'a') become ready
      -- simultaneously and keep their stable input order (c is index 1,
      -- b is index 2); then 'd'. Expected: [a, c, b, d].
      orderRuleSets [rs ["d"] ["b","c"], rs ["c"] ["a"], rs ["b"] ["a"], rs ["a"] []]
        @?= Right [rs ["a"] [], rs ["c"] ["a"], rs ["b"] ["a"], rs ["d"] ["b","c"]]

  , testCase "external EDB (no producer) imposes no ordering" $
      -- 'a' consumes 'base' which no rule set derives; the two rule sets are
      -- independent of each other and keep their input order.
      orderRuleSets [rs ["a"] ["base"], rs ["b"] []]
        @?= Right [rs ["a"] ["base"], rs ["b"] []]

  , testCase "direct cycle (a produces x consumes y, b produces y consumes x) is Left" $
      -- Both rule sets are pending forever; orderRuleSets returns Left with
      -- the cyclic rule sets. Assert it is a Left (not validate the exact
      -- cyclic set contents, which are an implementation detail).
      case orderRuleSets [rs ["x"] ["y"], rs ["y"] ["x"]] of
        Left _  -> pure ()
        Right _ -> error "expected a dependency-cycle Left, got an order"
  ]

-- | The full Phase B rule-set collection ('PB.Pipeline.Passes.runPhaseB'
-- runs these via one 'runRuleSets' call). Asserting here, at the pure
-- 'orderRuleSets' layer, that the merged production set is cycle-free and
-- respects the known cross-rule-set edges -- so the single-call structure
-- in 'runPhaseB' is statically sound, not just runtime-verified.
--
-- Plan 182 de-oracle: the schema coslice's 'legRules' / 'reachesRules' /
-- 'cosliceRules' were deleted and replaced by the algebraic closure in
-- 'PB.Analysis.SchemaAlgebra' (materialized by
-- 'SchemaAlgebra.materializeSchemaClosure'), so they no longer appear in
-- this production collection.
productionOrderTests :: TestTree
productionOrderTests = testGroup "orderRuleSets (production set)"
  [ testCase "full Phase B rule-set collection orders without a cycle" $
      case orderRuleSets productionRuleSets of
        Left cyclic -> error ("unexpected cycle in production rule sets: "
                                <> show (map rsRelations cyclic))
        Right _    -> pure ()
  ]

-- | The exact rule-set collection 'PB.Pipeline.Passes.runPhaseB' passes to
-- one 'runRuleSets' call, in its stable input order.
productionRuleSets :: [RuleSet]
productionRuleSets =
  [ DeadCode.callerCountRules, DeadCode.deadCodeRowsRules
  , DeadCode.liveProcRules
  ]

compileProgramTests :: TestTree
compileProgramTests = testGroup "compileProgram"
  [ testCase "edbRelations derives from ruleRefs not rsRelations" $
      edbRelations (rs ["b"] ["a"]) @?= [mkRel "a"]

  , testCase "compileProgram appends trailing dot to ruleText" $
      let edge = symRelation "edge" ["x", "y"]
          path = symRelation "path" ["x", "y"]
          ruleSet = RuleSet
            { rsRelations = [path]
            , rsRules = [Rule "path(x, y) :- edge(x, y)" [path, edge]]
            , rsChoiceDomains = []
            }
      in compileProgram ruleSet @?= T.unlines
           [ ".decl edge(x: symbol, y: symbol)"
           , ".input edge"
           , ".decl path(x: symbol, y: symbol)"
           , ".output path"
           , "path(x, y) :- edge(x, y)."
           ]
  ]
