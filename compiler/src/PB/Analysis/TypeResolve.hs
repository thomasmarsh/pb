{-# LANGUAGE StrictData #-}
-- | Type resolution and call resolution directly from the parsed AST.
--
-- Pure module — no I/O.  Public API:
--
--   extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]
--   extractCallSites  :: WorkspaceEnv -> ControlIndex -> Text -> Text -> SrFile -> [CallSite]
--   extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
--   resolveTypes      :: [LocalVar] -> IdentSet -> IdentSet -> [ResolvedType]
--   resolveCalls      :: [CallSite] -> IdentMap IdentSet -> Map Text Text -> Set Text -> Set Text -> [ResolvedCall]
--   resolveVirtual    :: Ident -> Text -> IdentMap IdentSet -> Map Text Text -> (Maybe Text, Maybe Text, Text, Text)
--   buildInheritsMap  :: [SrFile] -> Map Text Text
--   buildProcMap      :: [SrFile] -> IdentMap IdentSet
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
  , ancestorChain
  , buildInheritsMap
  , buildProcMap
  , buildObjectSet
  , buildUserTypeSet
  -- exposed for testing and Church spike
  , builtinClassNames
  , classifyPbType
  , classifyControlType
  , parseParams
  , paramsToVars
  , callSitesExpr
  , walkBodyCallSites
  , classifyLvalueChain
  , varRefsExpr
  , walkBodyVarRefs
  , srFileObject
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.DataWindow  (DataWindowFile (..), DwControl (..))
import PB.AST.Expr
import PB.AST.Ident       (Ident, IdentMap, IdentSet, identCanon, identMapEmpty,
                           identMapInsertWith, identMapLookup, identMapToList, identOrig,
                           identSetFromList, identSetLookup, identSetUnion, identSpan, mkIdent,
                           provenanceSpan)
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import PB.AST.Type        (PbType (..), parseTypeText, renderPbType)
import PB.Lexing.Token    (SourceSpan)
import PB.Analysis.CallClassify   (collectBodyLocals, resolveReceiverType)
import PB.Analysis.ControlHierarchy (ControlIndex, findLiteralDataObject, resolveMemberChainType)
import PB.Analysis.TypeEnv        (ScopedTypeEnv (..), WorkspaceEnv (..), ancestorChain,
                                    lookupInstanceVarOwner, procEnv)

import Data.Aeson         (ToJSON (..), (.=))
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

data GlobalVar = GlobalVar
  { gvFile   :: Text
  , gvObject :: Text
  , gvName   :: Text
  , gvType   :: Text
  , gvMods   :: [Text]
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
  , rvrKind         :: Text   -- "local" | "param" | "instance" | "global" | "control" | "class" | "builtin_property" | "unresolved"
  , rvrConfidence   :: Text   -- "high" | "unresolved"
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
  | Just o <- identSetLookup nIdent objs           = ("object", Just (identOrig o))
  | Just u <- identSetLookup nIdent userTypes      = ("user_type", Just (identOrig u))
  | identCanon nIdent `Set.member` pbBuiltins       = ("primitive", Nothing)
  | otherwise                                       = ("unresolved", Nothing)
  where nIdent = mkIdent n

-- ---------------------------------------------------------------------------
-- Parameter parsing

-- | Parse a comma-separated parameter declaration string into (name, PbType) pairs.
-- Input: "ref datawindow adw, long al_row"
-- Output: [("adw", PtUserDefined "datawindow"), ("al_row", PtPrimitive "long")]
parseParams :: Text -> [(Text, PbType)]
parseParams raw
  | T.null (T.strip raw) = []
  | otherwise            = mapMaybe parseSegment (T.splitOn "," raw)
  where
    paramMods = ["ref", "readonly", "const", "constant", "value"]

    parseSegment seg =
      let ws = dropWhile (\w -> T.toLower w `elem` paramMods) (T.words (T.strip seg))
          -- Array params render as "type name [ ]" (parseParamsAndThrows joins
          -- tokens with spaces, and '[' / ']' are separate tokens) -- the
          -- brackets always trail the name with no dimension expression in a
          -- signature, so everything from the first '[' on is discarded.
          nonMods = takeWhile (/= "[") ws
      in case reverse nonMods of
           (nm : ty : _) -> Just (nm, parseTypeText ty)
           _             -> Nothing

-- ---------------------------------------------------------------------------
-- Internal helpers for body walking

segName :: LvSegment -> Ident
segName (LvSegment n _) = n

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

paramsToVars :: Text -> Text -> Text -> Text -> Int -> [LocalVar]
paramsToVars file obj procN paramsText scopeLine =
  [ LocalVar
      { lvFile      = file
      , lvObject    = obj
      , lvProcName  = procN
      , lvVarName   = n
      , lvRawType   = renderPbType ty
      , lvIsParam   = True
      , lvScopeLine = scopeLine
      , lvPbType    = ty
      }
  | (n, ty) <- parseParams paramsText
  ]

-- ---------------------------------------------------------------------------
-- Call site extraction

walkBodyCallSites :: ScopedTypeEnv -> Text -> Text -> Text -> [Located BodyStmt] -> [CallSite]
walkBodyCallSites env file obj proc_ = foldStmts classify
  where
    classify (Located line stmt) = case stmt of
      BsCall expr        -> callSitesExpr env file obj proc_ (Just line) expr
      BsAssign _ rhs     -> callSitesExpr env file obj proc_ (Just line) rhs
      BsAssignExpr l rhs -> callSitesExpr env file obj proc_ (Just line) l
                         <> callSitesExpr env file obj proc_ (Just line) rhs
      BsReturn (Just e)  -> callSitesExpr env file obj proc_ (Just line) e
      BsLocalVar { varInit = Just e } -> callSitesExpr env file obj proc_ (Just line) e
      BsIf IfStmt { ifCond = c } -> callSitesExpr env file obj proc_ (Just line) c
      BsFor ForStmt { forFrom = fr, forTo = to_, forStep = step } ->
        callSitesExpr env file obj proc_ (Just line) fr
        <> callSitesExpr env file obj proc_ (Just line) to_
        <> maybe [] (callSitesExpr env file obj proc_ (Just line)) step
      BsDo DoStmt { doCond = pre, doLoop = post } ->
        condCallSites line pre <> condCallSites line post
      BsChoose ChooseStmt { chooseExpr = x } -> callSitesExpr env file obj proc_ (Just line) x
      _ -> []

    condCallSites _    Nothing            = []
    condCallSites line (Just (DoWhile e)) = callSitesExpr env file obj proc_ (Just line) e
    condCallSites line (Just (DoUntil e)) = callSitesExpr env file obj proc_ (Just line) e

callSitesExpr :: ScopedTypeEnv -> Text -> Text -> Text -> Maybe Int -> Expr -> [CallSite]
callSitesExpr env file obj proc_ mLine = foldExprs classify
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
          , csReceiverObject = resolveReceiverType env recv
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
      walkBodyLocalVars file obj (identOrig (esName (evSig ev))) (evBody ev)
    ) (srEvents sf)
  , concatMap (\ob ->
      walkBodyLocalVars file obj (identOrig (obEvent ob)) (obBody ob)
    ) (srOnBlocks sf)
  ]

-- | Extract call sites from all procedure bodies. Each procedure's
-- 'ScopedTypeEnv' (params + its own body locals, matching
-- 'PB.Pipeline.Runner.compileOne''s @procEnvWithLocals@) is built fresh here
-- so 'callSitesExpr' can resolve an 'ExMethodCall' receiver's declared type
-- via 'PB.Analysis.CallClassify.resolveReceiverType' -- see this module's
-- header comment for why that resolution happens at extraction time rather
-- than in Pass 5.
extractCallSites :: WorkspaceEnv -> ControlIndex -> Text -> Text -> SrFile -> [CallSite]
extractCallSites wsEnv controlIdx file obj sf = concat
  [ concatMap (\fb ->
      let body = fbBody fb
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj (parseParams (fnsParams (fbSig fb))))
      in walkBodyCallSites env file obj (identOrig (fnsName (fbSig fb))) body
    ) (srFunctions sf)
  , concatMap (\sb ->
      let body = sbBody sb
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj (parseParams (ssParams (sbSig sb))))
      in walkBodyCallSites env file obj (identOrig (ssName (sbSig sb))) body
    ) (srSubroutines sf)
  , concatMap (\ev ->
      let body = evBody ev
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj (parseParams (esRawSig (evSig ev))))
      in walkBodyCallSites env file obj (identOrig (esName (evSig ev))) body
    ) (srEvents sf)
  , concatMap (\ob ->
      let body = obBody ob
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj [])
      in walkBodyCallSites env file obj (identOrig (obEvent ob)) body
    ) (srOnBlocks sf)
  ]
  where
    withBodyLocals body baseEnv = baseEnv { steLocal = collectBodyLocals body <> steLocal baseEnv }

-- | Extract call sites from DataWindow control expressions and format strings.
-- Uses fromProc = "" (no containing procedure) and no line information; the
-- env carries only params/body-locals-free workspace scope (a DW control
-- expression has no enclosing procedure to seed locals from).
extractDwCallSites :: WorkspaceEnv -> ControlIndex -> Text -> Text -> DataWindowFile -> [CallSite]
extractDwCallSites wsEnv controlIdx file obj dw = concatMap fromCtrl (dwControls dw)
  where
    env = procEnv wsEnv controlIdx obj []
    fromCtrl ctrl =
      foldMap (callSitesExpr env file obj "" Nothing) (dwcParsedExpression ctrl)
      <> foldMap (callSitesExpr env file obj "" Nothing) (dwcParsedFormat ctrl)

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
    []           -> [ ResolvedVarRef file obj proc_ mLine "" access Nothing "unresolved" "unresolved" Nothing Nothing ]
    (seg0 : rest) ->
      let (kind0, tgt0, conf0, declTy0) = classifyRoot (segName seg0)
          row0 = mkRow seg0 (hopAccess rest) tgt0 kind0 conf0 declTy0
      in row0 : go declTy0 rest
  where
    hopAccess rest = if null rest then access else "read"

    mkRow seg acc tgt kind conf declTy =
      ResolvedVarRef file obj proc_ mLine (identOrig (segName seg)) acc tgt kind conf
        (provenanceSpan (identSpan (segName seg))) declTy

    go _      []           = []
    go recvTy (seg : rest) =
      let (kind, tgt, conf, declTy) = classifyMemberOf recvTy (segName seg)
          row = mkRow seg (hopAccess rest) tgt kind conf declTy
      in row : go declTy rest

    classifyRoot n
      | identCanon n == "this"  = ("class", Just obj, "high", Just (T.toLower obj))
      | identCanon n == "super" =
          case Map.lookup (mkIdent obj) (steHierarchy env) of
            Just anc -> ("class", Just (identOrig anc), "high", Just (T.toLower (identOrig anc)))
            Nothing  -> ("unresolved", Nothing, "unresolved", Nothing)
      | Just ty <- Map.lookup n (steLocal env) =
          ( if n `Set.member` steParams env then "param" else "local"
          , Nothing, "high", Just (T.toLower (renderPbType ty)) )
      | Just (ancIdent, ty) <- lookupInstanceVarOwner wsEnv (mkIdent obj) n =
          ("instance", Just (identOrig ancIdent), "high", Just (T.toLower (renderPbType ty)))
      | Just ty <- Map.lookup n (steGlobal env) =
          ("global", Nothing, "high", Just (T.toLower (renderPbType ty)))
      | Just ctrlTy <- resolveMemberChainType (steControlIndex env) (steHierarchy env) obj [identCanon n] =
          ("control", Just ctrlTy, "high", Just ctrlTy)
      | otherwise = ("unresolved", Nothing, "unresolved", Nothing)

    -- | Classify one member hop given the receiver type already resolved by
    -- the previous hop (this fold's own accumulator) -- not re-derived.
    classifyMemberOf Nothing _ = ("unresolved", Nothing, "unresolved", Nothing)
    classifyMemberOf (Just recvTy) finalName
      | Just (ancIdent, ty) <- lookupInstanceVarOwner wsEnv (mkIdent recvTy) finalName =
          ("instance", Just (identOrig ancIdent), "high", Just (T.toLower (renderPbType ty)))
      | identCanon (mkIdent recvTy) `Set.member` builtinClassNames
        || identCanon (mkIdent recvTy) `Set.member` pbBuiltins =
          ("builtin_property", Nothing, "high", Nothing)
      | otherwise = ("unresolved", Nothing, "unresolved", Nothing)

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
extractVarRefs wsEnv controlIdx file obj sf = concat
  [ concatMap (\fb ->
      let body = fbBody fb
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj (parseParams (fnsParams (fbSig fb))))
      in walkBodyVarRefs wsEnv env file obj (identOrig (fnsName (fbSig fb))) body
    ) (srFunctions sf)
  , concatMap (\sb ->
      let body = sbBody sb
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj (parseParams (ssParams (sbSig sb))))
      in walkBodyVarRefs wsEnv env file obj (identOrig (ssName (sbSig sb))) body
    ) (srSubroutines sf)
  , concatMap (\ev ->
      let body = evBody ev
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj (parseParams (esRawSig (evSig ev))))
      in walkBodyVarRefs wsEnv env file obj (identOrig (esName (evSig ev))) body
    ) (srEvents sf)
  , concatMap (\ob ->
      let body = obBody ob
          env  = withBodyLocals body (procEnv wsEnv controlIdx obj [])
      in walkBodyVarRefs wsEnv env file obj (identOrig (obEvent ob)) body
    ) (srOnBlocks sf)
  ]
  where
    withBodyLocals body baseEnv = baseEnv { steLocal = collectBodyLocals body <> steLocal baseEnv }

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

-- | Build an inheritance map (child → parent) from all srTypeBlocks.
-- A backtick-declared ancestor (e.g. @w_form_tab2`page1@ -- "extend
-- ancestor's own control of this same name") resolves to just the
-- ancestor class part, so the chain walk in 'ancestorChain'/'resolveVirtual'
-- can actually find that object rather than silently stopping at a node
-- no object is ever named ('splitAncestorRef'). 'Ident'-keyed (Plan 179
-- Phase 5) so a chain walk starting from a differently-cased query (e.g.
-- 'resolveVirtual''s caller-object argument) still matches this map's own
-- entries -- PB identifiers are case-insensitive, and every node in this
-- map is populated from the same 'Ident'-typed 'tdName'/'tdAncestorClass'
-- fields, so canonical-keyed lookup is always safe here.
buildInheritsMap :: [SrFile] -> Map.Map Ident Ident
buildInheritsMap = Map.fromList . concatMap fileInherits
  where
    fileInherits sf =
      [ (tdName td, tdAncestorClass td) | td <- srAllTypeDecls sf ]

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

-- | Classify each local variable's type.
resolveTypes :: [LocalVar] -> IdentSet -> IdentSet -> [ResolvedType]
resolveTypes vars objs userTypes = map resolve vars
  where
    resolve lv =
      let (kind, target) = classifyPbType (lvPbType lv) objs userTypes
          -- Fallback: infer control type from variable name when unresolved
          (kind', target') = case kind of
            "unresolved" -> case classifyControlType (lvVarName lv) of
              Just ctrlType -> ("primitive", Just ctrlType)
              Nothing       -> (kind, target)
            _            -> (kind, target)
      in ResolvedType
           { rtFile      = lvFile lv
           , rtObject    = lvObject lv
           , rtProcName  = lvProcName lv
           , rtVarName   = lvVarName lv
           , rtRawType   = lvRawType lv
           , rtKind      = kind'
           , rtTarget    = target'
           , rtScope     = if lvIsParam lv then "param" else "local"
           , rtScopeLine = lvScopeLine lv
           }

-- | Classify each instance (data member) variable's type. Unlike
-- 'resolveTypes', an instance var has no owning procedure -- it is visible
-- from every procedure body in its object -- so 'rtProcName' is the empty
-- text and consumers key visibility off 'rtScope' == "instance" instead of
-- a proc-name match (mirrors 'paramsToVars' using scope line 0 for "no
-- specific line" rather than inventing a Maybe).
resolveGlobalTypes :: [GlobalVar] -> IdentSet -> IdentSet -> [ResolvedType]
resolveGlobalTypes vars objs userTypes = map resolve vars
  where
    resolve gv =
      let pbTy = parseTypeText (gvType gv)
          (kind, target) = classifyPbType pbTy objs userTypes
          (kind', target') = case kind of
            "unresolved" -> case classifyControlType (gvName gv) of
              Just ctrlType -> ("primitive", Just ctrlType)
              Nothing       -> (kind, target)
            _            -> (kind, target)
      in ResolvedType
           { rtFile      = gvFile gv
           , rtObject    = gvObject gv
           , rtProcName  = ""
           , rtVarName   = gvName gv
           , rtRawType   = gvType gv
           , rtKind      = kind'
           , rtTarget    = target'
           , rtScope     = "instance"
           , rtScopeLine = 0
           }

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
resolveVirtual
  :: Ident
  -> Ident
  -> IdentMap IdentSet
  -> Map.Map Ident Ident
  -> (Maybe Text, Maybe Text, Text, Text)
resolveVirtual toNameIdent objN procMap inherits =
  let chain  = ancestorChain objN inherits
      found  = [ (anc, objIdent, orig)
               | anc <- chain
               , Just (objIdent, procs) <- [identMapLookup anc procMap]
               , Just orig <- [identSetLookup toNameIdent procs]
               ]
  in case found of
       ((anc, objIdent, orig):_) ->
         let kind = if anc == objN then "virtual" else "inherited"
         in (Just (identOrig objIdent), Just (identOrig orig), kind, "high")
       [] ->
         -- Global fallback: if this name exists in exactly one object outside the
         -- caller's ancestor chain, resolve there (matches Python global_procs logic).
         let chainSet    = Set.fromList chain
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
  -> IdentMap IdentSet              -- proc_map: object → proc names
  -> Map.Map Ident Ident            -- inherits: child → parent
  -> Set.Set Text                   -- builtin free-function names (lowercase)
  -> Set.Set Text                   -- builtin method names (lowercase)
  -> [ResolvedCall]
resolveCalls sites procMap inherits builtinFns builtinMethods =
  map (resolveOne procMap inherits builtinFns builtinMethods) sites

resolveOne
  :: IdentMap IdentSet
  -> Map.Map Ident Ident
  -> Set.Set Text
  -> Set.Set Text
  -> CallSite
  -> ResolvedCall
resolveOne procMap inherits builtinFns builtinMethods cs =
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
      "ExCall" ->
        let toNameIdent = mkIdent (csToName site)
        in if identCanon toNameIdent `Set.member` builtinFns
             then (Nothing, Nothing, "builtin", "high")
             else resolveVirtual toNameIdent (mkIdent (csObject site)) procMap inherits
      "ExCallArg"    -> resolveVirtual (mkIdent (csToName cs)) (mkIdent (csObject cs)) procMap inherits
      "ExMethodCall" ->
        if identCanon (mkIdent (csToName site)) `Set.member` builtinMethods
          then (Nothing, Nothing, "builtin", "high")
          else case csReceiverObject site of
                 Just recvTy -> resolveVirtual (mkIdent (csToName site)) (mkIdent recvTy) procMap inherits
                 Nothing     -> (Nothing, Nothing, "unresolved", "low")
      "ExDispatch"   -> (Nothing, Nothing, "unresolved", "low")
      _              -> (Nothing, Nothing, "unresolved", "low")
