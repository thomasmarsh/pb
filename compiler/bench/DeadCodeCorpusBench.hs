module Main (main) where

-- | Corpus-scale content-exact + wall-clock report for the dead-code
-- reachability PoC ('PB.Analysis.DeadCodeAlgebra', a sparse
-- 'PB.Algebra.Closure.reachFrom' worklist — NOT 'star's all-pairs closure,
-- see doc/plan/182-algebraic-analysis.md Section 11 / §12 item 6), the
-- planned replacement for Souffle's 'deadReachRules' IDB step.
--
-- Runs the existing pipeline unmodified (which materializes the EDB views
-- and runs 'deadReachRules', leaving @proc_dead@ in DuckDB), then:
--
--   1. Reads the raw EDB inputs back (procedures / resolved_calls /
--      object ancestors / dw_objects) the same way 'initDeadReachEdbViews'
--      does, and computes the algebraic @proc_dead@ via 'deadReachAlgebraic'.
--   2. Reads Souffle's @proc_dead@ (already materialized by the pipeline)
--      and asserts the two are content-exact (row-for-row, not just counts).
--   3. Measures the algebraic closure alone (EDB already read) vs Souffle's
--      isolated 'deadReachRules' timer (re-run with EDB already
--      materialized) — the same discipline as §11's taint bench.
--
-- The Souffle 'deadReachRules' oracle this bench diffs against is retained
-- only as a migration oracle (§12 item 7 CORRECTION); once parity is proven
-- it is scheduled for deletion. This bench does NOT wire the algebraic path
-- into production — it is a measurement/gate tool only.
import PB.Prelude
import PB.Pipeline.Runner (runModeDb)
import PB.Pipeline.DuckDb
  ( withWriteConn
  , queryProcedures
  , queryResolvedCalls
  , queryObjectAncestors
  , queryDwObjects
  )
import Database.DuckDB.Simple (query_)
import PB.Analysis.DeadCodeAlgebra (deadReachAlgebraic)
import PB.Pipeline.Souffle (runRuleSet)
import PB.Analysis.Rules.DeadCode (deadReachRules)

import qualified Data.Set as Set
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors, setNumCapabilities)
import Options.Applicative

data Options = Options
  { optInput           :: FilePath
  , optDb              :: FilePath
  , optDdl             :: [Text]
  , optSqlDialect      :: Text
  , optSqlWorkerPython :: Maybe FilePath
  }

optParser :: Parser Options
optParser = Options
  <$> strOption (long "input" <> short 'i' <> metavar "DIR" <> value "../example/openpay-0.1.1b-extract"
       <> help "Source root directory (default: ../example/openpay-0.1.1b-extract)")
  <*> strOption (long "db" <> metavar "FILE" <> value "/tmp/deadcode-corpus-bench.duckdb"
       <> help "Scratch DuckDB output path")
  <*> many (strOption (long "ddl" <> metavar "[SCHEMA:]FILE"
       <> help "DDL catalog file, optionally schema-tagged (repeatable)"))
  <*> strOption (long "sql-dialect" <> metavar "DIALECT" <> value "oracle"
       <> help "sqlglot dialect for DDL/embedded-SQL parsing (default: oracle)")
  <*> optional (strOption (long "sql-worker-python" <> metavar "BIN"
       <> help "Path to the python interpreter used to launch the SQL bridge worker"))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)

  putStrLn ("Running full pipeline: " <> T.pack (optInput opts) <> " -> " <> T.pack (optDb opts))
  t0 <- getCurrentTime
  runModeDb (optInput opts) (optDb opts) (optDdl opts) (optSqlDialect opts) (optSqlWorkerPython opts) Nothing
  t1 <- getCurrentTime
  putStrLn ("Full pipeline wall-clock: " <> showSecs (diffUTCTime t1 t0))
  putStrLn ""

  withWriteConn (optDb opts) $ \conn -> do
    -- Read raw EDB inputs (already materialized by the pipeline's
    -- initDeadReachEdbViews). The algebraic path reads these directly —
    -- no Souffle materialization needed.
    procs    <- queryProcedures conn
    calls    <- queryResolvedCalls conn
    inherits <- queryObjectAncestors conn
    dwObjs   <- queryDwObjects conn
    putStrLn (T.pack (show (length procs)) <> " procedures, "
           <> T.pack (show (length calls)) <> " resolved calls, "
           <> T.pack (show (length inherits)) <> " inherits, "
           <> T.pack (show (length dwObjs)) <> " dw objects")
    putStrLn ""

    -- Souffle oracle: proc_dead already materialized by the pipeline's
    -- deadReachRules run.
    souffleRows <- query_ conn "SELECT object, proc FROM proc_dead"
                  :: IO [(Text, Text)]
    let souffleDead = Set.fromList souffleRows

    -- Algebraic closure (EDB already read above — "closure alone").
    tAlg0 <- getCurrentTime
    let algDead = deadReachAlgebraic procs calls inherits dwObjs
        algCount = Set.size algDead
    tAlg1 <- algCount `seq` getCurrentTime
    putStrLn ("algebraic proc_dead: " <> T.pack (show algCount)
           <> " pairs in " <> showSecs (diffUTCTime tAlg1 tAlg0))

    -- Oracle-diff: content-exact (row-for-row, not just counts).
    let parity = algDead == souffleDead
    putStrLn ("oracle-diff (algebraic == souffle proc_dead): " <> T.pack (show parity))
    when (not parity) $ do
      let missing = Set.difference souffleDead algDead
          extra   = Set.difference algDead souffleDead
      putStrLn ("  souffle-only (dead in souffle, not algebraic): "
             <> T.pack (show (Set.size missing)))
      putStrLn ("  algebraic-only (dead in algebraic, not souffle): "
             <> T.pack (show (Set.size extra)))

    -- Isolated Souffle timer: re-run deadReachRules with EDB already
    -- materialized (same discipline as §11's taint bench).
    tSouffle0 <- getCurrentTime
    runRuleSet conn deadReachRules
    tSouffle1 <- getCurrentTime
    putStrLn ("souffle deadReachRules (isolated, EDB materialized): "
           <> showSecs (diffUTCTime tSouffle1 tSouffle0))

    -- Confirm Souffle proc_dead is stable across the re-run.
    souffleRows2 <- query_ conn "SELECT object, proc FROM proc_dead"
                   :: IO [(Text, Text)]
    let souffleDead2 = Set.fromList souffleRows2
    putStrLn ("souffle proc_dead count (after re-run): "
           <> T.pack (show (Set.size souffleDead2)))
    putStrLn ("souffle proc_dead stable across re-run: "
           <> T.pack (show (souffleDead == souffleDead2)))

    -- Verdict.
    let algSecs     = realToFrac (diffUTCTime tAlg1 tAlg0) :: Double
        souffleSecs = realToFrac (diffUTCTime tSouffle1 tSouffle0) :: Double
    putStrLn ""
    putStrLn ("Verdict: parity=" <> T.pack (show parity)
           <> ", algebraic " <> showSecs (diffUTCTime tAlg1 tAlg0)
           <> " vs souffle " <> showSecs (diffUTCTime tSouffle1 tSouffle0))
    when (algSecs > souffleSecs) $
      putStrLn "WARNING: algebraic closure is SLOWER than souffle (regression vs §12 item 6)."

  where
    desc = fullDesc <> progDesc
      "Corpus-scale content-exact + wall-clock report for the dead-code reachFrom PoC."

    showSecs :: NominalDiffTime -> Text
    showSecs d = T.pack (show (realToFrac d :: Double)) <> "s"
