module PhaseATest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb        (Handle, inMemory, withHandle, initSchema, queryHandle)
import PB.Pipeline.DuckDb.Appender (AppenderPool, withAppenderPool)
import PB.Pipeline.DuckDb.PhaseA
import PB.Analysis.DeadVars
  ( DeadVarFinding (..), DeadVarKind (..) )
import PB.Lexing.Token (Token (..), TokenKind (..), SourceSpan (..))
import Database.DuckDB.Simple.FromRow   (FromRow (..), field)
import Test.Tasty             (TestTree, testGroup)
import Test.Tasty.HUnit       (testCase, assertEqual)

phaseATables :: [Text]
phaseATables =
  [ "objects", "procedures", "call_sites", "global_vars"
  , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
  , "sql_statement_filters", "sql_statement_tables"
  , "source_files", "parse_errors", "identifier_tokens"
  , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
  , "dw_joins", "dw_retrieve_where"
  , "dw_arguments"
  , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
  , "dead_vars"
  ]

mkTok :: TokenKind -> Text -> (Int, Int, Int, Int) -> Token
mkTok kind txt (sl, sc, el, ec) = Token kind txt (SourceSpan sl sc el ec)

withTestPool :: Handle -> (AppenderPool -> IO a) -> IO a
withTestPool conn = withAppenderPool conn phaseATables

tests :: TestTree
tests = testGroup "PhaseA"
  [ testCase "initSchema creates all Phase A tables" testInitSchema
  , testCase "appendObjects accepts a row"           testAppendObjects
  , testCase "appendProcedures stores cfg_json"      testAppendProcedures
  , testCase "appendSqlStmtColumns/Filters accept rows" testAppendSqlStmtColumnsFilters
  , testCase "appendCatalogColumns/Pks/Fks accept rows" testAppendCatalogRows
  , testCase "appendDwRetrieveColumns accepts rows"  testAppendDwRetrieveColumns
  , testCase "appendDwRetrieveWhere accepts rows"    testAppendDwRetrieveWhere
  , testCase "appendDwArguments accepts rows"        testAppendDwArguments
  , testCase "appendDeadVars round-trip"             testAppendDeadVars
  , testCase "identifierTokenRows keeps only identifier-shaped tokens" testIdentifierTokenRowsFilter
  , testCase "identifierTokenRows counts duplicate-text occurrences independently" testIdentifierTokenRowsDuplicates
  , testCase "appendIdentifierTokens round-trip"     testAppendIdentifierTokens
  ]

testInitSchema :: IO ()
testInitSchema = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    -- Append to a non-stub table proves schema is active (appender throws on unknown table)
    appendObjects     pool []
    appendParseErrors pool []

testAppendObjects :: IO ()
testAppendObjects = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendObjects pool
      [ ObjectRow "test.srf" "powerscript" "w_test" (Just "w_ancestor") Nothing Nothing "confirmed" "function"
      , ObjectRow "other.sru" "powerscript" "u_util" Nothing            Nothing Nothing "confirmed" "userobject"
      ]
    -- Appending an empty list after a real batch must not throw
    appendObjects pool []

testAppendProcedures :: IO ()
testAppendProcedures = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    -- Two procedures with non-empty JSON blobs
    let cfgJs  = "{\"entry\":\"b0\",\"exits\":[\"b0\"],\"blocks\":[],\"edges\":[]}"
        instrJs  = "{\"nodes\":[],\"entry\":0,\"suspensionPoints\":[],\"sourceMap\":[]}"
        wiringJs = "{\"nodes\":{\"w0\":{\"tag\":\"WireReturn\"}},\"entry\":\"w0\"}"
    appendProcedures pool
      [ ProcRow "test.srf" "w_test" "open"  "event"  1  10 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed" [] "w_test"
      , ProcRow "test.srf" "w_test" "close" "event" 11  20 cfgJs instrJs wiringJs "" "" (Just 1) "confirmed" [] "w_test"
      ]
    assertEqual "procedures appended" () ()

testAppendSqlStmtColumnsFilters :: IO ()
testAppendSqlStmtColumnsFilters = withHandle inMemory $ \conn -> do
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
testAppendCatalogRows = withHandle inMemory $ \conn -> do
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
testAppendDwRetrieveColumns = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveColumns pool
      [ DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "kodkrat"
      , DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "misth_zpkrat" "desckrat"
      ]
    -- Appending an empty list after a real batch must not throw
    appendDwRetrieveColumns pool []

testAppendDwRetrieveWhere :: IO ()
testAppendDwRetrieveWhere = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDwRetrieveWhere pool
      [ DwRetrieveWhereRow "d_test.srd" "d_test" 0 "misth_zpkrat.kodxrisi" "=" ":arg1" (Just "and")
      , DwRetrieveWhereRow "d_test.srd" "d_test" 1 "t.mycol" ">" "100" Nothing
      ]
    -- Appending an empty list after a real batch must not throw
    appendDwRetrieveWhere pool []

data DwArgumentReadback = DwArgumentReadback Text Text Text Text Int deriving (Eq, Show)

instance FromRow DwArgumentReadback where
  fromRow = DwArgumentReadback <$> field <*> field <*> field <*> field <*> field

testAppendDwArguments :: IO ()
testAppendDwArguments = do
  rows <- withHandle inMemory $ \conn -> do
    initSchema conn
    withTestPool conn $ \pool -> do
      appendDwArguments pool
        [ DwArgumentRow "d_test.srd" "d_test" "customer_id" "number" 0
        , DwArgumentRow "d_test.srd" "d_test" "as_of_date"  "date"   1
        ]
      -- Appending an empty list after a real batch must not throw
      appendDwArguments pool []
    queryHandle conn
      "SELECT file, object, arg_name, arg_type, ordinal FROM dw_arguments ORDER BY ordinal"
  assertEqual "dw_arguments round-trips DwArgumentRow rows in ordinal order"
    [ DwArgumentReadback "d_test.srd" "d_test" "customer_id" "number" 0
    , DwArgumentReadback "d_test.srd" "d_test" "as_of_date"  "date"   1
    ]
    rows

-- | Local row shape for reading back @dead_vars@ -- no production query
-- function exists (Python reads it directly via SQL), so this test query_s
-- the DuckDB connection directly rather than adding one.
data DeadVarRow = DeadVarRow Text Text Text (Maybe Int) Text deriving (Eq, Show)

instance FromRow DeadVarRow where
  fromRow = DeadVarRow <$> field <*> field <*> field <*> field <*> field

testAppendDeadVars :: IO ()
testAppendDeadVars = withHandle inMemory $ \conn -> do
  initSchema conn
  withTestPool conn $ \pool -> do
    appendDeadVars pool
      [ DeadVarFinding "w_test" "of_save" "li_unused" (Just 12) NeverRead
      , DeadVarFinding "w_test" "of_save" "as_param"  Nothing   UnusedParam
      ]
    -- Appending an empty list after a real batch must not throw
    appendDeadVars pool []

  rows <- queryHandle conn
    "SELECT object, proc_name, var_name, line, kind FROM dead_vars ORDER BY var_name"
  assertEqual "dead_vars round-trips DeadVarFinding rows"
    [ DeadVarRow "w_test" "of_save" "as_param"  Nothing   "unused-param"
    , DeadVarRow "w_test" "of_save" "li_unused" (Just 12) "never-read"
    ]
    rows

-- | Mixed token kinds: identifier-shaped ('TkIdent'/'TkOtherKw'/'TkSqlKw'/
--   'TkDatatype') kept, structural/operator kinds ('TkDot'/'TkLParen') and a
--   real control keyword excluded from the file's coverage denominator.
testIdentifierTokenRowsFilter :: IO ()
testIdentifierTokenRowsFilter =
  let toks =
        [ mkTok TkIdent     "super"  (1, 1, 1, 6)
        , mkTok TkDoubleColon "::"   (1, 6, 1, 8)
        , mkTok TkOtherKw   "create" (1, 8, 1, 14)
        , mkTok TkDot       "."      (2, 5, 2, 6)
        , mkTok TkLParen    "("      (2, 10, 2, 11)
        , mkTok TkControlKw "if"     (3, 1, 3, 3)
        , mkTok TkDatatype  "string" (4, 1, 4, 7)
        , mkTok TkSqlKw     "select" (5, 1, 5, 7)
        ]
      rows = identifierTokenRows "w_test.srw" toks
  in assertEqual "only identifier-shaped tokens survive, spans preserved"
       [ IdentifierTokenRow "w_test.srw" "super"  "TkIdent"    (SourceSpan 1 1 1 6)
       , IdentifierTokenRow "w_test.srw" "create" "TkOtherKw"  (SourceSpan 1 8 1 14)
       , IdentifierTokenRow "w_test.srw" "string" "TkDatatype" (SourceSpan 4 1 4 7)
       , IdentifierTokenRow "w_test.srw" "select" "TkSqlKw"    (SourceSpan 5 1 5 7)
       ]
       rows

-- | Two occurrences of the same identifier text at different spans must
--   both survive as distinct rows -- coverage is per-occurrence, not
--   per-distinct-name.
testIdentifierTokenRowsDuplicates :: IO ()
testIdentifierTokenRowsDuplicates =
  let toks =
        [ mkTok TkIdent "li_count" (1, 1, 1, 9)
        , mkTok TkIdent "li_count" (2, 1, 2, 9)
        ]
      rows = identifierTokenRows "w_test.srw" toks
  in assertEqual "duplicate-text tokens counted independently by span"
       [ IdentifierTokenRow "w_test.srw" "li_count" "TkIdent" (SourceSpan 1 1 1 9)
       , IdentifierTokenRow "w_test.srw" "li_count" "TkIdent" (SourceSpan 2 1 2 9)
       ]
       rows

data IdentifierTokenReadback = IdentifierTokenReadback Text Text Text Int Int Int Int
  deriving (Eq, Show)

instance FromRow IdentifierTokenReadback where
  fromRow = IdentifierTokenReadback
    <$> field <*> field <*> field <*> field <*> field <*> field <*> field

testAppendIdentifierTokens :: IO ()
testAppendIdentifierTokens = do
  rows <- withHandle inMemory $ \conn -> do
    initSchema conn
    withTestPool conn $ \pool -> do
      appendIdentifierTokens pool
        [ IdentifierTokenRow "w_test.srw" "super"  "TkIdent"   (SourceSpan 1 1 1 6)
        , IdentifierTokenRow "w_test.srw" "create" "TkOtherKw" (SourceSpan 1 8 1 14)
        ]
      -- Appending an empty list after a real batch must not throw
      appendIdentifierTokens pool []
    queryHandle conn
      "SELECT file, text, kind, start_line, start_col, end_line, end_col \
      \FROM identifier_tokens ORDER BY start_col"
  assertEqual "identifier_tokens round-trips IdentifierTokenRow rows"
    [ IdentifierTokenReadback "w_test.srw" "super"  "TkIdent"   1 1 1 6
    , IdentifierTokenReadback "w_test.srw" "create" "TkOtherKw" 1 8 1 14
    ]
    rows
