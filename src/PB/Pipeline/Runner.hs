module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  , wrapSrFile
  ) where

import PB.Prelude
import PB.AST.DataWindow
import PB.AST.SourceFile
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Grammar.File       (parseSrFileWithSpans, SrSpans (..))
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
-- DataWindow

runDataWindow :: FilePath -> Text -> Either Text Value
runDataWindow path src = fmap (wrapDwFile path) (parseDataWindow src)

wrapDwFile :: FilePath -> DataWindowFile -> Value
wrapDwFile path dw = case toJSON dw of
  Object o -> Object (KM.fromList ["file" .= path, "kind" .= ("datawindow" :: Text)] <> o)
  v        -> v

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
  stmts          <- collectStatements lexLines
  (srFile, spans) <- parseSrFileWithSpans headers stmts
  Right (wrapSrFile path srFile spans)

wrapSrFile :: FilePath -> SrFile -> SrSpans -> Value
wrapSrFile path sf spans =
    let (objName, ancestor) = case srTypeBlocks sf of
          (tb:_) -> (tdName (tbDecl tb), Just (tdAncestor (tbDecl tb)))
          []     -> (T.pack path, Nothing)
        injectMeta :: (Int, Int) -> Value -> Value
        injectMeta (start, end) (Object o) =
            Object (KM.fromList ["meta" .= metaVal] <> o)
          where metaVal = object
                  [ "file"      .= T.pack path
                  , "object"    .= objName
                  , "ancestor"  .= ancestor
                  , "startLine" .= start
                  , "endLine"   .= end
                  ]
        injectMeta _ v = v
    in object
        [ "file"            .= path
        , "kind"            .= ("powerscript" :: Text)
        , "headers"         .= srHeaders sf
        , "forward"         .= srForward sf
        , "prototypes"      .= srPrototypes sf
        , "variables"       .= srVariables sf
        , "globalInstances" .= srGlobalInstances sf
        , "typeBlocks"      .= srTypeBlocks sf
        , "onBlocks"        .= zipWith injectMeta (spOnBlocks    spans) (map toJSON (srOnBlocks    sf))
        , "events"          .= zipWith injectMeta (spEvents      spans) (map toJSON (srEvents      sf))
        , "functions"       .= zipWith injectMeta (spFunctions   spans) (map toJSON (srFunctions   sf))
        , "subroutines"     .= zipWith injectMeta (spSubroutines spans) (map toJSON (srSubroutines sf))
        ]

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

