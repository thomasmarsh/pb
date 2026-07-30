{-# LANGUAGE StrictData #-}
module PB.Analysis.TypeEnv
  ( isDescendantOf
  -- Scoped env
  , WorkspaceEnv (..)
  , ScopedTypeEnv (..)
  , buildWorkspaceEnv
  , buildProcMap
  , buildCallableProcMap
  , withDwTables
  , withDwControls
  , withDwParamBindings
  , procEnv
  , lookupScopedVar
  , lookupScopedVarOrSelf
  , lookupInstanceVarOwner
  , ancestorChain
  , extractNestedTypeDecls
  ) where

import PB.Prelude
import PB.AST.BodyStmt (BodyStmt (..))
import PB.AST.DataWindow (DwTable)
import PB.AST.DwPropertySchema (DwControlKind)
import PB.AST.Ident    (Ident, IdentMap, IdentSet, identCanon, identMapEmpty, identMapInsertWith,
                         identSetFromList, identSetUnion, mkIdent, mkIdentSynthetic)
import PB.AST.Located  (Located (..))
import PB.AST.SourceFile
import PB.AST.Type
import PB.Analysis.ControlHierarchy (ControlIndex)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | Extract type declarations for inheritance resolution. A backtick-declared
-- ancestor (e.g. @w_form_tab2`page1@) resolves to just the ancestor class
-- part -- see 'splitAncestorRef'.
extractTypeDecls :: SrFile -> Map.Map Ident Ident
extractTypeDecls sf =
  Map.fromList [ (tdName td, tdAncestorClass td)
               | td <- srAllTypeDecls sf ]

-- | Ancestor pairs for every nested (@within@-qualified) control 'TypeBlock'
-- in a file -- e.g. @type mdi_1 from mdiclient within w_main@ declares
-- @mdi_1@'s own ancestor @mdiclient@, distinct from @w_main@'s own primary
-- ancestor. Additive to 'extractTypeDecls'\/'weHierarchy' (which already
-- folds every TypeBlock, primary and nested alike, into one flat map): kept
-- as its own function so a consumer whose existing ancestor source only
-- covers primary per-file objects (@objects.ancestor@ in the DuckDB schema,
-- and 'PB.Pipeline.Passes.riInherits' built from it) can union nested
-- control ancestors on top without touching that already-correct primary
-- behavior. Same flat-map name-collision caveat 'weHierarchy' already
-- accepts: a generic control name redeclared with a different ancestor
-- across two unrelated windows (e.g. codegen's @tab1@\/@page1@) resolves to
-- whichever declaration is last in 'Map.fromList' bias -- 'ControlIndex'
-- exists precisely to resolve that case precisely when the caller needs to;
-- this flat map is for callers (ancestor-chain method dispatch) that already
-- only ever had this level of precision.
extractNestedTypeDecls :: SrFile -> Map.Map Ident Ident
extractNestedTypeDecls sf =
  Map.fromList [ (tdName td, tdAncestorClass td)
               | tb <- srTypeBlocks sf
               , let td = tbDecl tb
               , tdWithin td /= Nothing
               ]

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
  , weProcMap      :: IdentMap IdentSet                          -- object name → set of proc names (functions/subroutines/events/on-blocks)
  , weDwTables     :: Map.Map Text DwTable                       -- lowercased .srd base filename → parsed column schema (Plan 196 Phase 4 item 1)
  , weDwControls   :: Map.Map Text (Map.Map Text DwControlKind)  -- lowercased .srd base filename → canon control name → placed-control kind (Plan 201 Track B1 Slice D)
  , weDwParamBindings :: Map.Map (Text, Text, Int) Text          -- (object, proc, param index) → inferred literal .srd binding (Plan 196 Phase 4 item 1)
  }

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
  , steParamIndex   :: Map.Map Ident Int       -- ^ each param's 0-based declaration position -- lets a
                                               -- 'ref datawindow' param be looked up in
                                               -- 'weDwParamBindings' by position (Plan 196 Phase 4 item 1).
  , steHierarchy    :: Map.Map Ident Ident
  , steObject       :: Text          -- enclosing object name; root for multi-hop chain resolution
  , steControlIndex :: ControlIndex  -- workspace-wide control index; see PB.Analysis.ControlHierarchy
  } deriving (Eq, Show)

buildWorkspaceEnv :: [SrFile] -> WorkspaceEnv
buildWorkspaceEnv sfs = WorkspaceEnv
  { weGlobals      = foldl' (\m sf -> m <> extractWsGlobals sf)     Map.empty sfs
  , weDwTables     = Map.empty
  , weDwControls   = Map.empty
  , weDwParamBindings = Map.empty
  , weInstanceVars = foldl' (\m sf -> Map.unionWith (<>) m (extractInstanceVars sf)) Map.empty sfs
  , weHierarchy    = foldl' (\m sf -> m <> extractTypeDecls sf)      Map.empty sfs
  , weProcMap      = buildProcMap sfs
  }

-- | Build a proc map (object → set of proc names) from all procedures. The
-- outer key is canonical-'Ident' ('IdentMap', Plan 179 procMap-outer-key
-- fix) recovering the object's own declared casing on lookup -- a chain
-- member reached via a differently-cased cross-file reference (another
-- file's own spelling of its ancestor) still finds this object's own entry.
-- 'resolveVirtual'/'resolveStaticCall' recover that declared casing from
-- the lookup result itself so the result round-trips through
-- 'PB.Analysis.TypeCheck.tcParams', which is keyed the same way. The inner
-- value is an 'IdentSet' so a call written with different casing than the
-- procedure's own declaration still resolves.
buildProcMap :: [SrFile] -> IdentMap IdentSet
buildProcMap = foldl' addFile identMapEmpty
  where
    addFile acc sf =
      let objIdent = fst (srPrimaryObject sf)
          names = identSetFromList $
            map (fnsName . fbSig) (srFunctions sf)
            <> map (ssName . sbSig) (srSubroutines sf)
            <> map (esName . evSig) (srEvents sf)
            <> map obEvent (srOnBlocks sf)
      in identMapInsertWith identSetUnion objIdent names acc

-- | Same shape as 'buildProcMap', restricted to proc kinds invocable via a
-- bare @name(...)@ call -- excludes @srEvents@\/@srOnBlocks@. See
-- 'PB.Pipeline.DuckDb.PhaseB.Query.queryCallableProcMap''s doc comment for
-- why this must be a separate map from 'buildProcMap' rather than a filter
-- applied everywhere: events are a real, PB-wide name collision risk with
-- builtin free functions (@open@\/@close@ on every window object) that
-- 'ExMethodCall'\/'ExCallArg' dispatch and the global call-site fallback
-- must keep seeing, but a bare 'ExCall' never legitimately targets one.
buildCallableProcMap :: [SrFile] -> IdentMap IdentSet
buildCallableProcMap = foldl' addFile identMapEmpty
  where
    addFile acc sf =
      let objIdent = fst (srPrimaryObject sf)
          names = identSetFromList $
            map (fnsName . fbSig) (srFunctions sf)
            <> map (ssName . sbSig) (srSubroutines sf)
      in identMapInsertWith identSetUnion objIdent names acc

-- | Attach the workspace's inferred @ref datawindow@ parameter bindings
-- (Plan 196 Phase 4 item 1), mirroring 'withDwTables''s additive shape.
withDwParamBindings :: Map.Map (Text, Text, Int) Text -> WorkspaceEnv -> WorkspaceEnv
withDwParamBindings binds ws = ws { weDwParamBindings = binds }

-- | Attach the workspace's parsed DataWindow column schemas (Plan 196
-- Phase 4 item 1). Kept separate from 'buildWorkspaceEnv' itself (whose
-- input is @['SrFile']@, PowerScript source only -- @.srd@ files parse to a
-- distinct 'PB.AST.DataWindow.DataWindowFile', never an 'SrFile') so the
-- ~40 existing 'buildWorkspaceEnv' call sites that don't care about
-- DataWindow column schemas (every unit test fixture) are unaffected.
withDwTables :: Map.Map Text DwTable -> WorkspaceEnv -> WorkspaceEnv
withDwTables tbls ws = ws { weDwTables = tbls }

-- | Attach the workspace's placed-control name → kind index (Plan 201 Track
-- B1 Slice D), mirroring 'withDwTables''s additive shape and the same
-- reasoning for keeping it separate from 'buildWorkspaceEnv': the ~40
-- existing 'buildWorkspaceEnv' call sites with no DataWindow input stay
-- unaffected.
withDwControls :: Map.Map Text (Map.Map Text DwControlKind) -> WorkspaceEnv -> WorkspaceEnv
withDwControls ctrls ws = ws { weDwControls = ctrls }

-- Globals: srGlobalInstances + forward instances + GlobalVars-scoped
-- srVariables (NOT TypeVars-scoped srVariables, which are a class's own
-- instance vars -- see extractInstanceVars).
extractWsGlobals :: SrFile -> Map.Map Ident PbType
extractWsGlobals sf =
  Map.fromList [ (giName gi, parseTypeTextAt (giTypeSpan gi) (giType gi))
               | gi <- srGlobalInstances sf ]
  <> case srForward sf of
       Nothing -> Map.empty
       Just (ForwardBlock { fwdInstances = gis }) ->
         Map.fromList [ (giName gi, parseTypeTextAt (giTypeSpan gi) (giType gi))
                      | gi <- gis ]
  <> Map.fromList
       [ (vdName d, parseTypeTextAt (vdTypeSpan d) (vdType d))
       | VariablesBlock { varScope = GlobalVars, varDecls = decls } <- srVariables sf
       , d <- decls
       ]

-- Instance vars: BsLocalVar nodes in non-within TypeBlock bodies (the
-- layout-property convention, e.g. "integer width = 1792" nested directly
-- in "global type X from Y ... end type"), unioned with any TypeVars-scoped
-- srVariables block (the standalone "type variables ... end variables"
-- convention real corpus .sru/.srw files and runtime/*.sru stdlib stubs use
-- for named instance vars), unioned with every structure's own field list
-- (a structure has no ancestor chain, so keying its fields into this same
-- map lets 'lookupInstanceVarOwner' resolve a structure-field hop for free
-- -- see doc/plan/213-varref-resolution-gaps.md's root cause 1). All three
-- attach to their own declared type name, never the file's primary object
-- for the structure case.
extractInstanceVars :: SrFile -> Map.Map Ident (Map.Map Ident PbType)
extractInstanceVars sf =
  Map.unionWith (<>) fromTypeBlocks (Map.unionWith (<>) fromTypeVarsBlock fromStructureBlocks)
  where
    fromTypeBlocks = Map.fromList
      [ ( tdName (tbDecl tb)
        , Map.fromList
            [ (vn, vt)
            | Located _ (BsLocalVar { varType = vt, varName = vn }) <- tbBody tb
            ]
        )
      | tb <- srTypeBlocks sf
      , tdWithin (tbDecl tb) == Nothing
      ]
    fromTypeVarsBlock =
      let vars = Map.fromList
            [ (vdName d, parseTypeTextAt (vdTypeSpan d) (vdType d))
            | VariablesBlock { varScope = TypeVars, varDecls = decls } <- srVariables sf
            , d <- decls
            ]
      in if Map.null vars then Map.empty else Map.singleton (fst (srPrimaryObject sf)) vars
    fromStructureBlocks = Map.fromListWith (<>)
      [ (sbName sb, Map.singleton (vdName d) (parseTypeTextAt (vdTypeSpan d) (vdType d)))
      | sb <- srStructureBlocks sf
      , d  <- sbFields sb
      ]

-- | Build a ScopedTypeEnv for one (object, params) pair from a WorkspaceEnv.
-- 'steInstance' merges every ancestor's own instance vars, nearest first
-- ('Map.unions' is left-biased, so 'objName''s own declaration shadows an
-- ancestor's same-named var) -- an instance var declared only on an
-- ancestor class was previously invisible to any procedure of a descendant
-- object, since the pre-Plan-195-Phase-E version looked up 'weInstanceVars'
-- for 'objName' alone with no chain walk.
procEnv :: WorkspaceEnv -> ControlIndex -> Text -> [Param] -> ScopedTypeEnv
procEnv ws idx objName params = ScopedTypeEnv
  { steGlobal       = weGlobals ws
  , steInstance     = Map.unions
                         [ fromMaybe Map.empty (Map.lookup anc (weInstanceVars ws))
                         | anc <- ancestorChain (mkIdent objName) (weHierarchy ws)
                         ]
  , steLocal        = Map.fromList [(paramName p, parseTypeTextAt (paramTypeSpan p) (paramType p)) | p <- params]
  , steParams       = Set.fromList [paramName p | p <- params]
  , steParamIndex   = Map.fromList [(paramName p, i) | (p, i) <- zip params [0 ..]]
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
  | identCanon n == "this"  = Just (PtUserDefined thisIdent)
  | identCanon n == "super" = PtUserDefined <$> Map.lookup (mkIdent (steObject env)) (steHierarchy env)
  | otherwise               = lookupScopedVar n env
  where
    -- 'this' has no type-name token of its own to point at -- 'steObject'
    -- only carries the enclosing object's name as plain 'Text', not the
    -- 'Ident' its own 'TypeDecl' declaration was minted with.
    thisIdent = mkIdentSynthetic "'this' keyword has no direct type-name token" (steObject env)

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
