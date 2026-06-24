module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeDb)
import PB.Pipeline.Serialise (emitTypeScript)

import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput  :: Maybe FilePath
  , optDb     :: Maybe FilePath
  , optEmitTs :: Bool
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input"  <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "db"               <> metavar "FILE" <> help "DuckDB output path"))
  <*> switch   (long "emit-ts"      <> help "Print TypeScript type declarations for the AST to stdout")

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case optEmitTs opts of
    True -> putStr emitTypeScript
    _    -> case (optInput opts, optDb opts) of
      (Just inp, Just db) -> runModeDb inp db
      _ -> die "usage: pb-runner -i <srcdir> --db <file> | --emit-ts"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree into a DuckDB AST database"
