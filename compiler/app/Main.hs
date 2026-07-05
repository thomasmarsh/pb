module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeDb, runModeDualCps)

import qualified Data.Text as T
import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput   :: Maybe FilePath
  , optDb      :: Maybe FilePath
  , optDualCps :: Bool
  , optInspect :: Maybe Text
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input" <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"              <> metavar "FILE" <> help "DuckDB output path"))
  <*> switch   (long "dual-cps" <> help "Compare old and new CPS compilers on all procedures")
  <*> optional (T.pack <$> strOption (long "inspect" <> metavar "OBJ::PROC"
                  <> help "With --dual-cps, dump OLD/NEW shape nodes for one obj::proc and exit"))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optInput opts, optDb opts, optDualCps opts) of
    (Just inp, _,       True)  -> runModeDualCps inp (optInspect opts)
    (Just inp, Just db, False) -> runModeDb inp db
    _ -> die "usage: pbc -i <srcdir> --db <file>  |  pbc -i <srcdir> --dual-cps [--inspect obj::proc]"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
