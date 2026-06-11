module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeFiles, runModeJsonl)

import Options.Applicative
import System.Exit (die)

data Options = Options
  { inputDir  :: FilePath
  , outputDir :: Maybe FilePath
  , jsonlMode :: Bool
  }

optParser :: Parser Options
optParser = Options
  <$> strOption (long "input"  <> short 'i' <> metavar "DIR" <> help "Source root directory")
  <*> optional (strOption (long "output" <> short 'o' <> metavar "DIR" <> help "Output root directory"))
  <*> switch   (long "jsonl"  <> help "Stream one JSON object per file to stdout")

main :: IO ()
main = do
  opts <- execParser (info (optParser <**> helper) desc)
  case (outputDir opts, jsonlMode opts) of
    (Just d,  False) -> runModeFiles (inputDir opts) d
    (Nothing, True)  -> runModeJsonl (inputDir opts)
    (Just _,  True)  -> die "cannot specify both -o and --jsonl"
    (Nothing, False) -> die "usage: pb-runner -i <srcdir> (-o <outdir> | --jsonl)"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree to a mirrored JSON AST tree"
