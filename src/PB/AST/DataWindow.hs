module PB.AST.DataWindow
  ( DataWindowFile (..)
  , DwObjectAttrs (..)
  , DwTable (..)
  , DwColumn (..)
  , DwArgument (..)
  , DwWhereClause (..)
  , DwRetrieve (..)
  , DwRetrieveOrRaw (..)
  , DwBand (..)
  , DwBandKind (..)
  , DwGroup (..)
  , DwControl (..)
  , DwUnknownBlock (..)
  ) where

import PB.Prelude
import Data.Map.Strict (Map)
import GHC.Generics    (Generic)

data DataWindowFile = DataWindowFile
  { dwRelease  :: Int
  , dwObject   :: DwObjectAttrs
  , dwTable    :: Maybe DwTable
  , dwBands    :: [DwBand]
  , dwGroups   :: [DwGroup]
  , dwControls :: [DwControl]
  , dwUnknowns :: [DwUnknownBlock]
  , dwMeta     :: Map Text (Map Text Text)
  } deriving (Eq, Show, Generic)

newtype DwObjectAttrs = DwObjectAttrs { doaAttrs :: Map Text Text }
  deriving (Eq, Show, Generic)

data DwTable = DwTable
  { dtColumns     :: [DwColumn]
  , dtRetrieve    :: Maybe DwRetrieveOrRaw
  , dtUpdate      :: Maybe Text
  , dtUpdateWhere :: Maybe Int
  , dtArguments   :: [DwArgument]
  } deriving (Eq, Show, Generic)

data DwWhereClause = DwWhereClause
  { dwcExp1  :: Text
  , dwcOp    :: Text
  , dwcExp2  :: Text
  , dwcLogic :: Maybe Text
  } deriving (Eq, Show, Generic)

data DwRetrieve = DwRetrieve
  { drVersion   :: Int
  , drTables    :: [Text]
  , drColumns   :: [Text]
  , drArguments :: [DwArgument]
  , drWhere     :: [DwWhereClause]
  } deriving (Eq, Show, Generic)

data DwRetrieveOrRaw
  = DwRetrieveOk  DwRetrieve
  | DwRetrieveRaw Text
  deriving (Eq, Show, Generic)

data DwColumn = DwColumn
  { dcName        :: Text
  , dcType        :: Text
  , dcDbName      :: Maybe Text
  , dcUpdate      :: Bool
  , dcKey         :: Bool
  , dcUpdateWhere :: Bool
  , dcDddwName    :: Maybe Text
  , dcAttrs       :: Map Text Text
  } deriving (Eq, Show, Generic)

data DwArgument = DwArgument
  { daName :: Text
  , daType :: Text
  } deriving (Eq, Show, Generic)

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
  deriving (Eq, Show, Generic)

data DwBand = DwBand
  { dbKind     :: DwBandKind
  , dbHeight   :: Maybe Int
  , dbColor    :: Maybe Text
  , dbAutoSize :: Bool
  , dbAttrs    :: Map Text Text
  } deriving (Eq, Show, Generic)

data DwGroup = DwGroup
  { dgLevel         :: Int
  , dgHeaderHeight  :: Maybe Int
  , dgTrailerHeight :: Maybe Int
  , dgBy            :: [Text]
  , dgNewPage       :: Bool
  , dgAttrs         :: Map Text Text
  } deriving (Eq, Show, Generic)

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
  } deriving (Eq, Show, Generic)

data DwUnknownBlock = DwUnknownBlock
  { dubKeyword :: Text
  , dubAttrs   :: Map Text Text
  } deriving (Eq, Show, Generic)
