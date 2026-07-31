-- | Parses '// @effects Tag, Tag' pragma comments out of the raw text of
-- @runtime\/*.sru@ files -- the effect-classification vocabulary
-- 'PB.Analysis.CallClassify' used to hand-maintain as disconnected literal
-- tables. A raw line-scanner over plain 'Text', deliberately independent of
-- 'PB.Lexing.*'\/'PB.Grammar.*' (these comments are stripped by the shared
-- lexer and never reach the AST) and of 'PB.Analysis.CallClassify.EffectTag'
-- itself: tag names are returned as raw 'Text', not decoded, so this module
-- has no dependency on the Analysis layer -- 'CallClassify' depends on this
-- module, so the reverse dependency would cycle.
module PB.Runtime.EffectAnnotations
  ( parseEffectAnnotations
  , realEffectAnnotations
  ) where

import PB.Prelude
import PB.Runtime.StdLibBytes (stdlibBytes)
import qualified Data.Map.Strict    as Map
import qualified Data.Set           as Set
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.FilePath (takeBaseName)

-- | Parse a set of raw @(FilePath, Text)@ file contents into a lookup keyed
-- by (lowercased class name from the filename, lowercased method name).
-- Exposed as a pure function of its input (rather than only the embedded
-- real files) so it can be unit-tested against small inline fixtures.
parseEffectAnnotations :: [(FilePath, Text)] -> Map.Map (Text, Text) (Set.Set Text)
parseEffectAnnotations files = Map.fromList
  [ ((className, methodName), tags)
  | (path, contents) <- files
  , let className = T.toLower (T.pack (takeBaseName path))
  , (methodName, tags) <- scanFile contents
  ]

-- | The real @runtime\/*.sru@ annotation table, decoded once from the
-- embedded stdlib bytes. Sourced from 'PB.Runtime.StdLibBytes' directly
-- (not 'PB.Runtime.StdLib', which pulls in the full parse pipeline and
-- would import-cycle back through 'PB.Compile.Flatten' into
-- 'PB.Analysis.CallClassify').
realEffectAnnotations :: Map.Map (Text, Text) (Set.Set Text)
realEffectAnnotations = parseEffectAnnotations
  [ (path, TE.decodeUtf8 bytes) | (path, bytes) <- stdlibBytes ]

-- | Walk a file's lines, pairing each @\/\/ \@effects ...@ comment with the
-- next @public function|subroutine|event@ declaration's own method name. A
-- non-blank line that isn't a matching declaration drops the pending
-- annotation rather than carrying it forward, so an annotation only ever
-- attaches to the declaration immediately below it.
scanFile :: Text -> [(Text, Set.Set Text)]
scanFile contents = go (T.lines contents) Nothing
  where
    go [] _ = []
    go (line : rest) pending =
      let t = T.strip line
      in case T.stripPrefix "// @effects" t of
           Just tagsText -> go rest (Just (parseTags tagsText))
           Nothing
             | T.null t -> go rest pending
             | otherwise -> case pending of
                 Nothing -> go rest Nothing
                 Just tags -> case methodNameOf t of
                   Just meth -> (meth, tags) : go rest Nothing
                   Nothing   -> go rest Nothing

-- | @(pure)@ is a literal marker for the empty set, distinct from a method
-- having no preceding annotation at all (absent from the map entirely).
parseTags :: Text -> Set.Set Text
parseTags raw
  | T.strip raw == "(pure)" = Set.empty
  | otherwise = Set.fromList (filter (not . T.null) (map T.strip (T.splitOn "," raw)))

-- | The method name is the last whitespace-separated token before the
-- parameter list's opening paren -- true whether the declaration is
-- @function <rettype> <name> (@ or @subroutine\/event <name> (@.
methodNameOf :: Text -> Maybe Text
methodNameOf t
  | any (`T.isPrefixOf` t) ["public function ", "public subroutine ", "public event "]
  = case reverse (T.words (T.takeWhile (/= '(') t)) of
      (name : _) | not (T.null name) -> Just (T.toLower name)
      _ -> Nothing
  | otherwise = Nothing
