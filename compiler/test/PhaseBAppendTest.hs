module PhaseBAppendTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb        (inMemory, withHandle, initSchema, queryHandle)
import PB.Pipeline.DuckDb.PhaseB.Append
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..) )
import PB.Pipeline.SqlParse (TableRef (..))
import Database.DuckDB.Simple.FromRow   (FromRow (..), field)
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual)

tests :: TestTree
tests = testGroup "PhaseB.Append"
  [ testCase "appendSchemaObjects/Morphisms accept rows" testAppendSchemaObjectsMorphisms
  ]

-- | Local row shape for reading back (leg_kind, leg_source) pairs raw --
-- no production query function exists for schema_morphisms/
-- decomposition_coslice (Python reads them directly via SQL), so this test
-- query_s the DuckDB connection directly rather than adding one.
data KindSourceRow = KindSourceRow Text Text deriving (Eq, Show)

instance FromRow KindSourceRow where
  fromRow = KindSourceRow <$> field <*> field

testAppendSchemaObjectsMorphisms :: IO ()
testAppendSchemaObjectsMorphisms = withHandle inMemory $ \conn -> do
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

  rows <- queryHandle conn "SELECT leg_kind, leg_source FROM schema_morphisms ORDER BY leg_kind"
  assertEqual "leg_source persists per row (Plan 163 Phase 4, D3)"
    [KindSourceRow "fk" "ddl_fk", KindSourceRow "reads" "sql_text"]
    rows
