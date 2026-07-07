module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeDb)

import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput :: Maybe FilePath
  , optDb    :: Maybe FilePath
  , optDdl   :: Maybe FilePath
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input" <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"              <> metavar "FILE" <> help "DuckDB output path"))
  <*> optional (strOption (long "ddl"             <> metavar "FILE" <> help "DDL catalog file (optional)"))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optInput opts, optDb opts) of
    (Just inp, Just db) -> runModeDb inp db (optDdl opts)
    _ -> die "usage: pbc -i <srcdir> --db <file> [--ddl <file>]"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
