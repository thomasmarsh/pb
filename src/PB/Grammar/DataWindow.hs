module PB.Grammar.DataWindow
  ( parseDataWindow
  , parseBandKind
  ) where

import PB.Prelude
import PB.AST.DataWindow
import PB.Lexing.DataWindow (DwBlock (..), scanBlocks)

import Control.Monad (guard)
import qualified Data.Map.Strict  as Map
import qualified Data.Text        as T
import qualified Data.Text.Read   as TR

-- ---------------------------------------------------------------------------
-- Entry point

parseDataWindow :: Text -> Either Text DataWindowFile
parseDataWindow src = do
    (release, blocks) <- scanBlocks src
    return (foldl' classifyBlock (emptyDwFile release) blocks)

emptyDwFile :: Int -> DataWindowFile
emptyDwFile n = DataWindowFile
    { dwRelease  = n
    , dwObject   = DwObjectAttrs Map.empty
    , dwTable    = Nothing
    , dwBands    = []
    , dwGroups   = []
    , dwControls = []
    , dwMeta     = Map.empty
    }

-- ---------------------------------------------------------------------------
-- Block classifier

classifyBlock :: DataWindowFile -> DwBlock -> DataWindowFile
classifyBlock dw (DwBlock kw content) = case kw of
    "datawindow" ->
        dw { dwObject = parseDwObjectAttrs content }
    "table" ->
        dw { dwTable = Just (parseDwTableStub content) }
    "group" ->
        dw { dwGroups = dwGroups dw ++ [parseDwGroupStub content] }
    _ | Just bk <- parseBandKind kw ->
            dw { dwBands = dwBands dw ++ [parseDwBandStub bk content] }
      | "." `T.isInfixOf` kw ->
            dw { dwMeta = Map.insert kw Map.empty (dwMeta dw) }
      | otherwise ->
            dw { dwControls = dwControls dw ++ [parseDwControlStub kw content] }

-- ---------------------------------------------------------------------------
-- Band kind

parseBandKind :: Text -> Maybe DwBandKind
parseBandKind kw = case kw of
    "header"     -> Just BkHeader
    "detail"     -> Just BkDetail
    "footer"     -> Just BkFooter
    "summary"    -> Just BkSummary
    "background" -> Just BkBackground
    "foreground" -> Just BkForeground
    _            -> tryGroupBand kw

tryGroupBand :: Text -> Maybe DwBandKind
tryGroupBand kw
    | Just n <- readDotNum  "header"  kw = Just (BkGroupHeader  n)
    | Just n <- readDotNum  "trailer" kw = Just (BkGroupTrailer n)
    | Just n <- readBrackNum "header"  kw = Just (BkGroupHeader  n)
    | Just n <- readBrackNum "trailer" kw = Just (BkGroupTrailer n)
    | otherwise                           = Nothing

readDotNum :: Text -> Text -> Maybe Int
readDotNum prefix kw = do
    rest <- T.stripPrefix (prefix <> ".") kw
    readAllDigits rest

readBrackNum :: Text -> Text -> Maybe Int
readBrackNum prefix kw = do
    rest      <- T.stripPrefix (prefix <> "[") kw
    (n, tail_) <- either (const Nothing) Just (TR.decimal rest)
    guard (tail_ == "]")
    return n

readAllDigits :: Text -> Maybe Int
readAllDigits t = case TR.decimal t of
    Right (n, "") -> Just n
    _             -> Nothing

-- ---------------------------------------------------------------------------
-- Stub block parsers (populated in DW-A2 through DW-A5)

parseDwObjectAttrs :: Text -> DwObjectAttrs
parseDwObjectAttrs _ = DwObjectAttrs Map.empty

parseDwTableStub :: Text -> DwTable
parseDwTableStub _ = DwTable [] Nothing Nothing Nothing []

parseDwBandStub :: DwBandKind -> Text -> DwBand
parseDwBandStub bk _ = DwBand bk Nothing Nothing False Map.empty

parseDwGroupStub :: Text -> DwGroup
parseDwGroupStub _ = DwGroup 0 Nothing Nothing [] False Map.empty

parseDwControlStub :: Text -> Text -> DwControl
parseDwControlStub kw _ =
    DwControl kw Nothing Nothing Nothing Nothing Nothing
              Nothing Nothing Nothing Nothing Nothing Map.empty
