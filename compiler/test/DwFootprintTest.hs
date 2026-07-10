module DwFootprintTest (tests) where

import PB.Prelude
import PB.AST.DataWindow      (DwTable (..), DwColumn (..), DwRetrieve (..), DwRetrieveOrRaw (..),
                                DwWhereClause (..), DwJoin (..))
import PB.AST.Expr            (Expr (..), Lvalue (..), LvSegment (..))
import PB.Analysis.DwFootprint
import PB.Analysis.SchemaCategory (SchMorphism (..), SchObject (..), StmtId (..), LegKind (..),
                                    FkSource (..), CatColumnRow (..))
import PB.Grammar.DataWindow  (parsePbSelect)
import PB.Pipeline.SqlParse   (TableRef (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures

emptyRetrieve :: DwRetrieve
emptyRetrieve = DwRetrieve
  { drVersion = 400, drTables = [], drColumns = [], drArguments = [], drWhere = [], drJoins = [] }

mkTable :: DwRetrieve -> [DwColumn] -> DwTable
mkTable r cols = DwTable
  { dtColumns = cols, dtRetrieve = Just (DwRetrieveOk r)
  , dtUpdate = Nothing, dtUpdateWhere = Nothing, dtArguments = []
  }

writeColumn :: DwColumn
writeColumn = DwColumn
  { dcName = "kodfinal", dcType = "decimal(0)", dcDbName = Just "misth_final.kodfinal"
  , dcUpdate = True, dcKey = True, dcUpdateWhere = True, dcDddwName = Nothing, dcAttrs = Map.empty
  }

ctx0 :: DwFootprintCtx
ctx0 = mkDwFootprintCtx [] Nothing

stmt1 :: SchObject
stmt1 = StmtObj (DwRetrieveId "f.srd" "dw1")

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "DwFootprint"
  [ testGroup "lvalueColumnRef"
      [ testCase "two-segment lvalue -> Just (table, column)" $
          lvalueColumnRef (ExLvalue (Lvalue [LvSegment "t" Nothing, LvSegment "c" Nothing]))
            @?= Just (TableRef Nothing "t", "c")

      , testCase "three-segment lvalue -> Just (namespace-qualified table, column)" $
          lvalueColumnRef (ExLvalue (Lvalue [LvSegment "ns" Nothing, LvSegment "t" Nothing, LvSegment "c" Nothing]))
            @?= Just (TableRef (Just "ns") "t", "c")

      , testCase "single-segment lvalue -> Nothing" $
          lvalueColumnRef (ExLvalue (Lvalue [LvSegment "x" Nothing])) @?= Nothing

      , testCase "four-segment lvalue -> Nothing" $
          lvalueColumnRef (ExLvalue (Lvalue [ LvSegment "a" Nothing, LvSegment "b" Nothing
                                             , LvSegment "c" Nothing, LvSegment "d" Nothing ]))
            @?= Nothing

      , testCase "subscripted segment -> Nothing" $
          lvalueColumnRef (ExLvalue (Lvalue [LvSegment "t" (Just ["1"]), LvSegment "c" Nothing]))
            @?= Nothing

      , testCase "host var expression -> Nothing (not an ExLvalue)" $
          lvalueColumnRef (ExHostVar (Lvalue [LvSegment "arg_x" Nothing])) @?= Nothing

      , testCase "literal expression -> Nothing" $
          lvalueColumnRef (ExInt "1") @?= Nothing

      , testCase "segment names are lowercased" $
          lvalueColumnRef (ExLvalue (Lvalue [LvSegment "MISTH_FINAL" Nothing, LvSegment "KodFinal" Nothing]))
            @?= Just (TableRef Nothing "misth_final", "kodfinal")
      ]

  , testGroup "dwRetrieveFootprint: column list -> LegRetrieve"
      [ testCase "drColumns become LegRetrieve legs, StmtObj -> ColumnObj" $
          let r = emptyRetrieve { drColumns = ["misth_final.kodfinal", "misth_final.descfinal"] }
          in dwRetrieveFootprint ctx0 "f.srd" "dw1" (mkTable r [])
               @?= Set.fromList
                     [ SchMorphism stmt1 (ColumnObj (TableRef Nothing "misth_final") "kodfinal") LegRetrieve
                     , SchMorphism stmt1 (ColumnObj (TableRef Nothing "misth_final") "descfinal") LegRetrieve
                     ]
      ]

  , testGroup "dwRetrieveFootprint: update-table columns -> LegWrites"
      [ testCase "dcUpdate=True column with dcDbName produces a LegWrites leg" $
          dwRetrieveFootprint ctx0 "f.srd" "dw1" (mkTable emptyRetrieve [writeColumn])
            @?= Set.singleton
                  (SchMorphism stmt1 (ColumnObj (TableRef Nothing "misth_final") "kodfinal") LegWrites)

      , testCase "dcUpdate=False column produces no leg" $
          dwRetrieveFootprint ctx0 "f.srd" "dw1"
            (mkTable emptyRetrieve [writeColumn { dcUpdate = False }])
            @?= Set.empty

      , testCase "dcUpdate=True with no dcDbName produces no leg" $
          dwRetrieveFootprint ctx0 "f.srd" "dw1"
            (mkTable emptyRetrieve [writeColumn { dcDbName = Nothing }])
            @?= Set.empty
      ]

  , testGroup "dwRetrieveFootprint: WHERE predicate -> LegReads (real corpus shapes)"
      [ testCase "afxfilterd.kodfilter = :kodfilter: EXP1 resolves via the DDL catalog; \
                 \EXP2 host-var contributes nothing" $
          let sql = "PBSELECT( VERSION(400) TABLE(NAME=~\"afxfilterd~\") \
                    \WHERE( EXP1 =~\"afxfilterd.kodfilter~\" OP =~\"=~\" \
                    \EXP2 =~\":kodfilter~\" ) )"
              table = DwTable
                { dtColumns = [], dtRetrieve = Just (parsePbSelect sql)
                , dtUpdate = Nothing, dtUpdateWhere = Nothing, dtArguments = []
                }
              ctx = mkDwFootprintCtx [CatColumnRow Nothing "afxfilterd" "kodfilter"] Nothing
          in dwRetrieveFootprint ctx "afxfilterd.srd" "dw_afx" table
               @?= Set.singleton
                     (SchMorphism (ColumnObj (TableRef Nothing "afxfilterd") "kodfilter")
                                  (StmtObj (DwRetrieveId "afxfilterd.srd" "dw_afx"))
                                  LegReads)

      , testCase "same WHERE, empty catalog: no leg (no guessing past what the catalog confirms)" $
          let sql = "PBSELECT( VERSION(400) TABLE(NAME=~\"afxfilterd~\") \
                    \WHERE( EXP1 =~\"afxfilterd.kodfilter~\" OP =~\"=~\" \
                    \EXP2 =~\":kodfilter~\" ) )"
              table = DwTable
                { dtColumns = [], dtRetrieve = Just (parsePbSelect sql)
                , dtUpdate = Nothing, dtUpdateWhere = Nothing, dtArguments = []
                }
          in dwRetrieveFootprint ctx0 "afxfilterd.srd" "dw_afx" table @?= Set.empty

      , testCase "3-segment lvalue (namespace.table.column) resolves with the explicit namespace" $
          let e  = ExLvalue (Lvalue [LvSegment "openpay" Nothing, LvSegment "misth_final" Nothing, LvSegment "kodfinal" Nothing])
              wc = DwWhereClause "openpay.misth_final.kodfinal" "=" ":x" Nothing
                     (Just e) (Just (ExHostVar (Lvalue [LvSegment "x" Nothing])))
              r  = emptyRetrieve { drWhere = [wc] }
              ctx = mkDwFootprintCtx [CatColumnRow (Just "openpay") "misth_final" "kodfinal"] Nothing
          in dwRetrieveFootprint ctx "f.srd" "dw1" (mkTable r [])
               @?= Set.singleton
                     (SchMorphism (ColumnObj (TableRef (Just "openpay") "misth_final") "kodfinal") stmt1 LegReads)

      , testCase "literal EXP2 (ExInt) contributes no leg of its own" $
          let wc = DwWhereClause "misth_final.isasf" "=" "1" Nothing
                     (Just (ExLvalue (Lvalue [LvSegment "misth_final" Nothing, LvSegment "isasf" Nothing])))
                     (Just (ExInt "1"))
              r  = emptyRetrieve { drWhere = [wc] }
              ctx = mkDwFootprintCtx [CatColumnRow Nothing "misth_final" "isasf"] Nothing
          in dwRetrieveFootprint ctx "f.srd" "dw1" (mkTable r [])
               @?= Set.singleton
                     (SchMorphism (ColumnObj (TableRef Nothing "misth_final") "isasf") stmt1 LegReads)
      ]

  , testGroup "dwRetrieveFootprint: joins -> LegFk FkDwJoin"
      [ testCase "drJoins become LegFk FkDwJoin legs between the two column refs" $
          let j = DwJoin { djLeft = "a.x", djOp = "=", djRight = "b.y", djOuter1 = Nothing, djOuter2 = Nothing }
              r = emptyRetrieve { drJoins = [j] }
          in dwRetrieveFootprint ctx0 "f.srd" "dw1" (mkTable r [])
               @?= Set.singleton
                     (SchMorphism (ColumnObj (TableRef Nothing "a") "x")
                                  (ColumnObj (TableRef Nothing "b") "y")
                                  (LegFk FkDwJoin))
      ]

  , testGroup "dwRetrieveFootprint: totality on missing/raw retrieve"
      [ testCase "dtRetrieve = Nothing yields only write legs, no crash" $
          let table = DwTable
                { dtColumns = [writeColumn], dtRetrieve = Nothing
                , dtUpdate = Nothing, dtUpdateWhere = Nothing, dtArguments = []
                }
          in dwRetrieveFootprint ctx0 "f.srd" "dw1" table
               @?= Set.singleton
                     (SchMorphism stmt1 (ColumnObj (TableRef Nothing "misth_final") "kodfinal") LegWrites)

      , testCase "dtRetrieve = Just (DwRetrieveRaw _) yields only write legs, no crash" $
          let table = DwTable
                { dtColumns = [writeColumn], dtRetrieve = Just (DwRetrieveRaw "garbage")
                , dtUpdate = Nothing, dtUpdateWhere = Nothing, dtArguments = []
                }
          in dwRetrieveFootprint ctx0 "f.srd" "dw1" table
               @?= Set.singleton
                     (SchMorphism stmt1 (ColumnObj (TableRef Nothing "misth_final") "kodfinal") LegWrites)
      ]

  , testGroup "dwRetrieveFootprint: default-namespace resolution"
      [ testCase "unqualified table resolves to the default namespace when the catalog confirms it" $
          let r = emptyRetrieve { drTables = ["misth_final"], drColumns = ["misth_final.kodfinal"] }
              ctx = mkDwFootprintCtx [CatColumnRow (Just "openpay") "misth_final" "kodfinal"] (Just "openpay")
          in dwRetrieveFootprint ctx "f.srd" "dw1" (mkTable r [])
               @?= Set.singleton
                     (SchMorphism stmt1 (ColumnObj (TableRef (Just "openpay") "misth_final") "kodfinal") LegRetrieve)
      ]
  ]
