module Main (main) where

-- | Corpus-scale self-consistency + wall-clock report for the algebraic
-- dead-code reachability closure ('PB.Analysis.DeadCodeAlgebra', a sparse
-- 'PB.Algebra.Closure.reachFrom' worklist -- NOT 'star's all-pairs closure,
-- see doc/plan/182-algebraic-analysis.md Section 11 / §12 item 6),
-- production's sole source for @proc_dead@ since the Plan 182 item 6
-- cutover.
--
-- Runs the existing pipeline unmodified (which now materializes @proc_dead@
-- algebraically via 'PB.Analysis.DeadCodeAlgebra.materializeDeadCodeClosure'
-- in 'PB.Pipeline.Passes.materializeAllEdbViews'), then re-reads the same raw
-- EDB inputs (procedures / resolved_calls / object ancestors / dw_objects)
-- and recomputes 'deadReachAlgebraic' independently, asserting the two are
-- content-exact -- a self-consistency check (determinism, no drift between
-- the production call site and a fresh one), not an oracle-diff. Unit-level
-- regression coverage for the closure's correctness lives entirely in
-- 'DeadCodeAlgebraTest.hs'.
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
    -- initDeadReachEdbViews). The algebraic path reads these directly.
    procs    <- queryProcedures conn
    calls    <- queryResolvedCalls conn
    inherits <- queryObjectAncestors conn
    dwObjs   <- queryDwObjects conn
    putStrLn (T.pack (show (length procs)) <> " procedures, "
           <> T.pack (show (length calls)) <> " resolved calls, "
           <> T.pack (show (length inherits)) <> " inherits, "
           <> T.pack (show (length dwObjs)) <> " dw objects")
    putStrLn ""

    -- Production's own proc_dead (materialized by materializeDeadCodeClosure
    -- during the pipeline run above).
    prodRows <- query_ conn "SELECT object, proc FROM proc_dead"
               :: IO [(Text, Text)]
    let prodDead = Set.fromList prodRows
    putStrLn ("production proc_dead: " <> T.pack (show (Set.size prodDead)) <> " pairs")

    -- Fresh, independent recomputation (closure alone, EDB already read).
    tAlg0 <- getCurrentTime
    let algDead = deadReachAlgebraic procs calls inherits dwObjs
        algCount = Set.size algDead
    tAlg1 <- algCount `seq` getCurrentTime
    putStrLn ("recomputed proc_dead: " <> T.pack (show algCount)
           <> " pairs in " <> showSecs (diffUTCTime tAlg1 tAlg0))

    -- Self-consistency: production's own output vs. a fresh recomputation.
    let consistent = algDead == prodDead
    putStrLn ("self-consistent (production == recomputed): " <> T.pack (show consistent))
    when (not consistent) $ do
      let missing = Set.difference prodDead algDead
          extra   = Set.difference algDead prodDead
      putStrLn ("  production-only: " <> T.pack (show (Set.size missing)))
      putStrLn ("  recomputed-only: " <> T.pack (show (Set.size extra)))

    putStrLn ""
    putStrLn ("Verdict: self-consistent=" <> T.pack (show consistent)
           <> ", closure " <> showSecs (diffUTCTime tAlg1 tAlg0))

  where
    desc = fullDesc <> progDesc
      "Corpus-scale self-consistency + wall-clock report for the algebraic dead-code closure."

    showSecs :: NominalDiffTime -> Text
    showSecs d = T.pack (show (realToFrac d :: Double)) <> "s"
