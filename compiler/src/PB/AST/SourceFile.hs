{-# LANGUAGE StrictData #-}
module PB.AST.SourceFile
  ( SrFile (..)
  , ForwardBlock (..)
  , PrototypesBlock (..)
  , ProtoDecl (..)
  , VariablesBlock (..)
  , VarScope (..)
  , TypeDecl (..)
  , TypeBlock (..)
  , VarDecl (..)
  , GlobalInstance (..)
  , FnSig (..)
  , SubSig (..)
  , EventSig (..)
  , FunctionBlock (..)
  , SubroutineBlock (..)
  , EventBlock (..)
  , OnBlock (..)
  , srAllTypeDecls
  , srPrimaryObject
  ) where

import PB.Prelude
import PB.AST.BodyStmt    (BodyStmt)
import PB.AST.Located     (Located)
import GHC.Generics       (Generic)

data SrFile = SrFile
  { srHeaders         :: [Text]
  , srForward         :: Maybe ForwardBlock
  , srPrototypes      :: Maybe PrototypesBlock
  , srVariables       :: Maybe VariablesBlock
  , srGlobalInstances :: [GlobalInstance]
  , srTypeBlocks      :: [TypeBlock]
  , srOnBlocks        :: [OnBlock]
  , srEvents          :: [EventBlock]
  , srFunctions       :: [FunctionBlock]
  , srSubroutines     :: [SubroutineBlock]
  } deriving (Eq, Show, Generic)

data ForwardBlock = ForwardBlock
  { fwdTypes     :: [TypeDecl]
  , fwdInstances :: [GlobalInstance]
  } deriving (Eq, Show, Generic)

newtype PrototypesBlock = PrototypesBlock
  { protoDecls :: [ProtoDecl]
  } deriving (Eq, Show, Generic)

data ProtoDecl
  = ProtoFn  FnSig
  | ProtoSub SubSig
  | ProtoEv  EventSig
  deriving (Eq, Show, Generic)

data VariablesBlock = VariablesBlock
  { varScope :: VarScope
  , varDecls :: [VarDecl]
  } deriving (Eq, Show, Generic)

data VarScope = GlobalVars | TypeVars
  deriving (Eq, Show, Generic)

data TypeDecl = TypeDecl
  { tdName     :: Text
  , tdAncestor :: Text
  , tdWithin   :: Maybe Text
  } deriving (Eq, Show, Generic)

data TypeBlock = TypeBlock
  { tbDecl :: TypeDecl
  , tbBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

data VarDecl = VarDecl
  { vdModifiers :: [Text]
  , vdType      :: Text
  , vdName      :: Text
  } deriving (Eq, Show, Generic)

data GlobalInstance = GlobalInstance
  { giType :: Text
  , giName :: Text
  } deriving (Eq, Show, Generic)

data FnSig = FnSig
  { fnsMods    :: [Text]
  , fnsReturnType :: Text
  , fnsName    :: Text
  , fnsParams  :: Text
  , fnsThrows  :: Maybe Text
  } deriving (Eq, Show, Generic)

data SubSig = SubSig
  { ssMods   :: [Text]
  , ssName   :: Text
  , ssParams :: Text
  , ssThrows :: Maybe Text
  } deriving (Eq, Show, Generic)

data EventSig = EventSig
  { esName   :: Text
  , esRawSig :: Text
  } deriving (Eq, Show, Generic)

data FunctionBlock = FunctionBlock
  { fbSig  :: FnSig
  , fbBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

data SubroutineBlock = SubroutineBlock
  { sbSig  :: SubSig
  , sbBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

data EventBlock = EventBlock
  { evSig   :: EventSig
  , evOwner :: Maybe Text
  , evBody  :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

data OnBlock = OnBlock
  { obQualName :: Text
  , obOwner    :: Text
  , obEvent    :: Text
  , obBody     :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | All type declarations: type-blocks first (authoritative), then forward.
-- Type-block entries win when both declare the same name (left-bias in fromList).
srAllTypeDecls :: SrFile -> [TypeDecl]
srAllTypeDecls sf =
  [ tbDecl tb | tb <- srTypeBlocks sf ]
  <> case srForward sf of
       Nothing -> []
       Just ForwardBlock { fwdTypes = tds } -> tds

-- | Primary object name and ancestor. Tries srTypeBlocks first (authoritative),
-- falls back to forward block, then returns ("", Nothing).
srPrimaryObject :: SrFile -> (Text, Maybe Text)
srPrimaryObject sf = case srTypeBlocks sf of
  (tb:_) -> (tdName (tbDecl tb), Just (tdAncestor (tbDecl tb)))
  []     -> case srForward sf of
              Just (ForwardBlock { fwdTypes = (td:_) }) ->
                (tdName td, Just (tdAncestor td))
              _ -> ("", Nothing)
