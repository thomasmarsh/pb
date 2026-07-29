{-# LANGUAGE StrictData #-}
module PB.AST.SourceFile
  ( SrFile (..)
  , ParseError (..)
  , ForwardBlock (..)
  , PrototypesBlock (..)
  , ProtoDecl (..)
  , VariablesBlock (..)
  , VarScope (..)
  , TypeDecl (..)
  , TypeBlock (..)
  , StructureBlock (..)
  , VarDecl (..)
  , GlobalInstance (..)
  , Param (..)
  , renderParams
  , FnSig (..)
  , SubSig (..)
  , EventSig (..)
  , FunctionBlock (..)
  , SubroutineBlock (..)
  , EventBlock (..)
  , OnBlock (..)
  , srAllTypeDecls
  , srPrimaryObject
  , splitAncestorRef
  , mkTypeDecl
  , mkTypeDeclAt
  ) where

import PB.Prelude
import PB.AST.BodyStmt    (BodyStmt)
import PB.AST.Ident       (Ident, identOrig, mkIdent, mkIdentAt)
import PB.AST.Located     (Located)
import PB.Lexing.Token    (SourceSpan)
import Control.DeepSeq    (NFData)
import GHC.Generics       (Generic)
import qualified Data.Text as T

-- | A parse error with its message and optional source line number.
data ParseError = ParseError
  { peMessage :: Text
  , peLine    :: Maybe Int
  } deriving (Eq, Show, Generic)

data SrFile = SrFile
  { srHeaders         :: [Text]
  , srForward         :: Maybe ForwardBlock
  , srPrototypes      :: Maybe PrototypesBlock
  , srVariables       :: [VariablesBlock]
  , srGlobalInstances :: [GlobalInstance]
  , srTypeBlocks      :: [TypeBlock]
  , srStructureBlocks :: [StructureBlock]
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
  { tdName             :: Ident
  , tdAncestor         :: Text
  , tdAncestorClass    :: Ident
  , tdAncestorOverride :: Maybe Ident
  , tdWithin           :: Maybe Text
  } deriving (Eq, Show, Generic)

-- | Construct a 'TypeDecl', minting its ancestor split ('splitAncestorRef')
-- once here rather than leaving each consumer to recompute it.
mkTypeDecl :: Text -> Text -> Maybe Text -> TypeDecl
mkTypeDecl name anc within =
  let (ancClass, ancOverride) = splitAncestorRef anc
  in TypeDecl
       { tdName             = mkIdent name
       , tdAncestor         = anc
       , tdAncestorClass    = ancClass
       , tdAncestorOverride = ancOverride
       , tdWithin           = within
       }

-- | Like 'mkTypeDecl' but attaches a real source span to 'tdName'.
mkTypeDeclAt :: SourceSpan -> Text -> Text -> Maybe Text -> TypeDecl
mkTypeDeclAt sp name anc within =
  let (ancClass, ancOverride) = splitAncestorRef anc
  in TypeDecl
       { tdName             = mkIdentAt sp name
       , tdAncestor         = anc
       , tdAncestorClass    = ancClass
       , tdAncestorOverride = ancOverride
       , tdWithin           = within
       }

data TypeBlock = TypeBlock
  { tbDecl :: TypeDecl
  , tbBody :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

-- | A @type NAME from structure ... end type@ declaration -- a first-class
-- node distinct from 'TypeBlock' so downstream consumers no longer need to
-- string-match 'tdAncestor' against the literal @"structure"@ text. A
-- structure has no ancestor chain, no visual placement, and no procedures,
-- so it carries only its own name and typed field list (reusing 'VarDecl',
-- the same shape a @type variables@ block's declarators already use).
data StructureBlock = StructureBlock
  { sbName   :: Ident
  , sbFields :: [VarDecl]
  } deriving (Eq, Show, Generic)

data VarDecl = VarDecl
  { vdModifiers :: [Text]
  , vdType      :: Text
  , vdTypeSpan  :: SourceSpan  -- ^ real span of the 'vdType' token
  , vdName      :: Ident
  } deriving (Eq, Show, Generic)

data GlobalInstance = GlobalInstance
  { giType     :: Text
  , giTypeSpan :: SourceSpan  -- ^ real span of the 'giType' token
  , giName     :: Ident
  } deriving (Eq, Show, Generic)

-- | One declared function\/subroutine\/event parameter. 'paramType'\/
-- 'paramTypeSpan' mirror 'VarDecl''s 'vdType'\/'vdTypeSpan' pair (deferring
-- 'PbType' parsing to the consumer via 'PB.AST.Type.parseTypeTextAt');
-- 'paramName' carries the parameter name's own real token span, the thing
-- a joined-string parameter list could never give it.
data Param = Param
  { paramMods     :: [Text]
  , paramType     :: Text
  , paramTypeSpan :: SourceSpan
  , paramName     :: Ident
  } deriving (Eq, Show, Generic)

-- | Reconstruct a display-only parameter-list string (e.g. for the
-- @procedures.params@ DB column) -- never re-parsed, so its exact
-- punctuation is not load-bearing.
renderParams :: [Param] -> Text
renderParams ps = T.intercalate ", "
  [ T.unwords (paramMods p <> [paramType p, identOrig (paramName p)])
  | p <- ps
  ]

data FnSig = FnSig
  { fnsMods           :: [Text]
  , fnsReturnType     :: Text
  , fnsReturnTypeSpan :: SourceSpan  -- ^ real span of the 'fnsReturnType' token
  , fnsName           :: Ident
  , fnsParams         :: [Param]
  , fnsThrows         :: Maybe Text
  , fnsLibrary        :: Maybe Text  -- ^ @LIBRARY "libname"@ clause on external function declarations
  , fnsAliasFor       :: Maybe Text  -- ^ @ALIAS FOR "extname"@ clause on external function declarations
  } deriving (Eq, Show, Generic)

data SubSig = SubSig
  { ssMods     :: [Text]
  , ssName     :: Ident
  , ssParams   :: [Param]
  , ssThrows   :: Maybe Text
  , ssLibrary  :: Maybe Text  -- ^ @LIBRARY "libname"@ clause on external subroutine declarations
  , ssAliasFor :: Maybe Text  -- ^ @ALIAS FOR "extname"@ clause on external subroutine declarations
  } deriving (Eq, Show, Generic)

data EventSig = EventSig
  { esName   :: Ident
  , esParams :: [Param]
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
  { obQualName :: Ident
  , obOwner    :: Ident
  , obEvent    :: Ident
  , obBody     :: [Located BodyStmt]
  } deriving (Eq, Show, Generic)

instance NFData SrFile
instance NFData ForwardBlock
instance NFData PrototypesBlock
instance NFData ProtoDecl
instance NFData VariablesBlock
instance NFData VarScope
instance NFData TypeDecl
instance NFData TypeBlock
instance NFData StructureBlock
instance NFData VarDecl
instance NFData GlobalInstance
instance NFData Param
instance NFData FnSig
instance NFData SubSig
instance NFData EventSig
instance NFData FunctionBlock
instance NFData SubroutineBlock
instance NFData EventBlock
instance NFData OnBlock

-- | All type declarations: type-blocks first (authoritative), then forward.
-- Type-block entries win when both declare the same name (left-bias in fromList).
srAllTypeDecls :: SrFile -> [TypeDecl]
srAllTypeDecls sf =
  [ tbDecl tb | tb <- srTypeBlocks sf ]
  <> case srForward sf of
       Nothing -> []
       Just ForwardBlock { fwdTypes = tds } -> tds

-- | Primary object name and ancestor. Prefers the srTypeBlocks entry whose
-- name matches the forward block's first fwdTypes entry -- PowerBuilder's
-- export convention always declares the file's own type first in forward,
-- ahead of any nested control forwards, so this is a reliable signal even
-- when a top-level object-level structure (e.g. `type os_data from
-- structure`) is textually declared before the file's real window/user-
-- object type block. Falls back to the textually-first srTypeBlocks entry
-- (old behavior) when there's no forward block or no name match, then to
-- the forward block, then to the file's first structure block (a standalone
-- @.srs@ file has no TypeBlock at all -- its only declared type is the
-- structure itself), then (mkIdent "", Nothing).
srPrimaryObject :: SrFile -> (Ident, Maybe Text)
srPrimaryObject sf = case matchByForwardHead of
  Just (name, anc) -> (name, Just anc)
  Nothing -> case srTypeBlocks sf of
    (tb:_) -> (tdName (tbDecl tb), Just (tdAncestor (tbDecl tb)))
    []     -> case srForward sf of
                Just (ForwardBlock { fwdTypes = (td:_) }) ->
                  (tdName td, Just (tdAncestor td))
                _ -> case srStructureBlocks sf of
                       (sb:_) -> (sbName sb, Just "structure")
                       []     -> (mkIdent "", Nothing)
  where
    matchByForwardHead :: Maybe (Ident, Text)
    matchByForwardHead = do
      ForwardBlock { fwdTypes = (fwdHead:_) } <- srForward sf
      case [ decl
           | tb <- srTypeBlocks sf
           , let decl = tbDecl tb
           , tdName decl == tdName fwdHead
           ] of
        (decl:_) -> Just (tdName decl, tdAncestor decl)
        []       -> Nothing

-- | Split PowerBuilder's "AncestorClass`LocalName" control-override syntax
-- (e.g. @w_form_tab2\`page1@ -- "this local override of @page1@ is based on
-- ancestor @w_form_tab2@'s own declaration of a control named @page1@").
-- The lexer treats backtick as an identifier-continuation character
-- ('PB.Lexing.Lexer.isIdentCont'), so a 'TypeDecl's 'tdAncestor' carries the
-- whole compound token verbatim; this splits it back apart for any consumer
-- that needs to walk the ancestor as a real object name (e.g.
-- 'PB.Analysis.TypeResolve.buildInheritsMap'). 'Nothing' (2nd component)
-- when there's no backtick -- the ordinary case. Splits at the first
-- backtick only. Used by 'mkTypeDecl' to mint 'tdAncestorClass'\/
-- 'tdAncestorOverride' once at construction.
splitAncestorRef :: Text -> (Ident, Maybe Ident)
splitAncestorRef t = case T.breakOn "`" t of
  (before, rest)
    | T.null rest -> (mkIdent before, Nothing)
    | otherwise   -> (mkIdent before, Just (mkIdent (T.drop 1 rest)))
