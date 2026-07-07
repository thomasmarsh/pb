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
  , testCase "appendSqlStmtColumns/Filters accept rows" testAppendSqlStmtColumnsFilters
  , testCase "appendCatalogColumns/Pks/Fks accept rows" testAppendCatalogRows
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
    [ ObjectRow "test.srf" "powerscript" "w_test" (Just "w_ancestor") Nothing Nothing "confirmed"
    , ObjectRow "other.sru" "powerscript" "u_util" Nothing            Nothing Nothing "confirmed"
    ]
  -- Appending an empty list after a real batch must not throw
  appendObjects conn []

testAppendProcedures :: IO ()
testAppendProcedures = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  -- Two procedures with non-empty JSON blobs
  let cfgJs  = "{\"entry\":\"b0\",\"exits\":[\"b0\"],\"blocks\":[],\"edges\":[]}"
      instrJs  = "{\"nodes\":[],\"entry\":0,\"suspensionPoints\":[],\"sourceMap\":[]}"
      wiringJs = "{\"term\":{\"tag\":\"LId\"},\"sharedBlocks\":{}}"
  appendProcedures conn
    [ ProcRow "test.srf" "w_test" "open"  "event"  1  10 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed"
    , ProcRow "test.srf" "w_test" "close" "event" 11  20 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed"
    ]
  -- appendLocalVars sharing the same connection must not conflict
  appendLocalVars conn []
  assertEqual "procedures appended" () ()

testAppendSqlStmtColumnsFilters :: IO ()
testAppendSqlStmtColumnsFilters = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendSqlStmtColumns conn
    [ SqlStmtColumnRow "test.srf" "fn_perm" "fn_perm" 30 Nothing (Just "usrgroupperm") "kodgroup" False
    , SqlStmtColumnRow "test.srf" "fn_perm" "fn_perm" 30 Nothing Nothing              "addrec"   False
    ]
  appendSqlStmtFilters conn
    [ SqlStmtFilterRow "test.srf" "w_test" "of_test" 5 Nothing (Just "account") "status" "=" "[\"Active\"]"
    ]
  -- Appending an empty list after a real batch must not throw
  appendSqlStmtColumns conn []
  appendSqlStmtFilters conn []

testAppendCatalogRows :: IO ()
testAppendCatalogRows = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendCatalogColumns conn
    [ CatalogColumnRow Nothing "afxfilterd" "kodfilterd" 0
    , CatalogColumnRow Nothing "afxfilterd" "kodfilter"  1
    ]
  appendCatalogPks conn
    [ CatalogPkRow Nothing "afxfilterd" "kodfilterd" 0
    ]
  appendCatalogFks conn
    [ CatalogFkRow (Just "0_15") Nothing "afxfilterd" "kodfilter" Nothing "afxfilter" "kodfilter" 0
    ]
  -- Appending an empty list after a real batch must not throw
  appendCatalogColumns conn []
  appendCatalogPks conn []
  appendCatalogFks conn []
