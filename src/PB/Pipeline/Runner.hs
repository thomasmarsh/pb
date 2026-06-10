module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  , wrapSrFile
  ) where

import PB.Prelude
import PB.AST.SourceFile
import PB.Grammar.File      (parseSrFile)
import PB.Lexing.Lexer      (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Splitter   (Statement (..), splitStatements)
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText, stripHeaders)
import PB.Pipeline.Serialise  ()

import Data.Aeson          (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Char           (toLower)
import qualified Data.Text as T
import System.FilePath     (takeExtension)

-- ---------------------------------------------------------------------------
-- Entry point

runFile :: FilePath -> Text -> Either Text Value
runFile path src = case fileKind path of
  DataWindow  -> runDataWindow  path src
  Pipeline    -> runPipeline    path src
  Project     -> runProject     path src
  PowerScript -> runPowerScript path src

data FileKind = DataWindow | Pipeline | Project | PowerScript

fileKind :: FilePath -> FileKind
fileKind fp = case map toLower (takeExtension fp) of
  ".srd" -> DataWindow
  ".srp" -> Pipeline
  ".srj" -> Project
  _      -> PowerScript

-- ---------------------------------------------------------------------------
-- DataWindow (stub)

runDataWindow :: FilePath -> Text -> Either Text Value
runDataWindow path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("datawindow" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

runPipeline :: FilePath -> Text -> Either Text Value
runPipeline path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("pipeline" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

runProject :: FilePath -> Text -> Either Text Value
runProject path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("project" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

-- ---------------------------------------------------------------------------
-- PowerScript pipeline

runPowerScript :: FilePath -> Text -> Either Text Value
runPowerScript path src = do
  let logicalLines         = normalizeText src
      (headers, bodyLines) = stripHeaders logicalLines
      lexLines             = tokenize bodyLines
  stmts  <- collectStatements lexLines
  srFile <- parseSrFile headers stmts
  Right (wrapSrFile path srFile)

wrapSrFile :: FilePath -> SrFile -> Value
wrapSrFile path sf = case toJSON sf of
  Object o -> Object (KM.fromList ["file" .= path, "kind" .= ("powerscript" :: Text)] <> o)
  v        -> v

-- | Convert lex results to statements, failing on the first lex error.
--   Empty-token statements (blank lines) are filtered out so the grammar
--   parser's eof succeeds on trailing whitespace.
collectStatements :: [LexLine] -> Either Text [Statement]
collectStatements lexLines =
  let results = splitStatements lexLines
  in case [err | Left err <- results] of
    (e : _) -> Left
        ("lex error at offset " <> T.pack (show (leOffset e))
         <> " line "            <> T.pack (show (llStartLine (leSource e))))
    [] -> Right [s | Right s <- results, not (null (stmtTokens s))]

