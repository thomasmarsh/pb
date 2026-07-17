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
import PB.AST.Ident    (identCanon)
import PB.AST.Located  (Located (..))
import PB.AST.SourceFile
import PB.AST.Type
import PB.Analysis.ControlHierarchy (ControlIndex)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- | Cross-file type environment.
data TypeEnv = TypeEnv
  { teVars      :: Map.Map Text PbType     -- variable name → type
  , teUserTypes :: Map.Map Text Text        -- user type name → ancestor (for inheritance)
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
extractGlobalVars :: SrFile -> Map.Map Text PbType
extractGlobalVars sf =
  Map.fromList [ (identCanon (giName gi), parseTypeText (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdInstances = gis }) ->
         Map.fromList [ (identCanon (giName gi), parseTypeText (giType gi))
                      | gi <- gis ]
  <> case srVariables sf of
       Nothing -> Map.empty
       Just (VariablesBlock { varDecls = decls }) ->
         Map.fromList [ (identCanon (vdName d), parseTypeText (vdType d)) | d <- decls ]
  <> mconcat
       [ Map.fromList
           [ (T.toLower vn, vt)
           | Located _ (BsLocalVar { varType = vt, varName = vn }) <- tbBody tb
           ]
       | tb <- srTypeBlocks sf
       , tdWithin (tbDecl tb) == Nothing
       ]

-- | Extract type declarations for inheritance resolution. A backtick-declared
-- ancestor (e.g. @w_form_tab2`page1@) resolves to just the ancestor class
-- part -- see 'splitAncestorRef' and 'PB.Analysis.TypeResolve.buildInheritsMap'
-- (same fix, same reasoning, applied here for 'lookupBaseType'/'isDescendantOf').
extractTypeDecls :: SrFile -> Map.Map Text Text
extractTypeDecls sf =
  Map.fromList [ (identCanon (tdName td), identCanon (tdAncestorClass td))
               | td <- srAllTypeDecls sf ]

-- | Look up a variable's type (case-insensitive).
lookupVarType :: Text -> TypeEnv -> Maybe PbType
lookupVarType name = Map.lookup (T.toLower name) . teVars

-- | Look up a user-defined type's ancestor (case-insensitive).
lookupUserType :: Text -> TypeEnv -> Maybe Text
lookupUserType name = Map.lookup (T.toLower name) . teUserTypes

-- | Resolve a variable name to its base type, walking the inheritance chain.
-- Returns the lowercased base type name, or Nothing if the variable is unknown.
lookupBaseType :: Text -> TypeEnv -> Maybe Text
lookupBaseType name env =
  fmap (walkInheritChain (teUserTypes env) . T.toLower . renderPbType)
       (Map.lookup (T.toLower name) (teVars env))

walkInheritChain :: Map.Map Text Text -> Text -> Text
walkInheritChain inh = go Set.empty
  where
    go seen ty
      | Set.member ty seen             = ty
      | Just p <- Map.lookup ty inh   = go (Set.insert ty seen) (T.toLower p)
      | otherwise                      = ty

-- | True when @ty@ (lowercased) is in @targets@ or has an ancestor in @targets@.
-- Cycle-safe via a visited set.
isDescendantOf :: Map.Map Text Text -> Text -> Set.Set Text -> Bool
isDescendantOf inh ty0 targets = go Set.empty (T.toLower ty0)
  where
    go seen ty
      | ty `Set.member` targets = True
      | ty `Set.member` seen    = False
      | Just p <- Map.lookup ty inh = go (Set.insert ty seen) (T.toLower p)
      | otherwise                    = False

-- ---------------------------------------------------------------------------
-- Scoped type environment

-- | Workspace-level snapshot built once from all parsed files.
data WorkspaceEnv = WorkspaceEnv
  { weGlobals      :: Map.Map Text PbType                       -- srVariables + forward instances
  , weInstanceVars :: Map.Map Text (Map.Map Text PbType)        -- object name → instance vars
  , weHierarchy    :: Map.Map Text Text                         -- full inheritance map
  } deriving (Eq, Show)

-- | Procedure-scoped env built per (object, procedure) call site.
-- Lookup order: steLocal > steInstance > steGlobal.
data ScopedTypeEnv = ScopedTypeEnv
  { steGlobal       :: Map.Map Text PbType
  , steInstance     :: Map.Map Text PbType
  , steLocal        :: Map.Map Text PbType   -- params only in P2a; body locals added in P2b
  , steHierarchy    :: Map.Map Text Text
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
extractWsGlobals :: SrFile -> Map.Map Text PbType
extractWsGlobals sf =
  Map.fromList [ (identCanon (giName gi), parseTypeText (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdInstances = gis }) ->
         Map.fromList [ (identCanon (giName gi), parseTypeText (giType gi))
                      | gi <- gis ]
  <> case srVariables sf of
       Nothing -> Map.empty
       Just (VariablesBlock { varDecls = decls }) ->
         Map.fromList [ (identCanon (vdName d), parseTypeText (vdType d)) | d <- decls ]

-- Instance vars: BsLocalVar nodes in non-within TypeBlock bodies, keyed by object name.
extractInstanceVars :: SrFile -> Map.Map Text (Map.Map Text PbType)
extractInstanceVars sf = Map.fromList
  [ ( identCanon (tdName (tbDecl tb))
    , Map.fromList
        [ (T.toLower vn, vt)
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
                         (Map.lookup (T.toLower objName) (weInstanceVars ws))
  , steLocal        = Map.fromList [(T.toLower n, ty) | (n, ty) <- params]
  , steHierarchy    = weHierarchy ws
  , steObject       = objName
  , steControlIndex = idx
  }

-- | Case-insensitive lookup: steLocal > steInstance > steGlobal.
lookupScopedVar :: Text -> ScopedTypeEnv -> Maybe PbType
lookupScopedVar name env =
  let k = T.toLower name
  in Map.lookup k (steLocal env)
     <|> Map.lookup k (steInstance env)
     <|> Map.lookup k (steGlobal env)

