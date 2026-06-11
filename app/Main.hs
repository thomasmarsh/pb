module Main (main) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)
import PB.Pipeline.Walk   (walkAllSrFiles)

import Data.Aeson               (encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text            as T

import Control.Exception        (SomeException, try)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.FilePath  (makeRelative, takeDirectory, (</>))

data Options = Options
  { inputDir  :: FilePath
  , outputDir :: FilePath
  }

optParser :: Parser Options
optParser = Options
  <$> strOption (long "input"  <> short 'i' <> metavar "DIR" <> help "Source root directory")
  <*> strOption (long "output" <> short 'o' <> metavar "DIR" <> help "Output root directory")

main :: IO ()
main = do
  opts  <- execParser (info (optParser <**> helper) desc)
  files <- walkAllSrFiles (inputDir opts)
  mapM_ (processFile opts) files
  where
    desc = fullDesc <> progDesc "Parse a PowerBuilder source tree to a mirrored JSON AST tree"

-- | Parse one file and write its JSON to the mirrored output path.
-- Encoding errors (e.g. Windows-1253 OpenPay files) produce an error JSON
-- rather than crashing the process.
processFile :: Options -> FilePath -> IO ()
processFile opts src = do
  let rel     = makeRelative (inputDir opts) src
      outPath = outputDir opts </> rel <> ".json"
      outDir  = takeDirectory outPath
  createDirectoryIfMissing True outDir
  readResult <- try (readFile src) :: IO (Either SomeException Text)
  let outcome = case readResult of
        Left  ex       -> Left ("encoding error: " <> T.pack (show ex))
        Right contents -> runFile src contents
  BL.writeFile outPath $ case outcome of
    Left  err -> encode $ object ["file" .= src, "error" .= err]
    Right val -> encode val
