module Main (main) where

import qualified PhaseATest
import qualified PhaseBQueryTest
import qualified PhaseBAppendTest
import qualified MaterializeTest
import qualified RelationsTest
import qualified DeadCodeReachabilityTest
import qualified SchemaClosureTest
import qualified StdLibTest
import qualified BodyParserTest
import qualified BodyStmtTest
import qualified CfgTest
import qualified CatEvalTest
import qualified EffTermTest
import qualified GoldenFixtureTest
import qualified SSATest
import qualified DataflowTest
import qualified DeadCodeTest
import qualified DeadVarsTest
import qualified InterpCoverageTest
import qualified TaintTest
import qualified ClosureTest
import qualified TaintEdgesTest
import qualified TaintClosureTest
import qualified EscapeTest
import qualified ExprTest
import qualified CorpusDebtTest
import qualified CorpusInvariantTest
import qualified CorpusTest
import qualified DataWindowTest
import qualified FileTest
import qualified IdentTest
import qualified PbApiTest
import qualified PipelineTest
import qualified ProgressTest
import qualified RunnerTest
import qualified PassesTest
import qualified SchemaCategoryTest
import qualified SchFootprintTest
import qualified DwFootprintTest
import qualified DwBindingFootprintTest
import qualified SerialiseTest
import qualified SqlLintTest
import qualified SqlParseTest
import qualified SplitterTest
import qualified StreamTest
import qualified TokenTest
import qualified TypeEnvTest
import qualified TypeResolveTest
import qualified TypeFamilyTest
import qualified TypeCheckTest
import qualified ControlHierarchyTest
import qualified DwParamBindingTest
import qualified DwBuiltinsTest
import qualified CallClassifyTest
import qualified EffectAnnotationsTest
import qualified CloneDetectTest
import qualified RegionsTest
import qualified SignaturesTest
import qualified PseudocodeTest
import qualified RenderTextTest
import qualified SimplifyTest


import Prelude
import Test.Tasty         (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "pb-compiler"
  [ PhaseATest.tests
  , PhaseBQueryTest.tests
  , PhaseBAppendTest.tests
  , MaterializeTest.tests
  , RelationsTest.tests
  , DeadCodeReachabilityTest.tests
  , SchemaClosureTest.tests
  , StdLibTest.tests
  , BodyParserTest.tests
  , BodyStmtTest.tests
  , CfgTest.tests
  , CatEvalTest.tests
  , EffTermTest.tests
  , GoldenFixtureTest.tests
  , SSATest.tests
  , DataflowTest.tests
  , DeadCodeTest.tests
  , DeadVarsTest.tests
  , InterpCoverageTest.tests
  , TaintTest.tests
  , ClosureTest.tests
  , TaintEdgesTest.tests
  , TaintClosureTest.tests
  , EscapeTest.tests
  , ExprTest.tests
  , CorpusDebtTest.tests
  , CorpusInvariantTest.tests
  , CorpusTest.tests
  , DataWindowTest.tests
  , FileTest.tests
  , IdentTest.tests
  , PbApiTest.tests
  , PipelineTest.tests
  , ProgressTest.tests
  , RunnerTest.tests
  , PassesTest.tests
  , SchemaCategoryTest.tests
  , SchFootprintTest.tests
  , DwFootprintTest.tests
  , DwBindingFootprintTest.tests
  , SerialiseTest.tests
  , TokenTest.tests
  , SplitterTest.tests
  , SqlLintTest.tests
  , SqlParseTest.tests
  , StreamTest.tests
  , TypeEnvTest.tests
  , TypeResolveTest.tests
  , TypeFamilyTest.tests
  , TypeCheckTest.tests
  , ControlHierarchyTest.tests
  , DwParamBindingTest.tests
  , DwBuiltinsTest.tests
  , CallClassifyTest.tests
  , EffectAnnotationsTest.tests
  , CloneDetectTest.tests
  , RegionsTest.tests
  , SignaturesTest.tests
  , PseudocodeTest.tests
  , RenderTextTest.tests
  , SimplifyTest.tests
  ]
