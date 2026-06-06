module PB.Pipeline.Runner
  ( runFile
  ) where

import PB.Prelude
import Data.Aeson     (Value, object, (.=))
import Data.Char      (toLower)
import System.FilePath (takeExtension)

-- | Top-level entry point: parse one PowerBuilder source file into a JSON AST.
--   Dispatches to the appropriate parser based on file extension.
runFile :: FilePath -> Text -> Either Text Value
runFile path src = case classifyFile path of
  DataWindow  -> runDataWindow  path src
  PowerScript -> runPowerScript path src

data FileKind = DataWindow | PowerScript

classifyFile :: FilePath -> FileKind
classifyFile fp = case map toLower (takeExtension fp) of
  ".srd" -> DataWindow
  _      -> PowerScript

runDataWindow :: FilePath -> Text -> Either Text Value
runDataWindow path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("datawindow" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

runPowerScript :: FilePath -> Text -> Either Text Value
runPowerScript path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("powerscript" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]
