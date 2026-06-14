module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runModeFiles, runModeJsonl)
import PB.Pipeline.Schema (astSchemaJSON, srFileSchemaJSON)

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Text as T
import Options.Applicative
import System.Exit (die)

data Options = Options
  { optInput   :: Maybe FilePath
  , optOutput  :: Maybe FilePath
  , optJsonl   :: Bool
  , optSchema  :: Maybe Text
  }

optParser :: Parser Options
optParser = Options
  <$> optional (strOption (long "input"  <> short 'i' <> metavar "DIR" <> help "Source root directory"))
  <*> optional (strOption (long "output" <> short 'o' <> metavar "DIR" <> help "Output root directory"))
  <*> switch   (long "jsonl"  <> help "Stream one JSON object per file to stdout")
  <*> optional (strOption (long "schema" <> metavar "TYPE" <> help "Dump JSON Schema (body|srfile) to stdout"))

main :: IO ()
main = do
  opts <- execParser (info (optParser <**> helper) desc)
  case optSchema opts of
    Just "body"   -> BSL.putStrLn (encode astSchemaJSON)
    Just "srfile" -> BSL.putStrLn (encode srFileSchemaJSON)
    Just other    -> die $ "unknown schema type: " <> T.unpack other <> " (use body or srfile)"
    Nothing -> case (optInput opts, optOutput opts, optJsonl opts) of
      (Just inp, Just d,  False) -> runModeFiles inp d
      (Just inp, Nothing, True)  -> runModeJsonl inp
      (Just _,    Just _,  True)  -> die "cannot specify both -o and --jsonl"
      _ -> die "usage: pb-runner (-i <srcdir> (-o <outdir> | --jsonl)) | --schema (body|srfile)"
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree to a mirrored JSON AST tree"
