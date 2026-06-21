-- | Type resolution and call resolution directly from the parsed AST.
--
-- Pure module — no I/O.  Public API:
--
--   extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]
--   extractCallSites  :: Text -> Text -> SrFile -> [CallSite]
--   extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
--   resolveTypes      :: [LocalVar] -> Set Text -> Set Text -> [ResolvedType]
--   resolveCalls      :: [CallSite] -> Map Text (Set Text) -> Map Text Text -> [ResolvedCall]
--   buildInheritsMap  :: [SrFile] -> Map Text Text
--   buildProcMap      :: [SrFile] -> Map Text (Set Text)
--   buildObjectSet    :: [SrFile] -> Set Text
--   buildUserTypeSet  :: [SrFile] -> Set Text
module PB.Pipeline.TypeResolve
  ( LocalVar (..)
  , CallSite (..)
  , GlobalVar (..)
  , ResolvedType (..)
  , ResolvedCall (..)
  , extractLocalVars
  , extractCallSites
  , extractGlobalVars
  , resolveTypes
  , resolveCalls
  , buildInheritsMap
  , buildProcMap
  , buildObjectSet
  , buildUserTypeSet
  -- exposed for testing
  , classifyPbType
  , parseParams
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
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

-- | Classify a PbType into a resolution kind and optional target name.
-- Mirrors Python classify_type() in type_resolution.py.
classifyPbType :: PbType -> Set.Set Text -> Set.Set Text -> (Text, Maybe Text)
classifyPbType (PtPrimitive _)   _    _         = ("primitive", Nothing)
classifyPbType (PtDecimalPrec _) _    _         = ("primitive", Nothing)
classifyPbType PtAny             _    _         = ("any", Nothing)
classifyPbType (PtUserDefined n) objs userTypes
  | n `Set.member` objs                       = ("object", Just n)
  | n `Set.member` userTypes                  = ("user_type", Just n)
  | T.toLower n `Set.member` pbBuiltins       = ("primitive", Nothing)
  | otherwise                                 = ("unresolved", Nothing)

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
      let nonMods = dropWhile (\w -> T.toLower w `elem` paramMods) (T.words (T.strip seg))
      in case reverse nonMods of
           (nm : ty : _) -> Just (nm, parseTypeText ty)
           _             -> Nothing

-- ---------------------------------------------------------------------------
-- Internal helpers for body walking

segName :: LvSegment -> Text
segName (LvSegment n _) = n

dispatchName :: DispatchExpr -> Text
dispatchName (DispatchExpr _ _ _ _ n _) = n

lvalueName :: Lvalue -> Text
lvalueName lv = T.intercalate "." (map segName (segments lv))

srFileObject :: SrFile -> Text
srFileObject sf = case srTypeBlocks sf of
  (tb:_) -> tdName (tbDecl tb)
  []     -> ""

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
  BsReturn (Just e)  -> callSitesExpr file obj proc_ (Just line) e
  BsIf IfStmt { ifThen = t, ifElseIfs = eis, ifElse = e } ->
    walkBodyCallSites file obj proc_ t
    <> concatMap (\ei -> walkBodyCallSites file obj proc_ (eifBody ei)) eis
    <> maybe [] (walkBodyCallSites file obj proc_) e
  BsFor ForStmt { forBody = b }   -> walkBodyCallSites file obj proc_ b
  BsDo DoStmt { doBody = b }      -> walkBodyCallSites file obj proc_ b
  BsChoose ChooseStmt { chooseClauses = cs } ->
    concatMap (\c -> walkBodyCallSites file obj proc_ (ccBody c)) cs
  _ -> []

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
        , csToName   = m
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
      paramsToVars file obj (fnsName (fbSig fb)) (fnsParams (fbSig fb)) 0
      <> walkBodyLocalVars file obj (fnsName (fbSig fb)) (fbBody fb)
    ) (srFunctions sf)
  , concatMap (\sb ->
      paramsToVars file obj (ssName (sbSig sb)) (ssParams (sbSig sb)) 0
      <> walkBodyLocalVars file obj (ssName (sbSig sb)) (sbBody sb)
    ) (srSubroutines sf)
  , concatMap (\ev ->
      walkBodyLocalVars file obj (esName (evSig ev)) (evBody ev)
    ) (srEvents sf)
  , concatMap (\ob ->
      walkBodyLocalVars file obj (obEvent ob) (obBody ob)
    ) (srOnBlocks sf)
  ]

-- | Extract call sites from all procedure bodies.
extractCallSites :: Text -> Text -> SrFile -> [CallSite]
extractCallSites file obj sf = concat
  [ concatMap (\fb -> walkBodyCallSites file obj (fnsName (fbSig fb)) (fbBody fb))
      (srFunctions sf)
  , concatMap (\sb -> walkBodyCallSites file obj (ssName (sbSig sb)) (sbBody sb))
      (srSubroutines sf)
  , concatMap (\ev -> walkBodyCallSites file obj (esName (evSig ev)) (evBody ev))
      (srEvents sf)
  , concatMap (\ob -> walkBodyCallSites file obj (obEvent ob) (obBody ob))
      (srOnBlocks sf)
  ]

-- | Extract global variable declarations (variables block + global instances).
extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
extractGlobalVars file obj sf =
  declGlobals <> instanceGlobals
  where
    declGlobals = case srVariables sf of
      Nothing -> []
      Just VariablesBlock { varDecls = ds } ->
        [ GlobalVar
            { gvFile   = file
            , gvObject = obj
            , gvName   = vdName d
            , gvType   = vdType d
            , gvMods   = vdModifiers d
            }
        | d <- ds
        ]
    instanceGlobals =
      [ GlobalVar
          { gvFile   = file
          , gvObject = obj
          , gvName   = giName gi
          , gvType   = giType gi
          , gvMods   = []
          }
      | gi <- srGlobalInstances sf
      ]

-- ---------------------------------------------------------------------------
-- Workspace-level graph builders

-- | Build an inheritance map (child → parent) from all srTypeBlocks.
buildInheritsMap :: [SrFile] -> Map.Map Text Text
buildInheritsMap = Map.fromList . concatMap fileInherits
  where
    fileInherits sf =
      [ (tdName (tbDecl tb), tdAncestor (tbDecl tb)) | tb <- srTypeBlocks sf ]
      <> case srForward sf of
           Nothing -> []
           Just ForwardBlock { fwdTypes = tds } ->
             [ (tdName td, tdAncestor td) | td <- tds ]

-- | Build a proc map (object → set of proc names) from all procedures.
buildProcMap :: [SrFile] -> Map.Map Text (Set.Set Text)
buildProcMap = foldl' addFile Map.empty
  where
    addFile acc sf =
      let obj   = srFileObject sf
          names = Set.fromList $
            map (fnsName . fbSig) (srFunctions sf)
            <> map (ssName . sbSig) (srSubroutines sf)
            <> map (esName . evSig) (srEvents sf)
            <> map obEvent (srOnBlocks sf)
      in Map.insertWith Set.union obj names acc

-- | All window/userobject-derived type names (not structures).
buildObjectSet :: [SrFile] -> Set.Set Text
buildObjectSet = Set.fromList . concatMap fileObjs
  where
    fileObjs sf =
      [ tdName (tbDecl tb)
      | tb <- srTypeBlocks sf
      , T.toLower (tdAncestor (tbDecl tb)) /= "structure"
      ]

-- | All structure-derived type names (user-defined value types).
buildUserTypeSet :: [SrFile] -> Set.Set Text
buildUserTypeSet = Set.fromList . concatMap fileUserTypes
  where
    fileUserTypes sf =
      [ tdName (tbDecl tb)
      | tb <- srTypeBlocks sf
      , T.toLower (tdAncestor (tbDecl tb)) == "structure"
      ]

-- ---------------------------------------------------------------------------
-- Type resolution

-- | Classify each local variable's type.
resolveTypes :: [LocalVar] -> Set.Set Text -> Set.Set Text -> [ResolvedType]
resolveTypes vars objs userTypes = map resolve vars
  where
    resolve lv =
      let (kind, target) = classifyPbType (lvPbType lv) objs userTypes
      in ResolvedType
           { rtFile      = lvFile lv
           , rtObject    = lvObject lv
           , rtProcName  = lvProcName lv
           , rtVarName   = lvVarName lv
           , rtRawType   = lvRawType lv
           , rtKind      = kind
           , rtTarget    = target
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
resolveVirtual
  :: Text
  -> Text
  -> Map.Map Text (Set.Set Text)
  -> Map.Map Text Text
  -> (Maybe Text, Maybe Text, Text, Text)
resolveVirtual toName objN procMap inherits =
  let chain  = ancestorChain objN inherits
      found  = [ anc
               | anc <- chain
               , toName `Set.member` Map.findWithDefault Set.empty anc procMap
               ]
  in case found of
       []      -> (Nothing, Nothing, "unresolved", "low")
       (anc:_) ->
         let kind = if anc == objN then "virtual" else "inherited"
         in (Just anc, Just toName, kind, "high")

-- | Resolve all call sites to their targets using cross-file proc and inherits maps.
resolveCalls
  :: [CallSite]
  -> Map.Map Text (Set.Set Text)   -- proc_map: object → proc names
  -> Map.Map Text Text              -- inherits: child → parent
  -> [ResolvedCall]
resolveCalls sites procMap inherits = map (resolveOne procMap inherits) sites

resolveOne
  :: Map.Map Text (Set.Set Text)
  -> Map.Map Text Text
  -> CallSite
  -> ResolvedCall
resolveOne procMap inherits cs =
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
             then resolveStaticCall toName
             else resolveVirtual toName (csObject site) procMap inherits
      "ExCallArg"    -> resolveVirtual (csToName cs) (csObject cs) procMap inherits
      "ExMethodCall" -> (Nothing, Nothing, "unresolved", "low")
      "ExDispatch"   -> (Nothing, Nothing, "unresolved", "low")
      _              -> (Nothing, Nothing, "unresolved", "low")

    resolveStaticCall toName =
      let objSet    = Map.keysSet procMap
          firstSeg  = T.takeWhile (/= '.') toName
          lastSeg   = T.takeWhileEnd (/= '.') toName
      in if firstSeg `Set.member` objSet
           then
             if lastSeg `Set.member` Map.findWithDefault Set.empty firstSeg procMap
               then (Just firstSeg, Just lastSeg, "static", "high")
               else (Just firstSeg, Nothing, "static", "medium")
           else (Nothing, Nothing, "unresolved", "low")
