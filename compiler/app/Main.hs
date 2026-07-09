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
  , optSqlWorker  :: Maybe FilePath
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input" <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"              <> metavar "FILE" <> help "DuckDB output path"))
  <*> many (strOption (long "ddl" <> metavar "[SCHEMA:]FILE"
              <> help "DDL catalog file, optionally schema-tagged (repeatable, e.g. --ddl CLIMS:clims.sql)"))
  <*> strOption (long "sql-dialect" <> metavar "DIALECT" <> value "oracle"
              <> help "sqlglot dialect for both DDL and embedded-SQL parsing (default: oracle)")
  <*> optional (strOption (long "sql-worker" <> metavar "BIN"
              <> help "Path to the pb-sql-worker binary (overrides PB_SQL_WORKER env var; \
                       \the pb CLI resolves and passes this explicitly so DDL/SQL parsing \
                       \doesn't depend on environment-variable propagation)"))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optInput opts, optDb opts) of
    (Just inp, Just db) -> runModeDb inp db (optDdl opts) (optSqlDialect opts) (optSqlWorker opts)
    _ -> die "usage: pbc -i <srcdir> --db <file> [--ddl [SCHEMA:]<file>]... [--sql-dialect <dialect>] [--sql-worker <bin>]"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
