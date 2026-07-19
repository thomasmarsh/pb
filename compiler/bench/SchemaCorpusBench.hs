module Main (main) where

-- | Corpus-scale parity gate for the algebraic schema-category closure
-- ('PB.Analysis.SchemaClosure' — 'legPriority' / 'reachClosure' /
-- 'cosliceClosure') against the production SQL materializers.
--
-- Runs the existing pipeline UNMODIFIED (so the production SQL materializers
-- populate the @reaches@ / @path_leg_fwd@ / @path_leg_back@ tables), then
-- independently recomputes those same three relations from the raw
-- @schema_morphisms@ / @schema_objects@ input relations via 'SchemaClosure', and
-- asserts the two are content-exact. This is a self-consistency check
-- (production SQL materializers vs. the algebraic closure), not the
-- 'DeadCodeCorpusBench' determinism check — it must PASS (exit non-zero on
-- any mismatch).
import PB.Prelude
import PB.Pipeline.Runner (runModeDb)
import PB.Pipeline.DuckDb
  ( withHandle, Config(..), queryHandle
  )
import PB.Pipeline.DuckDb.PhaseB.Query
  ( querySchemaMorphismRows
  , querySchemaObjects
  )
import PB.Pipeline.DuckDb.Relations (legSourceRows, seedRows)
import PB.Analysis.SchemaClosure
  ( legPriority, reachClosure, cosliceClosure )

import qualified Data.Set as Set
import qualified Data.Text as T
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
  <*> strOption (long "db" <> metavar "FILE" <> value "/tmp/schema-corpus-bench.duckdb"
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

  putStrLn ("Running full pipeline (production SQL materializers): "
            <> T.pack (optInput opts) <> " -> " <> T.pack (optDb opts))
  t0 <- getCurrentTime
  runModeDb (optInput opts) (optDb opts) (optDdl opts) (optSqlDialect opts) (optSqlWorkerPython opts) Nothing
  t1 <- getCurrentTime
  putStrLn ("Full pipeline wall-clock: " <> showSecs (diffUTCTime t1 t0))
  putStrLn ""

  withHandle (Config (optDb opts)) $ \conn -> do
    -- Production outputs materialized by the SQL materializers.
    prodReaches <- queryHandle conn "SELECT x, y FROM reaches"
                   :: IO [(Text, Text)]
    prodFwd <- queryHandle conn
                 "SELECT s, target, leg_ord, lf, lt, kind FROM path_leg_fwd"
                 :: IO [(Text, Text, Text, Text, Text, Text)]
    prodBack <- queryHandle conn
                  "SELECT s, target, leg_ord, lf, lt, kind FROM path_leg_back"
                  :: IO [(Text, Text, Text, Text, Text, Text)]

    let prodReachSet = Set.fromList [ [x, y] | (x, y) <- prodReaches ]
        prodFwdSet   = Set.fromList
          [ [s, t, o, lf, lt, k] | (s, t, o, lf, lt, k) <- prodFwd ]
        prodBackSet  = Set.fromList
          [ [s, t, o, lf, lt, k] | (s, t, o, lf, lt, k) <- prodBack ]

    putStrLn ("production reaches: " <> T.pack (show (Set.size prodReachSet)) <> " pairs")
    putStrLn ("production path_leg_fwd: " <> T.pack (show (Set.size prodFwdSet)) <> " rows")
    putStrLn ("production path_leg_back: " <> T.pack (show (Set.size prodBackSet)) <> " rows")
    putStrLn ""

    -- Independent algebraic recomputation from the raw input relations.
    morphisms <- querySchemaMorphismRows conn
    objects   <- querySchemaObjects conn
    let legSource = legSourceRows morphisms
        seeds    = [ k | [k] <- seedRows objects ]
        leg      = legPriority legSource
        reaches  = reachClosure leg
        (pathFwd, pathBack) = cosliceClosure seeds leg
        algReachSet = Set.fromList reaches
        algFwdSet   = Set.fromList pathFwd
        algBackSet  = Set.fromList pathBack

    putStrLn ("recomputed reaches: " <> T.pack (show (Set.size algReachSet)) <> " pairs")
    putStrLn ("recomputed path_leg_fwd: " <> T.pack (show (Set.size algFwdSet)) <> " rows")
    putStrLn ("recomputed path_leg_back: " <> T.pack (show (Set.size algBackSet)) <> " rows")
    putStrLn ""

    let reachOk = algReachSet == prodReachSet
        fwdOk   = algFwdSet   == prodFwdSet
        backOk  = algBackSet  == prodBackSet
        allOk   = reachOk && fwdOk && backOk

    unless reachOk $ reportDiff "reaches" prodReachSet algReachSet
    unless fwdOk   $ reportDiff "path_leg_fwd" prodFwdSet algFwdSet
    unless backOk  $ reportDiff "path_leg_back" prodBackSet algBackSet

    putStrLn ("Verdict: oracle-diff consistent="
              <> T.pack (show allOk)
              <> " (reaches=" <> T.pack (show reachOk)
              <> ", path_leg_fwd=" <> T.pack (show fwdOk)
              <> ", path_leg_back=" <> T.pack (show backOk) <> ")")

    -- Gate: fail loudly if parity is not proven.
    unless allOk $
      error "SchemaCorpusBench: parity MISMATCH — production SQL materializers and algebraic closure disagree."

  where
    desc = fullDesc <> progDesc
      "Corpus-scale parity gate for the algebraic schema-category closure (production SQL materializers vs. SchemaClosure)."

    reportDiff :: Text -> Set.Set [Text] -> Set.Set [Text] -> IO ()
    reportDiff name prod alg = do
      let missing = Set.difference prod alg   -- in production, not in algebraic
          extra   = Set.difference alg prod   -- in algebraic, not in production
      putStrLn ("  " <> name <> " mismatch:")
      putStrLn ("    production-only: " <> T.pack (show (Set.size missing)))
      putStrLn ("    algebraic-only: " <> T.pack (show (Set.size extra)))

    showSecs :: NominalDiffTime -> Text
    showSecs d = T.pack (show (realToFrac d :: Double)) <> "s"
