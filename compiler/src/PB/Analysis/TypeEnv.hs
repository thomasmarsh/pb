{-# LANGUAGE StrictData #-}
module PB.Analysis.TypeEnv
  ( TypeEnv (..)
  , buildWorkspaceTypeEnv
  , lookupVarType
  , lookupUserType
  , lookupBaseType
  , isDescendantOf
  , withProcScope
  ) where

import PB.Prelude
import PB.AST.BodyStmt (BodyStmt (..))
import PB.AST.Located  (Located (..))
import PB.AST.SourceFile
import PB.AST.Type
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
  Map.fromList [ (T.toLower (giName gi), parseTypeText (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdInstances = gis }) ->
         Map.fromList [ (T.toLower (giName gi), parseTypeText (giType gi))
                      | gi <- gis ]
  <> case srVariables sf of
       Nothing -> Map.empty
       Just (VariablesBlock { varDecls = decls }) ->
         Map.fromList [ (T.toLower (vdName d), parseTypeText (vdType d)) | d <- decls ]
  <> mconcat
       [ Map.fromList
           [ (T.toLower vn, vt)
           | Located _ (BsLocalVar { varType = vt, varName = vn }) <- tbBody tb
           ]
       | tb <- srTypeBlocks sf
       , tdWithin (tbDecl tb) == Nothing
       ]

-- | Extract type declarations for inheritance resolution.
extractTypeDecls :: SrFile -> Map.Map Text Text
extractTypeDecls sf =
  Map.fromList [ (T.toLower (tdName td), T.toLower (tdAncestor td))
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

-- | Overlay procedure parameters on top of a workspace type env.
-- Parameter names shadow any globals with the same name.
withProcScope :: [(Text, PbType)] -> TypeEnv -> TypeEnv
withProcScope params env = env
  { teVars = Map.fromList [(T.toLower n, ty) | (n, ty) <- params]
             `Map.union` teVars env }
