module DuckDbTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchPath (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  )
import PB.Pipeline.SqlParse (TableRef (..))
import Database.DuckDB.Simple           (query_)
import Database.DuckDB.Simple.FromRow   (FromRow (..), field)
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
  , testCase "appendDwRetrieveWhere accepts rows"    testAppendDwRetrieveWhere
  , testCase "SchemaCategory Phase B queries round-trip Phase A appends"
      testSchemaCategoryQueryRoundTrip
  , testCase "appendSchemaObjects/Morphisms accept rows" testAppendSchemaObjectsMorphisms
  , testCase "appendDecompositionCoslice accepts rows" testAppendDecompositionCoslice
  , testCase "appendCatFootprintColumns/queryCatFootprintColumns round-trip"
      testCatFootprintColumnsRoundTrip
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

testAppendDwRetrieveWhere :: IO ()
testAppendDwRetrieveWhere = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendDwRetrieveWhere conn
    [ DwRetrieveWhereRow "d_test.srd" "d_test" 0 "misth_zpkrat.kodxrisi" "=" ":arg1" (Just "and")
    , DwRetrieveWhereRow "d_test.srd" "d_test" 1 "t.mycol" ">" "100" Nothing
    ]
  -- Appending an empty list after a real batch must not throw
  appendDwRetrieveWhere conn []

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

-- | Plan 163 Phase 3: cat_footprint_columns is a separate table from
-- sql_statement_columns but reuses the same row types on both the append
-- (SqlStmtColumnRow) and query (SqlColRow) sides -- confirms the append/
-- query round-trip works against the new table name, and that it stays
-- independent of sql_statement_columns (querySqlCols sees none of these rows).
testCatFootprintColumnsRoundTrip :: IO ()
testCatFootprintColumnsRoundTrip = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  appendCatFootprintColumns conn
    [ SqlStmtColumnRow "w_dw_copy.srw" "w_dw_copy" "clicked" 553 Nothing (Just "sales_order_items") "id" True ]
  -- Appending an empty list after a real batch must not throw
  appendCatFootprintColumns conn []

  cfCols  <- queryCatFootprintColumns conn
  sqlCols <- querySqlCols             conn

  assertEqual "cat_footprint_columns round-trip"
    [SqlColRow (SqlStmtId "w_dw_copy.srw" "w_dw_copy" "clicked" 553) Nothing (Just "sales_order_items") "id" True]
    cfCols
  assertEqual "sql_statement_columns unaffected (separate table)" [] sqlCols

-- | Local row shape for reading back (leg_kind, leg_source) pairs raw --
-- no production query function exists for schema_morphisms/
-- decomposition_coslice (Python reads them directly via SQL), so these
-- tests query_ the DuckDB connection directly rather than adding one.
data KindSourceRow = KindSourceRow Text Text deriving (Eq, Show)

instance FromRow KindSourceRow where
  fromRow = KindSourceRow <$> field <*> field

testAppendSchemaObjectsMorphisms :: IO ()
testAppendSchemaObjectsMorphisms = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      colB = ColumnObj (TableRef Nothing "b") "y"
      stmt = StmtObj (SqlStmtId "f.srf" "obj" "proc" 1)
  appendSchemaObjects conn [colA, colB, stmt]
  appendSchemaMorphisms conn
    [ SchMorphism stmt colA LegReads SrcSqlText
    , SchMorphism colA colB LegFk SrcDdlFk
    ]
  -- Appending empty lists after a real batch must not throw
  appendSchemaObjects   conn []
  appendSchemaMorphisms conn []

  rows <- query_ conn "SELECT leg_kind, leg_source FROM schema_morphisms ORDER BY leg_kind"
  assertEqual "leg_source persists per row (Plan 163 Phase 4, D3)"
    [KindSourceRow "fk" "ddl_fk", KindSourceRow "reads" "sql_text"]
    rows

testAppendDecompositionCoslice :: IO ()
testAppendDecompositionCoslice = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      stmt = SqlStmtId "f.srf" "obj" "proc" 1
      path = SchPath colA (StmtObj stmt) [ SchMorphism colA (StmtObj stmt) LegReads SrcSqlText ]
  appendDecompositionCoslice conn [ (colA, [path]) ]
  -- Appending an empty list after a real batch must not throw
  appendDecompositionCoslice conn []

  rows <- query_ conn "SELECT leg_kind, leg_source FROM decomposition_coslice"
  assertEqual "leg_source persists on decomposition_coslice rows (Plan 163 Phase 4, D3)"
    [KindSourceRow "reads" "sql_text"]
    rows
