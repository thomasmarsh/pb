{-# LANGUAGE StrictData #-}
module PB.AST.DwPropertySchema
  ( DwControlKind (..)
  , DwBandCategory (..)
  , DwElementKind (..)
  , DwPropertyDoc (..)
  , DwPropertyEntry (..)
  , DwFunctionSource (..)
  , DwExprFunctionEntry (..)
  ) where

import PB.Prelude
import Control.DeepSeq   (NFData)
import GHC.Generics      (Generic)

-- | The closed set of real placed-control kinds confirmed by a full-corpus
-- survey (doc/plan/201-dw-property-survey.md) across two example corpora.
data DwControlKind
  = DwCkColumn
  | DwCkText
  | DwCkCompute
  | DwCkButton
  | DwCkBitmap
  | DwCkGraph
  | DwCkGroupBox
  | DwCkLine
  | DwCkRectangle
  | DwCkReport
  | DwCkTableBlob
  | DwCkCssGen
  | DwCkXmlGen
  | DwCkJsGen
  | DwCkXhtmlGen
  | DwCkXsltGen
  deriving (Eq, Ord, Show, Generic, Bounded, Enum)

-- | A DataWindow band's property-namespace category -- the same shape as
-- "PB.AST.DataWindow"'s 'DwBandKind' but without the group\/tree-level
-- 'Int' payload. The corpus survey (doc/plan/201-dw-property-survey.md)
-- confirms a band's property set depends only on its category, never on
-- which nesting level it occupies, so the catalog dispatch key must not
-- carry the level -- a full 'DwBandKind' key would make a group-header
-- band's properties silently unresolvable at every level except whichever
-- one happened to be surveyed.
data DwBandCategory
  = DbcHeader
  | DbcDetail
  | DbcFooter
  | DbcSummary
  | DbcBackground
  | DbcForeground
  | DbcGroupHeader
  | DbcGroupTrailer
  | DbcTreeLevel
  deriving (Eq, Ord, Show, Generic, Bounded, Enum)

-- | Every distinct kind of DataWindow element a property/attribute can
-- belong to, per the survey's real groupings. 'DwEkMeta' has no argument:
-- the real corpus survey found export-format settings (export.pdf.*,
-- export.xml.*, ...) fold into one flat key namespace with the block name
-- already embedded in the dotted key, never split by block. 'DwEkGroup'
-- likewise has no argument: a DW group-by definition ('PB.AST.DataWindow'\'s
-- @DwGroup@) is not itself kind-varying the way bands or controls are, and
-- the survey found its properties in one flat, level-independent bucket
-- (the same level-independence @DwBandCategory@ already applies to bands).
data DwElementKind
  = DwEkControl DwControlKind
  | DwEkBand DwBandCategory
  | DwEkTableColumn
  | DwEkObject
  | DwEkGroup
  | DwEkMeta
  deriving (Eq, Ord, Show, Generic)

-- | A documentation match for one property/function, or the honest
-- absence of one. 'dwpdDescription' is separately optional because a doc
-- page can be matched (a real page exists and is cited) even when no
-- one-paragraph description could be extracted from it -- these are two
-- independent facts, not one collapsed into the other.
data DwPropertyDoc = DwPropertyDoc
  { dwpdPage        :: Text
  , dwpdDescription :: Maybe Text
  } deriving (Eq, Show, Generic)

data DwPropertyEntry = DwPropertyEntry
  { dwpeKey          :: Text
  , dwpeOccurrences  :: Int
  , dwpeCorpora      :: [Text]
  , dwpeSampleValues :: [Text]
  , dwpeDoc          :: Maybe DwPropertyDoc
  } deriving (Eq, Show, Generic)

data DwFunctionSource
  = DwFnParsed
  | DwFnRawTextFallback
  deriving (Eq, Show, Generic)

data DwExprFunctionEntry = DwExprFunctionEntry
  { dwefName            :: Text
  , dwefOccurrences     :: Int
  , dwefSource          :: DwFunctionSource
  , dwefExampleCitation :: Text
  , dwefDoc             :: Maybe DwPropertyDoc
  } deriving (Eq, Show, Generic)

instance NFData DwControlKind
instance NFData DwBandCategory
instance NFData DwElementKind
instance NFData DwPropertyDoc
instance NFData DwPropertyEntry
instance NFData DwFunctionSource
instance NFData DwExprFunctionEntry
