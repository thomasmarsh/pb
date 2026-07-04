module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeDb, runModeDualCps)

import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput   :: Maybe FilePath
  , optDb      :: Maybe FilePath
  , optDualCps :: Bool
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input" <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"              <> metavar "FILE" <> help "DuckDB output path"))
  <*> switch   (long "dual-cps" <> help "Compare old and new CPS compilers on all procedures")

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optInput opts, optDb opts, optDualCps opts) of
    (Just inp, _,       True)  -> runModeDualCps inp
    (Just inp, Just db, False) -> runModeDb inp db
    _ -> die "usage: pbc -i <srcdir> --db <file>  |  pbc -i <srcdir> --dual-cps"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
