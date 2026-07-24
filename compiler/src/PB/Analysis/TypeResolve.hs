{-# LANGUAGE StrictData #-}
-- | Type resolution and call resolution directly from the parsed AST.
--
-- Pure module — no I/O.  Public API:
--
--   extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]
--   extractCallSites  :: WorkspaceEnv -> ControlIndex -> Text -> Text -> SrFile -> [CallSite]
--   extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
--   resolveTypes      :: [LocalVar] -> IdentSet -> IdentSet -> [ResolvedType]
--   resolveCalls      :: [CallSite] -> IdentMap IdentSet -> IdentMap IdentSet -> Map Text Text -> Set Text -> Set Text -> [ResolvedCall]
--   resolveVirtual    :: Ident -> Text -> IdentMap IdentSet -> Map Text Text -> (Maybe Text, Maybe Text, Text, Text)
--   buildObjectSet    :: [SrFile] -> IdentSet
--   buildUserTypeSet  :: [SrFile] -> IdentSet
--
-- 'extractCallSites' resolves each 'ExMethodCall' receiver's declared type
-- at extraction time via 'PB.Analysis.CallClassify.resolveReceiverType'
-- ('CallSite.csReceiverObject') — that machinery needs a per-procedure
-- 'ScopedTypeEnv' (params + body locals + workspace instance/global maps)
-- and the workspace-wide 'ControlIndex', neither of which exist yet at
-- Pass 5's later, DB-round-tripped 'resolveCalls' stage. 'resolveOne'
-- then just walks 'csReceiverObject' through the same 'resolveVirtual'
-- ancestor-chain combinator every other call kind already uses — no second
-- resolution algorithm.
module PB.Analysis.TypeResolve
  ( LocalVar (..)
  , CallSite (..)
  , GlobalVar (..)
  , ResolvedType (..)
  , ResolvedCall (..)
  , ResolvedVarRef (..)
  , DwControlBinding (..)
  , extractLocalVars
  , extractCallSites
  , extractDwCallSites
  , extractVarRefs
  , extractDwVarRefs
  , extractGlobalVars
  , extractDwControlBindings
  , resolveTypes
  , resolveGlobalTypes
  , resolveCalls
  , resolveVirtual
  , resolveAncestorChain
  , ancestorChain
  , buildProcMap
  , buildCallableProcMap
  , buildObjectSet
  , buildUserTypeSet
  -- exposed for testing and Church spike
  , builtinClassNames
  , isDwFamilyType
  , classifyPbType
  , classifyControlType
  , paramsToVars
  , callSitesExpr
  , walkBodyCallSites
  , classifyLvalueChain
  , classifyChainHops
  , resolveReceiverTypeXref
  , varRefsExpr
  , walkBodyVarRefs
  , srFileObject
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.DataWindow  (DataWindowFile (..), DwControl (..), DwTable (..), DwColumn (..))
import PB.AST.DwPropertySchema (DwElementKind (..), DwBandCategory (..))
import PB.AST.Expr
import PB.AST.Ident       (Ident, IdentMap, IdentSet, identCanon, identMapLookup, identMapToList,
                           identOrig, identSetFromList, identSetLookup, identSpan, mkIdent,
                           provenanceSpan)
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import PB.AST.Type        (PbType (..), parseTypeTextAt, renderPbType)
import PB.Lexing.Token    (SourceSpan)
import PB.Analysis.CallClassify   (ProcUnit (..), forProcedures)
import PB.Analysis.DwBuiltins     (dwPropertyCatalog, classifyDwBandKeyword)
import PB.Analysis.ControlHierarchy (ControlIndex, findLiteralDataObject, resolveMemberChainType,
                                      resolveMemberChainDwBinding)
import PB.Analysis.TypeEnv        (ScopedTypeEnv (..), WorkspaceEnv (..), ancestorChain,
                                    buildProcMap, buildCallableProcMap, isDescendantOf,
                                    lookupInstanceVarOwner, procEnv)

import Data.Aeson         (ToJSON (..), (.=))
import Data.Foldable      (find)
import qualified Data.Aeson as A
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Hardcoded PB built-in class names that classify as "primitive" kind.
-- Mirrors Python's PB_BUILTINS set in type_resolution.py.

pbBuiltins :: Set.Set Text
pbBuiltins = Set.fromList
  [ "datawindow", "datastore", "datawindowchild", "window"
  , "pointer", "transaction", "dynamicdescriptionarea"
  , "error", "message", "powerobject", "structure"
  , "treeviewitem", "dwitemstatus", "menu"
  ]

-- | Naming-convention map for window control type inference.
-- Prefix -> PB class name. Longer prefixes first to avoid false matches.
-- TODO: this is wrong since these prefixes are just convention and culture,
-- not a hard rule. The only correct mapping is .sr* -> type.
controlPrefixMap :: [(Text, Text)]
controlPrefixMap =
  [ ("ddplb_", "dropdownpicturelistbox")
  , ("ddlb_",  "dropdownlistbox")
  , ("dddw_",  "datawindowchild")
  , ("dw_",    "datawindow")
  , ("cbx_",   "checkbox")
  , ("hpb_",   "hprogressbar")
  , ("htb_",   "htrackbar")
  , ("hsb_",   "hscrollbar")
  , ("vpb_",   "vprogressbar")
  , ("vtb_",   "vtrackbar")
  , ("vsb_",   "vscrollbar")
  , ("plb_",   "picturelistbox")
  , ("sh_",    "statichyperlink")
  , ("ph_",    "picturehyperlink")
  , ("rb_",    "radiobutton")
  , ("cb_",    "commandbutton")
  , ("st_",    "statictext")
  , ("sle_",   "singlelineedit")
  , ("mle_",   "multilineedit")
  , ("em_",    "editmask")
  , ("lb_",    "listbox")
  , ("tv_",    "treeview")
  , ("lv_",    "listview")
  , ("rte_",   "richtextedit")
  , ("tab_",   "tab")
  , ("gr_",    "graph")
  , ("ole_",   "olecontrol")
  , ("uo_",    "userobject")
  , ("gb_",    "groupbox")
  , ("p_",     "picture")
  , ("m_",     "menu")
  ]

-- | Infer PB control type from naming convention (e.g. dw_main -> datawindow).
classifyControlType :: Text -> Maybe Text
classifyControlType name = go controlPrefixMap
  where
    lower = T.toLower name
    go [] = Nothing
    go ((prefix, pbType) : rest)
      | prefix `T.isPrefixOf` lower = Just pbType
      | otherwise = go rest

-- ---------------------------------------------------------------------------
-- Data types

-- | lvPbType is an internal field used for classification; excluded from JSON.
data LocalVar = LocalVar
  { lvFile      :: Text
  , lvObject    :: Text
  , lvProcName  :: Text
  , lvVarName   :: Text
  , lvRawType   :: Text
  , lvIsParam   :: Bool
  , lvScopeLine :: Int
  , lvPbType    :: PbType
  } deriving (Eq, Show)

instance ToJSON LocalVar where
  toJSON lv = A.object
    [ "file"      .= lvFile      lv
    , "object"    .= lvObject    lv
    , "procName"  .= lvProcName  lv
    , "varName"   .= lvVarName   lv
    , "rawType"   .= lvRawType   lv
    , "isParam"   .= lvIsParam   lv
    , "scopeLine" .= lvScopeLine lv
    ]

data CallSite = CallSite
  { csFile           :: Text
  , csObject         :: Text
  , csFromProc       :: Text
  , csToName         :: Text
  , csCallType       :: Text
  , csLine           :: Maybe Int
  , csReceiverObject :: Maybe Text
    -- ^ 'ExMethodCall' only: the receiver's resolved declared type (lowercase),
    -- via 'PB.Analysis.CallClassify.resolveReceiverType'. 'Nothing' for
    -- 'ExCall'\/'ExDispatch', and for an 'ExMethodCall' whose receiver isn't
    -- statically resolvable (e.g. a chained-call receiver such as
    -- @a.b().c()@'s @c@ -- skipped rather than guessed).
  , csToNameSpan     :: Maybe SourceSpan
    -- ^ The real source span of the identifier token(s) 'csToName' was
    -- flattened from -- distinct from 'csLine' (the enclosing statement's
    -- line, which 'PB.Analysis.Taint.buildInterprocEdges' matches call
    -- sites against def\/use sites by, and so must stay untouched).
  } deriving (Eq, Show)

instance ToJSON CallSite where
  toJSON cs = A.object
    [ "file"           .= csFile           cs
    , "object"         .= csObject         cs
    , "fromProc"       .= csFromProc       cs
    , "toName"         .= csToName         cs
    , "callType"       .= csCallType       cs
    , "line"           .= csLine           cs
    , "receiverObject" .= csReceiverObject cs
    , "toNameSpan"     .= csToNameSpan     cs
    ]

-- | gvPbType is an internal field used for classification; excluded from
-- JSON -- mirrors 'LocalVar''s 'lvRawType'/'lvPbType' pair.
data GlobalVar = GlobalVar
  { gvFile   :: Text
  , gvObject :: Text
  , gvName   :: Text
  , gvType   :: Text
  , gvMods   :: [Text]
  , gvPbType :: PbType
  } deriving (Eq, Show)

instance ToJSON GlobalVar where
  toJSON gv = A.object
    [ "file"   .= gvFile   gv
    , "object" .= gvObject gv
    , "name"   .= gvName   gv
    , "type"   .= gvType   gv
    , "mods"   .= gvMods   gv
    ]

data ResolvedType = ResolvedType
  { rtFile      :: Text
  , rtObject    :: Text
  , rtProcName  :: Text
  , rtVarName   :: Text
  , rtRawType   :: Text
  , rtKind      :: Text    -- "primitive" | "user_type" | "object" | "any" | "unresolved"
  , rtTarget    :: Maybe Text
  , rtScope     :: Text    -- "local" | "param" | "instance"
  , rtScopeLine :: Int
  } deriving (Eq, Show)

instance ToJSON ResolvedType where
  toJSON rt = A.object
    [ "file"      .= rtFile      rt
    , "object"    .= rtObject    rt
    , "procName"  .= rtProcName  rt
    , "varName"   .= rtVarName   rt
    , "rawType"   .= rtRawType   rt
    , "kind"      .= rtKind      rt
    , "target"    .= rtTarget    rt
    , "scope"     .= rtScope     rt
    , "scopeLine" .= rtScopeLine rt
    ]

data ResolvedCall = ResolvedCall
  { rcFile         :: Text
  , rcObject       :: Text
  , rcFromProc     :: Text
  , rcToName       :: Text
  , rcCallType     :: Text
  , rcLine         :: Maybe Int
  , rcTargetObject :: Maybe Text
  , rcTargetProc   :: Maybe Text
  , rcKind         :: Text   -- "virtual" | "static" | "inherited" | "unresolved"
  , rcConfidence   :: Text   -- "high" | "medium" | "low"
  , rcSpan         :: Maybe SourceSpan  -- ^ see 'CallSite.csToNameSpan'
  } deriving (Eq, Show)

instance ToJSON ResolvedCall where
  toJSON rc = A.object
    [ "file"         .= rcFile         rc
    , "object"       .= rcObject       rc
    , "fromProc"     .= rcFromProc     rc
    , "toName"       .= rcToName       rc
    , "callType"     .= rcCallType     rc
    , "line"         .= rcLine         rc
    , "targetObject" .= rcTargetObject rc
    , "targetProc"   .= rcTargetProc   rc
    , "kind"         .= rcKind         rc
    , "confidence"   .= rcConfidence   rc
    , "span"         .= rcSpan         rc
    ]

-- | One resolved read\/write reference to a named identifier -- the
-- canonical variable\/property cross-reference relation, parallel to
-- 'ResolvedCall'. Fully resolved at extraction time, unlike 'ResolvedCall'
-- -- a variable reference is always scoped to the current
-- procedure's own 'PB.Analysis.TypeEnv.ScopedTypeEnv' plus the
-- workspace-wide 'ControlIndex', never an ancestor-chain call dispatch, so
-- no Pass-5 cross-file closure is needed the way 'resolveCalls' needs one.
data ResolvedVarRef = ResolvedVarRef
  { rvrFile         :: Text
  , rvrObject       :: Text
  , rvrFromProc     :: Text
  , rvrLine         :: Maybe Int
  , rvrName         :: Text
  , rvrAccess       :: Text          -- "read" | "write"
  , rvrTargetObject :: Maybe Text
  , rvrKind         :: Text   -- "local" | "param" | "instance" | "global" | "control" | "class" | "class_static" | "builtin_property" | "dw_column" | "dw_control" | "dw_property" | "unresolved"
  , rvrConfidence   :: Text   -- "high" | "low" | "unresolved"
  , rvrSpan         :: Maybe SourceSpan
    -- ^ The real source span of this occurrence's own identifier segment
    -- ('rvrName') -- distinct from 'rvrLine' (the enclosing statement's
    -- line; kept as-is for parity with 'CallSite.csLine').
  , rvrDeclaredType :: Maybe Text
    -- ^ This segment's own resolved PowerScript type (lowercased, e.g.
    -- \"long\", \"w_main\"), where the classification that produced
    -- 'rvrKind' had one in hand -- 'Nothing' for a builtin property (no
    -- type table exists for builtin class members) or an unresolved
    -- segment.
  } deriving (Eq, Show)

instance ToJSON ResolvedVarRef where
  toJSON rvr = A.object
    [ "file"         .= rvrFile         rvr
    , "object"       .= rvrObject       rvr
    , "fromProc"     .= rvrFromProc     rvr
    , "line"         .= rvrLine         rvr
    , "name"         .= rvrName         rvr
    , "access"       .= rvrAccess       rvr
    , "targetObject" .= rvrTargetObject rvr
    , "kind"         .= rvrKind         rvr
    , "confidence"   .= rvrConfidence   rvr
    , "span"         .= rvrSpan         rvr
    , "declaredType" .= rvrDeclaredType rvr
    ]

-- ---------------------------------------------------------------------------
-- Type classification

-- | PB built-in reference types that are semantically objects, not value
-- primitives. parseTypeText puts them in PtPrimitive because they appear in
-- primitiveNames, but classifyPbType should emit "object" kind for them.
builtinClassNames :: Set.Set Text
builtinClassNames = Set.fromList
  [ "datawindow", "datastore", "datawindowchild"
  , "transaction", "nonvisualobject", "visualobject"
  , "powerobject", "userobject", "oleobject"
  , "singlelineedit", "multilineedit", "listbox", "dropdownlistbox"
  , "commandbutton", "checkbox", "radiobutton", "statictext"
  , "window", "childwindow", "sheet", "tab"
  ]

-- | The narrower subset of 'builtinClassNames' that carries the
-- @object.\<column\>@ dynamic pseudo-property (Plan 196 Phase 4 item 1) --
-- that pseudo-property does not exist on e.g. a plain window or button.
dwFamilyClassNames :: Set.Set Text
dwFamilyClassNames = Set.fromList ["datawindow", "datastore", "datawindowchild"]

-- | True when @ty@ itself, or any ancestor reached by walking @inherits@, is
-- one of 'dwFamilyClassNames'. Exported so both 'classifyChainHops' (a
-- receiver's own resolved type) and 'PB.Analysis.DwParamBinding' (a
-- parameter's declared type) share one definition of "is this DW-family"
-- rather than risking two independent copies drifting apart.
isDwFamilyType :: Map.Map Ident Ident -> Text -> Bool
isDwFamilyType inherits ty =
  any (\a -> identCanon a `Set.member` dwFamilyClassNames) (ancestorChain (mkIdent ty) inherits)

-- | Classify a PbType into a resolution kind and optional target name.
-- Mirrors Python classify_type() in type_resolution.py. objs\/userTypes are
-- matched case-insensitively via 'identSetLookup' -- PB identifiers are
-- case-insensitive, so a declared type spelled differently from the
-- matching 'TypeDecl''s own casing (e.g. a var declared @W_Main@ against an
-- object declared @w_main@) must still resolve; the returned target text is
-- always the matched entry's own declared casing ('identOrig'), never the
-- query's, so every consumer sees one canonical spelling per object.
classifyPbType :: PbType -> IdentSet -> IdentSet -> (Text, Maybe Text)
classifyPbType (PtPrimitive t)   _    _
  | identCanon tIdent `Set.member` builtinClassNames = ("object",    Just (identCanon tIdent))
  | otherwise                                        = ("primitive", Nothing)
  where tIdent = mkIdent t
classifyPbType (PtDecimalPrec _) _    _         = ("primitive", Nothing)
classifyPbType PtAny             _    _         = ("any", Nothing)
classifyPbType (PtUserDefined n) objs userTypes
  | Just o <- identSetLookup n objs           = ("object", Just (identOrig o))
  | Just u <- identSetLookup n userTypes      = ("user_type", Just (identOrig u))
  | identCanon n `Set.member` pbBuiltins       = ("primitive", Nothing)
  | otherwise                                  = ("unresolved", Nothing)

-- ---------------------------------------------------------------------------
-- Parameter parsing

-- ---------------------------------------------------------------------------
-- Internal helpers for body walking

dispatchName :: DispatchExpr -> Text
dispatchName (DispatchExpr _ _ _ _ n _) = identOrig n

lvalueName :: Lvalue -> Text
lvalueName lv = T.intercalate "." (map (identOrig . segName) (segments lv))

srFileObject :: SrFile -> Text
srFileObject = identOrig . fst . srPrimaryObject

-- ---------------------------------------------------------------------------
-- Local variable extraction

walkBodyLocalVars :: Text -> Text -> Text -> [Located BodyStmt] -> [LocalVar]
walkBodyLocalVars file obj proc_ = foldStmts classify
  where
    classify (Located line stmt) = case stmt of
      BsLocalVar { varType = ty, varName = n } ->
        [ LocalVar
            { lvFile      = file
            , lvObject    = obj
            , lvProcName  = proc_
            , lvVarName   = identOrig n
            , lvRawType   = renderPbType ty
            , lvIsParam   = False
            , lvScopeLine = line
            , lvPbType    = ty
            } ]
      _ -> []

paramsToVars :: Text -> Text -> Text -> [Param] -> Int -> [LocalVar]
paramsToVars file obj procN params scopeLine =
  [ LocalVar
      { lvFile      = file
      , lvObject    = obj
      , lvProcName  = procN
      , lvVarName   = identOrig (paramName p)
      , lvRawType   = renderPbType ty
      , lvIsParam   = True
      , lvScopeLine = scopeLine
      , lvPbType    = ty
      }
  | p <- params
  , let ty = parseTypeTextAt (paramTypeSpan p) (paramType p)
  ]

-- ---------------------------------------------------------------------------
-- Call site extraction

walkBodyCallSites :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Text -> [Located BodyStmt] -> [CallSite]
walkBodyCallSites wsEnv env file obj proc_ = foldStmts classify
  where
    classify (Located line stmt) = case stmt of
      BsCall expr        -> callSitesExpr wsEnv env file obj proc_ (Just line) expr
      BsAssign _ rhs     -> callSitesExpr wsEnv env file obj proc_ (Just line) rhs
      BsAssignExpr l rhs -> callSitesExpr wsEnv env file obj proc_ (Just line) l
                         <> callSitesExpr wsEnv env file obj proc_ (Just line) rhs
      BsReturn (Just e)  -> callSitesExpr wsEnv env file obj proc_ (Just line) e
      BsLocalVar { varInit = Just e } -> callSitesExpr wsEnv env file obj proc_ (Just line) e
      BsIf IfStmt { ifCond = c } -> callSitesExpr wsEnv env file obj proc_ (Just line) c
      BsFor ForStmt { forFrom = fr, forTo = to_, forStep = step } ->
        callSitesExpr wsEnv env file obj proc_ (Just line) fr
        <> callSitesExpr wsEnv env file obj proc_ (Just line) to_
        <> maybe [] (callSitesExpr wsEnv env file obj proc_ (Just line)) step
      BsDo DoStmt { doCond = pre, doLoop = post } ->
        condCallSites line pre <> condCallSites line post
      BsChoose ChooseStmt { chooseExpr = x } -> callSitesExpr wsEnv env file obj proc_ (Just line) x
      _ -> []

    condCallSites _    Nothing            = []
    condCallSites line (Just (DoWhile e)) = callSitesExpr wsEnv env file obj proc_ (Just line) e
    condCallSites line (Just (DoUntil e)) = callSitesExpr wsEnv env file obj proc_ (Just line) e

-- | Resolve an 'ExMethodCall' receiver's declared type for 'csReceiverObject',
-- reusing 'classifyChainHops' -- the same per-hop fold 'classifyLvalueChain'
-- uses -- so a call receiver gets exactly the same instance-var-chain\/
-- nested-control\/ancestor-chain-builtin resolution power a var-ref chain
-- already has (Plan 196 Phase 4 item 2). 'PB.Analysis.CallClassify.
-- resolveReceiverType' is a different, narrower resolver reused by SSA
-- effect classification and deliberately left alone.
resolveReceiverTypeXref :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Expr -> Maybe Text
resolveReceiverTypeXref wsEnv env obj proc_ (ExLvalue lv) = terminalDeclTy (classifyChainHops wsEnv env obj proc_ lv)
resolveReceiverTypeXref wsEnv env obj proc_ (ExCall lv _) = terminalDeclTy (classifyChainHops wsEnv env obj proc_ lv)
resolveReceiverTypeXref _     _   _   _     _             = Nothing

terminalDeclTy :: [(Text, Maybe Text, Text, Maybe Text)] -> Maybe Text
terminalDeclTy hops = case reverse hops of
  ((_, _, _, declTy) : _) -> declTy
  []                      -> Nothing

callSitesExpr :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Text -> Maybe Int -> Expr -> [CallSite]
callSitesExpr wsEnv env file obj proc_ mLine = foldExprs classify
  where
    classify ExCall { callee = lv } =
      [ CallSite
          { csFile           = file
          , csObject         = obj
          , csFromProc       = proc_
          , csToName         = lvalueName lv
          , csCallType       = "ExCall"
          , csLine           = mLine
          , csReceiverObject = Nothing
          , csToNameSpan     = case reverse (segments lv) of
              (finalSeg:_) -> provenanceSpan (identSpan (segName finalSeg))
              []           -> Nothing
          } ]
    classify ExMethodCall { receiver = recv, method = m } =
      [ CallSite
          { csFile           = file
          , csObject         = obj
          , csFromProc       = proc_
          , csToName         = identOrig m
          , csCallType       = "ExMethodCall"
          , csLine           = mLine
          , csReceiverObject = resolveReceiverTypeXref wsEnv env obj proc_ recv
          , csToNameSpan     = provenanceSpan (identSpan m)
          } ]
    classify (ExDispatch de@DispatchExpr { name = n }) =
      [ CallSite
          { csFile           = file
          , csObject         = obj
          , csFromProc       = proc_
          , csToName         = dispatchName de
          , csCallType       = "ExDispatch"
          , csLine           = mLine
          , csReceiverObject = Nothing
          , csToNameSpan     = provenanceSpan (identSpan n)
          } ]
    classify _ = []

-- ---------------------------------------------------------------------------
-- Exported extraction functions

-- | Extract local variable declarations (body vars + params) from all procedures.
extractLocalVars :: Text -> Text -> SrFile -> [LocalVar]
extractLocalVars file obj sf = concat
  [ concatMap (\fb ->
      paramsToVars file obj (identOrig (fnsName (fbSig fb))) (fnsParams (fbSig fb)) 0
      <> walkBodyLocalVars file obj (identOrig (fnsName (fbSig fb))) (fbBody fb)
    ) (srFunctions sf)
  , concatMap (\sb ->
      paramsToVars file obj (identOrig (ssName (sbSig sb))) (ssParams (sbSig sb)) 0
      <> walkBodyLocalVars file obj (identOrig (ssName (sbSig sb))) (sbBody sb)
    ) (srSubroutines sf)
  , concatMap (\ev ->
      paramsToVars file obj (identOrig (esName (evSig ev))) (esParams (evSig ev)) 0
      <> walkBodyLocalVars file obj (identOrig (esName (evSig ev))) (evBody ev)
    ) (srEvents sf)
  , concatMap (\ob ->
      walkBodyLocalVars file obj (identOrig (obEvent ob)) (obBody ob)
    ) (srOnBlocks sf)
  ]

-- | Extract call sites from all procedure bodies. Each procedure's
-- 'ScopedTypeEnv' (params + its own body locals, matching
-- 'PB.Pipeline.Runner.compileOne''s @procEnvWithLocals@) comes from
-- 'forProcedures' (Plan 197 Finding 7 -- built once per procedure, not
-- reconstructed here) so 'callSitesExpr' can resolve an 'ExMethodCall'
-- receiver's declared type via 'PB.Analysis.CallClassify.resolveReceiverType'
-- -- see this module's header comment for why that resolution happens at
-- extraction time rather than in Pass 5.
extractCallSites :: WorkspaceEnv -> ControlIndex -> Text -> Text -> SrFile -> [CallSite]
extractCallSites wsEnv controlIdx file obj sf =
  concatMap
    (\pu -> walkBodyCallSites wsEnv (puEnv pu) file obj (puName pu) (puBody pu))
    (forProcedures wsEnv controlIdx obj sf)

-- | Extract call sites from DataWindow control expressions and format strings.
-- Uses fromProc = "" (no containing procedure) and no line information; the
-- env carries only params/body-locals-free workspace scope (a DW control
-- expression has no enclosing procedure to seed locals from).
extractDwCallSites :: WorkspaceEnv -> ControlIndex -> Text -> Text -> DataWindowFile -> [CallSite]
extractDwCallSites wsEnv controlIdx file obj dw = concatMap fromCtrl (dwControls dw)
  where
    env = procEnv wsEnv controlIdx obj []
    fromCtrl ctrl =
      foldMap (callSitesExpr wsEnv env file obj "" Nothing) (dwcParsedExpression ctrl)
      <> foldMap (callSitesExpr wsEnv env file obj "" Nothing) (dwcParsedFormat ctrl)

-- ---------------------------------------------------------------------------
-- Variable/property reference extraction

-- | Classify every segment of one lvalue occurrence (a read or a write)
-- into its own 'ResolvedVarRef' -- not just the trailing segment. The
-- first segment resolves against the procedure's own scope (@this@\/
-- @super@, param\/local, instance -- walking the object's own ancestor
-- chain via 'lookupInstanceVarOwner', global), falling back to a 1-hop
-- 'ControlIndex' lookup for a visual control (e.g. @dw_1@) -- the same
-- fallback order 'PB.Analysis.CallClassify.resolveLvalueType' already uses
-- for a call receiver. Every later segment is classified relative to the
-- receiver type resolved from everything before it (via 'resolveLvalueType'
-- on the growing prefix): a cross-object instance\/structure-member var if
-- the receiver type declares one, a @builtin_property@ if the receiver is
-- merely a known builtin class, else @unresolved@ -- no guessing past what
-- the workspace actually declares. Only the final segment carries the
-- caller's real read\/write intent (@access@); every segment before it is
-- necessarily read to navigate to the next hop regardless of what happens
-- to the final target (e.g. in @a.b.c = 5@, @a@ and @b@ are reads). Each
-- segment also reports its own resolved declared type (where the
-- classification that produced its 'rvrKind' had one in hand), read
-- directly off whichever lookup found it (steLocal\/steInstance\/steGlobal's
-- 'PbType', or 'lookupInstanceVarOwner''s). That resolved type is threaded
-- forward as the *next* hop's own receiver type, rather than re-derived by
-- calling 'resolveLvalueType' on the growing prefix from scratch -- that
-- function's 2+-segment case only walks the 'ControlIndex' chain (nested
-- visual controls), so it cannot see a receiver that is itself a plain
-- instance variable of a structure\/object type (e.g. hop 2 of
-- @uo_1.io_inner.ai_count@, where @io_inner@ is a declared instance var, not
-- a nested control) -- threading the fold's own already-resolved type
-- avoids re-deriving something the fold already knows, and is correct at
-- any chain depth. Subscript-expression identifiers (e.g. the @i@ in
-- @arr[i]@) are not covered here; see 'PB.Analysis.Dataflow.walkExprIdents'
-- for that concern.
classifyLvalueChain
  :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Text -> Maybe Int -> Text -> Lvalue -> [ResolvedVarRef]
classifyLvalueChain wsEnv env file obj proc_ mLine access lv =
  case segments lv of
    [] -> [ ResolvedVarRef file obj proc_ mLine "" access Nothing "unresolved" "unresolved" Nothing Nothing ]
    segs -> zipWith3 mkRow segs (accesses segs) (classifyChainHops wsEnv env obj proc_ lv)
  where
    accesses segs = replicate (length segs - 1) "read" ++ [access]

    mkRow seg acc (kind, tgt, conf, declTy) =
      ResolvedVarRef file obj proc_ mLine (identOrig (segName seg)) acc tgt kind conf
        (provenanceSpan (identSpan (segName seg))) declTy

-- | Classify every segment of a dotted 'Lvalue' chain into a (kind, target
-- object, confidence, declared type) tuple per hop, threading each hop's own
-- resolved type forward as the next hop's receiver type -- the resolution
-- logic 'classifyLvalueChain' wraps into 'ResolvedVarRef' rows, and
-- 'resolveReceiverTypeXref' reuses directly (keeping only the terminal hop)
-- for an 'ExMethodCall' receiver. The single place ancestor-chain\/nested-
-- control\/instance-var-chain hop resolution lives, so every cross-reference
-- consumer sees identical resolution power (Plan 196 Phase 4 item 2).
-- Deliberately separate from 'PB.Analysis.CallClassify.resolveLvalueType',
-- which serves a narrower need (SSA effect classification via
-- 'classifyExpr'\/'classifyEffects', consumed by 'PB.Compile.FromSSA') and
-- must not gain a 'WorkspaceEnv' dependency that would ripple into the
-- compile pipeline for a cross-reference-only fix.
classifyChainHops :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Lvalue -> [(Text, Maybe Text, Text, Maybe Text)]
classifyChainHops wsEnv env obj proc_ lv =
  case segments lv of
    []            -> []
    (seg0 : rest) ->
      let hop0 = classifyRoot (segName seg0)
      in publicRow hop0 : go (contOf hop0) rest
  where
    publicRow (kind, tgt, conf, declTy, _) = (kind, tgt, conf, declTy)
    contOf    (_, _, _, _, cont)           = cont

    go _    []           = []
    go cont (seg : rest) =
      let hop = classifyMemberOf cont (segName seg)
      in publicRow hop : go (contOf hop) rest

    -- 'literalAnchor' at hop 1 always tests @obj@'s own control declarations
    -- for this segment, *independent* of which branch below actually wins
    -- display -- PowerBuilder's own codegen declares an identically-named
    -- instance var for *every* placed control (e.g. a window with a
    -- @tab1@ control also declares a plain instance var @tab1 tab1@), so
    -- 'lookupInstanceVarOwner' succeeds for virtually every real nested
    -- control's own name and would otherwise always win priority, silently
    -- discarding the one piece of state (the visual-tree anchor) a
    -- *further* nested-control hop needs. See 'classifyMemberOf's own
    -- 'literalExt'\/'hasAExt' for the full design rationale (confirmed via
    -- real-corpus regression, not hypothetical).
    classifyRoot n
      | identCanon n == "this"  =
          ("class", Just obj, "high", Just (T.toLower obj), Just (mkOrdinary (T.toLower obj) Nothing literalAnchor))
      | identCanon n == "super" =
          case Map.lookup (mkIdent obj) (steHierarchy env) of
            Just anc -> let ancTy = T.toLower (identOrig anc)
                        in ("class_static", Just (identOrig anc), "high", Just ancTy, Just (mkOrdinary ancTy Nothing literalAnchor))
            Nothing  -> ("unresolved", Nothing, "unresolved", Nothing, Nothing)
      | Just ty <- Map.lookup n (steLocal env) =
          let tyTxt   = T.toLower (renderPbType ty)
              isParam = n `Set.member` steParams env
              -- A 'ref datawindow' param has no static binding on its own
              -- declaration; Plan 196 Phase 4 item 1's 'PB.Analysis.
              -- DwParamBinding' traces it instead, one hop across the call
              -- graph to whichever literal DW every caller passes at this
              -- position (only populated when every caller agrees).
              dwBind
                | isParam, isDwFamily tyTxt
                = Map.lookup n (steParamIndex env)
                    >>= \idx -> Map.lookup (obj, proc_, idx) (weDwParamBindings wsEnv)
                | otherwise = Nothing
          in ( if isParam then "param" else "local"
             , Nothing, "high", Just tyTxt, Just (mkOrdinary tyTxt dwBind literalAnchor) )
      | Just (ancIdent, ty) <- lookupInstanceVarOwner wsEnv (mkIdent obj) n =
          let tyTxt = T.toLower (renderPbType ty)
          in ("instance", Just (identOrig ancIdent), "high", Just tyTxt, Just (mkOrdinary tyTxt Nothing literalAnchor))
      | Just ty <- Map.lookup n (steGlobal env) =
          let tyTxt = T.toLower (renderPbType ty)
          in ("global", Nothing, "high", Just tyTxt, Just (mkOrdinary tyTxt Nothing literalAnchor))
      | Just ctrlTy <- literalCtrl =
          ("control", Just ctrlTy, "high", Just ctrlTy,
           Just (mkOrdinary ctrlTy (dwBindingFor obj [nSeg]) literalAnchor))
      | Map.member n (steHierarchy env) =
          -- A bare segment naming its own declared class/window/UDT rather
          -- than an in-scope variable holding one -- e.g. @w_main::event()@.
          -- Ordered after every real in-scope check above so an actual
          -- local\/instance\/global\/control wins over a same-named type.
          let tyTxt = identCanon n
          in ("class_static", Just (identOrig n), "high", Just tyTxt, Just (mkOrdinary tyTxt Nothing literalAnchor))
      | isBuiltinFamily obj =
          -- A bare, unqualified name inside the enclosing object's own
          -- script is an implicit @this.@ access -- if 'obj' itself is (or
          -- descends from) a builtin class, an otherwise-unresolvable bare
          -- name is most plausibly that builtin ancestor's own inherited
          -- property (e.g. a menu item's bare @ParentWindow@), not a typo.
          ("builtin_property", Nothing, "high", Nothing, Nothing)
      | otherwise = ("unresolved", Nothing, "unresolved", Nothing, Nothing)
      where
        nSeg          = identCanon n
        literalCtrl   = resolveMemberChainType (steControlIndex env) (steHierarchy env) obj [nSeg]
        literalAnchor = const (obj, [nSeg]) <$> literalCtrl

    -- | True when @ty@ itself, or any ancestor reached by walking
    -- 'steHierarchy', is a recognized builtin class name. A user-defined
    -- descendant of a builtin class (e.g. @w_printer from window@) inherits
    -- that builtin's own property\/method surface, so a member unresolved
    -- against the descendant's own name must still be checked against every
    -- ancestor up to the builtin root before giving up.
    isBuiltinFamily ty = isDescendantOf (steHierarchy env) ty (builtinClassNames <> pbBuiltins)

    isDwFamily recvTy = isDwFamilyType (steHierarchy env) recvTy

    -- | The literal @.srd@ name statically bound to the control resolved by
    -- walking @root@ down @path@, if any -- reuses the exact @(root, path)@
    -- arguments 'resolveMemberChainType' was just called with, so this never
    -- re-derives a different chain.
    dwBindingFor root path = resolveMemberChainDwBinding (steControlIndex env) (steHierarchy env) root path

    mkOrdinary ty dwBind ctrlAnchor = OrdinaryRecv ty dwBind ctrlAnchor

    -- | Classify one member hop given the previous hop's own continuation
    -- context (this fold's own accumulator). 'OrdinaryRecv' carries the
    -- current hop's own declared type (for instance-var\/global-like
    -- lookups), its own statically-known DataWindow binding if applicable
    -- (so the *next* hop can expose that binding's column namespace if it
    -- turns out to be the DW pseudo-property @object@), and the inherited
    -- visual-tree @(anchor, pathFromAnchor)@, if the chain up to (not
    -- including) this hop was reachable via 'resolveMemberChainType' at all.
    --
    -- The anchor is threaded and tested *independent* of which branch below
    -- wins display, for the same reason 'classifyRoot' computes
    -- 'literalAnchor' independently: PowerBuilder's codegen gives every
    -- placed control a same-named instance var, so 'lookupInstanceVarOwner'
    -- succeeds for virtually every real nested-control segment and would
    -- otherwise always win the instance-var branch below, silently breaking
    -- the anchor for any *further* nested-control hop even though the
    -- visual tree is still perfectly walkable underneath. Confirmed as a
    -- real regression via real-corpus `--db` re-verification, not
    -- hypothetical: a 3+-hop pure nested-control chain with no intervening
    -- instance var (@tab1.page1.uo_epidom.uf_filter()@,
    -- `final.pbl/w_misth_final_details_form_edit.srw:74`) silently lost its
    -- `ExMethodCall` receiver resolution once hop 1 ('tab1', which *also*
    -- has a same-named instance var per that codegen convention) reset the
    -- anchor to 'Nothing' merely because 'lookupInstanceVarOwner' won
    -- display there.
    --
    -- 'literalExt' extends the inherited anchor with this segment (one
    -- 'resolveMemberChainType' call, re-derived from the *same* stable
    -- anchor with the growing suffix -- 'resolveChain' is not decomposable
    -- into independent single-segment calls, since it switches between two
    -- different root-tracking conventions as it walks a real chain).
    -- 'hasAExt' is the "has-a" fallback: 'recvTy' is a plain instance
    -- var\/param's own type (never itself reached via a control chain, or
    -- the literal continuation just failed), so a nested visual control on
    -- it starts a *fresh* one-segment chain rooted at 'recvTy' (e.g.
    -- @iw_parent.dw_main@, where @iw_parent@ is an instance var and
    -- @dw_main@ is a control declared on its class -- 'PB.Analysis.
    -- ControlHierarchy''s own module documentation calls this the "has-a"
    -- convention, the literal-name walk the "visual-tree" convention).
    -- 'literalExt' wins when both succeed, since it reflects the actually-
    -- declared chain rather than a same-named coincidence.
    classifyMemberOf Nothing _ = ("unresolved", Nothing, "unresolved", Nothing, Nothing)
    -- | The hop immediately after @.Object@: either the literal @DataWindow@
    -- pseudo-name (selects the object-level property bucket), a closed-set
    -- bandname keyword (@Detail@\/@Footer@\/@Summary@\/@Header@\/@Trailer@,
    -- 'classifyDwBandKeyword'), a real data column name, or a placed
    -- control's own name (Plan 201 Track B1 Slice D -- real corpus grep
    -- confirms @.Object.gr_1.graphtype@-shaped chains are common, not edge
    -- cases). Whichever wins threads its 'DwElementKind' forward via
    -- 'DwPropertyNamespace' so the *next* hop can resolve the actual
    -- property name against 'dwPropertyCatalog'.
    classifyMemberOf (Just (DwColumnsNamespace mDwName)) finalName
      | identCanon finalName == "datawindow" =
          ("builtin_property", Nothing, "high", Nothing, Just (DwPropertyNamespace DwEkObject []))
      | Just cat <- classifyDwBandKeyword (identCanon finalName) =
          ("builtin_property", Nothing, "high", Nothing, Just (DwPropertyNamespace (DwEkBand cat) []))
      -- | @Tree.Level@ is the one bandname the real syntax spells as two dot
      -- segments (XREF_80815_Bandname_property.html), with no confirmed
      -- occurrence in either in-repo example corpus and no real catalog data
      -- behind 'DbcTreeLevel' either way -- so this never reports "high"
      -- confidence. Tagging it 'dw_property'\/"low" (rather than falling
      -- through to the generic 'otherwise' \"dw_column\" bucket below) keeps
      -- it distinguishable in the Type Coverage dashboard's kind\/confidence
      -- breakdown, so a future corpus that does use this shape shows up as a
      -- visible bump instead of disappearing into undifferentiated noise.
      | identCanon finalName == "tree" =
          ("dw_property", Nothing, "low", Nothing, Just (DwPropertyNamespace (DwEkBand DbcTreeLevel) ["tree"]))
      | Just col <- mCol =
          ("dw_column", Nothing, "high", Just (dcType col), Just (DwPropertyNamespace DwEkTableColumn []))
      | Just ctrlKind <- mCtrl =
          ("dw_control", Nothing, "high", Nothing, Just (DwPropertyNamespace (DwEkControl ctrlKind) []))
      | otherwise = ("dw_column", Nothing, "low", Nothing, Nothing)
      where
        mCol = mDwName >>= \dwName -> Map.lookup (T.toLower dwName) (weDwTables wsEnv)
                                    >>= find (\c -> identCanon (mkIdent (dcName c)) == identCanon finalName)
                                    . dtColumns
        mCtrl = mDwName >>= \dwName -> Map.lookup (T.toLower dwName) (weDwControls wsEnv)
                                     >>= Map.lookup (identCanon finalName)
    -- | Every hop after a resolved @.Object@ element (a control, column, or
    -- the @DataWindow@ pseudo-object itself): accumulates the dotted
    -- property-path segments seen so far and retries the lookup against
    -- 'dwPropertyCatalog' on every hop, since catalog keys are themselves
    -- multi-segment dotted paths (e.g. @column.count@, @title.dispattr.
    -- fontproperty@) that don't necessarily match after just one hop.
    classifyMemberOf (Just (DwPropertyNamespace ek path)) finalName =
      let path'  = path <> [identCanon finalName]
          dotted = T.intercalate "." path'
          bucket = Map.findWithDefault Map.empty ek dwPropertyCatalog
      in case Map.lookup dotted bucket of
           Just _  -> ("dw_property", Nothing, "high", Nothing, Nothing)
           Nothing -> ("dw_property", Nothing, "low", Nothing, Just (DwPropertyNamespace ek path'))
    classifyMemberOf (Just (OrdinaryRecv recvTy recvDwBinding ctrlAnchor)) finalName
      | identCanon finalName == "object" && isDwFamily recvTy =
          ("builtin_property", Nothing, "high", recvDwBinding, Just (DwColumnsNamespace recvDwBinding))
      | Just (ancIdent, ty) <- lookupInstanceVarOwner wsEnv (mkIdent recvTy) finalName =
          let tyTxt = T.toLower (renderPbType ty)
          in ("instance", Just (identOrig ancIdent), "high", Just tyTxt, Just (mkOrdinary tyTxt Nothing bestAnchor))
      | Just ctrlTy <- bestCtrl =
          ("control", Just ctrlTy, "high", Just ctrlTy, Just (mkOrdinary ctrlTy bestDw bestAnchor))
      | isBuiltinFamily recvTy =
          ("builtin_property", Nothing, "high", Nothing, Nothing)
      | otherwise = ("unresolved", Nothing, "unresolved", Nothing, Nothing)
      where
        fSeg       = identCanon finalName
        literalExt = ctrlAnchor >>= \(r, p) ->
          let p' = p <> [fSeg]
          in (,) (r, p') <$> resolveMemberChainType (steControlIndex env) (steHierarchy env) r p'
        hasAExt    = (,) (recvTy, [fSeg]) <$> resolveMemberChainType (steControlIndex env) (steHierarchy env) recvTy [fSeg]
        bestExt    = literalExt <|> hasAExt
        bestAnchor = fst <$> bestExt
        bestCtrl   = snd <$> bestExt
        bestDw     = bestAnchor >>= \(r, p) -> dwBindingFor r p

-- | What the *next* hop of a dotted chain should resolve against, given the
-- current hop's own classification -- see 'classifyChainHops'\'s
-- 'classifyMemberOf' doc for the full design rationale.
data ChainContinuation
  = OrdinaryRecv Text (Maybe Text) (Maybe (Text, [Text]))
  | DwColumnsNamespace (Maybe Text)
  | DwPropertyNamespace DwElementKind [Text]

-- | Read references to every named identifier appearing in an expression
-- tree (RHS, conditions, call args, returns, ...) -- calls
-- 'classifyLvalueChain' on every 'ExLvalue' node 'foldExprs' reaches.
varRefsExpr :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Text -> Maybe Int -> Expr -> [ResolvedVarRef]
varRefsExpr wsEnv env file obj proc_ mLine = foldExprs classify
  where
    classify (ExLvalue lv) = classifyLvalueChain wsEnv env file obj proc_ mLine "read" lv
    classify _              = []

-- | Walk one procedure body, emitting a 'ResolvedVarRef' for every named
-- read\/write reference. Mirrors 'walkBodyCallSites''s traversal shape and
-- timing (per-procedure 'ScopedTypeEnv', built once by the caller) but
-- covers every statement shape that reads or writes an 'Lvalue', not just
-- call sites.
walkBodyVarRefs :: WorkspaceEnv -> ScopedTypeEnv -> Text -> Text -> Text -> [Located BodyStmt] -> [ResolvedVarRef]
walkBodyVarRefs wsEnv env file obj proc_ = foldStmts classify
  where
    classify (Located line stmt) = case stmt of
      BsLocalVar { varInit = Just e }               -> readsIn line e
      BsAssign lv rhs                                -> writeRef line lv <> readsIn line rhs
      BsAugAssign lv _ _                             -> writeRef line lv <> readRef line lv
      BsInc lv                                       -> writeRef line lv <> readRef line lv
      BsDec lv                                       -> writeRef line lv <> readRef line lv
      BsCall expr                                    -> readsIn line expr
      BsReturn (Just e)                              -> readsIn line e
      BsIf IfStmt { ifCond = c }                     -> readsIn line c
      BsFor ForStmt { forVar = fv, forFrom = fr, forTo = to_, forStep = step } ->
        writeRef line fv <> readsIn line fr <> readsIn line to_ <> maybe [] (readsIn line) step
      BsDo DoStmt { doCond = pre, doLoop = post }    -> condRefs line pre <> condRefs line post
      BsChoose ChooseStmt { chooseExpr = x }         -> readsIn line x
      BsDestroy lv                                   -> readRef line lv
      BsAssignExpr l rhs                             -> lhsRefs line l <> readsIn line rhs
      BsThrow e                                      -> readsIn line e
      _                                              -> []

    readsIn line = varRefsExpr wsEnv env file obj proc_ (Just line)

    readRef  line lv = classifyLvalueChain wsEnv env file obj proc_ (Just line) "read"  lv
    writeRef line lv = classifyLvalueChain wsEnv env file obj proc_ (Just line) "write" lv

    condRefs _    Nothing            = []
    condRefs line (Just (DoWhile e)) = readsIn line e
    condRefs line (Just (DoUntil e)) = readsIn line e

    lhsRefs line (ExLvalue lv) = writeRef line lv
    lhsRefs line e             = readsIn line e

-- | Extract every variable\/property read\/write reference from all
-- procedure bodies, resolved at extraction time -- see 'ResolvedVarRef''s
-- header comment for why this needs no later cross-file stage, unlike
-- 'extractCallSites'. Reuses the identical per-procedure 'ScopedTypeEnv'
-- construction 'extractCallSites' builds (params + body locals);
-- deliberately a second pass over each body rather than merged with
-- 'extractCallSites''s own traversal, since the two extractions serve
-- different consumers and this keeps 'extractCallSites''s own shape and
-- tests untouched.
extractVarRefs :: WorkspaceEnv -> ControlIndex -> Text -> Text -> SrFile -> [ResolvedVarRef]
extractVarRefs wsEnv controlIdx file obj sf =
  concatMap
    (\pu -> walkBodyVarRefs wsEnv (puEnv pu) file obj (puName pu) (puBody pu))
    (forProcedures wsEnv controlIdx obj sf)

-- | Extract variable\/property references from DataWindow control
-- expressions and format strings, mirroring 'extractDwCallSites'.
extractDwVarRefs :: WorkspaceEnv -> ControlIndex -> Text -> Text -> DataWindowFile -> [ResolvedVarRef]
extractDwVarRefs wsEnv controlIdx file obj dw = concatMap fromCtrl (dwControls dw)
  where
    env = procEnv wsEnv controlIdx obj []
    fromCtrl ctrl =
      foldMap (varRefsExpr wsEnv env file obj "" Nothing) (dwcParsedExpression ctrl)
      <> foldMap (varRefsExpr wsEnv env file obj "" Nothing) (dwcParsedFormat ctrl)

-- | Extract global variable declarations (variables block + global instances).
extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
extractGlobalVars file obj sf =
  declGlobals <> instanceGlobals <> forwardInstanceGlobals
  where
    declGlobals =
      [ GlobalVar
          { gvFile   = file
          , gvObject = obj
          , gvName   = identOrig (vdName d)
          , gvType   = vdType d
          , gvMods   = vdModifiers d
          , gvPbType = parseTypeTextAt (vdTypeSpan d) (vdType d)
          }
      | VariablesBlock { varDecls = ds } <- srVariables sf
      , d <- ds
      ]
    instanceGlobals =
      [ GlobalVar
          { gvFile   = file
          , gvObject = obj
          , gvName   = identOrig (giName gi)
          , gvType   = giType gi
          , gvMods   = []
          , gvPbType = parseTypeTextAt (giTypeSpan gi) (giType gi)
          }
      | gi <- srGlobalInstances sf
      ]
    forwardInstanceGlobals = case srForward sf of
      Nothing -> []
      Just ForwardBlock { fwdInstances = gis } ->
        [ GlobalVar
            { gvFile   = file
            , gvObject = obj
            , gvName   = identOrig (giName gi)
            , gvType   = giType gi
            , gvMods   = []
            , gvPbType = parseTypeTextAt (giTypeSpan gi) (giType gi)
            }
        | gi <- gis
        ]

-- | A control (or an object's own outer 'TypeBlock') whose 'dataobject'
-- property is a literal string. Static-only: this does not follow runtime
-- aliasing (e.g. @idw_epidom = tab1.page1.uo_epidom.dw@, seen in
-- @w_misth_fylo_form.srw@) — a control with no literal 'dataobject' in its
-- own 'TypeBlock' body simply produces no binding, matching the project's
-- existing "skip rather than guess" precedent for ambiguous SQL columns.
data DwControlBinding = DwControlBinding
  { dcbFile        :: Text
  , dcbObject      :: Ident  -- ^ owning window/userobject
  , dcbControlName :: Ident  -- ^ child control name, or "this" for the object's own outer TypeBlock
  , dcbDwName      :: Ident  -- ^ literal dataobject/DataObject string value
  } deriving (Eq, Show)

-- | Extract every static control -> DataWindow-object binding from a file's
-- 'TypeBlock's. A block with 'tdWithin = Just parent' describes a child
-- control named 'tdName' placed inside 'parent'; a block with
-- 'tdWithin = Nothing' describes the object's own outer type, so a literal
-- 'dataobject' set there binds "this".
extractDwControlBindings :: Text -> SrFile -> [DwControlBinding]
extractDwControlBindings file sf =
  [ DwControlBinding file owner ctrlName (mkIdent dwName)
  | tb <- srTypeBlocks sf
  , let decl = tbDecl tb
        (owner, ctrlName) = case tdWithin decl of
          Just parent -> (mkIdent parent, tdName decl)
          Nothing     -> (tdName decl, "this")
  , Just dwName <- [findLiteralDataObject (tbBody tb)]
  ]

-- ---------------------------------------------------------------------------
-- Workspace-level graph builders

-- | All window/userobject-derived type names (not structures).
buildObjectSet :: [SrFile] -> IdentSet
buildObjectSet = identSetFromList . concatMap fileObjs
  where
    fileObjs sf =
      [ tdName td
      | td <- srAllTypeDecls sf
      , T.toLower (tdAncestor td) /= "structure"
      ]

-- | All structure-derived type names (user-defined value types).
buildUserTypeSet :: [SrFile] -> IdentSet
buildUserTypeSet = identSetFromList . concatMap fileUserTypes
  where
    fileUserTypes sf =
      [ tdName td
      | td <- srAllTypeDecls sf
      , T.toLower (tdAncestor td) == "structure"
      ]

-- ---------------------------------------------------------------------------
-- Type resolution

-- | Shared classification core for 'resolveTypes'\/'resolveGlobalTypes':
-- both call 'classifyPbType', apply the same 'classifyControlType' fallback
-- for an "unresolved" result, then build a 'ResolvedType' -- they differ only
-- in how the caller derives 'rtProcName'\/'rtScope'\/'rtScopeLine' from a
-- 'LocalVar' vs a 'GlobalVar'.
resolveOneType :: Text -> Text -> Text -> Text -> Text -> Text -> Int -> PbType -> IdentSet -> IdentSet -> ResolvedType
resolveOneType file obj procN varName rawType scope scopeLine pbTy objs userTypes =
  let (kind, target) = classifyPbType pbTy objs userTypes
      -- Fallback: infer control type from variable name when unresolved
      (kind', target') = case kind of
        "unresolved" -> case classifyControlType varName of
          Just ctrlType -> ("primitive", Just ctrlType)
          Nothing       -> (kind, target)
        _            -> (kind, target)
  in ResolvedType
       { rtFile      = file
       , rtObject    = obj
       , rtProcName  = procN
       , rtVarName   = varName
       , rtRawType   = rawType
       , rtKind      = kind'
       , rtTarget    = target'
       , rtScope     = scope
       , rtScopeLine = scopeLine
       }

-- | Classify each local variable's type.
resolveTypes :: [LocalVar] -> IdentSet -> IdentSet -> [ResolvedType]
resolveTypes vars objs userTypes = map resolve vars
  where
    resolve lv = resolveOneType (lvFile lv) (lvObject lv) (lvProcName lv) (lvVarName lv)
      (lvRawType lv) (if lvIsParam lv then "param" else "local") (lvScopeLine lv)
      (lvPbType lv) objs userTypes

-- | Classify each instance (data member) variable's type. Unlike
-- 'resolveTypes', an instance var has no owning procedure -- it is visible
-- from every procedure body in its object -- so 'rtProcName' is the empty
-- text and consumers key visibility off 'rtScope' == "instance" instead of
-- a proc-name match (mirrors 'paramsToVars' using scope line 0 for "no
-- specific line" rather than inventing a Maybe).
resolveGlobalTypes :: [GlobalVar] -> IdentSet -> IdentSet -> [ResolvedType]
resolveGlobalTypes vars objs userTypes = map resolve vars
  where
    resolve gv = resolveOneType (gvFile gv) (gvObject gv) "" (gvName gv)
      (gvType gv) "instance" 0 (gvPbType gv) objs userTypes

-- ---------------------------------------------------------------------------
-- Call resolution

-- | Resolve a non-dotted call via the caller's own procs and ancestor chain.
-- @toName@ is the call site's identifier, minted once by the caller (either
-- reused directly from an already-'Ident'-typed 'Expr' field, or minted once
-- from a 'Text' wire field such as 'CallSite.csToName' — never re-derived
-- via 'T.toLower' downstream of that single mint). The resolved procedure
-- name in the result is always the matched declaration's own casing
-- ('identOrig'), recovered via 'IdentSet', not the query's. @objN@ is
-- 'Ident' (Plan 179 Phase 5) so the ancestor-chain walk is case-insensitive
-- at its very first hop too. @procMap@ is 'IdentMap'-keyed (Plan 179
-- procMap-outer-key fix) so the resolved target object's name is also
-- always the matched declaration's own casing, recovered from the lookup
-- result — not @anc@'s own casing, which is only however some file's
-- 'inherits' entry happened to spell that ancestor and can genuinely differ
-- from the ancestor's own declaration in its own file.
-- | Ancestor-chain-only resolution: walk @objN@'s own ancestor chain and
-- return the first entry (nearest first) whose procMap contains @toNameIdent@.
-- Deliberately excludes 'resolveVirtual''s "global fallback" (searching
-- every object in the corpus outside the chain) -- callers that need a
-- receiver-precise match without that corpus-wide fallback's
-- misattribution risk (e.g. 'resolveOne''s builtin-method dispatch) use
-- this directly instead of 'resolveVirtual'.
resolveAncestorChain
  :: Ident
  -> Ident
  -> IdentMap IdentSet
  -> Map.Map Ident Ident
  -> Maybe (Text, Text, Text)
resolveAncestorChain toNameIdent objN procMap inherits =
  let chain = ancestorChain objN inherits
      found = [ (anc, objIdent, orig)
              | anc <- chain
              , Just (objIdent, procs) <- [identMapLookup anc procMap]
              , Just orig <- [identSetLookup toNameIdent procs]
              ]
  in case found of
       ((anc, objIdent, orig):_) ->
         let kind = if anc == objN then "virtual" else "inherited"
         in Just (identOrig objIdent, identOrig orig, kind)
       [] -> Nothing

resolveVirtual
  :: Ident
  -> Ident
  -> IdentMap IdentSet
  -> Map.Map Ident Ident
  -> (Maybe Text, Maybe Text, Text, Text)
resolveVirtual toNameIdent objN procMap inherits =
  case resolveAncestorChain toNameIdent objN procMap inherits of
    Just (tObj, tProc, kind) -> (Just tObj, Just tProc, kind, "high")
    Nothing ->
      -- Global fallback: if this name exists in exactly one object outside the
      -- caller's ancestor chain, resolve there (matches Python global_procs logic).
      let chain       = ancestorChain objN inherits
          chainSet    = Set.fromList chain
          globalMatch = [ (objIdent, orig)
                        | (objIdent, procs) <- identMapToList procMap
                        , Just orig <- [identSetLookup toNameIdent procs]
                        , objIdent `Set.notMember` chainSet
                        ]
      in case globalMatch of
           [(objIdent, orig)] -> (Just (identOrig objIdent), Just (identOrig orig), "virtual", "high")
           _                  -> (Nothing, Nothing, "unresolved", "low")

-- | Resolve all call sites to their targets using cross-file proc and inherits maps.
resolveCalls
  :: [CallSite]
  -> IdentMap IdentSet              -- proc_map: object → proc names (all kinds)
  -> IdentMap IdentSet              -- callable_proc_map: object → proc names (function/subroutine only, see 'resolveOne')
  -> Map.Map Ident Ident            -- inherits: child → parent
  -> Set.Set Text                   -- builtin free-function names (lowercase)
  -> Set.Set Text                   -- builtin method names (lowercase)
  -> [ResolvedCall]
resolveCalls sites procMap callableProcMap inherits builtinFns builtinMethods =
  map (resolveOne procMap callableProcMap inherits builtinFns builtinMethods) sites

resolveOne
  :: IdentMap IdentSet
  -> IdentMap IdentSet
  -> Map.Map Ident Ident
  -> Set.Set Text
  -> Set.Set Text
  -> CallSite
  -> ResolvedCall
resolveOne procMap callableProcMap inherits builtinFns builtinMethods cs =
  let (tObj, tProc, kind, conf) = dispatch cs
  in ResolvedCall
       { rcFile         = csFile cs
       , rcObject       = csObject cs
       , rcFromProc     = csFromProc cs
       , rcToName       = csToName cs
       , rcCallType     = csCallType cs
       , rcLine         = csLine cs
       , rcTargetObject = tObj
       , rcTargetProc   = tProc
       , rcKind         = kind
       , rcConfidence   = conf
       , rcSpan         = csToNameSpan cs
       }
  where
    dispatch site = case csCallType site of
      -- Every real 'ExCall' produced by parsing is a bare, unqualified call
      -- (Plan 195 Phase B: a receiver-qualified 'receiver.method()' always
      -- parses as 'ExMethodCall', never a dotted 'ExCall.callee') -- no
      -- dotted-name special case needed here.
      -- A bare call's own object (and its ancestors) is checked first via
      -- 'callableProcMap' -- restricted to function/subroutine proc kinds,
      -- since a real corpus function/subroutine sharing a name with a
      -- builtin free function (a local helper shadowing it) must win, the
      -- same precedence 'ExMethodCall' below already gives a receiver's own
      -- procMap entry over a builtin method name. This must NOT use the
      -- full 'procMap': every window object registers an 'open'\/'close'
      -- event, which would otherwise falsely shadow the builtin 'Open'\/
      -- 'Close' free functions for any bare call made from inside that
      -- window's own script -- events are never callable via bare
      -- @name(...)@ syntax in the first place.
      "ExCall" ->
        let toNameIdent = mkIdent (csToName site)
            objN        = mkIdent (csObject site)
        in case resolveAncestorChain toNameIdent objN callableProcMap inherits of
             Just (tObj, tProc, kind) -> (Just tObj, Just tProc, kind, "high")
             Nothing
               | identCanon toNameIdent `Set.member` builtinFns ->
                   (Nothing, Nothing, "builtin", "high")
               | otherwise -> resolveVirtual toNameIdent objN procMap inherits
      "ExCallArg"    -> resolveVirtual (mkIdent (csToName cs)) (mkIdent (csObject cs)) procMap inherits
      "ExMethodCall" ->
        case csReceiverObject site of
          Just recvTy ->
            case resolveAncestorChain (mkIdent (csToName site)) (mkIdent recvTy) procMap inherits of
              Just (tObj, tProc, kind) -> (Just tObj, Just tProc, kind, "high")
              Nothing
                | identCanon (mkIdent (csToName site)) `Set.member` builtinMethods ->
                    (Nothing, Nothing, "builtin", "high")
                | otherwise ->
                    resolveVirtual (mkIdent (csToName site)) (mkIdent recvTy) procMap inherits
          Nothing ->
            if identCanon (mkIdent (csToName site)) `Set.member` builtinMethods
              then (Nothing, Nothing, "builtin", "high")
              else (Nothing, Nothing, "unresolved", "low")
      "ExDispatch"   -> (Nothing, Nothing, "unresolved", "low")
      _              -> (Nothing, Nothing, "unresolved", "low")
