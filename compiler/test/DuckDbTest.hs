module DuckDbTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), FkSource (..), SchMorphism (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  )
import PB.Pipeline.SqlParse (TableRef (..))
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual)

tests :: TestTree
tests = testGroup "DuckDb"
  [ testCase "initSchema creates all Phase A tables" testInitSchema
  , testCase "appendObjects accepts a row"           testAppendObjects
  , testCase "appendProcedures stores cfg_json"      testAppendProcedures
  , testCase "appendSqlStmtColumns/Filters accept rows" testAppendSqlStmtColumnsFilters
  , testCase "appendCatalogColumns/Pks/Fks accept rows" testAppendCatalogRows
  , testCase "appendDwRetrieveColumns accepts rows"  testAppendDwRetrieveColumns
  , testCase "SchemaCategory Phase B queries round-trip Phase A appends"
      testSchemaCategoryQueryRoundTrip
  , testCase "appendSchemaObjects/Morphisms accept rows" testAppendSchemaObjectsMorphisms
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

testAppendDwRetrieveColumns :: IO ()
testAppendDwRetrieveColumns = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendDwRetrieveColumns conn
    [ DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "kodkrat"
    , DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "desckrat"
    ]
  -- Appending an empty list after a real batch must not throw
  appendDwRetrieveColumns conn []

-- | Plan 148 Phase 1b: appends via the Phase A row types, queries back via
-- the new SchemaCategory read-side query functions, and confirms the
-- FromRow instances reconstruct the same values (column-order mismatches
-- between the append and query sides would silently corrupt data here).
testSchemaCategoryQueryRoundTrip :: IO ()
testSchemaCategoryQueryRoundTrip = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendDwRetrieveColumns conn
    [ DwRetrieveColumnRow "d_test.srd" "d_test" (Just "sales") "orders" "id" ]
  appendDwJoins conn
    [ DwJoinRow "d_test.srd" "d_test" "usruserperm.kodapp" "=" "usrapps.kodapp" Nothing Nothing ]
  appendSqlStmtColumns conn
    [ SqlStmtColumnRow "fn_perm.srf" "fn_perm" "fn_perm" 30 Nothing (Just "usrgroupperm") "kodgroup" False ]
  appendCatalogColumns conn
    [ CatalogColumnRow Nothing "afxfilterd" "kodfilterd" 0 ]
  appendCatalogFks conn
    [ CatalogFkRow (Just "0_15") Nothing "afxfilterd" "kodfilter" Nothing "afxfilter" "kodfilter" 0 ]

  drCols  <- queryDwRetrieveColumns conn
  djLegs  <- queryDwJoinLegs        conn
  sqlCols <- querySqlCols           conn
  catCols <- queryCatColumns        conn
  catFks  <- queryCatFks            conn

  assertEqual "dw_retrieve_columns round-trip"
    [DwRetrieveColRow "d_test.srd" "d_test" (Just "sales") "orders" "id"] drCols
  assertEqual "dw_joins round-trip"
    [DwJoinLegRow "d_test.srd" "d_test" "usruserperm.kodapp" "usrapps.kodapp"] djLegs
  assertEqual "sql_statement_columns round-trip"
    [SqlColRow (SqlStmtId "fn_perm.srf" "fn_perm" "fn_perm" 30) Nothing (Just "usrgroupperm") "kodgroup" False]
    sqlCols
  assertEqual "catalog_columns round-trip"
    [CatColumnRow Nothing "afxfilterd" "kodfilterd"] catCols
  assertEqual "catalog_fks round-trip"
    [CatFkRow Nothing "afxfilterd" "kodfilter" Nothing "afxfilter" "kodfilter"] catFks

testAppendSchemaObjectsMorphisms :: IO ()
testAppendSchemaObjectsMorphisms = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      colB = ColumnObj (TableRef Nothing "b") "y"
      stmt = StmtObj (SqlStmtId "f.srf" "obj" "proc" 1)
  appendSchemaObjects conn [colA, colB, stmt]
  appendSchemaMorphisms conn
    [ SchMorphism stmt colA LegReads
    , SchMorphism colA colB (LegFk FkDdl)
    ]
  -- Appending empty lists after a real batch must not throw
  appendSchemaObjects   conn []
  appendSchemaMorphisms conn []
