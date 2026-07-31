module PB.Runtime.StdLib (parseStdlibFiles) where

import PB.Prelude
import qualified Data.Text         as T
import qualified Data.Text.Encoding as TE
import PB.Pipeline.Emit (ParsedFile (..), parsePowerScriptFile, stripBom, stdlibPathPrefix)
import PB.AST.SourceFile (ParseError (..))
import PB.Runtime.StdLibBytes (stdlibBytes)
import System.FilePath  (takeFileName)

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
