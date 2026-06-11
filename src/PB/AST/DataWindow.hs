module PB.AST.DataWindow
  ( DataWindowFile (..)
  , DwObjectAttrs (..)
  , DwTable (..)
  , DwColumn (..)
  , DwArgument (..)
  , DwBand (..)
  , DwBandKind (..)
  , DwGroup (..)
  , DwControl (..)
  ) where

import PB.Prelude
import Data.Map.Strict (Map)

data DataWindowFile = DataWindowFile
  { dwRelease  :: Int
  , dwObject   :: DwObjectAttrs
  , dwTable    :: Maybe DwTable
  , dwBands    :: [DwBand]
  , dwGroups   :: [DwGroup]
  , dwControls :: [DwControl]
  , dwMeta     :: Map Text (Map Text Text)
  } deriving (Eq, Show)

newtype DwObjectAttrs = DwObjectAttrs { doaAttrs :: Map Text Text }
  deriving (Eq, Show)

data DwTable = DwTable
  { dtColumns     :: [DwColumn]
  , dtRetrieve    :: Maybe Text
  , dtUpdate      :: Maybe Text
  , dtUpdateWhere :: Maybe Int
  , dtArguments   :: [DwArgument]
  } deriving (Eq, Show)

data DwColumn = DwColumn
  { dcName        :: Text
  , dcType        :: Text
  , dcDbName      :: Maybe Text
  , dcUpdate      :: Bool
  , dcKey         :: Bool
  , dcUpdateWhere :: Bool
  , dcDddwName    :: Maybe Text
  , dcAttrs       :: Map Text Text
  } deriving (Eq, Show)

data DwArgument = DwArgument
  { daName :: Text
  , daType :: Text
  } deriving (Eq, Show)

data DwBandKind
  = BkHeader
  | BkDetail
  | BkFooter
  | BkSummary
  | BkBackground
  | BkForeground
  | BkGroupHeader Int
  | BkGroupTrailer Int
  | BkTreeLevel Int
  deriving (Eq, Show)

data DwBand = DwBand
  { dbKind     :: DwBandKind
  , dbHeight   :: Maybe Int
  , dbColor    :: Maybe Text
  , dbAutoSize :: Bool
  , dbAttrs    :: Map Text Text
  } deriving (Eq, Show)

data DwGroup = DwGroup
  { dgLevel         :: Int
  , dgHeaderHeight  :: Maybe Int
  , dgTrailerHeight :: Maybe Int
  , dgBy            :: [Text]
  , dgNewPage       :: Bool
  , dgAttrs         :: Map Text Text
  } deriving (Eq, Show)

data DwControl = DwControl
  { dwcType       :: Text
  , dwcName       :: Maybe Text
  , dwcBand       :: Maybe DwBandKind
  , dwcId         :: Maybe Int
  , dwcX          :: Maybe Int
  , dwcY          :: Maybe Int
  , dwcWidth      :: Maybe Int
  , dwcHeight     :: Maybe Int
  , dwcVisible    :: Maybe Bool
  , dwcExpression :: Maybe Text
  , dwcTabSeq     :: Maybe Int
  , dwcAttrs      :: Map Text Text
  } deriving (Eq, Show)
