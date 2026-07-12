module SouffleEngineTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
  ( Relation (..), symRelation, Literal (..), Rule (..), RuleSet (..), orderRuleSets )

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), testCase)

-- Small helpers to build rule sets by relation name, keeping the dependency
-- tests readable. A rule set "produces" its rsRelations and "consumes" any
-- relation in a rule body that is not an rsRelation.
mkRel :: Text -> Relation
mkRel n = symRelation n ["x"]

-- | A rule set that derives @outs@ from @ins@ (one body literal per input).
rs :: [Text] -> [Text] -> RuleSet
rs outs ins = RuleSet
  { rsRelations = map mkRel outs
  , rsRules     = [ Rule (Literal (mkRel o) ["x"] False Nothing)
                        [ Literal (mkRel i) ["x"] False Nothing | i <- ins ]
                  | o <- outs ]
  , rsChoiceDomains = []
  }

tests :: TestTree
tests = testGroup "SouffleEngine.orderRuleSets"
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
