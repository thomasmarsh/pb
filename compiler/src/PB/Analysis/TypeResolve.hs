{-# LANGUAGE StrictData #-}
-- | Type resolution and call resolution directly from the parsed AST.
--
-- Pure module — no I/O.  Public API:
--
--   extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]
--   extractCallSites  :: Text -> Text -> SrFile -> [CallSite]
--   extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
--   resolveTypes      :: [LocalVar] -> IdentSet -> IdentSet -> [ResolvedType]
--   resolveCalls      :: [CallSite] -> Map Text IdentSet -> Map Text Text -> Set Text -> Set Text -> [ResolvedCall]
--   resolveVirtual    :: Ident -> Text -> Map Text IdentSet -> Map Text Text -> (Maybe Text, Maybe Text, Text, Text)
--   resolveStaticCall :: Text -> Map Text IdentSet -> (Maybe Text, Maybe Text, Text, Text)
--   buildInheritsMap  :: [SrFile] -> Map Text Text
--   buildProcMap      :: [SrFile] -> Map Text IdentSet
--   buildObjectSet    :: [SrFile] -> IdentSet
--   buildUserTypeSet  :: [SrFile] -> IdentSet
module PB.Analysis.TypeResolve
  ( LocalVar (..)
  , CallSite (..)
  , GlobalVar (..)
  , ResolvedType (..)
  , ResolvedCall (..)
  , DwControlBinding (..)
  , extractLocalVars
  , extractCallSites
  , extractDwCallSites
  , extractGlobalVars
  , extractDwControlBindings
  , findLiteralDataObject
  , resolveTypes
  , resolveCalls
  , resolveVirtual
  , resolveStaticCall
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
  , srFileObject
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.DataWindow  (DataWindowFile (..), DwControl (..))
import PB.AST.Expr
import PB.AST.Ident       (Ident, IdentSet, identCanon, identOrig, identSetEmpty,
                           identSetFromList, identSetLookup, identSetUnion, mkIdent)
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import PB.AST.Type        (PbType (..), parseTypeText, renderPbType)

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
  { csFile     :: Text
  , csObject   :: Text
  , csFromProc :: Text
  , csToName   :: Text
  , csCallType :: Text
  , csLine     :: Maybe Int
  } deriving (Eq, Show)

instance ToJSON CallSite where
  toJSON cs = A.object
    [ "file"     .= csFile     cs
    , "object"   .= csObject   cs
    , "fromProc" .= csFromProc cs
    , "toName"   .= csToName   cs
    , "callType" .= csCallType cs
    , "line"     .= csLine     cs
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
  , rtIsParam   :: Bool
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
    , "isParam"   .= rtIsParam   rt
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
walkBodyLocalVars file obj proc_ = concatMap (walkStmtLocalVars file obj proc_)

walkStmtLocalVars :: Text -> Text -> Text -> Located BodyStmt -> [LocalVar]
walkStmtLocalVars file obj proc_ (Located line stmt) = case stmt of
  BsLocalVar { varType = ty, varName = n } ->
    [ LocalVar
        { lvFile      = file
        , lvObject    = obj
        , lvProcName  = proc_
        , lvVarName   = n
        , lvRawType   = renderPbType ty
        , lvIsParam   = False
        , lvScopeLine = line
        , lvPbType    = ty
        } ]
  BsIf IfStmt { ifThen = t, ifElseIfs = eis, ifElse = e } ->
    walkBodyLocalVars file obj proc_ t
    <> concatMap (\ei -> walkBodyLocalVars file obj proc_ (eifBody ei)) eis
    <> maybe [] (walkBodyLocalVars file obj proc_) e
  BsFor ForStmt { forBody = b }   -> walkBodyLocalVars file obj proc_ b
  BsDo DoStmt { doBody = b }      -> walkBodyLocalVars file obj proc_ b
  BsChoose ChooseStmt { chooseClauses = cs } ->
    concatMap (\c -> walkBodyLocalVars file obj proc_ (ccBody c)) cs
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

walkBodyCallSites :: Text -> Text -> Text -> [Located BodyStmt] -> [CallSite]
walkBodyCallSites file obj proc_ = concatMap (walkStmtCallSites file obj proc_)

walkStmtCallSites :: Text -> Text -> Text -> Located BodyStmt -> [CallSite]
walkStmtCallSites file obj proc_ (Located line stmt) = case stmt of
  BsCall expr        -> callSitesExpr file obj proc_ (Just line) expr
  BsAssign _ rhs     -> callSitesExpr file obj proc_ (Just line) rhs
  BsAssignExpr l rhs -> callSitesExpr file obj proc_ (Just line) l
                     <> callSitesExpr file obj proc_ (Just line) rhs
  BsReturn (Just e)  -> callSitesExpr file obj proc_ (Just line) e
  BsLocalVar { varInit = Just e } -> callSitesExpr file obj proc_ (Just line) e
  BsIf IfStmt { ifCond = c, ifThen = t, ifElseIfs = eis, ifElse = e } ->
    callSitesExpr file obj proc_ (Just line) c
    <> walkBodyCallSites file obj proc_ t
    <> concatMap (\ei -> callSitesExpr file obj proc_ (Just line) (eifCond ei)
                      <> walkBodyCallSites file obj proc_ (eifBody ei)) eis
    <> maybe [] (walkBodyCallSites file obj proc_) e
  BsFor ForStmt { forFrom = fr, forTo = to_, forStep = step, forBody = b } ->
    callSitesExpr file obj proc_ (Just line) fr
    <> callSitesExpr file obj proc_ (Just line) to_
    <> maybe [] (callSitesExpr file obj proc_ (Just line)) step
    <> walkBodyCallSites file obj proc_ b
  BsDo DoStmt { doCond = pre, doBody = b, doLoop = post } ->
    condCallSites pre
    <> walkBodyCallSites file obj proc_ b
    <> condCallSites post
  BsChoose ChooseStmt { chooseExpr = x, chooseClauses = cs } ->
    callSitesExpr file obj proc_ (Just line) x
    <> concatMap (\c -> walkBodyCallSites file obj proc_ (ccBody c)) cs
  _ -> []
  where
    condCallSites Nothing                = []
    condCallSites (Just (DoWhile e))     = callSitesExpr file obj proc_ (Just line) e
    condCallSites (Just (DoUntil e))     = callSitesExpr file obj proc_ (Just line) e

callSitesExpr :: Text -> Text -> Text -> Maybe Int -> Expr -> [CallSite]
callSitesExpr file obj proc_ mLine expr = case expr of
  ExCall { callee = lv } ->
    [ CallSite
        { csFile     = file
        , csObject   = obj
        , csFromProc = proc_
        , csToName   = lvalueName lv
        , csCallType = "ExCall"
        , csLine     = mLine
        } ]
  ExMethodCall { method = m } ->
    [ CallSite
        { csFile     = file
        , csObject   = obj
        , csFromProc = proc_
        , csToName   = identOrig m
        , csCallType = "ExMethodCall"
        , csLine     = mLine
        } ]
  ExDispatch de ->
    [ CallSite
        { csFile     = file
        , csObject   = obj
        , csFromProc = proc_
        , csToName   = dispatchName de
        , csCallType = "ExDispatch"
        , csLine     = mLine
        } ]
  ExBinOp { lhs = l, rhs = r } ->
    callSitesExpr file obj proc_ mLine l
    <> callSitesExpr file obj proc_ mLine r
  ExNot e    -> callSitesExpr file obj proc_ mLine e
  ExNeg e    -> callSitesExpr file obj proc_ mLine e
  ExArray es -> concatMap (callSitesExpr file obj proc_ mLine) es
  _          -> []

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
      walkBodyLocalVars file obj (obEvent ob) (obBody ob)
    ) (srOnBlocks sf)
  ]

-- | Extract call sites from all procedure bodies.
extractCallSites :: Text -> Text -> SrFile -> [CallSite]
extractCallSites file obj sf = concat
  [ concatMap (\fb -> walkBodyCallSites file obj (identOrig (fnsName (fbSig fb))) (fbBody fb))
      (srFunctions sf)
  , concatMap (\sb -> walkBodyCallSites file obj (identOrig (ssName (sbSig sb))) (sbBody sb))
      (srSubroutines sf)
  , concatMap (\ev -> walkBodyCallSites file obj (identOrig (esName (evSig ev))) (evBody ev))
      (srEvents sf)
  , concatMap (\ob -> walkBodyCallSites file obj (obEvent ob) (obBody ob))
      (srOnBlocks sf)
  ]

-- | Extract call sites from DataWindow control expressions and format strings.
-- Uses fromProc = "" (no containing procedure) and no line information.
extractDwCallSites :: Text -> Text -> DataWindowFile -> [CallSite]
extractDwCallSites file obj dw = concatMap fromCtrl (dwControls dw)
  where
    fromCtrl ctrl =
      foldMap (callSitesExpr file obj "" Nothing) (dwcParsedExpression ctrl)
      <> foldMap (callSitesExpr file obj "" Nothing) (dwcParsedFormat ctrl)

-- | Extract global variable declarations (variables block + global instances).
extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
extractGlobalVars file obj sf =
  declGlobals <> instanceGlobals <> forwardInstanceGlobals
  where
    declGlobals = case srVariables sf of
      Nothing -> []
      Just VariablesBlock { varDecls = ds } ->
        [ GlobalVar
            { gvFile   = file
            , gvObject = obj
            , gvName   = identOrig (vdName d)
            , gvType   = vdType d
            , gvMods   = vdModifiers d
            }
        | d <- ds
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
  , dcbObject      :: Text  -- ^ owning window/userobject
  , dcbControlName :: Text  -- ^ child control name, or "this" for the object's own outer TypeBlock
  , dcbDwName      :: Text  -- ^ literal dataobject/DataObject string value
  } deriving (Eq, Show)

-- | Extract every static control -> DataWindow-object binding from a file's
-- 'TypeBlock's. A block with 'tdWithin = Just parent' describes a child
-- control named 'tdName' placed inside 'parent'; a block with
-- 'tdWithin = Nothing' describes the object's own outer type, so a literal
-- 'dataobject' set there binds "this".
extractDwControlBindings :: Text -> SrFile -> [DwControlBinding]
extractDwControlBindings file sf =
  [ DwControlBinding file owner ctrlName dwName
  | tb <- srTypeBlocks sf
  , let decl = tbDecl tb
        (owner, ctrlName) = case tdWithin decl of
          Just parent -> (parent, identOrig (tdName decl))
          Nothing     -> (identOrig (tdName decl), "this")
  , Just dwName <- [findLiteralDataObject (tbBody tb)]
  ]

-- | The literal string value of a @dataobject@ property set directly in a
-- 'TypeBlock's body (via a 'BsLocalVar' with a string-literal initializer),
-- if any. Shared by 'extractDwControlBindings' (per-file) and
-- 'PB.Analysis.ControlHierarchy.buildControlIndex' (workspace-wide).
findLiteralDataObject :: [Located BodyStmt] -> Maybe Text
findLiteralDataObject stmts = case
  [ s
  | Located _ BsLocalVar { varName = n, varInit = Just (ExStr s) } <- stmts
  , T.toLower n == "dataobject"
  ] of
    (s:_) -> Just s
    []    -> Nothing

-- ---------------------------------------------------------------------------
-- Workspace-level graph builders

-- | Build an inheritance map (child → parent) from all srTypeBlocks.
-- A backtick-declared ancestor (e.g. @w_form_tab2`page1@ -- "extend
-- ancestor's own control of this same name") resolves to just the
-- ancestor class part, so the chain walk in 'ancestorChain'/'resolveVirtual'
-- can actually find that object rather than silently stopping at a node
-- no object is ever named ('splitAncestorRef').
buildInheritsMap :: [SrFile] -> Map.Map Text Text
buildInheritsMap = Map.fromList . concatMap fileInherits
  where
    fileInherits sf =
      [ (identOrig (tdName td), identOrig (tdAncestorClass td)) | td <- srAllTypeDecls sf ]

-- | Build a proc map (object → set of proc names) from all procedures.
-- The outer key stays the object's declared-casing 'Text' (unchanged —
-- 'resolveVirtual''s ancestor-chain walk and 'resolveStaticCall''s object
-- match both need to recover this exact declared spelling so the result
-- round-trips through 'PB.Analysis.TypeCheck.tcParams', which is keyed the
-- same way). The inner value is an 'IdentSet' so a call written with
-- different casing than the procedure's own declaration still resolves.
buildProcMap :: [SrFile] -> Map.Map Text IdentSet
buildProcMap = foldl' addFile Map.empty
  where
    addFile acc sf =
      let obj   = srFileObject sf
          names = identSetFromList $
            map (fnsName . fbSig) (srFunctions sf)
            <> map (ssName . sbSig) (srSubroutines sf)
            <> map (esName . evSig) (srEvents sf)
            <> map (mkIdent . obEvent) (srOnBlocks sf)
      in Map.insertWith identSetUnion obj names acc

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
           , rtIsParam   = lvIsParam lv
           , rtScopeLine = lvScopeLine lv
           }

-- ---------------------------------------------------------------------------
-- Call resolution

-- | Walk the inheritance chain from a starting object, including itself.
ancestorChain :: Text -> Map.Map Text Text -> [Text]
ancestorChain start inherits = go [start] start
  where
    go chain cur = case Map.lookup cur inherits of
      Nothing     -> chain
      Just parent ->
        if parent `elem` chain then chain
        else go (chain <> [parent]) parent

-- | Resolve a non-dotted call via the caller's own procs and ancestor chain.
-- @toName@ is the call site's identifier, minted once by the caller (either
-- reused directly from an already-'Ident'-typed 'Expr' field, or minted once
-- from a 'Text' wire field such as 'CallSite.csToName' — never re-derived
-- via 'T.toLower' downstream of that single mint). The resolved procedure
-- name in the result is always the matched declaration's own casing
-- ('identOrig'), recovered via 'IdentSet', not the query's.
resolveVirtual
  :: Ident
  -> Text
  -> Map.Map Text IdentSet
  -> Map.Map Text Text
  -> (Maybe Text, Maybe Text, Text, Text)
resolveVirtual toNameIdent objN procMap inherits =
  let chain  = ancestorChain objN inherits
      found  = [ (anc, orig)
               | anc <- chain
               , Just orig <- [identSetLookup toNameIdent (Map.findWithDefault identSetEmpty anc procMap)]
               ]
  in case found of
       ((anc, orig):_) ->
         let kind = if anc == objN then "virtual" else "inherited"
         in (Just anc, Just (identOrig orig), kind, "high")
       [] ->
         -- Global fallback: if this name exists in exactly one object outside the
         -- caller's ancestor chain, resolve there (matches Python global_procs logic).
         let chainSet    = Set.fromList chain
             globalMatch = [ (obj, orig)
                           | (obj, procs) <- Map.toList procMap
                           , Just orig <- [identSetLookup toNameIdent procs]
                           , obj `Set.notMember` chainSet
                           ]
         in case globalMatch of
              [(obj, orig)] -> (Just obj, Just (identOrig orig), "virtual", "high")
              _             -> (Nothing, Nothing, "unresolved", "low")

-- | Resolve a dotted @ClassName.procName@ static\/global call reference
-- against the workspace proc map (does not consult @inherits@ — a static
-- reference names its target class directly, no ancestor walk). Exported so
-- 'PB.Analysis.TypeCheck.inferExpr''s 'ExCall' case can resolve the same
-- dotted-call shape directly from an 'Expr' node rather than re-deriving
-- this dispatch a second time. Both the class and procedure segments are
-- minted into 'Ident's here — this is their true origin, carved out of one
-- compound dotted 'Text' for the first time — and matched case-insensitively;
-- the returned object name is recovered from 'procMap''s own declared-casing
-- key (a linear scan over the workspace's objects, once per dotted call site
-- — negligible next to the corpus-wide volumes this pipeline already
-- handles), not the call site's own spelling, so the result round-trips
-- through 'PB.Analysis.TypeCheck.tcParams''s exact-Text keying.
resolveStaticCall :: Text -> Map.Map Text IdentSet -> (Maybe Text, Maybe Text, Text, Text)
resolveStaticCall toName procMap =
  let firstSeg      = T.takeWhile (/= '.') toName
      lastSeg       = T.takeWhileEnd (/= '.') toName
      firstSegIdent = mkIdent firstSeg
      objMatch      = listToMaybe
        [ (obj, procs)
        | (obj, procs) <- Map.toList procMap
        , identCanon (mkIdent obj) == identCanon firstSegIdent
        ]
  in case objMatch of
       Nothing -> (Nothing, Nothing, "unresolved", "low")
       Just (obj, procsForObj) ->
         case identSetLookup (mkIdent lastSeg) procsForObj of
           Just orig -> (Just obj, Just (identOrig orig), "static", "high")
           Nothing   -> (Just obj, Nothing, "static", "medium")

-- | Resolve all call sites to their targets using cross-file proc and inherits maps.
resolveCalls
  :: [CallSite]
  -> Map.Map Text IdentSet          -- proc_map: object → proc names
  -> Map.Map Text Text              -- inherits: child → parent
  -> Set.Set Text                   -- builtin free-function names (lowercase)
  -> Set.Set Text                   -- builtin method names (lowercase)
  -> [ResolvedCall]
resolveCalls sites procMap inherits builtinFns builtinMethods =
  map (resolveOne procMap inherits builtinFns builtinMethods) sites

resolveOne
  :: Map.Map Text IdentSet
  -> Map.Map Text Text
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
       }
  where
    dispatch site = case csCallType site of
      "ExCall" ->
        let toName = csToName site
        in if "." `T.isInfixOf` toName
             then resolveStaticCall toName procMap
             else
               let toNameIdent = mkIdent toName
               in if identCanon toNameIdent `Set.member` builtinFns
                    then (Nothing, Nothing, "builtin", "high")
                    else resolveVirtual toNameIdent (csObject site) procMap inherits
      "ExCallArg"    -> resolveVirtual (mkIdent (csToName cs)) (csObject cs) procMap inherits
      "ExMethodCall" ->
        if identCanon (mkIdent (csToName site)) `Set.member` builtinMethods
          then (Nothing, Nothing, "builtin", "high")
          else (Nothing, Nothing, "unresolved", "low")
      "ExDispatch"   -> (Nothing, Nothing, "unresolved", "low")
      _              -> (Nothing, Nothing, "unresolved", "low")
