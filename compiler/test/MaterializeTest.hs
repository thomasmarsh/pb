module MaterializeTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb        (inMemory, withHandle, initSchema, executeHandle, queryHandle)
import PB.Pipeline.DuckDb.Materialize
import PB.Pipeline.DuckDb.PhaseB.Append (appendSchemaObjects, appendSchemaMorphisms)
import PB.Pipeline.DuckDb.PhaseB.Query (SchemaClosureReady (..))
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchGraph (..), schObjectKey
  )
import PB.Pipeline.SqlParse (TableRef (..))
import Database.DuckDB.Simple           (Query (..))
import Database.DuckDB.Simple.FromRow   (FromRow (..), field)
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual)

import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | Local row shape for reading back (leg_kind, leg_source) pairs raw.
data KindSourceRow = KindSourceRow Text Text deriving (Eq, Show)

instance FromRow KindSourceRow where
  fromRow = KindSourceRow <$> field <*> field

-- | Local row shape for reading back the Phase F schema_objects join-back
-- columns: (seed_kind, seed_table_name, seed_column_name, target_kind,
-- target_stmt_file, target_stmt_object, target_stmt_proc, target_stmt_line,
-- leg_from_kind, leg_from_table_name, leg_from_column_name, leg_to_kind,
-- leg_to_stmt_file, leg_to_stmt_object, leg_to_stmt_proc, leg_to_stmt_line).
data DecomposedRow = DecomposedRow
  Text Text Text
  Text Text Text Text Int
  Text Text Text
  Text Text Text Text Int
  deriving (Eq, Show)

instance FromRow DecomposedRow where
  fromRow = DecomposedRow
    <$> field <*> field <*> field
    <*> field <*> field <*> field <*> field <*> field
    <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field <*> field

tests :: TestTree
tests = testGroup "Materialize"
  [ testCase "materializeDecompositionCoslice projects path_leg + recovers leg_source" testMaterializeDecompositionCoslice
  , testCase "materializeImpliedFk decodes ColKey pairs to namespace/table/column" testMaterializeImpliedFk
  , testCase "materializeColumnRisk decodes ColKeys, excluding non-column (stmt) nodes" testMaterializeColumnRisk
  ]

testMaterializeDecompositionCoslice :: IO ()
testMaterializeDecompositionCoslice = withHandle inMemory $ \conn -> do
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
  -- Hand-create the path_leg_fwd output table the production SQL projection
  -- would materialize, so the SQL projection under test can read it.
  -- recreateTextTable + appendTextRows would be the production path; here the
  -- SQL projection is what's under test, so we hand-create the table.
  void $ executeHandle conn (Query "CREATE TABLE path_leg_fwd (s TEXT, target TEXT, leg_ord TEXT, lf TEXT, lt TEXT, kind TEXT)")
  void $ executeHandle conn (Query ("INSERT INTO path_leg_fwd VALUES ('"
    <> colAKey <> "', '" <> stmtKey <> "', '0', '" <> colAKey <> "', '" <> stmtKey <> "', 'reads')"))
  void $ executeHandle conn (Query "CREATE TABLE path_leg_back (s TEXT, target TEXT, leg_ord TEXT, lf TEXT, lt TEXT, kind TEXT)")
  materializeDecompositionCoslice conn (SchemaClosureReady ()) (SchGraph Set.empty [] Map.empty Map.empty)

  rows <- queryHandle conn "SELECT leg_kind, leg_source FROM decomposition_coslice"
  assertEqual "leg_source recovered via schema_morphisms join (Plan 161 Phase 2c)"
    [KindSourceRow "reads" "sql_text"]
    rows

  decomposed <- queryHandle conn
    (Query (T.unlines
      [ "SELECT seed_kind, seed_table_name, seed_column_name,"
      , "       target_kind, target_stmt_file, target_stmt_object, target_stmt_proc, target_stmt_line,"
      , "       leg_from_kind, leg_from_table_name, leg_from_column_name,"
      , "       leg_to_kind, leg_to_stmt_file, leg_to_stmt_object, leg_to_stmt_proc, leg_to_stmt_line"
      , "  FROM decomposition_coslice"
      ]))
  assertEqual "seed/target/leg_from/leg_to decoded via schema_objects join-back (Plan 198 Phase F)"
    [ DecomposedRow "column" "a" "x"
                    "stmt" "f.srf" "obj" "proc" 1
                    "column" "a" "x"
                    "stmt" "f.srf" "obj" "proc" 1
    ]
    decomposed

-- | Local row shape for reading back (from_table, from_column, to_table,
-- to_column) from @implied_fk@.
data FkPairRow = FkPairRow Text Text Text Text deriving (Eq, Show)

instance FromRow FkPairRow where
  fromRow = FkPairRow <$> field <*> field <*> field <*> field

testMaterializeImpliedFk :: IO ()
testMaterializeImpliedFk = withHandle inMemory $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      colB = ColumnObj (TableRef Nothing "b") "y"
  appendSchemaObjects conn [colA, colB]
  -- Hand-create the implied_fk_pairs output table the production SQL
  -- materializer would populate, so 'materializeImpliedFk' can read it.
  void $ executeHandle conn (Query "CREATE TABLE implied_fk_pairs (x TEXT, y TEXT)")
  void $ executeHandle conn (Query ("INSERT INTO implied_fk_pairs VALUES ('"
    <> schObjectKey colA <> "', '" <> schObjectKey colB <> "')"))
  materializeImpliedFk conn (ImpliedFkPairsReady ()) (SchGraph Set.empty [] Map.empty Map.empty)

  rows <- queryHandle conn
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
testMaterializeColumnRisk = withHandle inMemory $ \conn -> do
  initSchema conn
  let colA = ColumnObj (TableRef Nothing "a") "x"
      stmt = StmtObj (SqlStmtId "f.srf" "obj" "proc" 1)
  appendSchemaObjects conn [colA, stmt]
  -- Hand-create the risk_count output table: one column node, one stmt node --
  -- the stmt row exercises the kind = 'column' filter (a real bug found on
  -- the openpay corpus: schema_objects has no namespace/table_name/
  -- column_name for stmt/dw_retrieve kinds, so an unfiltered join
  -- materialized 115 opaque all-NULL rows there).
  void $ executeHandle conn (Query "CREATE TABLE risk_count (x TEXT, n TEXT)")
  void $ executeHandle conn (Query ("INSERT INTO risk_count VALUES ('"
    <> schObjectKey colA <> "', '3'), ('" <> schObjectKey stmt <> "', '7')"))
  materializeColumnRisk conn (RiskCountReady ()) (SchGraph Set.empty [] Map.empty Map.empty)

  rows <- queryHandle conn "SELECT table_name, column_name, downstream_count FROM column_risk"
  assertEqual "only the column-kind node is materialized, with its count"
    [RiskRow "a" "x" 3]
    rows
