module Main (main) where

import qualified BodyParserTest
import qualified BodyStmtTest
import qualified ExprTest
import qualified CorpusInvariantTest
import qualified CorpusTest
import qualified FileTest
import qualified MaskTest
import qualified PipelineTest
import qualified RunnerTest
import qualified SerialiseTest
import qualified SplitterTest
import qualified StreamTest
import qualified TokenTest


import Prelude
import Test.Tasty         (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "pb-ast"
  [ BodyParserTest.tests
  , BodyStmtTest.tests
  , ExprTest.tests
  , CorpusInvariantTest.tests
  , CorpusTest.tests
  , FileTest.tests
  , MaskTest.tests
  , PipelineTest.tests
  , RunnerTest.tests
  , SerialiseTest.tests
  , TokenTest.tests
  , SplitterTest.tests
  , StreamTest.tests
  ]
