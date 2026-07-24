module DwBindingFootprintTest (tests) where

import PB.Prelude
import PB.AST.DataWindow      (DataWindowFile (..), DwObjectAttrs (..), DwTable (..),
                                DwColumn (..), DwControl (..))
import PB.AST.Expr            (Expr (..), Lvalue (..), LvSegment (..), BinOp (..))
import PB.AST.Ident           (mkIdent)
import PB.Analysis.DwBindingFootprint

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures

-- | Build an 'ExLvalue' referencing a bare, single-segment column-style
-- name -- the shape a binding expression uses to reference a sibling
-- column of the same DataWindow (see 'columnNameRef').
bareRef :: Text -> Expr
bareRef nm = ExLvalue (Lvalue [LvSegment (mkIdent nm) Nothing])

baseColumn :: DwColumn
baseColumn = DwColumn
  { dcName = "col", dcType = "long", dcDbName = Nothing, dcUpdate = False
  , dcKey = False, dcUpdateWhere = False, dcDddwName = Nothing
  , dcValidation = Nothing, dcParsedValidation = Nothing, dcValidationTokens = []
  , dcValidationMsg = Nothing, dcParsedValidationMsg = Nothing, dcValidationMsgTokens = []
  , dcAttrs = Map.empty
  }

baseControl :: DwControl
baseControl = DwControl
  { dwcType = "text", dwcName = Nothing, dwcBand = Nothing, dwcId = Nothing
  , dwcX = Nothing, dwcY = Nothing, dwcWidth = Nothing, dwcHeight = Nothing
  , dwcVisible = Nothing
  , dwcExpression = Nothing, dwcParsedExpression = Nothing, dwcExpressionTokens = []
  , dwcFormat = Nothing, dwcParsedFormat = Nothing, dwcFormatTokens = []
  , dwcColor = Nothing, dwcParsedColor = Nothing, dwcColorTokens = []
  , dwcTabSeq = Nothing, dwcAttrs = Map.empty
  }

mkDwFile :: [DwColumn] -> [DwControl] -> DataWindowFile
mkDwFile cols ctls = DataWindowFile
  { dwRelease  = 400
  , dwObject   = DwObjectAttrs Map.empty
  , dwTable    = Just DwTable { dtColumns = cols, dtRetrieve = Nothing
                              , dtUpdate = Nothing, dtUpdateWhere = Nothing, dtArguments = [] }
  , dwBands    = []
  , dwGroups   = []
  , dwControls = ctls
  , dwUnknowns = []
  , dwMeta     = Map.empty
  }

salaryCol :: DwColumn
salaryCol = baseColumn { dcName = "salary" }

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "DwBindingFootprint"
  [ testGroup "columnNameRef"
      [ testCase "single-segment lvalue matching a known column -> Just name" $
          columnNameRef (Set.fromList ["salary"]) (bareRef "salary") @?= Just "salary"

      , testCase "single-segment lvalue not in column set -> Nothing" $
          columnNameRef (Set.fromList ["salary"]) (bareRef "bonus") @?= Nothing

      , testCase "multi-segment lvalue -> Nothing" $
          columnNameRef (Set.fromList ["salary"])
            (ExLvalue (Lvalue [ LvSegment (mkIdent "t") Nothing
                               , LvSegment (mkIdent "salary") Nothing ]))
            @?= Nothing

      , testCase "non-lvalue expr (call, literal) -> Nothing" $ do
          columnNameRef (Set.fromList ["salary"])
            (ExCall { callee = Lvalue [LvSegment (mkIdent "gettext") Nothing]
                    , callArgs = [] })
            @?= Nothing
          columnNameRef (Set.fromList ["salary"]) (ExInt "0") @?= Nothing
      ]

  , testGroup "dwBindingFootprint"
      [ testCase "control expression referencing a column -> BindExpression edge" $
          let ctl = baseControl { dwcName = Just "cmp1", dwcParsedExpression = Just (bareRef "salary") }
              dw  = mkDwFile [salaryCol] [ctl]
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.singleton (DwBindEdge "f.srd" "dw1" "salary" BindExpression "cmp1")

      , testCase "control format ~t-expression referencing a column -> BindFormat edge" $
          let ctl = baseControl { dwcName = Just "c1", dwcParsedFormat = Just (bareRef "salary") }
              dw  = mkDwFile [salaryCol] [ctl]
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.singleton (DwBindEdge "f.srd" "dw1" "salary" BindFormat "c1")

      , testCase "control color ~t-expression referencing a column -> BindColor edge" $
          let ctl = baseControl { dwcName = Just "c1", dwcParsedColor = Just (bareRef "salary") }
              dw  = mkDwFile [salaryCol] [ctl]
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.singleton (DwBindEdge "f.srd" "dw1" "salary" BindColor "c1")

      , testCase "column validation referencing another column -> BindValidation edge" $
          let deptCol = baseColumn { dcName = "dept_id" }
              validated = baseColumn
                { dcName = "salary", dcParsedValidation = Just (bareRef "dept_id") }
              dw = mkDwFile [validated, deptCol] []
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.singleton (DwBindEdge "f.srd" "dw1" "dept_id" BindValidation "salary")

      , testCase "column validationmsg string-concat referencing a column -> BindValidationMsg edge" $
          let deptCol = baseColumn { dcName = "dept_id" }
              validated = baseColumn
                { dcName = "salary"
                , dcParsedValidationMsg = Just
                    (ExBinOp { lhs = ExStr "must be less than "
                             , op = BopAdd
                             , rhs = bareRef "dept_id" })
                }
              dw = mkDwFile [validated, deptCol] []
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.singleton (DwBindEdge "f.srd" "dw1" "dept_id" BindValidationMsg "salary")

      , testCase "column validation referencing its own column (0-hop self-loop)" $
          let selfValid = salaryCol { dcParsedValidation = Just (bareRef "salary") }
              dw = mkDwFile [selfValid] []
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.singleton (DwBindEdge "f.srd" "dw1" "salary" BindValidation "salary")

      , testCase "expression referencing unknown identifier (function call, no column match) -> no edge" $
          let ctl = baseControl
                { dwcName = Just "cmp1"
                , dwcParsedExpression = Just
                    (ExCall { callee = Lvalue [LvSegment (mkIdent "gettext") Nothing]
                            , callArgs = [] })
                }
              dw = mkDwFile [salaryCol] [ctl]
          in dwBindingFootprint "f.srd" "dw1" dw @?= Set.empty

      , testCase "unnamed control contributes no edge even with a column-referencing expression" $
          let ctl = baseControl { dwcName = Nothing, dwcParsedExpression = Just (bareRef "salary") }
              dw  = mkDwFile [salaryCol] [ctl]
          in dwBindingFootprint "f.srd" "dw1" dw @?= Set.empty

      , testCase "no expressions present -> empty set" $
          dwBindingFootprint "f.srd" "dw1" (mkDwFile [salaryCol] [baseControl { dwcName = Just "c1" }])
            @?= Set.empty

      , testCase "duplicate-key collision: two bindings referencing the same column dedupe under Set" $
          let ctl1 = baseControl { dwcName = Just "c1", dwcParsedExpression = Just (bareRef "salary") }
              ctl2 = baseControl { dwcName = Just "c1", dwcParsedFormat = Just (bareRef "salary") }
              dw   = mkDwFile [salaryCol] [ctl1, ctl2]
          in dwBindingFootprint "f.srd" "dw1" dw @?=
               Set.fromList
                 [ DwBindEdge "f.srd" "dw1" "salary" BindExpression "c1"
                 , DwBindEdge "f.srd" "dw1" "salary" BindFormat "c1"
                 ]
      ]
  ]
