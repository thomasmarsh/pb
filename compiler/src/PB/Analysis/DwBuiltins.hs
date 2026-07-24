{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Compile-time embedding of the real-corpus-derived DataWindow property
-- and expression-function catalog (doc/plan/201-dw-property-survey.md).
module PB.Analysis.DwBuiltins
  ( dwPropertyCatalog
  , dwExprFunctionCatalog
  , classifyDwControlKind
  ) where

import PB.Prelude
import PB.AST.DwPropertySchema

import Data.Aeson         (FromJSON (..), eitherDecodeStrict, withObject, withText, (.:), (.:?))
import Data.FileEmbed     (embedFile)

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

dwPropertiesBytes :: BS.ByteString
dwPropertiesBytes = $(embedFile "data/dw_properties.json")

data DwPropertiesJson = DwPropertiesJson
  { dpjProperties :: [DwPropertyRow]
  , dpjFunctions  :: [DwFunctionRow]
  }

instance FromJSON DwPropertiesJson where
  parseJSON = withObject "DwPropertiesJson" $ \o -> DwPropertiesJson
    <$> o .: "properties"
    <*> o .: "functions"

data DwPropertyRow = DwPropertyRow
  { dprElement :: DwElementKind
  , dprEntry   :: DwPropertyEntry
  }

instance FromJSON DwPropertyRow where
  parseJSON = withObject "DwPropertyRow" $ \o -> do
    element <- o .: "element"
    key     <- o .: "key"
    occ     <- o .: "occurrences"
    corpora <- o .: "corpora"
    samples <- o .: "sample_values"
    doc     <- o .:? "doc"
    pure (DwPropertyRow element (DwPropertyEntry key occ corpora samples doc))

data DwFunctionRow = DwFunctionRow
  { dfrName  :: Text
  , dfrEntry :: DwExprFunctionEntry
  }

instance FromJSON DwFunctionRow where
  parseJSON = withObject "DwFunctionRow" $ \o -> do
    name     <- o .: "name"
    occ      <- o .: "occurrences"
    src      <- o .: "source"
    citation <- o .: "example_citation"
    doc      <- o .:? "doc"
    pure (DwFunctionRow name (DwExprFunctionEntry name occ src citation doc))

instance FromJSON DwPropertyDoc where
  parseJSON = withObject "DwPropertyDoc" $ \o -> DwPropertyDoc
    <$> o .: "page"
    <*> o .:? "description"

instance FromJSON DwFunctionSource where
  parseJSON = withText "DwFunctionSource" $ \t -> case t of
    "parsed"            -> pure DwFnParsed
    "raw_text_fallback" -> pure DwFnRawTextFallback
    other               -> fail ("unknown function source: " <> T.unpack other)

instance FromJSON DwElementKind where
  parseJSON = withObject "DwElementKind" $ \o -> do
    kind <- o .: "kind"
    case (kind :: Text) of
      "object"       -> pure DwEkObject
      "table_column" -> pure DwEkTableColumn
      "meta"         -> pure DwEkMeta
      "group"        -> pure DwEkGroup
      "band"         -> DwEkBand    <$> o .: "band"
      "control"      -> DwEkControl <$> o .: "control"
      other          -> fail ("unknown element kind: " <> T.unpack other)

instance FromJSON DwBandCategory where
  parseJSON = withText "DwBandCategory" $ \t -> case t of
    "DbcHeader"       -> pure DbcHeader
    "DbcDetail"       -> pure DbcDetail
    "DbcFooter"       -> pure DbcFooter
    "DbcSummary"      -> pure DbcSummary
    "DbcBackground"   -> pure DbcBackground
    "DbcForeground"   -> pure DbcForeground
    "DbcGroupHeader"  -> pure DbcGroupHeader
    "DbcGroupTrailer" -> pure DbcGroupTrailer
    "DbcTreeLevel"    -> pure DbcTreeLevel
    other             -> fail ("unknown band category: " <> T.unpack other)

instance FromJSON DwControlKind where
  parseJSON = withText "DwControlKind" $ \t ->
    maybe (fail ("unknown control kind: " <> T.unpack t)) pure (classifyDwControlKind t)

-- | The single source of truth mapping a raw control-block keyword -- either
-- 'dw_properties.json''s survey-time @kind.control@ tag or a live-parsed
-- 'PB.AST.DataWindow.DwControl''s own 'dwcType' -- to the closed
-- 'DwControlKind' set. Case-insensitive: real @.srd@ control keywords are
-- lowercase by grammar convention, but 'TypeResolve''s 'classifyMemberOf'
-- reuses this against a live-parsed 'dwcType' rather than only the JSON
-- decoder, so this must not assume its caller already normalized case.
classifyDwControlKind :: Text -> Maybe DwControlKind
classifyDwControlKind t = case T.toLower t of
    "column"    -> Just DwCkColumn
    "text"      -> Just DwCkText
    "compute"   -> Just DwCkCompute
    "button"    -> Just DwCkButton
    "bitmap"    -> Just DwCkBitmap
    "graph"     -> Just DwCkGraph
    "groupbox"  -> Just DwCkGroupBox
    "line"      -> Just DwCkLine
    "rectangle" -> Just DwCkRectangle
    "report"    -> Just DwCkReport
    "tableblob" -> Just DwCkTableBlob
    "cssgen"    -> Just DwCkCssGen
    "xmlgen"    -> Just DwCkXmlGen
    "jsgen"     -> Just DwCkJsGen
    "xhtmlgen"  -> Just DwCkXhtmlGen
    "xsltgen"   -> Just DwCkXsltGen
    _           -> Nothing

parsedCatalog :: Either String DwPropertiesJson
parsedCatalog = eitherDecodeStrict dwPropertiesBytes

-- | Keyed by the lowercased property path, matching every other lookup in
-- this codebase against a PB-sourced name ('PB.AST.Ident.identCanon') --
-- PB property paths are case-insensitive, and a handful of real survey
-- entries (e.g. @HTMLDW@, @print.buttons.pageSetUp@) are recorded with
-- their original mixed case, which would otherwise silently never match a
-- canonicalized chain-hop lookup.
dwPropertyCatalog :: Map.Map DwElementKind (Map.Map Text DwPropertyEntry)
dwPropertyCatalog = case parsedCatalog of
  Left  _   -> Map.empty
  Right dpj -> Map.fromListWith Map.union
    [ (dprElement row, Map.singleton (T.toLower (dwpeKey (dprEntry row))) (dprEntry row))
    | row <- dpjProperties dpj
    ]

dwExprFunctionCatalog :: Map.Map Text DwExprFunctionEntry
dwExprFunctionCatalog = case parsedCatalog of
  Left  _   -> Map.empty
  Right dpj -> Map.fromList [ (dfrName row, dfrEntry row) | row <- dpjFunctions dpj ]
