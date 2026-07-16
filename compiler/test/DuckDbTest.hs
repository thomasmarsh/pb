module DuckDbTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  , schObjectKey
  )
import PB.Pipeline.SqlParse (TableRef (..))
import Database.DuckDB.Simple           (Query (..), execute_, query_)
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
  ]

withTestPool :: DuckConn -> (AppenderPool -> IO a) -> IO a
withTestPool conn = withAppenderPool conn phaseATables

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
  , testCase "materializeDecompositionCoslice projects path_leg + recovers leg_source" testMaterializeDecompositionCoslice
  , testCase "materializeImpliedFk decodes ColKey pairs to namespace/table/column" testMaterializeImpliedFk
  , testCase "materializeColumnRisk decodes ColKeys, excluding non-column (stmt) nodes" testMaterializeColumnRisk
  , testCase "appendCatFootprintColumns/queryCatFootprintColumns round-trip"
      testCatFootprintColumnsRoundTrip
  ]

testInitSchema :: IO ()
testInitSchema = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    -- Append to a non-stub table proves schema is active (appender throws on unknown table)
    appendObjects     pool []
    appendParseErrors pool []

testAppendObjects :: IO ()
testAppendObjects = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendObjects pool
      [ ObjectRow "test.srf" "powerscript" "w_test" (Just "w_ancestor") Nothing Nothing "confirmed"
      , ObjectRow "other.sru" "powerscript" "u_util" Nothing            Nothing Nothing "confirmed"
      ]
    -- Appending an empty list after a real batch must not throw
    appendObjects pool []

testAppendProcedures :: IO ()
testAppendProcedures = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    -- Two procedures with non-empty JSON blobs
    let cfgJs  = "{\"entry\":\"b0\",\"exits\":[\"b0\"],\"blocks\":[],\"edges\":[]}"
        instrJs  = "{\"nodes\":[],\"entry\":0,\"suspensionPoints\":[],\"sourceMap\":[]}"
        wiringJs = "{\"nodes\":{\"w0\":{\"tag\":\"WireReturn\"}},\"entry\":\"w0\"}"
    appendProcedures pool
      [ ProcRow "test.srf" "w_test" "open"  "event"  1  10 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed"
      , ProcRow "test.srf" "w_test" "close" "event" 11  20 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed"
      ]
    -- appendLocalVars sharing the same pool must not conflict
    appendLocalVars pool []
    assertEqual "procedures appended" () ()

testAppendSqlStmtColumnsFilters :: IO ()
testAppendSqlStmtColumnsFilters = withWriteConn ":memory:" $ \conn -> do
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
testAppendCatalogRows = withWriteConn ":memory:" $ \conn -> do
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
testAppendDwRetrieveColumns = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveColumns pool
      [ DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "kodkrat"
      , DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "desckrat"
      ]
    -- Appending an empty list after a real batch must not throw
    appendDwRetrieveColumns pool []

testAppendDwRetrieveWhere :: IO ()
testAppendDwRetrieveWhere = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveWhere pool
      [ DwRetrieveWhereRow "d_test.srd" "d_test" 0 "misth_zpkrat.kodxrisi" "=" ":arg1" (Just "and")
      , DwRetrieveWhereRow "d_test.srd" "d_test" 1 "t.mycol" ">" "100" Nothing
      ]
    -- Appending an empty list after a real batch must not throw
    appendDwRetrieveWhere pool []

-- | Plan 148 Phase 1b: appends via the Phase A row types, queries back via
-- the new SchemaCategory read-side query functions, and confirms the
-- FromRow instances reconstruct the same values (column-order mismatches
-- between the append and query sides would silently corrupt data here).
testSchemaCategoryQueryRoundTrip :: IO ()
testSchemaCategoryQueryRoundTrip = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveColumns pool
      [ DwRetrieveColumnRow "d_test.srd" "d_test" (Just "sales") "orders" "id" ]
    appendDwJoins pool
      [ DwJoinRow "d_test.srd" "d_test" "usruserperm.kodapp" "=" "usrapps.kodapp" Nothing Nothing ]
    appendSqlStmtColumns pool
      [ SqlStmtColumnRow "fn_perm.srf" "fn_perm" "fn_perm" 30 Nothing (Just "usrgroupperm") "kodgroup" False ]
    appendCatalogColumns pool
      [ CatalogColumnRow Nothing "afxfilterd" "kodfilterd" 0 ]
    appendCatalogFks pool
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
  withTestPool conn $ \pool -> do
    appendCatFootprintColumns pool
      [ SqlStmtColumnRow "w_dw_copy.srw" "w_dw_copy" "clicked" 553 Nothing (Just "sales_order_items") "id" True ]
    -- Appending an empty list after a real batch must not throw
    appendCatFootprintColumns pool []

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

testMaterializeDecompositionCoslice :: IO ()
testMaterializeDecompositionCoslice = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  -- Seed the inputs materializeDecompositionCoslice reads from: a stmt target,
  -- the morphism (leg_source recovery), and a forward path_leg row (seed -> stmt).
  let colAKey = "col:a.x"
      stmtKey = "stmt:sql:f.srf:obj:proc:1"
  appendSchemaObjects conn [ ColumnObj (TableRef Nothing "a") "x"
                           , StmtObj (SqlStmtId "f.srf" "obj" "proc" 1) ]
  appendSchemaMorphisms conn [ SchMorphism (ColumnObj (TableRef Nothing "a") "x")
                               (StmtObj (SqlStmtId "f.srf" "obj" "proc" 1))
                               LegReads SrcSqlText ]
  -- Simulate the Souffle path_leg_fwd output table (materialized by runRuleSet).
  -- recreateTextTable + appendTextRows would be the production path; here the
  -- SQL projection is what's under test, so we hand-create the table.
  void $ execute_ conn (Query "CREATE TABLE path_leg_fwd (s TEXT, target TEXT, leg_ord TEXT, lf TEXT, lt TEXT, kind TEXT)")
  void $ execute_ conn (Query ("INSERT INTO path_leg_fwd VALUES ('"
    <> colAKey <> "', '" <> stmtKey <> "', '0', '" <> colAKey <> "', '" <> stmtKey <> "', 'reads')"))
  void $ execute_ conn (Query "CREATE TABLE path_leg_back (s TEXT, target TEXT, leg_ord TEXT, lf TEXT, lt TEXT, kind TEXT)")
  materializeDecompositionCoslice conn

  rows <- query_ conn "SELECT leg_kind, leg_source FROM decomposition_coslice"
  assertEqual "leg_source recovered via schema_morphisms join (Plan 161 Phase 2c)"
    [KindSourceRow "reads" "sql_text"]
    rows

-- | Local row shape for reading back (from_table, from_column, to_table,
-- to_column) from @implied_fk@.
data FkPairRow = FkPairRow Text Text Text Text deriving (Eq, Show)

instance FromRow FkPairRow where
  fromRow = FkPairRow <$> field <*> field <*> field <*> field

testMaterializeImpliedFk :: IO ()
testMaterializeImpliedFk = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      colB = ColumnObj (TableRef Nothing "b") "y"
  appendSchemaObjects conn [colA, colB]
  -- Simulate Souffle's implied_fk_pairs output (materialized by runRuleSet
  -- via recreateTextTable/appendTextRows in production).
  void $ execute_ conn (Query "CREATE TABLE implied_fk_pairs (x TEXT, y TEXT)")
  void $ execute_ conn (Query ("INSERT INTO implied_fk_pairs VALUES ('"
    <> schObjectKey colA <> "', '" <> schObjectKey colB <> "')"))
  materializeImpliedFk conn

  rows <- query_ conn
    "SELECT from_table, from_column, to_table, to_column FROM implied_fk"
  assertEqual "ColKey pair decoded to human-readable table/column names"
    [FkPairRow "a" "x" "b" "y"]
    rows

-- | Local row shape for reading back (table_name, column_name,
-- downstream_count) from @column_risk@.
data RiskRow = RiskRow Text Text Int deriving (Eq, Show)

instance FromRow RiskRow where
  fromRow = RiskRow <$> field <*> field <*> field

testMaterializeColumnRisk :: IO ()
testMaterializeColumnRisk = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      stmt = StmtObj (SqlStmtId "f.srf" "obj" "proc" 1)
  appendSchemaObjects conn [colA, stmt]
  -- Simulate Souffle's risk_count output: one column node, one stmt node --
  -- the stmt row exercises the kind = 'column' filter (a real bug found on
  -- the openpay corpus: schema_objects has no namespace/table_name/
  -- column_name for stmt/dw_retrieve kinds, so an unfiltered join
  -- materialized 115 opaque all-NULL rows there).
  void $ execute_ conn (Query "CREATE TABLE risk_count (x TEXT, n TEXT)")
  void $ execute_ conn (Query ("INSERT INTO risk_count VALUES ('"
    <> schObjectKey colA <> "', '3'), ('" <> schObjectKey stmt <> "', '7')"))
  materializeColumnRisk conn

  rows <- query_ conn "SELECT table_name, column_name, downstream_count FROM column_risk"
  assertEqual "only the column-kind node is materialized, with its count"
    [RiskRow "a" "x" 3]
    rows
