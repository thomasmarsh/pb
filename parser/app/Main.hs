module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeFiles, runModeJsonl)
import PB.Pipeline.Serialise (emitPython, emitTypeScript)

import Options.Applicative
import System.Exit (die)
import GHC.Conc   (getNumProcessors, setNumCapabilities)

data Options = Options
  { optInput  :: Maybe FilePath
  , optOutput :: Maybe FilePath
  , optJsonl  :: Bool
  , optEmitTs :: Bool
  , optEmitPy :: Bool
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input"  <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "output" <> short 'o' <> metavar "DIR" <> help "Output root directory"))
  <*> switch   (long "jsonl"   <> help "Stream one JSON object per file to stdout")
  <*> switch   (long "emit-ts" <> help "Print TypeScript type declarations for the AST to stdout")
  <*> switch   (long "emit-py" <> help "Print Python TypedDict declarations for the AST to stdout")

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)
  case (optEmitTs opts, optEmitPy opts) of
    (True, _) -> putStr emitTypeScript
    (_, True) -> putStr emitPython
    _         -> case (optInput opts, optOutput opts, optJsonl opts) of
      (Just inp, Just d,  False) -> runModeFiles inp d
      (Just inp, Nothing, True)  -> runModeJsonl inp
      (Just _,   Just _,  True)  -> die "cannot specify both -o and --jsonl"
      _ -> die "usage: pb-runner (-i <srcdir> (-o <outdir> | --jsonl)) | --emit-ts | --emit-py"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree to a mirrored JSON AST tree"
