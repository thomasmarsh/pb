module MaterializeTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb        (inMemory, withHandle, initSchema, executeHandle, queryHandle)
import PB.Pipeline.DuckDb.Materialize
import PB.Pipeline.DuckDb.PhaseB.Append (appendSchemaObjects, appendSchemaMorphisms)
import PB.Pipeline.DuckDb.PhaseB.Query (SchemaClosureReady (..), CallGraphAndTaintReady (..))
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), LegSource (..), SchMorphism (..)
  , SchGraph (..), schObjectKey
  )
import PB.Analysis.Taint (TaintSource (..), TaintSink (..))
import PB.Analysis.CallClassify (EffectTag (..))
import PB.Analysis.EffectClosure (materializeProcEffects, computeProcEffectClosure)
import PB.Pipeline.SqlParse (TableRef (..))
import Database.DuckDB.Simple           (Query (..))
import Database.DuckDB.Simple.FromRow   (FromRow (..), field)
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual, assertBool)

import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import PB.AST.Expr (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident (Ident, IdentMap, identMapEmpty, identMapInsertWith, mkIdentSynthetic)
import PB.AST.SourceFile (SubSig (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR (Eff (..), extractEffTable)
import PB.Explain.Materialize (ExplainSeedRow (..), materializeProcPseudocode)
import PB.Pipeline.Serialise ()
import Data.Aeson (Value (..), decodeStrict)
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text.Encoding as TE

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
  , testCase "materializeTaintPaths emits one row per confirmed pair, not one per duplicate-key source/sink occurrence" testMaterializeTaintPaths
  , testCase "materializeProcEffects writes one proc_effects row per tag for a procedure with only direct effects" testMaterializeProcEffectsDirect
  , testCase "materializeProcEffects's proc_effects rows reflect tags transitively closed through a 2-hop call chain" testMaterializeProcEffectsTransitive
  , testCase "materializeProcEffects writes zero proc_effects rows for a procedure whose closure is genuinely empty" testMaterializeProcEffectsPure
  , testCase "materializeProcEffects's returned Map matches computeProcEffectClosure called directly" testMaterializeProcEffectsReturnValue
  , testGroup "ProcPseudocode"
    [ testCase "one proc_pseudocode row per retained procedure, keyed by (object, proc_name)" testMaterializeProcPseudocodeRowPerProc
    , testCase "pseudocode_json decodes to a JSON object with a non-null rootRegion/regions shape" testMaterializeProcPseudocodeJsonShape
    , testCase "a call resolved via the caller's ancestor chain surfaces its transitive effect tag in the materialized rootSig" testMaterializeProcPseudocodeEffectsReachJson
    , testCase "two objects declaring the same bare proc name each materialize their own object's resolved effects, not a name-only union" testMaterializeProcPseudocodeNameCollision
    ]
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

-- | Local row shape for reading back a full @taint_paths@ row.
data TaintPathRow = TaintPathRow
  Text Text Text Text Text Text Text Text Text Text Text
  deriving (Eq, Show)

instance FromRow TaintPathRow where
  fromRow = TaintPathRow
    <$> field <*> field <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field <*> field <*> field

testMaterializeTaintPaths :: IO ()
testMaterializeTaintPaths = withHandle inMemory $ \conn -> do
  initSchema conn
  -- taint_step_kind is normally populated by TaintClosure.materializeTaintStepKind;
  -- hand-create it empty here since steps_json isn't under test.
  void $ executeHandle conn
    (Query "CREATE TABLE taint_step_kind (s TEXT, t TEXT, leg_ord TEXT, lf TEXT, lt TEXT, kind TEXT, step_kind TEXT, description TEXT)")
  let src1 = TaintSource "f.srf" "obj" "proc" "var" "select_into" (Just 10)
      -- Same (object, proc_name, var_name) key as src1, different line --
      -- the real-corpus shape that used to fan out through a re-derived
      -- join against raw (non-deduplicated) source/sink lists.
      src2 = TaintSource "f.srf" "obj" "proc" "var" "select_into" (Just 20)
      snk  = TaintSink   "f.srf" "obj" "proc" "var" "db_write" "high" (Just 30)
      cgtr = CallGraphAndTaintReady
        { cgtrSources      = [src1, src2]
        , cgtrSinks        = [snk]
        , cgtrReachesPairs = []
        , cgtrConfirmed    = [(src1, snk)]
        }
  materializeTaintPaths conn cgtr

  rows <- queryHandle conn
    (Query (T.unlines
      [ "SELECT file, object, proc_name, var_name,"
      , "       target_file, target_object, target_proc, target_var,"
      , "       severity, category, steps_json"
      , "  FROM taint_paths"
      ]))
  assertEqual "one row per confirmed pair, driven by cgtrConfirmed not the raw duplicate-key source list"
    [ TaintPathRow "f.srf" "obj" "proc" "var" "f.srf" "obj" "proc" "var" "high" "sql_injection" "[]" ]
    rows

-- | Local row shape for reading back a @proc_effects@ row.
data ProcEffectRow = ProcEffectRow Text Text Text deriving (Eq, Ord, Show)

instance FromRow ProcEffectRow where
  fromRow = ProcEffectRow <$> field <*> field <*> field

-- | Shared runner for the three assertion-shape-identical
-- 'materializeProcEffects' cases below (direct-only, transitive, genuinely
-- pure) -- table-driven via fixtures passed in, not repeated structure.
runProcEffectsCase :: [(Text, Text, Set.Set EffectTag)] -> [(Text, Text, Text, Text)] -> [ProcEffectRow] -> IO ()
runProcEffectsCase seeds edges expected = withHandle inMemory $ \conn -> do
  initSchema conn
  _ <- materializeProcEffects seeds edges conn
  rows <- queryHandle conn "SELECT object, proc_name, effect_tag FROM proc_effects ORDER BY object, proc_name, effect_tag"
  assertEqual "proc_effects rows" (Set.fromList expected) (Set.fromList rows)

testMaterializeProcEffectsDirect :: IO ()
testMaterializeProcEffectsDirect =
  runProcEffectsCase [("o", "a", Set.singleton ReadsDb)] [] [ProcEffectRow "o" "a" "ReadsDb"]

testMaterializeProcEffectsTransitive :: IO ()
testMaterializeProcEffectsTransitive =
  runProcEffectsCase
    [("o", "a", Set.empty), ("o", "b", Set.empty), ("o", "c", Set.singleton Suspends)]
    [("o", "a", "o", "b"), ("o", "b", "o", "c")]
    [ ProcEffectRow "o" "a" "Suspends", ProcEffectRow "o" "b" "Suspends", ProcEffectRow "o" "c" "Suspends" ]

testMaterializeProcEffectsPure :: IO ()
testMaterializeProcEffectsPure =
  runProcEffectsCase
    [("o", "a", Set.empty), ("o", "b", Set.empty)]
    [("o", "a", "o", "b")]
    []

testMaterializeProcEffectsReturnValue :: IO ()
testMaterializeProcEffectsReturnValue = withHandle inMemory $ \conn -> do
  initSchema conn
  let seeds = [("o", "a", Set.singleton ReadsDb), ("o", "b", Set.singleton WritesDb)]
      edges = [("o", "a", "o", "b")]
  result <- materializeProcEffects seeds edges conn
  assertEqual "returned Map matches computeProcEffectClosure called directly"
    (computeProcEffectClosure seeds edges) result

-- ---------------------------------------------------------------------------
-- materializeProcPseudocode (Plan 221 Phase 2)

ident :: Text -> Ident
ident = mkIdentSynthetic "MaterializeTest fixture"

envFor :: Text -> ScopedTypeEnv
envFor obj = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty (ident obj) Map.empty

-- | Local row shape for reading back a @proc_pseudocode@ row.
data ProcPseudocodeRow = ProcPseudocodeRow Text Text Text deriving (Eq, Show)

instance FromRow ProcPseudocodeRow where
  fromRow = ProcPseudocodeRow <$> field <*> field <*> field

-- | Declares @name@ as callable on @obj@, resolvable via the ancestor-chain
-- walk 'PB.Explain.Signatures'/'PB.Explain.Pseudocode' both use.
sigMapWith :: Text -> Text -> IdentMap (Map.Map Ident (Either a SubSig))
sigMapWith obj name = identMapInsertWith Map.union (ident obj)
  (Map.singleton (ident name) (Right (SubSig [] (ident name) [] Nothing Nothing Nothing)))
  identMapEmpty

-- | Decode a @pseudocode_json@ column value into a 'Value', navigating
-- @stripCamelCasePrefix@'d keys ("pcRootSig" -> "rootSig", etc. -- see
-- 'PB.Pipeline.Serialise').
decodeJson :: Text -> Value
decodeJson raw = fromMaybe (error "pseudocode_json did not decode") (decodeStrict (TE.encodeUtf8 raw))

field' :: Text -> Value -> Value
field' k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
field' _ _          = Null

testMaterializeProcPseudocodeRowPerProc :: IO ()
testMaterializeProcPseudocodeRowPerProc = withHandle inMemory $ \conn -> do
  initSchema conn
  let term = extractEffTable (EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ())
      seedRows =
        [ ExplainSeedRow "w_a" "ue_clicked" term (envFor "w_a")
        , ExplainSeedRow "w_b" "ue_open"    term (envFor "w_b")
        ]
  materializeProcPseudocode identMapEmpty Map.empty seedRows conn
  rows <- queryHandle conn "SELECT object, proc_name, pseudocode_json FROM proc_pseudocode ORDER BY object, proc_name"
  assertEqual "one row per retained procedure"
    [("w_a", "ue_clicked"), ("w_b", "ue_open")]
    [ (o, p) | ProcPseudocodeRow o p _ <- rows ]

testMaterializeProcPseudocodeJsonShape :: IO ()
testMaterializeProcPseudocodeJsonShape = withHandle inMemory $ \conn -> do
  initSchema conn
  let term = extractEffTable (EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ())
  materializeProcPseudocode identMapEmpty Map.empty [ExplainSeedRow "w_a" "ue_clicked" term (envFor "w_a")] conn
  [ProcPseudocodeRow _ _ raw] <- queryHandle conn "SELECT object, proc_name, pseudocode_json FROM proc_pseudocode"
  let v = decodeJson raw
  assertBool "rootRegion present" (field' "rootRegion" v /= Null)
  assertBool "regions present" (field' "regions" v /= Null)

testMaterializeProcPseudocodeEffectsReachJson :: IO ()
testMaterializeProcPseudocodeEffectsReachJson = withHandle inMemory $ \conn -> do
  initSchema conn
  let term = extractEffTable (ECall "helper" [] 1 Set.empty :: Eff () ())
      sigMap = sigMapWith "w_a" "helper"
      procEffects = Map.singleton ("w_a", "helper") (Set.singleton ReadsDb)
  materializeProcPseudocode sigMap procEffects [ExplainSeedRow "w_a" "ue_clicked" term (envFor "w_a")] conn
  [ProcPseudocodeRow _ _ raw] <- queryHandle conn "SELECT object, proc_name, pseudocode_json FROM proc_pseudocode"
  let effects = field' "effects" (field' "rootSig" (decodeJson raw))
  assertEqual "rootSig.effects carries the ancestor-chain-resolved ReadsDb tag" (Array (pure (String "ReadsDb"))) effects

testMaterializeProcPseudocodeNameCollision :: IO ()
testMaterializeProcPseudocodeNameCollision = withHandle inMemory $ \conn -> do
  initSchema conn
  let term = extractEffTable (ECall "helper" [] 1 Set.empty :: Eff () ())
      sigMap = identMapInsertWith Map.union (ident "w_b") (Map.singleton (ident "helper") (Right (SubSig [] (ident "helper") [] Nothing Nothing Nothing)))
                 (sigMapWith "w_a" "helper")
      procEffects = Map.fromList
        [ (("w_a", "helper"), Set.singleton ReadsDb)
        , (("w_b", "helper"), Set.singleton WritesDb)
        ]
      seedRows =
        [ ExplainSeedRow "w_a" "ue_clicked" term (envFor "w_a")
        , ExplainSeedRow "w_b" "ue_open"    term (envFor "w_b")
        ]
  materializeProcPseudocode sigMap procEffects seedRows conn
  rows <- queryHandle conn "SELECT object, proc_name, pseudocode_json FROM proc_pseudocode ORDER BY object, proc_name"
  let effectsFor raw = field' "effects" (field' "rootSig" (decodeJson raw))
  case rows of
    [ProcPseudocodeRow "w_a" _ rawA, ProcPseudocodeRow "w_b" _ rawB] -> do
      assertEqual "w_a's own resolved tag" (Array (pure (String "ReadsDb"))) (effectsFor rawA)
      assertEqual "w_b's own resolved tag, not w_a's" (Array (pure (String "WritesDb"))) (effectsFor rawB)
    other -> error ("expected exactly 2 rows, got " <> show other)

var :: Text -> Expr
var name = ExLvalue (Lvalue [LvSegment (ident name) Nothing])
