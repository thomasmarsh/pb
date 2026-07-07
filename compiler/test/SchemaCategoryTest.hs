module SchemaCategoryTest (tests) where

import PB.Prelude
import PB.Analysis.SchemaCategory
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set  as Set

import Hedgehog          (Gen, assert, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (assertBool, testCase, (@?=))
import Test.Tasty.Hedgehog    (testProperty)

-- ---------------------------------------------------------------------------
-- Helpers

emptyInputs :: SchemaInputs
emptyInputs = SchemaInputs [] [] [] [] []

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
                            LegRetrieve
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
            (SchMorphism (ColumnObj (TableRef Nothing "a") "x") (StmtObj sid) LegReads
               `elem` sgLegs sch)
          assertBool "b.y leg present"
            (SchMorphism (ColumnObj (TableRef Nothing "b") "y") (StmtObj sid) LegReads
               `elem` sgLegs sch)
          assertBool "no cross-attribution a.y"
            (not (SchMorphism (ColumnObj (TableRef Nothing "a") "y") (StmtObj sid) LegReads
                    `elem` sgLegs sch))
          assertBool "no cross-attribution b.x"
            (not (SchMorphism (ColumnObj (TableRef Nothing "b") "x") (StmtObj sid) LegReads
                    `elem` sgLegs sch))

    , testCase "write column produces stmt -> column leg" $
        let sid = SqlStmtId "f.srf" "obj" "proc" 5
            inp = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ] }
            sch = buildSchema inp
        in sgLegs sch @?=
             [ SchMorphism (StmtObj sid) (ColumnObj (TableRef Nothing "account") "balance") LegWrites ]

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
                            (LegFk FkDwJoin)
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
                                  (LegFk FkDdl)
            unusedObj = ColumnObj (TableRef Nothing "usrgroupperm") "unused_col"
        in do
          assertBool "FK leg present" (fkLeg `elem` sgLegs sch)
          assertBool "catalog-only column is an object" (Set.member unusedObj (sgObjects sch))
          assertBool "catalog-only column has no legs"
            (not (any (\m -> legFrom m == unusedObj || legTo m == unusedObj) (sgLegs sch)))
    ]

  , testGroup "SchPath"
    [ testCase "composePath endpoint mismatch is Nothing" $
        let oA = ColumnObj (TableRef Nothing "a") "x"
            oB = ColumnObj (TableRef Nothing "b") "y"
            oC = ColumnObj (TableRef Nothing "c") "z"
            p  = SchPath oA oB [ SchMorphism oA oB LegReads ]
        in composePath p (idPath oC) @?= Nothing

    , testCase "idPath is left and right unit" $
        let oA = ColumnObj (TableRef Nothing "a") "x"
            oB = ColumnObj (TableRef Nothing "b") "y"
            p  = SchPath oA oB [ SchMorphism oA oB LegReads ]
        in do
          composePath (idPath oA) p @?= Just p
          composePath p (idPath oB) @?= Just p
    ]

  -- -------------------------------------------------------------------------
  -- Hedgehog properties

  , testProperty "every leg endpoint is a member of sgObjects" $ property $ do
      inp <- forAll genSchemaInputs
      let sch = buildSchema inp
      assert (all
        (\m -> Set.member (legFrom m) (sgObjects sch) && Set.member (legTo m) (sgObjects sch))
        (sgLegs sch))

  , testProperty "composePath is associative where defined" $ property $ do
      n <- forAll $ Gen.int (Range.linear 1 6)
      objs <- forAll $ Gen.list (Range.singleton (n + 1)) genObj
      let chain = objs
          legs  = [ SchMorphism a b LegReads | (a, b) <- zip chain (drop 1 chain) ]
      i <- forAll $ Gen.int (Range.linear 0 n)
      j <- forAll $ Gen.int (Range.linear i n)
      let slice lo hi = SchPath (chain !!! lo) (chain !!! hi) (take (hi - lo) (drop lo legs))
          p1 = slice 0 i
          p2 = slice i j
          p3 = slice j n
          lhs = composePath p1 p2 >>= \p12 -> composePath p12 p3
          rhs = composePath p2 p3 >>= \p23 -> composePath p1 p23
      lhs === rhs

  , testGroup "Traversal"
    [ testCase "blastRadius includes the identity path at the seed" $
        let colA = ColumnObj (TableRef Nothing "a") "x"
            sch  = buildSchema emptyInputs
        in assertBool "idPath colA present" (idPath colA `elem` blastRadius sch colA)

    , testCase "blastRadius follows a LegReads -> LegWrites two-hop chain" $
        let colA = ColumnObj (TableRef Nothing "a") "x"
            colB = ColumnObj (TableRef Nothing "b") "y"
            sid  = SqlStmtId "f.srf" "obj" "proc" 5
            inp  = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "a") "x" False  -- LegReads: colA -> stmt
                  , SqlColRow sid Nothing (Just "b") "y" True   -- LegWrites: stmt -> colB
                  ]
              }
            sch = buildSchema inp
            paths = blastRadius sch colA
            expected = SchPath colA colB
              [ SchMorphism colA (StmtObj sid) LegReads
              , SchMorphism (StmtObj sid) colB LegWrites
              ]
        in assertBool "two-hop path colA -> stmt -> colB present" (expected `elem` paths)

    , testCase "blastRadius is cycle-safe on a cyclic FK graph (terminates, no path revisits an object)" $
        let colA = ColumnObj (TableRef Nothing "a") "x"
            inp  = emptyInputs
              { inCatalogFks =
                  [ CatFkRow Nothing "a" "x" Nothing "b" "y"
                  , CatFkRow Nothing "b" "y" Nothing "a" "x"
                  ]
              }
            sch = buildSchema inp
            paths = blastRadius sch colA
            objsIn p = spFrom p : map legTo (spLegs p)
            noRevisit p = let os = objsIn p in length os == length (Set.fromList (map schObjectKey os))
        in do
          assertBool "terminates with a finite, small result" (length paths <= 4)
          assertBool "no path revisits an object" (all noRevisit paths)

    , testCase "validationWalkBack finds a direct LegWrites writer" $
        let colA = ColumnObj (TableRef Nothing "account") "balance"
            sid  = SqlStmtId "f.srf" "obj" "proc" 5
            inp  = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ] }
            sch = buildSchema inp
            expected = SchPath (StmtObj sid) colA [ SchMorphism (StmtObj sid) colA LegWrites ]
        in assertBool "writer path present" (expected `elem` validationWalkBack sch colA)

    , testCase "validationWalkBack finds a DW retrieve via LegRetrieve" $
        let colA = ColumnObj (TableRef Nothing "orders") "id"
            dwId = DwRetrieveId "d_test.srd" "d_test"
            inp  = emptyInputs
              { inDwRetrieveColumns =
                  [ DwRetrieveColRow "d_test.srd" "d_test" Nothing "orders" "id" ] }
            sch = buildSchema inp
            expected = SchPath (StmtObj dwId) colA [ SchMorphism (StmtObj dwId) colA LegRetrieve ]
        in assertBool "retrieve path present" (expected `elem` validationWalkBack sch colA)

    , testCase "validationWalkBack follows an FK chain transitively (usrgroupperm.kodaction -> usractions.kodaction shape)" $
        let colGroupPerm = ColumnObj (TableRef Nothing "usrgroupperm") "kodaction"
            colActions    = ColumnObj (TableRef Nothing "usractions") "kodaction"
            sid = SqlStmtId "f.srf" "obj" "proc" 1
            inp = emptyInputs
              { inCatalogFks =
                  [ CatFkRow Nothing "usrgroupperm" "kodaction" Nothing "usractions" "kodaction" ]
              , inSqlColumns =
                  [ SqlColRow sid Nothing (Just "usrgroupperm") "kodaction" True ]
              }
            sch = buildSchema inp
            expected = SchPath (StmtObj sid) colActions
              [ SchMorphism (StmtObj sid) colGroupPerm LegWrites
              , SchMorphism colGroupPerm colActions (LegFk FkDdl)
              ]
        in assertBool "writer-through-FK path present" (expected `elem` validationWalkBack sch colActions)

    , testCase "constraintWriters returns every StmtId reachable backward from the constraint's column" $
        let colA = ColumnObj (TableRef Nothing "account") "status"
            sid  = SqlStmtId "f.srf" "obj" "proc" 9
            dwId = DwRetrieveId "d.srd" "d_test"
            inp  = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "status" True ]
              , inDwRetrieveColumns =
                  [ DwRetrieveColRow "d.srd" "d_test" Nothing "account" "status" ]
              }
            sch = buildSchema inp
            found = constraintWriters sch constraint
            constraint = ValidationConstraint colA "status must be one of A/I/P"
        in do
          assertBool "sql writer found" (sid `elem` found)
          assertBool "dw retrieve found" (dwId `elem` found)

    , testProperty "no path from blastRadius or validationWalkBack revisits an object" $ property $ do
        inp <- forAll genSchemaInputs
        let sch = buildSchema inp
            objsIn p = spFrom p : map legTo (spLegs p)
            noRevisit p = let os = objsIn p in length os == length (Set.fromList (map schObjectKey os))
        assert (all noRevisit (concatMap (blastRadius sch) (Set.toList (sgObjects sch))))
        assert (all noRevisit (concatMap (validationWalkBack sch) (Set.toList (sgObjects sch))))

    , testProperty "every validationWalkBack path ends at the seed; every blastRadius path starts at the seed" $ property $ do
        inp <- forAll genSchemaInputs
        let sch = buildSchema inp
        assert (all (\o -> all (\p -> spTo p == o) (validationWalkBack sch o)) (Set.toList (sgObjects sch)))
        assert (all (\o -> all (\p -> spFrom p == o) (blastRadius sch o)) (Set.toList (sgObjects sch)))
    ]

  , testGroup "columnCoslice"
    [ testCase "forward-only reachable statement appears via its reads leg" $
        let colA = ColumnObj (TableRef Nothing "a") "x"
            sid  = SqlStmtId "f.srf" "obj" "proc" 5
            inp  = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "a") "x" False ] }  -- LegReads: colA -> stmt
            sch = buildSchema inp
            expected = SchPath colA (StmtObj sid) [ SchMorphism colA (StmtObj sid) LegReads ]
        in assertBool "reads-leg path present" (expected `elem` columnCoslice sch colA)

    , testCase "backward-only reachable statement appears via its writes leg" $
        let colA = ColumnObj (TableRef Nothing "account") "balance"
            sid  = SqlStmtId "f.srf" "obj" "proc" 5
            inp  = emptyInputs
              { inSqlColumns = [ SqlColRow sid Nothing (Just "account") "balance" True ] }  -- LegWrites: stmt -> colA
            sch = buildSchema inp
            expected = SchPath (StmtObj sid) colA [ SchMorphism (StmtObj sid) colA LegWrites ]
        in assertBool "writes-leg path present" (expected `elem` columnCoslice sch colA)

    , testCase "statement reachable via both forward and backward directions is deduped to one entry, the shorter path" $
        let colA = ColumnObj (TableRef Nothing "a") "x"
            sid  = SqlStmtId "f.srf" "obj" "proc" 5
            inp  = emptyInputs
              { inSqlColumns =
                  [ SqlColRow sid Nothing (Just "a") "x" False  -- LegReads: colA -> stmt (forward, 1 hop)
                  , SqlColRow sid Nothing (Just "b") "y" True   -- LegWrites: stmt -> colB (backward via FK, 2 hops)
                  ]
              , inCatalogFks =
                  [ CatFkRow Nothing "b" "y" Nothing "a" "x" ]  -- LegFk: colB -> colA
              }
            sch = buildSchema inp
            paths = columnCoslice sch colA
            matchesStmt p = case p of
              SchPath from to _ | from == colA && to == StmtObj sid -> True
              SchPath from to _ | from == StmtObj sid && to == colA -> True
              _ -> False
            shortPath = SchPath colA (StmtObj sid) [ SchMorphism colA (StmtObj sid) LegReads ]
        in do
          assertBool "exactly one entry reaches the statement" (length (filter matchesStmt paths) == 1)
          assertBool "the kept entry is the shorter (1-hop) forward path" (shortPath `elem` paths)

    , testCase "FK-chained writer two hops away (backward) is included" $
        let colGroupPerm = ColumnObj (TableRef Nothing "usrgroupperm") "kodaction"
            colActions    = ColumnObj (TableRef Nothing "usractions") "kodaction"
            sid = SqlStmtId "f.srf" "obj" "proc" 1
            inp = emptyInputs
              { inCatalogFks =
                  [ CatFkRow Nothing "usrgroupperm" "kodaction" Nothing "usractions" "kodaction" ]
              , inSqlColumns =
                  [ SqlColRow sid Nothing (Just "usrgroupperm") "kodaction" True ]
              }
            sch = buildSchema inp
            expected = SchPath (StmtObj sid) colActions
              [ SchMorphism (StmtObj sid) colGroupPerm LegWrites
              , SchMorphism colGroupPerm colActions (LegFk FkDdl)
              ]
        in assertBool "two-hop FK writer path present" (expected `elem` columnCoslice sch colActions)

    , testCase "column with no legs has an empty coslice" $
        let colA = ColumnObj (TableRef Nothing "a") "x"
            inp  = emptyInputs { inCatalogColumns = [ CatColumnRow Nothing "a" "x" ] }
            sch  = buildSchema inp
        in columnCoslice sch colA @?= []

    , testProperty "every columnCoslice entry's endpoint is a StmtObj other than the seed" $ property $ do
        inp <- forAll genSchemaInputs
        let sch = buildSchema inp
            isStmtObj (StmtObj _) = True
            isStmtObj _            = False
            endpointOf seed p
              | spFrom p == seed = spTo p
              | otherwise         = spFrom p
        assert (all
          (\seed -> all (isStmtObj . endpointOf seed) (columnCoslice sch seed))
          (Set.toList (sgObjects sch)))
    ]
  ]

-- | Total indexing for the fixed-length generated chain (avoids the banned
-- partial @(!!)@; safe because @lo@/@hi@ are always in @[0 .. length xs]@
-- by construction of the ranges above).
(!!!) :: [a] -> Int -> a
xs !!! k = case drop k xs of
  (x : _) -> x
  []      -> error "impossible: index out of range in chain generator"

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

genObj :: Gen SchObject
genObj = ColumnObj <$> (TableRef <$> genMaybeNs <*> genTableName) <*> genColName

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
  <*> Gen.list (Range.linear 0 4) genSqlColRow
  <*> Gen.list (Range.linear 0 4) genCatColumnRow
  <*> Gen.list (Range.linear 0 4) genCatFkRow
