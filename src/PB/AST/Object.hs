module PB.AST.Object
  ( SrFile (..)
  , ForwardBlock (..)
  , PrototypesBlock (..)
  , ProtoDecl (..)
  , VariablesBlock (..)
  , VarScope (..)
  , TypeDecl (..)
  , TypeBlock (..)
  , VarDecl (..)
  , FnSig (..)
  , SubSig (..)
  , EventSig (..)
  , FunctionBlock (..)
  , SubroutineBlock (..)
  , EventBlock (..)
  , OnBlock (..)
  ) where

import PB.Prelude
import PB.Lexing.Splitter (Statement)

data SrFile = SrFile
  { srHeaders     :: [Text]
  , srForward     :: Maybe ForwardBlock
  , srPrototypes  :: Maybe PrototypesBlock
  , srVariables   :: Maybe VariablesBlock
  , srTypeBlocks  :: [TypeBlock]
  , srOnBlocks    :: [OnBlock]
  , srEvents      :: [EventBlock]
  , srFunctions   :: [FunctionBlock]
  , srSubroutines :: [SubroutineBlock]
  } deriving (Eq, Show)

data ForwardBlock = ForwardBlock
  { fwdTypes :: [TypeDecl]
  } deriving (Eq, Show)

data PrototypesBlock = PrototypesBlock
  { protoDecls :: [ProtoDecl]
  } deriving (Eq, Show)

data ProtoDecl
  = ProtoFn  FnSig
  | ProtoSub SubSig
  | ProtoEv  EventSig
  deriving (Eq, Show)

data VariablesBlock = VariablesBlock
  { varScope :: VarScope
  , varDecls :: [VarDecl]
  } deriving (Eq, Show)

data VarScope = GlobalVars | TypeVars
  deriving (Eq, Show)

data TypeDecl = TypeDecl
  { tdName     :: Text
  , tdAncestor :: Text
  , tdWithin   :: Maybe Text
  } deriving (Eq, Show)

data TypeBlock = TypeBlock
  { tbDecl     :: TypeDecl
  , tbVarDecls :: [VarDecl]
  } deriving (Eq, Show)

data VarDecl = VarDecl
  { vdModifiers :: [Text]
  , vdType      :: Text
  , vdName      :: Text
  } deriving (Eq, Show)

data FnSig = FnSig
  { fnsMods    :: [Text]
  , fnsRetType :: Text
  , fnsName    :: Text
  , fnsParams  :: Text
  , fnsThrows  :: Maybe Text
  } deriving (Eq, Show)

data SubSig = SubSig
  { ssMods   :: [Text]
  , ssName   :: Text
  , ssParams :: Text
  , ssThrows :: Maybe Text
  } deriving (Eq, Show)

data EventSig = EventSig
  { esName   :: Text
  , esRawSig :: Text
  } deriving (Eq, Show)

data FunctionBlock = FunctionBlock
  { fbSig  :: FnSig
  , fbBody :: [Statement]
  } deriving (Eq, Show)

data SubroutineBlock = SubroutineBlock
  { sbSig  :: SubSig
  , sbBody :: [Statement]
  } deriving (Eq, Show)

data EventBlock = EventBlock
  { evSig  :: EventSig
  , evBody :: [Statement]
  } deriving (Eq, Show)

data OnBlock = OnBlock
  { obQualName :: Text
  , obOwner    :: Text
  , obEvent    :: Text
  , obBody     :: [Statement]
  } deriving (Eq, Show)
