module Main (main) where

import qualified DuckDbTest
import qualified DatalogTest
import qualified StdLibTest
import qualified BodyParserTest
import qualified BodyStmtTest
import qualified CfgTest
import qualified CatEvalTest
import qualified CatOpTest
import qualified GoldenFixtureTest
import qualified SSATest
import qualified DataflowTest
import qualified DeadCodeTest
import qualified TaintTest
import qualified EscapeTest
import qualified ExprTest
import qualified CorpusDebtTest
import qualified CorpusInvariantTest
import qualified CorpusTest
import qualified DataWindowTest
import qualified FileTest
import qualified PbApiTest
import qualified PipelineTest
import qualified RunnerTest
import qualified SchemaCategoryTest
import qualified SchFootprintTest
import qualified DwFootprintTest
import qualified SerialiseTest
import qualified SqlParseTest
import qualified SplitterTest
import qualified StreamTest
import qualified TokenTest
import qualified TypeEnvTest
import qualified TypeResolveTest
import qualified ControlHierarchyTest
import qualified CallClassifyTest


import Prelude
import Test.Tasty         (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "pb-compiler"
  [ DuckDbTest.tests
  , DatalogTest.tests
  , StdLibTest.tests
  , BodyParserTest.tests
  , BodyStmtTest.tests
  , CfgTest.tests
  , CatEvalTest.tests
  , CatOpTest.tests
  , GoldenFixtureTest.tests
  , SSATest.tests
  , DataflowTest.tests
  , DeadCodeTest.tests
  , TaintTest.tests
  , EscapeTest.tests
  , ExprTest.tests
  , CorpusDebtTest.tests
  , CorpusInvariantTest.tests
  , CorpusTest.tests
  , DataWindowTest.tests
  , FileTest.tests
  , PbApiTest.tests
  , PipelineTest.tests
  , RunnerTest.tests
  , SchemaCategoryTest.tests
  , SchFootprintTest.tests
  , DwFootprintTest.tests
  , SerialiseTest.tests
  , TokenTest.tests
  , SplitterTest.tests
  , SqlParseTest.tests
  , StreamTest.tests
  , TypeEnvTest.tests
  , TypeResolveTest.tests
  , ControlHierarchyTest.tests
  , CallClassifyTest.tests
  ]
