module SqlParseTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr     (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Located  (Located (..))
import PB.Pipeline.SqlParse

import Control.Exception (SomeException, try)
import qualified Data.Text as T
import System.Directory  (getTemporaryDirectory)
import System.Process    (callProcess)

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertBool, testCase)

import Prelude ((!!))


-- ---------------------------------------------------------------------------
-- Mock Python worker scripts
-- ---------------------------------------------------------------------------

-- | Normal worker: loops forever, answers every request with canned data.
mockWorkerLines :: [Text]
mockWorkerLines =
  [ "#!/usr/bin/env python3"
  , "import sys, json, struct"
  , "H = struct.Struct('>I')"
  , "def read():"
  , "    h = sys.stdin.buffer.read(4)"
  , "    if len(h) < 4: return None"
  , "    (n,) = H.unpack(h)"
  , "    return json.loads(sys.stdin.buffer.read(n))"
  , "def write(obj):"
  , "    b = json.dumps(obj).encode()"
  , "    sys.stdout.buffer.write(H.pack(len(b)) + b)"
  , "    sys.stdout.buffer.flush()"
  , "while True:"
  , "    m = read()"
  , "    if m is None: sys.exit(0)"
  , "    write({'tables':['t'],'columns':['c'],'operation':'SELECT','parse_ok':True})"
  ]

-- | Crash worker: handles exactly one request then exits with code 1.
crashWorkerLines :: [Text]
crashWorkerLines =
  [ "#!/usr/bin/env python3"
  , "import sys, json, struct"
  , "H = struct.Struct('>I')"
  , "h = sys.stdin.buffer.read(4)"
  , "if len(h) == 4:"
  , "    (n,) = H.unpack(h)"
  , "    json.loads(sys.stdin.buffer.read(n))"
  , "    b = json.dumps({'tables':['t'],'columns':['c'],'operation':'SELECT','parse_ok':True}).encode()"
  , "    sys.stdout.buffer.write(H.pack(len(b)) + b)"
  , "    sys.stdout.buffer.flush()"
  , "sys.exit(1)"
  ]

-- | Write a script to a temp file and make it executable.
installScript :: String -> [Text] -> IO FilePath
installScript name ls = do
  tmp <- getTemporaryDirectory
  let path = tmp <> "/" <> name
  writeFile path (T.unlines ls)
  callProcess "chmod" ["+x", path]
  pure path

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "SqlParse"
  [ testGroup "extractBsRawNodes"
    [ testCase "empty list" $
        assertEqual "empty" [] (extractBsRawNodes [])

    , testCase "no BsRaw nodes" $
        assertEqual "no BsRaw"
          []
          (extractBsRawNodes [Located 1 BsExit, Located 2 BsContinue])

    , testCase "flat list of BsRaw" $ do
        let stmts =
              [ Located 1 (BsRaw "SELECT 1")
              , Located 2 BsExit
              , Located 3 (BsRaw "INSERT INTO t VALUES (1)")
              ]
        assertEqual "count" 2 (length (extractBsRawNodes stmts))
        assertEqual "line 1" (1, "SELECT 1")
          (extractBsRawNodes stmts !! 0)
        assertEqual "line 3" (3, "INSERT INTO t VALUES (1)")
          (extractBsRawNodes stmts !! 1)

    , testCase "nested inside BsIf then-branch" $ do
        let inner = [Located 10 (BsRaw "UPDATE t SET x = 1")]
            stmt  = Located 5 (BsIf IfStmt
              { ifCond    = ExNull
              , ifThen    = inner
              , ifElseIfs = []
              , ifElse    = Nothing
              })
        assertEqual "nested BsRaw"
          [(10, "UPDATE t SET x = 1")]
          (extractBsRawNodes [stmt])

    , testCase "nested in all if branches" $ do
        let ei   = ElseIf { eifCond = ExNull
                          , eifBody = [Located 2 (BsRaw "SELECT 2")] }
            stmt = Located 0 (BsIf IfStmt
              { ifCond    = ExNull
              , ifThen    = [Located 1 (BsRaw "SELECT 1")]
              , ifElseIfs = [ei]
              , ifElse    = Just [Located 3 (BsRaw "SELECT 3")]
              })
        assertEqual "all branches" 3 (length (extractBsRawNodes [stmt]))

    , testCase "nested inside BsFor" $ do
        let lv   = Lvalue [LvSegment { name = "x", subscript = Nothing }]
            stmt = Located 5 (BsFor ForStmt
              { forVar  = lv
              , forFrom = ExNull
              , forTo   = ExNull
              , forStep = Nothing
              , forBody = [Located 7 (BsRaw "EXECUTE sp_foo")]
              })
        assertEqual "BsFor" [(7, "EXECUTE sp_foo")] (extractBsRawNodes [stmt])

    , testCase "nested inside BsDo" $ do
        let stmt = Located 4 (BsDo DoStmt
              { doCond = Nothing
              , doBody = [Located 6 (BsRaw "DELETE FROM t")]
              , doLoop = Nothing
              })
        assertEqual "BsDo" [(6, "DELETE FROM t")] (extractBsRawNodes [stmt])

    , testCase "nested inside BsChoose clauses" $ do
        let c1   = CaseClause { ccExpr = Nothing
                              , ccBody = [Located 8 (BsRaw "SELECT 8")] }
            c2   = CaseClause { ccExpr = Nothing
                              , ccBody = [Located 9 (BsRaw "SELECT 9")] }
            stmt = Located 6 (BsChoose ChooseStmt
              { chooseExpr    = ExNull
              , chooseClauses = [c1, c2]
              })
        assertEqual "BsChoose" 2 (length (extractBsRawNodes [stmt]))
    ]

  , testGroup "SqlBridgePool"
    [ testCase "missing binary raises exception" $ do
        result <- try @SomeException (startSqlBridgePool 1 "/nonexistent/pb-sql-worker")
        assertBool "should throw on missing binary" (isLeft result)

    , testCase "pool of 2: send 5 requests each, all succeed" $ do
        script <- installScript "pb_mock_worker.py" mockWorkerLines
        pool   <- startSqlBridgePool 2 script
        results0 <- mapM (\_ -> parseSql pool 0 "SELECT foo FROM bar") [1..5 :: Int]
        results1 <- mapM (\_ -> parseSql pool 1 "SELECT baz FROM qux") [1..5 :: Int]
        traverse_ (\r -> assertEqual "parse_ok" True (srParseOk r))   (results0 <> results1)
        traverse_ (\r -> assertEqual "tables"   ["t"] (srTables r))   (results0 <> results1)
        traverse_ (\r -> assertEqual "columns"  ["c"] (srColumns r))  (results0 <> results1)
        shutdownSqlBridgePool pool

    , testCase "no cross-worker interference" $ do
        script <- installScript "pb_mock_worker.py" mockWorkerLines
        pool   <- startSqlBridgePool 2 script
        r0 <- parseSql pool 0 "SELECT from_worker_0"
        r1 <- parseSql pool 1 "SELECT from_worker_1"
        assertEqual "w0 parse_ok" True (srParseOk r0)
        assertEqual "w1 parse_ok" True (srParseOk r1)
        shutdownSqlBridgePool pool

    , testCase "crash recovery: worker restarts after exit-1" $ do
        -- Crash script handles exactly 1 request then exits with code 1.
        -- The pool auto-restarts; the retry spawns a fresh crash-script process
        -- which handles that 1 retry request before exiting again.
        crashScript <- installScript "pb_crash_worker.py" crashWorkerLines
        pool <- startSqlBridgePool 1 crashScript
        r1 <- parseSql pool 0 "SELECT 1"
        assertEqual "first call (before crash)" True (srParseOk r1)
        -- Worker crashed after responding. Next call triggers restart.
        r2 <- parseSql pool 0 "SELECT 2"
        assertEqual "second call (after restart)" True (srParseOk r2)
        shutdownSqlBridgePool pool
    ]
  ]
