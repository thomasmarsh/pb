{-# LANGUAGE StrictData #-}
module PB.AST.DataWindow
  ( DataWindowFile (..)
  , DwObjectAttrs (..)
  , DwTable (..)
  , DwColumn (..)
  , DwArgument (..)
  , DwWhereClause (..)
  , DwJoin (..)
  , DwRetrieve (..)
  , DwRetrieveOrRaw (..)
  , DwBand (..)
  , DwBandKind (..)
  , DwGroup (..)
  , DwControl (..)
  , DwUnknownBlock (..)
  ) where

import PB.Prelude
import PB.AST.Expr     (Expr)
import PB.Lexing.Token (Token)
import Control.DeepSeq (NFData)
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
  { dwcExp1       :: Text
  , dwcOp         :: Text
  , dwcExp2       :: Text
  , dwcLogic      :: Maybe Text
  , dwcParsedExp1 :: Maybe Expr
  , dwcParsedExp2 :: Maybe Expr
  } deriving (Eq, Show, Generic)

data DwJoin = DwJoin
  { djLeft   :: Text
  , djOp     :: Text
  , djRight  :: Text
  , djOuter1 :: Maybe Text
  , djOuter2 :: Maybe Text
  } deriving (Eq, Show, Generic)

data DwRetrieve = DwRetrieve
  { drVersion   :: Int
  , drTables    :: [Text]
  , drColumns   :: [Text]
  , drArguments :: [DwArgument]
  , drWhere     :: [DwWhereClause]
  , drJoins     :: [DwJoin]
  } deriving (Eq, Show, Generic)

data DwRetrieveOrRaw
  = DwRetrieveOk  DwRetrieve
  | DwRetrieveRaw Text
  deriving (Eq, Show, Generic)

data DwColumn = DwColumn
  { dcName                :: Text
  , dcType                :: Text
  , dcDbName              :: Maybe Text
  , dcUpdate              :: Bool
  , dcKey                 :: Bool
  , dcUpdateWhere         :: Bool
  , dcDddwName            :: Maybe Text
  , dcValidation          :: Maybe Text
  , dcParsedValidation    :: Maybe Expr
  , dcValidationTokens    :: [Token]
  , dcValidationMsg       :: Maybe Text
  , dcParsedValidationMsg :: Maybe Expr
  , dcValidationMsgTokens :: [Token]
  , dcAttrs               :: Map Text Text
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
  { dwcType             :: Text
  , dwcName             :: Maybe Text
  , dwcBand             :: Maybe DwBandKind
  , dwcId               :: Maybe Int
  , dwcX                :: Maybe Int
  , dwcY                :: Maybe Int
  , dwcWidth            :: Maybe Int
  , dwcHeight           :: Maybe Int
  , dwcVisible          :: Maybe Bool
  , dwcExpression       :: Maybe Text
  , dwcParsedExpression :: Maybe Expr
  , dwcExpressionTokens :: [Token]
    -- ^ Plan 201 Phase 5a: the raw lexed tokens 'dwcParsedExpression' was
    -- parsed from, kept alongside (not just inside) the parsed 'Expr' --
    -- the token-level type-resolution coverage denominator
    -- ('PB.Pipeline.DuckDb.PhaseA.identifierTokenRows') needs the full
    -- token stream, not just what survived into the AST.
  , dwcFormat           :: Maybe Text
  , dwcParsedFormat     :: Maybe Expr
  , dwcFormatTokens     :: [Token]
  , dwcColor            :: Maybe Text
  , dwcParsedColor      :: Maybe Expr
  , dwcColorTokens      :: [Token]
  , dwcTabSeq           :: Maybe Int
  , dwcAttrs            :: Map Text Text
  } deriving (Eq, Show, Generic)

data DwUnknownBlock = DwUnknownBlock
  { dubKeyword :: Text
  , dubAttrs   :: Map Text Text
  } deriving (Eq, Show, Generic)

instance NFData DataWindowFile
instance NFData DwObjectAttrs
instance NFData DwTable
instance NFData DwWhereClause
instance NFData DwJoin
instance NFData DwRetrieve
instance NFData DwRetrieveOrRaw
instance NFData DwColumn
instance NFData DwArgument
instance NFData DwBandKind
instance NFData DwBand
instance NFData DwGroup
instance NFData DwControl
instance NFData DwUnknownBlock
