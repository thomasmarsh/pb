{-# LANGUAGE StrictData #-}
module PB.Analysis.TypeEnv
  ( TypeEnv (..)
  , buildWorkspaceTypeEnv
  , lookupVarType
  , lookupUserType
  , lookupBaseType
  , isDescendantOf
  -- Scoped env
  , WorkspaceEnv (..)
  , ScopedTypeEnv (..)
  , buildWorkspaceEnv
  , procEnv
  , lookupScopedVar
  ) where

import PB.Prelude
import PB.AST.BodyStmt (BodyStmt (..))
import PB.AST.Ident    (Ident, identCanon, mkIdent)
import PB.AST.Located  (Located (..))
import PB.AST.SourceFile
import PB.AST.Type
import PB.Analysis.ControlHierarchy (ControlIndex)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | Cross-file type environment.
data TypeEnv = TypeEnv
  { teVars      :: Map.Map Ident PbType   -- variable name → type
  , teUserTypes :: Map.Map Ident Ident    -- user type name → ancestor (for inheritance)
  } deriving (Eq, Show)

emptyTypeEnv :: TypeEnv
emptyTypeEnv = TypeEnv Map.empty Map.empty

-- | Build a workspace-wide type environment from all source files.
-- Pass files in dependency order (forward declarations first).
buildWorkspaceTypeEnv :: [SrFile] -> TypeEnv
buildWorkspaceTypeEnv = foldl' mergeFile emptyTypeEnv
  where
    mergeFile env sf = env
      { teVars = teVars env <> extractGlobalVars sf
      , teUserTypes = teUserTypes env <> extractTypeDecls sf
      }

-- | Extract global variable declarations (instance vars + variables block).
-- Also picks up instance variable declarations from the global type body
-- (the typeBlock where within == Nothing), which the parser emits as BsLocalVar
-- nodes rather than GlobalInstance entries.
extractGlobalVars :: SrFile -> Map.Map Ident PbType
extractGlobalVars sf =
  Map.fromList [ (giName gi, parseTypeText (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdInstances = gis }) ->
         Map.fromList [ (giName gi, parseTypeText (giType gi))
                      | gi <- gis ]
  <> case srVariables sf of
       Nothing -> Map.empty
       Just (VariablesBlock { varDecls = decls }) ->
         Map.fromList [ (vdName d, parseTypeText (vdType d)) | d <- decls ]
  <> mconcat
       [ Map.fromList
           [ (vn, vt)
           | Located _ (BsLocalVar { varType = vt, varName = vn }) <- tbBody tb
           ]
       | tb <- srTypeBlocks sf
       , tdWithin (tbDecl tb) == Nothing
       ]

-- | Extract type declarations for inheritance resolution. A backtick-declared
-- ancestor (e.g. @w_form_tab2`page1@) resolves to just the ancestor class
-- part -- see 'splitAncestorRef' and 'PB.Analysis.TypeResolve.buildInheritsMap'
-- (same fix, same reasoning, applied here for 'lookupBaseType'/'isDescendantOf').
extractTypeDecls :: SrFile -> Map.Map Ident Ident
extractTypeDecls sf =
  Map.fromList [ (tdName td, tdAncestorClass td)
               | td <- srAllTypeDecls sf ]

-- | Look up a variable's type (case-insensitive: 'Ident''s own 'Ord').
lookupVarType :: Ident -> TypeEnv -> Maybe PbType
lookupVarType name = Map.lookup name . teVars

-- | Look up a user-defined type's ancestor (case-insensitive).
lookupUserType :: Ident -> TypeEnv -> Maybe Ident
lookupUserType name = Map.lookup name . teUserTypes

-- | Resolve a variable name to its base type, walking the inheritance chain.
-- Returns the terminal ancestor 'Ident' (preserving whatever casing the
-- ancestor map stored it under), or Nothing if the variable is unknown.
lookupBaseType :: Ident -> TypeEnv -> Maybe Ident
lookupBaseType name env =
  fmap (walkInheritChain (teUserTypes env) . mkIdent . renderPbType)
       (Map.lookup name (teVars env))

walkInheritChain :: Map.Map Ident Ident -> Ident -> Ident
walkInheritChain inh = go Set.empty
  where
    go seen ty
      | Set.member ty seen          = ty
      | Just p <- Map.lookup ty inh = go (Set.insert ty seen) p
      | otherwise                   = ty

-- | True when @ty@ is in @targets@ or has an ancestor in @targets@, walking
-- @inh@ (the workspace's Ident-keyed ancestor map). Cycle-safe via a visited
-- set. @ty0@\/@targets@ stay 'Text': they compare against a closed
-- builtin-class-family vocabulary ('PB.Analysis.CallClassify.dwTypes'\/
-- 'transTypes'), not a workspace identifier -- see
-- @doc/plan/179-canonical-identifier-consumers.md@'s Stage 0 audit.
isDescendantOf :: Map.Map Ident Ident -> Text -> Set.Set Text -> Bool
isDescendantOf inh ty0 targets = go Set.empty (mkIdent ty0)
  where
    go seen ty
      | identCanon ty `Set.member` targets = True
      | ty `Set.member` seen                = False
      | Just p <- Map.lookup ty inh         = go (Set.insert ty seen) p
      | otherwise                            = False

-- ---------------------------------------------------------------------------
-- Scoped type environment

-- | Workspace-level snapshot built once from all parsed files.
data WorkspaceEnv = WorkspaceEnv
  { weGlobals      :: Map.Map Ident PbType                       -- srVariables + forward instances
  , weInstanceVars :: Map.Map Ident (Map.Map Ident PbType)       -- object name → instance vars
  , weHierarchy    :: Map.Map Ident Ident                        -- full inheritance map
  } deriving (Eq, Show)

-- | Procedure-scoped env built per (object, procedure) call site.
-- Lookup order: steLocal > steInstance > steGlobal.
data ScopedTypeEnv = ScopedTypeEnv
  { steGlobal       :: Map.Map Ident PbType
  , steInstance     :: Map.Map Ident PbType
  , steLocal        :: Map.Map Ident PbType   -- params only in P2a; body locals added in P2b
  , steHierarchy    :: Map.Map Ident Ident
  , steObject       :: Text          -- enclosing object name; root for multi-hop chain resolution
  , steControlIndex :: ControlIndex  -- workspace-wide control index; see PB.Analysis.ControlHierarchy
  } deriving (Eq, Show)

buildWorkspaceEnv :: [SrFile] -> WorkspaceEnv
buildWorkspaceEnv sfs = WorkspaceEnv
  { weGlobals      = foldl' (\m sf -> m <> extractWsGlobals sf)     Map.empty sfs
  , weInstanceVars = foldl' (\m sf -> Map.unionWith (<>) m (extractInstanceVars sf)) Map.empty sfs
  , weHierarchy    = foldl' (\m sf -> m <> extractTypeDecls sf)      Map.empty sfs
  }

-- Globals: srGlobalInstances + forward instances + srVariables (NOT TypeBlock body vars).
extractWsGlobals :: SrFile -> Map.Map Ident PbType
extractWsGlobals sf =
  Map.fromList [ (giName gi, parseTypeText (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdInstances = gis }) ->
         Map.fromList [ (giName gi, parseTypeText (giType gi))
                      | gi <- gis ]
  <> case srVariables sf of
       Nothing -> Map.empty
       Just (VariablesBlock { varDecls = decls }) ->
         Map.fromList [ (vdName d, parseTypeText (vdType d)) | d <- decls ]

-- Instance vars: BsLocalVar nodes in non-within TypeBlock bodies, keyed by object name.
extractInstanceVars :: SrFile -> Map.Map Ident (Map.Map Ident PbType)
extractInstanceVars sf = Map.fromList
  [ ( tdName (tbDecl tb)
    , Map.fromList
        [ (vn, vt)
        | Located _ (BsLocalVar { varType = vt, varName = vn }) <- tbBody tb
        ]
    )
  | tb <- srTypeBlocks sf
  , tdWithin (tbDecl tb) == Nothing
  ]

-- | Build a ScopedTypeEnv for one (object, params) pair from a WorkspaceEnv.
procEnv :: WorkspaceEnv -> ControlIndex -> Text -> [(Text, PbType)] -> ScopedTypeEnv
procEnv ws idx objName params = ScopedTypeEnv
  { steGlobal       = weGlobals ws
  , steInstance     = fromMaybe Map.empty
                         (Map.lookup (mkIdent objName) (weInstanceVars ws))
  , steLocal        = Map.fromList [(mkIdent n, ty) | (n, ty) <- params]
  , steHierarchy    = weHierarchy ws
  , steObject       = objName
  , steControlIndex = idx
  }

-- | Case-insensitive lookup: steLocal > steInstance > steGlobal.
lookupScopedVar :: Ident -> ScopedTypeEnv -> Maybe PbType
lookupScopedVar name env =
  Map.lookup name (steLocal env)
  <|> Map.lookup name (steInstance env)
  <|> Map.lookup name (steGlobal env)
