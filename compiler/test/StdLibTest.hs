module StdLibTest (tests) where

import PB.Prelude
import PB.Pipeline.DuckDb
import PB.Pipeline.Emit    (ParsedFile (..), ParseOutcome (..), parsePowerScriptFile, stripBom)
import PB.Pipeline.Runner  (compileOne, appendToDb)
import PB.Analysis.TypeEnv (WorkspaceEnv (..), buildWorkspaceEnv)
import PB.Analysis.TypeCheck (buildTypeCheckWorkspace)
import PB.Analysis.DwFootprint (mkDwFootprintCtx)
import PB.Runtime.StdLib   (parseStdlibFiles)

import Database.DuckDB.Simple          (Query, query_)
import Database.DuckDB.Simple.FromRow  (FromRow (..), field)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertEqual, assertBool)

tests :: TestTree
tests = testGroup "StdLib"
  [ testCase "parseStdlibFiles produces all 11 classes"        testParsed
  , testCase "loadStdlib: objects table populated"             testObjectsTable
  , testCase "loadStdlib: procedures for powerobject present"  testProcedures
  , testCase "loadStdlib: all rows are __stdlib__ files"       testFilePrefix
  , testCase "loadStdlib: all rows have confidence=speculative" testConfidence
  , testCase "user-code rows have confidence=confirmed"        testUserConfirmed
  , testCase "stdlib TypeEnv contains inheritance chain"       testInheritance
  ]

newtype OneText = OneText { unOneText :: Text }
instance FromRow OneText where fromRow = OneText <$> field

expectedClasses :: [Text]
expectedClasses =
  [ "powerobject", "nonvisualobject", "dragobject", "drawobject"
  , "graphicobject", "windowobject", "window", "userobject"
  , "dwobject", "datastore", "datawindow"
  ]

withStdlibDb :: (DuckConn -> IO a) -> IO a
withStdlibDb act = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  pfs <- parseStdlibFiles
  let wsEnv = buildWorkspaceEnv (map pfSrFile pfs)
  withAppenderPool conn phaseATables $ \pool -> do
    mapM_ (\pf -> do
      cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) wsEnv Map.empty (buildTypeCheckWorkspace []) Map.empty Nothing "speculative" (PsParsed pf)
      appendToDb pool cf) pfs
  act conn
  where
    phaseATables =
      [ "objects", "procedures", "local_vars", "dead_vars", "type_mismatches", "call_sites", "global_vars"
      , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
      , "sql_statement_filters", "sql_statement_tables", "cat_footprint_columns"
      , "source_files", "parse_errors"
      , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
      , "dw_write_columns", "dw_where_columns", "dw_joins", "dw_retrieve_where"
      , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
      ]

queryOneTexts :: DuckConn -> Query -> IO [Text]
queryOneTexts conn sql = map unOneText <$> query_ conn sql

testParsed :: IO ()
testParsed = do
  pfs <- parseStdlibFiles
  assertEqual "file count" 11 (length pfs)
  let paths = map (T.pack . pfPath) pfs
  mapM_ (\cls ->
    assertBool ("missing __stdlib__/" <> T.unpack cls <> ".sru")
               (("__stdlib__/" <> cls <> ".sru") `elem` paths)
    ) expectedClasses

testObjectsTable :: IO ()
testObjectsTable = withStdlibDb $ \conn -> do
  objs <- queryOneTexts conn "SELECT object FROM objects ORDER BY object"
  mapM_ (\cls ->
    assertBool ("missing object: " <> T.unpack cls) (cls `elem` objs)
    ) expectedClasses

testProcedures :: IO ()
testProcedures = withStdlibDb $ \conn -> do
  procs <- queryOneTexts conn
    "SELECT proc_name FROM procedures WHERE object = 'powerobject'"
  assertBool "PostEvent present" ("PostEvent" `elem` procs)
  assertBool "ClassName present" ("ClassName" `elem` procs)

testFilePrefix :: IO ()
testFilePrefix = withStdlibDb $ \conn -> do
  badFiles <- queryOneTexts conn
    "SELECT DISTINCT file FROM objects WHERE file NOT LIKE '__stdlib__%'"
  assertEqual "no non-stdlib object rows" [] badFiles
  badProcFiles <- queryOneTexts conn
    "SELECT DISTINCT file FROM procedures WHERE file NOT LIKE '__stdlib__%'"
  assertEqual "no non-stdlib procedure rows" [] badProcFiles

testConfidence :: IO ()
testConfidence = withStdlibDb $ \conn -> do
  badObjs <- queryOneTexts conn
    "SELECT object FROM objects WHERE confidence != 'speculative'"
  assertEqual "all object rows speculative" [] badObjs
  badProcs <- queryOneTexts conn
    "SELECT proc_name FROM procedures WHERE confidence != 'speculative'"
  assertEqual "all procedure rows speculative" [] badProcs

testUserConfirmed :: IO ()
testUserConfirmed = withWriteConn ":memory:" $ \conn -> do
  initSchema conn
  let src = "HA$PBExportHeader$w_test.srw\n\nglobal type w_test from window\nend type\n"
  case parsePowerScriptFile (stripBom src) of
    Left  err      -> error ("parse: " <> T.unpack err)
    Right (sf, sp) -> do
      let wsEnv = buildWorkspaceEnv [sf]
          pf    = ParsedFile "w_test.srw" sf sp src
      withAppenderPool conn phaseATables $ \pool -> do
        cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) wsEnv Map.empty (buildTypeCheckWorkspace []) Map.empty Nothing "confirmed" (PsParsed pf)
        appendToDb pool cf
  confs <- queryOneTexts conn "SELECT confidence FROM objects"
  assertEqual "user object is confirmed" ["confirmed"] confs
  where
    phaseATables =
      [ "objects", "procedures", "local_vars", "dead_vars", "type_mismatches", "call_sites", "global_vars"
      , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
      , "sql_statement_filters", "sql_statement_tables", "cat_footprint_columns"
      , "source_files", "parse_errors"
      , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
      , "dw_write_columns", "dw_where_columns", "dw_joins", "dw_retrieve_where"
      , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
      ]

testInheritance :: IO ()
testInheritance = do
  pfs    <- parseStdlibFiles
  let ut = weHierarchy (buildWorkspaceEnv (map pfSrFile pfs))
  assertEqual "powerobject → object"
    (Just "object")      (Map.lookup "powerobject"     ut)
  assertEqual "nonvisualobject → powerobject"
    (Just "powerobject") (Map.lookup "nonvisualobject" ut)
  assertEqual "dragobject → powerobject"
    (Just "powerobject") (Map.lookup "dragobject"      ut)
  assertEqual "graphicobject → dragobject"
    (Just "dragobject")  (Map.lookup "graphicobject"   ut)
  assertEqual "windowobject → dragobject"
    (Just "dragobject")  (Map.lookup "windowobject"    ut)
  assertEqual "window → windowobject"
    (Just "windowobject") (Map.lookup "window"         ut)
  assertEqual "dwobject → powerobject"
    (Just "powerobject") (Map.lookup "dwobject"        ut)
  assertEqual "datawindow → dwobject"
    (Just "dwobject")    (Map.lookup "datawindow"      ut)
  assertEqual "datastore → dwobject"
    (Just "dwobject")    (Map.lookup "datastore"       ut)
