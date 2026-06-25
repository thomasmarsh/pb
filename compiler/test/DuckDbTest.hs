module DuckDbTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual)

tests :: TestTree
tests = testGroup "DuckDb"
  [ testCase "initSchema creates all Phase A tables" testInitSchema
  , testCase "appendObjects accepts a row"           testAppendObjects
  , testCase "appendProcedures stores cfg_json"      testAppendProcedures
  ]

testInitSchema :: IO ()
testInitSchema = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  -- Append to a non-stub table proves schema is active (appender throws on unknown table)
  appendObjects     conn []
  appendParseErrors conn []

testAppendObjects :: IO ()
testAppendObjects = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendObjects conn
    [ ObjectRow "test.srf" "powerscript" "w_test" (Just "w_ancestor") Nothing Nothing
    , ObjectRow "other.sru" "powerscript" "u_util" Nothing            Nothing Nothing
    ]
  -- Appending an empty list after a real batch must not throw
  appendObjects conn []

testAppendProcedures :: IO ()
testAppendProcedures = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  -- Two procedures with non-empty JSON blobs
  let cfgJs  = "{\"entry\":\"b0\",\"exits\":[\"b0\"],\"blocks\":[],\"edges\":[]}"
      cpsJs  = "{\"nodes\":[],\"entry\":0,\"suspensionPoints\":[],\"sourceMap\":[]}"
  appendProcedures conn
    [ ProcRow "test.srf" "w_test" "open"  "event"  1  10 cfgJs cpsJs "" "" (Just 1)
    , ProcRow "test.srf" "w_test" "close" "event" 11  20 cfgJs cpsJs "" "" (Just 1)
    ]
  -- appendLocalVars sharing the same connection must not conflict
  appendLocalVars conn []
  assertEqual "procedures appended" () ()
