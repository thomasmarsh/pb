module SchemaCategoryTest (tests) where

import PB.Prelude
import PB.Analysis.SchemaCategory
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set  as Set

import Hedgehog          (Gen, assert, forAll, property)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (assertBool, testCase, (@?=))
import Test.Tasty.Hedgehog    (testProperty)

-- ---------------------------------------------------------------------------
-- Helpers

emptyInputs :: SchemaInputs
emptyInputs = SchemaInputs [] [] [] [] [] [] [] [] Nothing

tests :: TestTree
tests = testGroup "SchemaCategory"

  [ testGroup "splitColumnRef"
    [ testCase "splits on last dot incl. three-part name" $
        splitColumnRef "sales.customer.id" @?= Just (TableRef (Just "sales") "customer", "id")

    , testCase "splits simple two-part name, no namespace" $
        splitColumnRef "customer.id" @?= Just (TableRef Nothing "customer", "id")

    , testCase "returns Nothing for unqualified text" $
        splitColumnRef "id" @?= Nothing

    , testCase "returns Nothing for a trailing-dot malformed ref" $
        splitColumnRef "customer." @?= Nothing

    , testCase "lowercases the result" $
        splitColumnRef "Sales.Customer.ID" @?= Just (TableRef (Just "sales") "customer", "id")
    ]

  , testGroup "buildSchema"
    [ testCase "DW retrieve column emits LegRetrieve per qualified column" $
        let inp = emptyInputs
              { inDwRetrieveColumns =
                  [ DwRetrieveColRow "d_test.srd" "d_test" Nothing "orders" "id" ]
              }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (StmtObj (DwRetrieveId "d_test.srd" "d_test"))
                            (ColumnObj (TableRef Nothing "orders") "id")
                            LegRetrieve SrcDwRetrieve
             ]

    , testCase "DW update-table column emits LegWrites stmt -> column, tagged SrcDwRetrieve" $
        -- Plan 163 Phase 6: wiring PB.Analysis.DwFootprint.dwRetrieveFootprint's
        -- writeLegs into production. A DW's update=yes column (e.g.
        -- dw_misth_final_list.srd's `column=(... update=yes ...
        -- dbname="misth_final.kodfinal")`) must produce a LegWrites leg the
        -- same shape a PS INSERT/UPDATE statement's write column would.
        let inp = emptyInputs
              { inDwWriteColumns =
                  [ DwRetrieveColRow "d_test.srd" "d_test" Nothing "misth_final" "kodfinal" ]
              }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (StmtObj (DwRetrieveId "d_test.srd" "d_test"))
                            (ColumnObj (TableRef Nothing "misth_final") "kodfinal")
                            LegWrites SrcDwRetrieve
             ]

    , testCase "DW WHERE-operand column emits LegReads column -> stmt, tagged SrcDwWhere" $
        let inp = emptyInputs
              { inDwWhereColumns =
                  [ DwRetrieveColRow "d_test.srd" "d_test" Nothing "misth_final" "kodxrisi" ]
              }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (ColumnObj (TableRef Nothing "misth_final") "kodxrisi")
                            (StmtObj (DwRetrieveId "d_test.srd" "d_test"))
                            LegReads SrcDwWhere
             ]

    , testCase "multi-table stmt columns attributed via sql_statement_columns" $
        let sid = SqlStmtId "fn_perm.srf" "fn_perm" "fn_perm" 30
            inp = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "a") "x" False
                  , SqlColRow sid Nothing (Just "b") "y" False
                  ]
              }
            sch = buildSchema inp
        in do
          assertBool "a.x leg present"
            (SchMorphism (ColumnObj (TableRef Nothing "a") "x") (StmtObj sid) LegReads SrcSqlText
               `elem` sgLegs sch)
          assertBool "b.y leg present"
            (SchMorphism (ColumnObj (TableRef Nothing "b") "y") (StmtObj sid) LegReads SrcSqlText
               `elem` sgLegs sch)
          assertBool "no cross-attribution a.y"
            (not (SchMorphism (ColumnObj (TableRef Nothing "a") "y") (StmtObj sid) LegReads SrcSqlText
                    `elem` sgLegs sch))
          assertBool "no cross-attribution b.x"
            (not (SchMorphism (ColumnObj (TableRef Nothing "b") "x") (StmtObj sid) LegReads SrcSqlText
                    `elem` sgLegs sch))

    , testCase "write column produces stmt -> column leg" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            inp = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ] }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (StmtObj sid) (ColumnObj (TableRef Nothing "account") "balance") LegWrites SrcSqlText ]

    , testCase "stmt column with no resolved table_name produces no ColumnObj/leg" $
        let sid = SqlStmtId "fn_perm.srf" "fn_perm" "fn_perm" 30
            inp = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing Nothing "addrec" False ] }
            sch = buildSchema inp
        in do
          sgLegs sch @?= []
          sgObjects sch @?= Set.empty

    , testCase "DwJoin emits LegFk FkDwJoin column->column" $
        let inp = emptyInputs
              { inDwJoins = [ DwJoinLegRow "dw.srd" "dw_usruserperm_list" "usruserperm.kodapp" "usrapps.kodapp" ] }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (ColumnObj (TableRef Nothing "usruserperm") "kodapp")
                            (ColumnObj (TableRef Nothing "usrapps") "kodapp")
                            LegFk SrcDwJoin
             ]

    , testCase "catalog FK emits LegFk FkDdl; catalog-only columns become objects with no legs" $
        let inp = emptyInputs
              { inCatalogColumns =
                  [ CatColumnRow Nothing "usrgroupperm" "kodaction"
                  , CatColumnRow Nothing "usrgroupperm" "unused_col"
                  ]
              , inCatalogFks =
                  [ CatFkRow Nothing "usrgroupperm" "kodaction" Nothing "usractions" "kodaction" ]
              }
            sch = buildSchema inp
            fkLeg = SchMorphism (ColumnObj (TableRef Nothing "usrgroupperm") "kodaction")
                                  (ColumnObj (TableRef Nothing "usractions")   "kodaction")
                                  LegFk SrcDdlFk
            unusedObj = ColumnObj (TableRef Nothing "usrgroupperm") "unused_col"
        in do
          assertBool "FK leg present" (fkLeg `elem` sgLegs sch)
          assertBool "catalog-only column is an object" (Set.member unusedObj (sgObjects sch))
          assertBool "catalog-only column has no legs"
            (not (any (\m -> legFrom m == unusedObj || legTo m == unusedObj) (sgLegs sch)))

    , testCase "cat-footprint column produces a LegWrites morphism, same as inSqlColumns (Plan 163 Phase 3)" $
        let sid = SqlStmtId "w_dw_copy.srw" "w_dw_copy" "clicked" 553
            inp = emptyInputs
              { inCatFootprintColumns =
                  [ SqlColRow sid Nothing (Just "sales_order_items") "id" True ] }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (StmtObj sid) (ColumnObj (TableRef Nothing "sales_order_items") "id") LegWrites SrcCatFootprint ]

    , testCase "empty inCatFootprintColumns is a no-op" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            inp = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ]
              , inCatFootprintColumns = []
              }
            withoutField = emptyInputs { inSqlColumns = inSqlColumns inp }
        in do
          sgLegs    (buildSchema inp) @?= sgLegs    (buildSchema withoutField)
          sgObjects (buildSchema inp) @?= sgObjects (buildSchema withoutField)

    , testCase "cat-footprint legs resolve through the same default-namespace path as SQL legs" $
        let sid = SqlStmtId "w_dw_copy.srw" "w_dw_copy" "clicked" 553
            resolvedObj = ColumnObj (TableRef (Just "clims") "sales_order_items") "id"
            inp = emptyInputs
              { inCatFootprintColumns =
                  [ SqlColRow sid Nothing (Just "sales_order_items") "id" True ]
              , inCatalogColumns =
                  [ CatColumnRow (Just "clims") "sales_order_items" "id" ]
              , inDefaultNamespace = Just "clims"
              }
            sch = buildSchema inp
        in do
          assertBool "resolved (clims-qualified) object present"
            (Set.member resolvedObj (sgObjects sch))
          assertBool "writes leg attaches to the resolved object"
            (SchMorphism (StmtObj sid) resolvedObj LegWrites SrcCatFootprint `elem` sgLegs sch)
    ]

  , testGroup "leg_source tagging (Plan 163 Phase 4, D3)"
    [ testCase "dw_retrieve_columns row tags SrcDwRetrieve" $
        let inp = emptyInputs
              { inDwRetrieveColumns =
                  [ DwRetrieveColRow "d_test.srd" "d_test" Nothing "orders" "id" ] }
        in map legSource (sgLegs (buildSchema inp)) @?= [SrcDwRetrieve]

    , testCase "sql_statement_columns row tags SrcSqlText" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            inp = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ] }
        in map legSource (sgLegs (buildSchema inp)) @?= [SrcSqlText]

    , testCase "cat_footprint_columns row tags SrcCatFootprint" $
        let sid = SqlStmtId "w_dw_copy.srw" "w_dw_copy" "clicked" 553
            inp = emptyInputs
              { inCatFootprintColumns =
                  [ SqlColRow sid Nothing (Just "sales_order_items") "id" True ] }
        in map legSource (sgLegs (buildSchema inp)) @?= [SrcCatFootprint]

    , testCase "dw_joins row tags SrcDwJoin" $
        let inp = emptyInputs
              { inDwJoins = [ DwJoinLegRow "dw.srd" "dw_usruserperm_list" "usruserperm.kodapp" "usrapps.kodapp" ] }
        in map legSource (sgLegs (buildSchema inp)) @?= [SrcDwJoin]

    , testCase "catalog_fks row tags SrcDdlFk" $
        let inp = emptyInputs
              { inCatalogFks =
                  [ CatFkRow Nothing "usrgroupperm" "kodaction" Nothing "usractions" "kodaction" ] }
        in map legSource (sgLegs (buildSchema inp)) @?= [SrcDdlFk]
    ]

  , testGroup "resolveTableRef"
    [ testCase "catalogNamespacedTables restricts to Just-namespace rows" $
        catalogNamespacedTables
          [ CatColumnRow (Just "clims") "account" "id"
          , CatColumnRow Nothing "orphan" "id"
          , CatColumnRow (Just "clims") "account" "balance"
          ]
          @?= Set.fromList [("clims", "account")]

    , testCase "already-qualified ref passes through unchanged regardless of catalog" $
        resolveTableRef (Set.fromList [("clims", "account")]) (Just "clims")
          (TableRef (Just "other") "account")
          @?= TableRef (Just "other") "account"

    , testCase "unqualified ref resolves against a matching catalog entry" $
        resolveTableRef (Set.fromList [("clims", "account")]) (Just "clims")
          (TableRef Nothing "account")
          @?= TableRef (Just "clims") "account"

    , testCase "unqualified ref with no catalog entry under default namespace stays unresolved" $
        resolveTableRef (Set.fromList [("clims", "other")]) (Just "clims")
          (TableRef Nothing "account")
          @?= TableRef Nothing "account"

    , testCase "no default namespace leaves unqualified ref unchanged" $
        resolveTableRef (Set.fromList [("clims", "account")]) Nothing
          (TableRef Nothing "account")
          @?= TableRef Nothing "account"

    , testCase "default namespace comparison is case-insensitive against the lowercase catalog" $
        resolveTableRef (Set.fromList [("clims", "account")]) (Just "CLIMS")
          (TableRef Nothing "account")
          @?= TableRef (Just "clims") "account"
    ]

  , testGroup "defaultNamespace"
    [ testCase "unqualified SQL column unifies with catalog-only ColumnObj under matching default namespace" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            resolvedObj = ColumnObj (TableRef (Just "clims") "clinicalaccession") "id"
            inp = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "clinicalaccession") "id" False ]
              , inCatalogColumns =
                  [ CatColumnRow (Just "clims") "clinicalaccession" "id" ]
              , inDefaultNamespace = Just "clims"
              }
            sch = buildSchema inp
        in do
          assertBool "resolved (clims-qualified) object present"
            (Set.member resolvedObj (sgObjects sch))
          assertBool "no unresolved (unqualified) duplicate object"
            (not (Set.member (ColumnObj (TableRef Nothing "clinicalaccession") "id") (sgObjects sch)))
          assertBool "reads leg attaches to the resolved object"
            (SchMorphism resolvedObj (StmtObj sid) LegReads SrcSqlText `elem` sgLegs sch)

    , testCase "unqualified ref stays unresolved when default namespace's catalog has no matching table" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            unresolvedObj = ColumnObj (TableRef Nothing "orphan_table") "id"
            inp = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "orphan_table") "id" False ]
              , inCatalogColumns =
                  [ CatColumnRow (Just "clims") "other_table" "id" ]
              , inDefaultNamespace = Just "clims"
              }
            sch = buildSchema inp
        in do
          assertBool "unresolved object present"
            (Set.member unresolvedObj (sgObjects sch))
          assertBool "reads leg attaches to the unresolved object"
            (SchMorphism unresolvedObj (StmtObj sid) LegReads SrcSqlText `elem` sgLegs sch)

    , testCase "no default namespace configured leaves TableRef Nothing unchanged (regression pin)" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            inp = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ]
              , inCatalogColumns = [ CatColumnRow (Just "clims") "account" "balance" ]
              , inDefaultNamespace = Nothing
              }
            sch = buildSchema inp
        in assertBool "leg still targets the unqualified (Nothing-namespace) object"
             (SchMorphism (StmtObj sid) (ColumnObj (TableRef Nothing "account") "balance") LegWrites SrcSqlText
                `elem` sgLegs sch)

    , testCase "table defined in multiple namespaces: only the default-namespace copy absorbs unqualified legs" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            resolvedObj    = ColumnObj (TableRef (Just "clims") "clinicalaccession") "id"
            commonObj      = ColumnObj (TableRef (Just "clims_common") "clinicalaccession") "id"
            archiveObj     = ColumnObj (TableRef (Just "clims_archive") "clinicalaccession") "id"
            inp = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "clinicalaccession") "id" False ]
              , inCatalogColumns =
                  [ CatColumnRow (Just "clims") "clinicalaccession" "id"
                  , CatColumnRow (Just "clims_common") "clinicalaccession" "id"
                  , CatColumnRow (Just "clims_archive") "clinicalaccession" "id"
                  ]
              , inDefaultNamespace = Just "clims"
              }
            sch = buildSchema inp
            hasLegTo o = any (\m -> legTo m == o || legFrom m == o) (sgLegs sch)
        in do
          assertBool "default-namespace copy absorbs the unqualified leg"
            (SchMorphism resolvedObj (StmtObj sid) LegReads SrcSqlText `elem` sgLegs sch)
          assertBool "clims_common copy has no legs" (not (hasLegTo commonObj))
          assertBool "clims_archive copy has no legs" (not (hasLegTo archiveObj))

    , testCase "default namespace resolves case-insensitively against the (always-lowercase) catalog" $
        -- Regression: --default-namespace is a raw CLI value with no
        -- upstream case normalization, while catalog_columns.namespace is
        -- always lowercased by ddl.py's _table_ident regardless of --ddl
        -- tag casing. A user typing --default-namespace CLIMS (the plan's
        -- own motivating example) against a lowercase-derived "clims"
        -- catalog must still resolve — found via a real multi-schema
        -- reindex (Plan 157 Phase 4/5), not by this test suite originally.
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            resolvedObj = ColumnObj (TableRef (Just "clims") "clinicalaccession") "id"
            inp = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "clinicalaccession") "id" False ]
              , inCatalogColumns =
                  [ CatColumnRow (Just "clims") "clinicalaccession" "id" ]
              , inDefaultNamespace = Just "CLIMS"
              }
            sch = buildSchema inp
        in assertBool "resolves despite --default-namespace CLIMS vs. catalog's lowercase clims"
             (SchMorphism resolvedObj (StmtObj sid) LegReads SrcSqlText `elem` sgLegs sch)
    ]

  -- -------------------------------------------------------------------------
  -- Hedgehog properties

  , testProperty "every leg endpoint is a member of sgObjects" $ property $ do
      inp <- forAll genSchemaInputs
      let sch = buildSchema inp
      assert (all
        (\m -> Set.member (legFrom m) (sgObjects sch) && Set.member (legTo m) (sgObjects sch))
        (sgLegs sch))
  ]

-- ---------------------------------------------------------------------------
-- Generators

genName :: [Text] -> Gen Text
genName = Gen.element

genTableName :: Gen Text
genTableName = genName ["orders", "customers", "line_item"]

genColName :: Gen Text
genColName = genName ["id", "name", "status"]

genMaybeNs :: Gen (Maybe Text)
genMaybeNs = Gen.maybe (genName ["sales", "hr"])

genFileName :: Gen Text
genFileName = genName ["a.srd", "b.srd", "c.srf"]

genDwName :: Gen Text
genDwName = genName ["d_one", "d_two"]

genStmtId :: Gen StmtId
genStmtId = SqlStmtId <$> genFileName <*> genName ["obj1", "obj2"] <*> genName ["p1", "p2"] <*> Gen.int (Range.linear 1 100)

genDwRetrieveColRow :: Gen DwRetrieveColRow
genDwRetrieveColRow =
  DwRetrieveColRow <$> genFileName <*> genDwName <*> genMaybeNs <*> genTableName <*> genColName

genDwJoinLegRow :: Gen DwJoinLegRow
genDwJoinLegRow = do
  f   <- genFileName
  dw  <- genDwName
  lt  <- genTableName
  lc  <- genColName
  rt  <- genTableName
  rc  <- genColName
  pure (DwJoinLegRow f dw (lt <> "." <> lc) (rt <> "." <> rc))

genSqlColRow :: Gen SqlColRow
genSqlColRow =
  SqlColRow <$> genStmtId <*> genMaybeNs <*> Gen.maybe genTableName <*> genColName <*> Gen.bool

genCatColumnRow :: Gen CatColumnRow
genCatColumnRow = CatColumnRow <$> genMaybeNs <*> genTableName <*> genColName

genCatFkRow :: Gen CatFkRow
genCatFkRow =
  CatFkRow <$> genMaybeNs <*> genTableName <*> genColName <*> genMaybeNs <*> genTableName <*> genColName

genSchemaInputs :: Gen SchemaInputs
genSchemaInputs = SchemaInputs
  <$> Gen.list (Range.linear 0 4) genDwRetrieveColRow
  <*> Gen.list (Range.linear 0 4) genDwJoinLegRow
  <*> Gen.list (Range.linear 0 4) genDwRetrieveColRow
  <*> Gen.list (Range.linear 0 4) genDwRetrieveColRow
  <*> Gen.list (Range.linear 0 4) genSqlColRow
  <*> Gen.list (Range.linear 0 4) genSqlColRow
  <*> Gen.list (Range.linear 0 4) genCatColumnRow
  <*> Gen.list (Range.linear 0 4) genCatFkRow
  <*> genMaybeNs
