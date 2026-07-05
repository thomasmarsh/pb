module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeDb, runModeDualCps, runModeDualTrace)

import qualified Data.Text as T
import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput     :: Maybe FilePath
  , optDb        :: Maybe FilePath
  , optDualCps   :: Bool
  , optDualTrace :: Bool
  , optInspect   :: Maybe Text
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input" <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"              <> metavar "FILE" <> help "DuckDB output path"))
  <*> switch   (long "dual-cps" <> help "Compare old and new CPS compilers on all procedures (shape diff)")
  <*> switch   (long "dual-trace" <> help "Compare old and new CPS compilers on all procedures (behavioral trace diff)")
  <*> optional (T.pack <$> strOption (long "inspect" <> metavar "OBJ::PROC"
                  <> help "With --dual-cps, dump OLD/NEW shape nodes for one obj::proc and exit"))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optInput opts, optDb opts, optDualCps opts, optDualTrace opts) of
    (Just inp, _,       True,  False) -> runModeDualCps inp (optInspect opts)
    (Just inp, _,       False, True)  -> runModeDualTrace inp
    (Just inp, Just db, False, False) -> runModeDb inp db
    _ -> die "usage: pbc -i <srcdir> --db <file>  |  pbc -i <srcdir> --dual-cps [--inspect obj::proc]  |  pbc -i <srcdir> --dual-trace"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
