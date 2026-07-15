module SouffleFuzzTest (tests) where

import PB.Prelude
import PB.Pipeline.Souffle
  ( Relation (..), symRelation, colNames, Rule (..), RuleSet (..)
  , runRuleSet, sanitizeFactField
  )
import PB.Pipeline.DuckDb (withWriteConn, recreateTextTable, appendTextRows, queryTextRows)

import qualified Data.Set  as Set
import qualified Data.Text as T
import Hedgehog (Gen, Property, evalIO, forAll, property, withTests, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty          (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

-- | Plan 173 -- fuzzes the Haskell<->Soufflé-CLI transport layer
-- ('PB.Pipeline.Souffle.runRuleSetWith''s @.facts@/@.csv@ round trip),
-- independent of any domain rule set's own semantics (those are covered by
-- @SouffleSchemaTest.hs@/@SouffleTaintTest.hs@/@SouffleDeadCodeTest.hs@).

-- | 1-6 column relation, columns @c1@..@cN@ -- the schema shape itself isn't
-- the fuzz target ('compileProgram''s own tests in @SouffleEngineTest.hs@
-- cover @.decl@ rendering); this module fuzzes ROW DATA through a fixed
-- schema shape.
genRelation :: Gen Relation
genRelation = do
  n <- Gen.int (Range.linear 1 6)
  pure (symRelation "gen_in" [ "c" <> T.pack (show i) | i <- [1 .. n :: Int] ])

-- | One adversarial field value: the characters 'sanitizeFactField' exists
-- to strip (tab/newline/CR), an empty string, the literal extensions
-- Soufflé's own transport files use, and Unicode text.
genField :: Gen Text
genField = Gen.choice
  [ Gen.text (Range.linear 0 12) Gen.alphaNum
  , pure ""
  , pure "a\tb"
  , pure "a\nb"
  , pure "a\rb"
  , pure "\t\n\r"
  , pure "x.facts"
  , pure "x.csv"
  , Gen.text (Range.linear 1 8) Gen.unicode
  ]

genRow :: Relation -> Gen [Text]
genRow rel = traverse (const genField) (colNames rel)

-- | @out(...) :- in(...)@, arity generalized to 'rel''s own column count --
-- 'rel' and the derived relation reuse the same column names verbatim, so
-- the generated relation's arity IS the rule's arity with nothing separate
-- to keep in sync.
identityRuleSet :: Relation -> RuleSet
identityRuleSet rel =
  let outRel   = rel { relName = "gen_out" }
      atomCols = T.intercalate ", " (colNames rel)
  in RuleSet
       { rsRelations = [outRel]
       , rsRules =
           [ Rule (relName outRel <> "(" <> atomCols <> ") :- "
                     <> relName rel <> "(" <> atomCols <> ")")
                  [outRel, rel]
           ]
       , rsChoiceDomains = []
       }

-- | Seeds 'rel' as a real DuckDB table, runs 'identityRuleSet' through the
-- real @souffle@ CLI, reads the derived relation back. Soufflé relations
-- are SETS, so exact-duplicate input rows (after sanitization) legitimately
-- collapse to one -- comparison is by 'Set.Set', not list/multiset.
roundTrip :: Relation -> [[Text]] -> IO (Set.Set [Text], Set.Set [Text])
roundTrip rel rows = withWriteConn ":memory:" $ \conn -> do
  recreateTextTable conn (relName rel) (colNames rel)
  appendTextRows conn (relName rel) rows
  runRuleSet conn (identityRuleSet rel)
  outRows <- queryTextRows conn "gen_out" (colNames rel)
  let expected = Set.fromList (map (map sanitizeFactField) rows)
  pure (expected, Set.fromList outRows)

prop_roundTripIdentity :: Property
prop_roundTripIdentity = withTests 30 . property $ do
  rel  <- forAll genRelation
  rows <- forAll (Gen.list (Range.linear 0 20) (genRow rel))
  (expected, actual) <- evalIO (roundTrip rel rows)
  actual === expected

prop_arityPreserved :: Property
prop_arityPreserved = withTests 30 . property $ do
  rel  <- forAll genRelation
  rows <- forAll (Gen.list (Range.linear 0 20) (genRow rel))
  (_, actual) <- evalIO (roundTrip rel rows)
  let arity = length (colNames rel)
  Set.filter ((/= arity) . length) actual === Set.empty

tests :: TestTree
tests = testGroup "SouffleFuzz"
  [ testProperty "round-trip identity: sanitized input equals output (as a set)" prop_roundTripIdentity
  , testProperty "arity preserved across generated relation shapes" prop_arityPreserved
  ]
