module PhaseBQueryTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb        (Handle, inMemory, withHandle, initSchema)
import PB.Pipeline.DuckDb.Appender (AppenderPool, withAppenderPool)
import PB.Pipeline.DuckDb.PhaseA
import PB.Pipeline.DuckDb.PhaseB.Query
import PB.AST.Ident              (mkIdentAt)
import PB.AST.Type                (PbType (..), pbTypeSpan)
import PB.Analysis.SchemaCategory
  ( StmtId (..)
  , DwRetrieveColRow (..), DwJoinLegRow (..), SqlColRow (..)
  , CatColumnRow (..), CatFkRow (..)
  )
import PB.Analysis.TypeResolve   (LocalVar (..), GlobalVar (..))
import PB.Lexing.Token            (SourceSpan (..))
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (assertFailure, testCase, assertEqual, (@?=))

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
tests = testGroup "PhaseB.Query"
  [ testCase "SchemaCategory Phase B queries round-trip Phase A appends"
      testSchemaCategoryQueryRoundTrip
  , testCase "appendCatFootprintColumns/queryCatFootprintColumns round-trip"
      testCatFootprintColumnsRoundTrip
  , testCase "appendLocalVars/queryLocalVars round-trips a user-defined type's own span"
      testLocalVarTypeSpanRoundTrip
  , testCase "appendGlobalVars/queryGlobalVars round-trips a user-defined type's own span"
      testGlobalVarTypeSpanRoundTrip
  ]

-- | Plan 196 Phase 2: a 'PtUserDefined' type's declared-type token span
-- must survive the local_vars/global_vars DB round trip, not just the
-- in-memory Phase A row -- confirms the additive type_start_line/col
-- columns and the 'FromRow' reconstruction via 'parseTypeTextAt' actually
-- wire together, not just that each half compiles in isolation.
testLocalVarTypeSpanRoundTrip :: IO ()
testLocalVarTypeSpanRoundTrip = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool ->
    appendLocalVars pool
      [ LocalVar
          { lvFile = "t.srw", lvObject = "w_test", lvProcName = "of_run"
          , lvVarName = "lw_child", lvRawType = "w_child", lvIsParam = False
          , lvScopeLine = 3
          , lvPbType = PtUserDefined (mkIdentAt (SourceSpan 3 10 3 17) "w_child")
          }
      , LocalVar
          { lvFile = "t.srw", lvObject = "w_test", lvProcName = "of_run"
          , lvVarName = "li_count", lvRawType = "integer", lvIsParam = False
          , lvScopeLine = 4, lvPbType = PtPrimitive "integer"
          }
      ]

  lvs <- queryLocalVars conn
  case [lv | lv <- lvs, lvVarName lv == "lw_child"] of
    [lv] -> pbTypeSpan (lvPbType lv) @?= Just (SourceSpan 3 10 3 17)
    other -> assertFailure ("expected exactly 1 lw_child row, got " ++ show (length other))
  case [lv | lv <- lvs, lvVarName lv == "li_count"] of
    [lv] -> pbTypeSpan (lvPbType lv) @?= Nothing
    other -> assertFailure ("expected exactly 1 li_count row, got " ++ show (length other))

testGlobalVarTypeSpanRoundTrip :: IO ()
testGlobalVarTypeSpanRoundTrip = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool ->
    appendGlobalVars pool
      [ GlobalVar
          { gvFile = "t.srw", gvObject = "w_test", gvName = "iw_child"
          , gvType = "w_child", gvMods = []
          , gvPbType = PtUserDefined (mkIdentAt (SourceSpan 8 3 8 10) "w_child")
          }
      ]

  gvs <- queryGlobalVars conn
  case gvs of
    [gv] -> pbTypeSpan (gvPbType gv) @?= Just (SourceSpan 8 3 8 10)
    other -> assertFailure ("expected exactly 1 row, got " ++ show (length other))

-- | Plan 148 Phase 1b: appends via the Phase A row types, queries back via
-- the new SchemaCategory read-side query functions, and confirms the
-- FromRow instances reconstruct the same values (column-order mismatches
-- between the append and query sides would silently corrupt data here).
testSchemaCategoryQueryRoundTrip :: IO ()
testSchemaCategoryQueryRoundTrip = withHandle inMemory $ \conn -> do
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
testCatFootprintColumnsRoundTrip = withHandle inMemory $ \conn -> do
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
