module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeDb)

import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput      :: Maybe FilePath
  , optDb         :: Maybe FilePath
  , optDdl        :: [Text]
  , optSqlDialect :: Text
  , optSqlWorkerPython :: Maybe FilePath
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input" <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"              <> metavar "FILE" <> help "DuckDB output path"))
  <*> many (strOption (long "ddl" <> metavar "[SCHEMA:]FILE"
              <> help "DDL catalog file, optionally schema-tagged (repeatable, e.g. --ddl CLIMS:clims.sql)"))
  <*> strOption (long "sql-dialect" <> metavar "DIALECT" <> value "oracle"
              <> help "sqlglot dialect for both DDL and embedded-SQL parsing (default: oracle)")
  <*> optional (strOption (long "sql-worker-python" <> metavar "BIN"
              <> help "Path to the python interpreter used to launch the SQL bridge worker \
                       \(pb.pipeline.bridge.sql_worker, run via -m -- its location is fixed \
                       \within the pb_pipeline distribution and needs no separate discovery). \
                       \Overrides PB_SQL_WORKER env var; the pb CLI always passes its own \
                       \sys.executable here unconditionally, so bridge availability can't be \
                       \lost to environment-variable propagation."))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optInput opts, optDb opts) of
    (Just inp, Just db) -> runModeDb inp db (optDdl opts) (optSqlDialect opts) (optSqlWorkerPython opts)
    _ -> die "usage: pbc -i <srcdir> --db <file> [--ddl [SCHEMA:]<file>]... [--sql-dialect <dialect>] [--sql-worker-python <bin>]"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
