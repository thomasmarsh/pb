module Main (main) where

import qualified PrettyPrintTest
import qualified BodyParserTest
import qualified BodyStmtTest
import qualified CfgBuildTest
import qualified CpsCompileTest
import qualified ExprTest
import qualified CorpusDebtTest
import qualified CorpusInvariantTest
import qualified CorpusTest
import qualified DataWindowTest
import qualified FileTest
import qualified PipelineTest
import qualified RunnerTest
import qualified SerialiseTest
import qualified SplitterTest
import qualified StreamTest
import qualified TokenTest
import qualified TypeEnvTest


import Prelude
import Test.Tasty         (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "pb-ast"
  [ PrettyPrintTest.tests
  , BodyParserTest.tests
  , BodyStmtTest.tests
  , CfgBuildTest.tests
  , CpsCompileTest.tests
  , ExprTest.tests
  , CorpusDebtTest.tests
  , CorpusInvariantTest.tests
  , CorpusTest.tests
  , DataWindowTest.tests
  , FileTest.tests
  , PipelineTest.tests
  , RunnerTest.tests
  , SerialiseTest.tests
  , TokenTest.tests
  , SplitterTest.tests
  , StreamTest.tests
  , TypeEnvTest.tests
  ]
