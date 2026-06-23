{-# LANGUAGE StrictData #-}
module PB.Pipeline.TypeEnv
  ( TypeEnv (..)
  , buildWorkspaceTypeEnv
  , lookupVarType
  , lookupUserType
  , lookupBaseType
  , withProcScope
  ) where

import PB.Prelude
import PB.AST.SourceFile
import PB.AST.BodyStmt
import PB.AST.Type
import PB.AST.Located (Located (..))
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
      { teVars = teVars env <> extractGlobalVars sf <> extractBodyVars sf
      , teUserTypes = teUserTypes env <> extractTypeDecls sf
      }

-- | Extract global variable declarations (instance vars + variables block).
extractGlobalVars :: SrFile -> Map.Map Text PbType
extractGlobalVars sf =
  Map.fromList [ (T.toLower (giName gi), parseTypeText (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srVariables sf of
       Nothing -> Map.empty
       Just (VariablesBlock { varDecls = decls }) ->
         Map.fromList [ (T.toLower (vdName d), parseTypeText (vdType d)) | d <- decls ]

-- | Extract type declarations for inheritance resolution.
extractTypeDecls :: SrFile -> Map.Map Text Text
extractTypeDecls sf =
  Map.fromList [ (T.toLower (tdName (tbDecl tb)), T.toLower (tdAncestor (tbDecl tb)))
               | tb <- srTypeBlocks sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdTypes = tds }) ->
         Map.fromList [ (T.toLower (tdName td), T.toLower (tdAncestor td)) | td <- tds ]

-- | Walk all procedure bodies and collect local variable declarations.
extractBodyVars :: SrFile -> Map.Map Text PbType
extractBodyVars sf = Map.unions
  [ walkBody (fbBody fn)  | fn  <- srFunctions   sf ]
  <> Map.unions
  [ walkBody (sbBody sub) | sub <- srSubroutines sf ]
  <> Map.unions
  [ walkBody (evBody ev)  | ev  <- srEvents      sf ]
  <> Map.unions
  [ walkBody (obBody ob)  | ob  <- srOnBlocks    sf ]

walkBody :: [Located BodyStmt] -> Map.Map Text PbType
walkBody = Map.unions . map (walkStmt . locNode)

walkStmt :: BodyStmt -> Map.Map Text PbType
walkStmt (BsLocalVar { varName = name, varType = ty }) =
  Map.singleton (T.toLower name) ty
walkStmt (BsIf IfStmt { ifThen = t, ifElseIfs = eis, ifElse = e }) =
  walkBody t <> Map.unions (map (walkBody . eifBody) eis) <> maybe Map.empty walkBody e
walkStmt (BsFor ForStmt { forBody = b }) = walkBody b
walkStmt (BsDo DoStmt { doBody = b }) = walkBody b
walkStmt (BsChoose ChooseStmt { chooseClauses = cs }) =
  Map.unions [ walkBody (ccBody c) | c <- cs ]
walkStmt _ = Map.empty

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

-- | Overlay procedure parameters on top of a workspace type env.
-- Parameter names shadow any globals with the same name.
withProcScope :: [(Text, PbType)] -> TypeEnv -> TypeEnv
withProcScope params env = env
  { teVars = Map.fromList [(T.toLower n, ty) | (n, ty) <- params]
             `Map.union` teVars env }
