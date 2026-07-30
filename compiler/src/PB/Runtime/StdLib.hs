{-# LANGUAGE TemplateHaskell #-}
module PB.Runtime.StdLib (parseStdlibFiles) where

import PB.Prelude
import Data.FileEmbed (embedDir)
import qualified Data.ByteString   as BS
import qualified Data.Text         as T
import qualified Data.Text.Encoding as TE
import PB.Pipeline.Emit (ParsedFile (..), parsePowerScriptFile, stripBom, stdlibPathPrefix)
import PB.AST.SourceFile (ParseError (..))
import System.FilePath  (takeFileName)

-- Embedded at compile time from runtime/ at the repo root (../runtime
-- relative to compiler/). 'embedDir' only registers a GHC recompilation
-- dependency on files present at the time it last spliced -- adding a new
-- runtime/*.sru file requires forcing this module to actually recompile
-- (not just relink) once, e.g. via 'cabal clean' or touching this file's
-- content, or the new file silently never reaches 'parseStdlibFiles'.
stdlibBytes :: [(FilePath, BS.ByteString)]
stdlibBytes = $(embedDir "../runtime")

-- | Parse all embedded stdlib .sru files into ParsedFile values.
-- Calls error if any file fails to parse (these are our own files; parse failure is a bug).
parseStdlibFiles :: IO [ParsedFile]
parseStdlibFiles = mapM parseOne stdlibBytes
  where
    parseOne (path, bytes) =
      let virtualPath = T.unpack stdlibPathPrefix <> takeFileName path
          src         = stripBom (TE.decodeUtf8 bytes)
      in case parsePowerScriptFile src of
           Left err          -> error ("stdlib: " <> virtualPath <> ": " <> T.unpack (peMessage err))
           Right (sf, sp, tks) -> pure ParsedFile
             { pfPath     = virtualPath
             , pfSrFile   = sf
             , pfSpans    = sp
             , pfContents = src
             , pfTokens   = tks
             }
