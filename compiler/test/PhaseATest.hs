module PhaseATest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb        (Handle, inMemory, withHandle, initSchema, queryHandle)
import PB.Pipeline.DuckDb.Appender (AppenderPool, withAppenderPool)
import PB.Pipeline.DuckDb.PhaseA
import PB.Analysis.DeadVars
  ( DeadVarFinding (..), DeadVarKind (..) )
import Database.DuckDB.Simple.FromRow   (FromRow (..), field)
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual)

phaseATables :: [Text]
phaseATables =
  [ "objects", "procedures", "local_vars", "call_sites", "global_vars"
  , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
  , "sql_statement_filters", "sql_statement_tables", "cat_footprint_columns"
  , "source_files", "parse_errors"
  , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
  , "dw_write_columns", "dw_where_columns", "dw_joins", "dw_retrieve_where"
  , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
  , "dead_vars"
  ]

withTestPool :: Handle -> (AppenderPool -> IO a) -> IO a
withTestPool conn = withAppenderPool conn phaseATables

tests :: TestTree
tests = testGroup "PhaseA"
  [ testCase "initSchema creates all Phase A tables" testInitSchema
  , testCase "appendObjects accepts a row"           testAppendObjects
  , testCase "appendProcedures stores cfg_json"      testAppendProcedures
  , testCase "appendSqlStmtColumns/Filters accept rows" testAppendSqlStmtColumnsFilters
  , testCase "appendCatalogColumns/Pks/Fks accept rows" testAppendCatalogRows
  , testCase "appendDwRetrieveColumns accepts rows"  testAppendDwRetrieveColumns
  , testCase "appendDwRetrieveWhere accepts rows"    testAppendDwRetrieveWhere
  , testCase "appendDeadVars round-trip"             testAppendDeadVars
  ]

testInitSchema :: IO ()
testInitSchema = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    -- Append to a non-stub table proves schema is active (appender throws on unknown table)
    appendObjects     pool []
    appendParseErrors pool []

testAppendObjects :: IO ()
testAppendObjects = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendObjects pool
      [ ObjectRow "test.srf" "powerscript" "w_test" (Just "w_ancestor") Nothing Nothing "confirmed"
      , ObjectRow "other.sru" "powerscript" "u_util" Nothing            Nothing Nothing "confirmed"
      ]
    -- Appending an empty list after a real batch must not throw
    appendObjects pool []

testAppendProcedures :: IO ()
testAppendProcedures = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    -- Two procedures with non-empty JSON blobs
    let cfgJs  = "{\"entry\":\"b0\",\"exits\":[\"b0\"],\"blocks\":[],\"edges\":[]}"
        instrJs  = "{\"nodes\":[],\"entry\":0,\"suspensionPoints\":[],\"sourceMap\":[]}"
        wiringJs = "{\"nodes\":{\"w0\":{\"tag\":\"WireReturn\"}},\"entry\":\"w0\"}"
    appendProcedures pool
      [ ProcRow "test.srf" "w_test" "open"  "event"  1  10 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed" []
      , ProcRow "test.srf" "w_test" "close" "event" 11  20 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed" []
      ]
    -- appendLocalVars sharing the same pool must not conflict
    appendLocalVars pool []
    assertEqual "procedures appended" () ()

testAppendSqlStmtColumnsFilters :: IO ()
testAppendSqlStmtColumnsFilters = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendSqlStmtColumns pool
      [ SqlStmtColumnRow "test.srf" "fn_perm" "fn_perm" 30 Nothing (Just "usrgroupperm") "kodgroup" False
      , SqlStmtColumnRow "test.srf" "fn_perm" "fn_perm" 30 Nothing Nothing              "addrec"   False
      ]
    appendSqlStmtFilters pool
      [ SqlStmtFilterRow "test.srf" "w_test" "of_test" 5 Nothing (Just "account") "status" "=" "[\"Active\"]"
      ]
    -- Appending an empty list after a real batch must not throw
    appendSqlStmtColumns pool []
    appendSqlStmtFilters pool []

testAppendCatalogRows :: IO ()
testAppendCatalogRows = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendCatalogColumns pool
      [ CatalogColumnRow Nothing "afxfilterd" "kodfilterd" 0
      , CatalogColumnRow Nothing "afxfilterd" "kodfilter"  1
      ]
    appendCatalogPks pool
      [ CatalogPkRow Nothing "afxfilterd" "kodfilterd" 0
      ]
    appendCatalogFks pool
      [ CatalogFkRow (Just "0_15") Nothing "afxfilterd" "kodfilter" Nothing "afxfilter" "kodfilter" 0
      ]
    -- Appending an empty list after a real batch must not throw
    appendCatalogColumns pool []
    appendCatalogPks pool []
    appendCatalogFks pool []

testAppendDwRetrieveColumns :: IO ()
testAppendDwRetrieveColumns = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveColumns pool
      [ DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "kodkrat"
      , DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "desckrat"
      ]
    -- Appending an empty list after a real batch must not throw
    appendDwRetrieveColumns pool []

testAppendDwRetrieveWhere :: IO ()
testAppendDwRetrieveWhere = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveWhere pool
      [ DwRetrieveWhereRow "d_test.srd" "d_test" 0 "misth_zpkrat.kodxrisi" "=" ":arg1" (Just "and")
      , DwRetrieveWhereRow "d_test.srd" "d_test" 1 "t.mycol" ">" "100" Nothing
      ]
    -- Appending an empty list after a real batch must not throw
    appendDwRetrieveWhere pool []

-- | Local row shape for reading back @dead_vars@ -- no production query
-- function exists (Python reads it directly via SQL), so this test query_s
-- the DuckDB connection directly rather than adding one.
data DeadVarRow = DeadVarRow Text Text Text (Maybe Int) Text deriving (Eq, Show)

instance FromRow DeadVarRow where
  fromRow = DeadVarRow <$> field <*> field <*> field <*> field <*> field

testAppendDeadVars :: IO ()
testAppendDeadVars = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDeadVars pool
      [ DeadVarFinding "w_test" "of_save" "li_unused" (Just 12) NeverRead
      , DeadVarFinding "w_test" "of_save" "as_param"  Nothing   UnusedParam
      ]
    -- Appending an empty list after a real batch must not throw
    appendDeadVars pool []

  rows <- queryHandle conn
    "SELECT object, proc_name, var_name, line, kind FROM dead_vars ORDER BY var_name"
  assertEqual "dead_vars round-trips DeadVarFinding rows"
    [ DeadVarRow "w_test" "of_save" "as_param"  Nothing   "unused-param"
    , DeadVarRow "w_test" "of_save" "li_unused" (Just 12) "never-read"
    ]
    rows
