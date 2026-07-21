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
  , lookupScopedVarOrSelf
  , lookupInstanceVarOwner
  , ancestorChain
  ) where

import PB.Prelude
import PB.AST.BodyStmt (BodyStmt (..))
import PB.AST.Ident    (Ident, identCanon, identOrig, mkIdent)
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
  <> Map.fromList
       [ (vdName d, parseTypeText (vdType d))
       | VariablesBlock { varDecls = decls } <- srVariables sf
       , d <- decls
       ]
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
  , steParams       :: Set.Set Ident          -- ^ the subset of 'steLocal' that are params --
                                               -- 'procEnv' seeds 'steLocal' with params, and
                                               -- 'PB.Analysis.TypeResolve.extractCallSites''s
                                               -- @withBodyLocals@ then merges body locals into that same
                                               -- map, so 'steLocal' alone can no longer tell param from
                                               -- local; this set is fixed at 'procEnv' time and never
                                               -- touched by that later merge.
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
  <> Map.fromList
       [ (vdName d, parseTypeText (vdType d))
       | VariablesBlock { varDecls = decls } <- srVariables sf
       , d <- decls
       ]

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
-- 'steInstance' merges every ancestor's own instance vars, nearest first
-- ('Map.unions' is left-biased, so 'objName''s own declaration shadows an
-- ancestor's same-named var) -- an instance var declared only on an
-- ancestor class was previously invisible to any procedure of a descendant
-- object, since the pre-Plan-195-Phase-E version looked up 'weInstanceVars'
-- for 'objName' alone with no chain walk.
procEnv :: WorkspaceEnv -> ControlIndex -> Text -> [(Text, PbType)] -> ScopedTypeEnv
procEnv ws idx objName params = ScopedTypeEnv
  { steGlobal       = weGlobals ws
  , steInstance     = Map.unions
                         [ fromMaybe Map.empty (Map.lookup anc (weInstanceVars ws))
                         | anc <- ancestorChain (mkIdent objName) (weHierarchy ws)
                         ]
  , steLocal        = Map.fromList [(mkIdent n, ty) | (n, ty) <- params]
  , steParams       = Set.fromList [mkIdent n | (n, _) <- params]
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

-- | Like 'lookupScopedVar', but resolves the PowerScript keywords @this@
-- (the enclosing object's own type) and @super@ (its immediate ancestor,
-- one hop up 'steHierarchy') before falling back to an ordinary variable
-- lookup. Neither keyword is ever a declared variable, so 'lookupScopedVar'
-- alone always misses them -- every single-segment receiver/lvalue-type
-- resolution in the codebase (call classification, type inference, call
-- resolution) shares this one function so a @this.foo()@/@super.foo()@ call
-- resolves consistently everywhere rather than in some consumers and not
-- others.
lookupScopedVarOrSelf :: Ident -> ScopedTypeEnv -> Maybe PbType
lookupScopedVarOrSelf n env
  | identCanon n == "this"  = Just (PtUserDefined (steObject env))
  | identCanon n == "super" = PtUserDefined . identOrig <$> Map.lookup (mkIdent (steObject env)) (steHierarchy env)
  | otherwise               = lookupScopedVar n env

-- | Walk the inheritance chain from a starting object, including itself.
-- Lives here (rather than in 'PB.Analysis.TypeResolve', which re-exports
-- it) so 'procEnv' can reuse the exact same chain walk for ancestor-aware
-- instance-var lookup instead of re-implementing it -- 'PB.Analysis.TypeResolve'
-- and 'PB.Analysis.TypeFamily' both still reach this via their existing
-- 'ancestorChain' import. 'Ident'-keyed so the walk is case-insensitive at
-- every hop, matching PB's own identifier semantics.
ancestorChain :: Ident -> Map.Map Ident Ident -> [Ident]
ancestorChain start inherits = go [start] start
  where
    go chain cur = case Map.lookup cur inherits of
      Nothing     -> chain
      Just parent ->
        if parent `elem` chain then chain
        else go (chain <> [parent]) parent

-- | Find which object in @start@'s own ancestor chain (including itself)
-- actually declares an instance var named @name@, nearest first. The
-- provenance-preserving counterpart of 'procEnv''s 'steInstance', which
-- folds every ancestor's instance vars into one 'Map.unions'\'d map for
-- ordinary lookup -- fine for "what type is this," but it loses which
-- ancestor actually declared the entry, which a cross-reference consumer
-- needs as its \"declared on\" target.
lookupInstanceVarOwner :: WorkspaceEnv -> Ident -> Ident -> Maybe (Ident, PbType)
lookupInstanceVarOwner ws start name = go (ancestorChain start (weHierarchy ws))
  where
    go [] = Nothing
    go (anc:rest) = case Map.lookup anc (weInstanceVars ws) >>= Map.lookup name of
      Just ty -> Just (anc, ty)
      Nothing -> go rest
