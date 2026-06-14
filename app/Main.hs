module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeFiles, runModeJsonl)
import PB.Pipeline.Serialise (allTypeScriptDeclarations, formatTSDeclarations)

import qualified Data.Text as T
import Options.Applicative
import System.Exit (die)

data Options = Options
  { optInput  :: Maybe FilePath
  , optOutput :: Maybe FilePath
  , optJsonl  :: Bool
  , optEmitTs :: Bool
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input"  <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "output" <> short 'o' <> metavar "DIR" <> help "Output root directory"))
  <*> switch   (long "jsonl"   <> help "Stream one JSON object per file to stdout")
  <*> switch   (long "emit-ts" <> help "Print TypeScript type declarations for the AST to stdout")

main :: IO ()
main = do
  opts <- execParser (info (optParser <**> helper) desc)
  if optEmitTs opts
    then putStrLn (T.pack (formatTSDeclarations allTypeScriptDeclarations))
    else case (optInput opts, optOutput opts, optJsonl opts) of
      (Just inp, Just d,  False) -> runModeFiles inp d
      (Just inp, Nothing, True)  -> runModeJsonl inp
      (Just _,   Just _,  True)  -> die "cannot specify both -o and --jsonl"
      _ -> die "usage: pb-runner (-i <srcdir> (-o <outdir> | --jsonl)) | --emit-ts"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree to a mirrored JSON AST tree"
