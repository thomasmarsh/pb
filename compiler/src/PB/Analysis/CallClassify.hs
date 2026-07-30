{-# LANGUAGE StrictData #-}
-- | Pure call classification helpers, plus a small pure AST utility
-- ('collectBodyLocals') used by the SSA→EffTerm pipeline.  No monadic
-- state, no InstrNode emission — just classification logic and name
-- utilities.
--
-- 'classifyExpr' returns 'PureCall' or 'SuspendCall' with the effect
-- name baked in — callers never need a separate effect-name computation.
module PB.Analysis.CallClassify
  ( CallKind (..)
  , classifyExpr
  , EffectTag (..)
  , classifyEffects
  , effectName
  , calleeName
  , isTriggerEvent
  , isBuiltinSuspendFn
  , isTypedSuspend
  , resolveReceiverType
  , resolveLvalueType
  , segName
  , lvHead
  , collectBodyLocals
  , ProcUnit (..)
  , forProcedures
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Ident      (Ident, identCanon, identOrig, mkIdent)
import PB.AST.Located    (Located (..))
import PB.AST.SourceFile (SrFile (..), FnSig (..), SubSig (..), EventSig (..), FunctionBlock (..),
                           SubroutineBlock (..), EventBlock (..), OnBlock (..), Param)
import PB.AST.Type       (PbType, renderPbType)
import PB.Lexing.Token   (SourceSpan)
import PB.Analysis.ControlHierarchy (ControlIndex, resolveMemberChainType)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..), WorkspaceEnv, lookupScopedVar, lookupScopedVarOrSelf,
                             isDescendantOf, procEnv)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Call kind

-- | Classification of an expression: pure call or suspending call.
-- The effect name is computed separately by 'effectName' (takes pre-parsed
-- '[Expr]' args to avoid importing Grammar.Body).
data CallKind = PureCall | SuspendCall deriving (Eq, Show)

-- | A tag describing one side effect a call performs. A call may carry
-- several at once (e.g. a DataWindow @Update()@ both writes the DB and
-- suspends) -- see 'classifyEffects'.
data EffectTag = ReadsDb | WritesDb | WritesUi | Suspends
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Side-effect classification

-- | Classify an expression as Pure or Suspend using type information when
-- available.  Without type info the fallback is conservative: PureCall.
-- Free functions in 'isBuiltinSuspendFn' are always Suspend regardless of type.
-- The effect name is computed separately by 'effectName'.
classifyExpr :: ScopedTypeEnv -> Expr -> CallKind
classifyExpr env (ExCall lv _) =
  case segments lv of
    [s] | isBuiltinSuspendFn (identCanon (segName s)) -> SuspendCall
    segs@(_ : _ : _) ->
      case reverse segs of
        methSeg : revHeadSegs ->
          let meth = identCanon (segName methSeg)
          in case resolveLvalueType env (Lvalue (reverse revHeadSegs)) of
               Just ty | isTypedSuspend (steHierarchy env) ty meth -> SuspendCall
               _ -> PureCall
        [] -> PureCall
    _ -> PureCall
classifyExpr env (ExMethodCall recv meth _) =
  case resolveReceiverType env recv of
    Just ty | isTypedSuspend (steHierarchy env) ty (identCanon meth) -> SuspendCall
    _       -> PureCall
classifyExpr _ _ = PureCall

-- | Classify an expression's side effects as a set of tags -- an additive,
-- finer-grained sibling of 'classifyExpr' (which stays a single-bit
-- Pure/Suspend verdict feeding FromSSA's ECall/ESuspend IR-node choice; a
-- call may carry several effect tags at once, e.g. a DataWindow @Update()@
-- both writes the DB and suspends, which a single verdict can't express).
-- Mirrors 'classifyExpr's dispatch shape exactly; unresolvable/untyped calls
-- fall back to the empty set, the same conservative-fallback precedent
-- 'classifyExpr' uses for 'PureCall'.
classifyEffects :: ScopedTypeEnv -> Expr -> Set.Set EffectTag
classifyEffects env (ExCall lv _) =
  case segments lv of
    [s] -> Map.findWithDefault Set.empty (identCanon (segName s)) builtinEffectTags
    segs@(_ : _ : _) ->
      case reverse segs of
        methSeg : revHeadSegs ->
          let meth = identCanon (segName methSeg)
          in case resolveLvalueType env (Lvalue (reverse revHeadSegs)) of
               Just ty -> typedEffectTags (steHierarchy env) ty meth
               Nothing -> Set.empty
        [] -> Set.empty
    _ -> Set.empty
classifyEffects env (ExMethodCall recv meth _) =
  case resolveReceiverType env recv of
    Just ty -> typedEffectTags (steHierarchy env) ty (identCanon meth)
    Nothing -> Set.empty
classifyEffects _ _ = Set.empty

-- ---------------------------------------------------------------------------
-- Effect naming

-- | Return the effect tag for a Suspend expression.  Only called for
-- expressions that 'classifyExpr' already deemed Suspend.
-- Takes pre-parsed '[Expr]' args (the caller's responsibility) to avoid
-- importing 'PB.Grammar.Body.parseExpr' here.
effectName :: Expr -> [Expr] -> Text
effectName expr args =
  let cn    = T.toLower (calleeName expr)
      head_ = T.takeWhile (/= '.') cn
  in if cn == "fn_retrievechild"
     then case args of
            (ExLvalue dv:ExStr col:_) ->
              let dwCtrl = case segments dv of { (s:_) -> identCanon (segName s); [] -> "?" }
              in "retrieve:child_" <> T.toLower col <> ":" <> dwCtrl
            (_:ExStr col:_) -> "retrieve:child_" <> T.toLower col <> ":?"
            _               -> "retrieve:child_?:?"
     else if cn `elem` ["open", "opensheet", "openwithparm", "opensheetwithparm"] then "open"
     else if "close" `T.isSuffixOf` cn       then "close"
     else if ".retrieve" `T.isSuffixOf` cn   then "retrieve:" <> head_
     else "executeSql"

-- | Free functions that are always suspending regardless of receiver type.
isBuiltinSuspendFn :: Text -> Bool
isBuiltinSuspendFn n = n `Map.member` builtinEffectTags

-- | Effect tags for a free (single-segment) function name. 'run'/'execute'
-- launch an external process/subshell (confirmed against real corpus usage,
-- e.g. bare @Run("clipbrd.exe")@ and @run(ls_tempfile)@ calls -- distinct
-- from a @.Run()@ method call on an OLE Automation object, which this
-- single-segment dispatch never reaches) -- neither is a DB or UI effect in
-- this project's vocabulary, so both carry 'Suspends' only.
builtinEffectTags :: Map.Map Text (Set.Set EffectTag)
builtinEffectTags = Map.fromList
  [ ("open",                Set.fromList [Suspends, WritesUi])
  , ("opensheet",           Set.fromList [Suspends, WritesUi])
  , ("openwithparm",        Set.fromList [Suspends, WritesUi])
  , ("opensheetwithparm",   Set.fromList [Suspends, WritesUi])
  , ("close",               Set.fromList [Suspends, WritesUi])
  , ("fn_retrievechild",    Set.fromList [Suspends, ReadsDb])
  , ("execute",             Set.singleton Suspends)
  , ("run",                 Set.singleton Suspends)
  ]

dwTypes :: Set.Set Text
dwTypes = Set.fromList ["datawindow", "datastore", "datawindowchild"]

transTypes :: Set.Set Text
transTypes = Set.singleton "transaction"

-- | Effect tags for a DataWindow/DataStore method. 'retrieve' reads the DB;
-- 'update'/'delete' and the remaining buffer-mutating operations
-- ('reset'/'rowscopy'/'rowsmove'/'sharedata'/'modify') write it; 'print' is
-- rendering/output, a UI effect rather than a data one.
dwMethodEffectTags :: Map.Map Text (Set.Set EffectTag)
dwMethodEffectTags = Map.fromList
  [ ("retrieve",  Set.fromList [Suspends, ReadsDb])
  , ("update",    Set.fromList [Suspends, WritesDb])
  , ("delete",    Set.fromList [Suspends, WritesDb])
  , ("reset",     Set.fromList [Suspends, WritesDb])
  , ("rowscopy",  Set.fromList [Suspends, WritesDb])
  , ("rowsmove",  Set.fromList [Suspends, WritesDb])
  , ("sharedata", Set.fromList [Suspends, WritesDb])
  , ("modify",    Set.fromList [Suspends, WritesDb])
  , ("print",     Set.fromList [Suspends, WritesUi])
  ]

-- | Effect tags for a Transaction method. 'commit' finalizes pending writes;
-- the rest are connection/state management with no direct data effect.
transMethodEffectTags :: Map.Map Text (Set.Set EffectTag)
transMethodEffectTags = Map.fromList
  [ ("commit",     Set.fromList [Suspends, WritesDb])
  , ("rollback",   Set.singleton Suspends)
  , ("connect",    Set.singleton Suspends)
  , ("disconnect", Set.singleton Suspends)
  , ("autocommit", Set.singleton Suspends)
  ]

-- | Return True when a method on a type (given by declared name) is side-effecting.
-- Uses isDescendantOf so user-defined DW/Transaction subclasses are handled
-- correctly even when the full stdlib inheritance chain is loaded.
isTypedSuspend :: Map.Map Ident Ident -> Text -> Text -> Bool
isTypedSuspend inh ty meth
  | isDescendantOf inh ty dwTypes    = meth `Map.member` dwMethodEffectTags
  | isDescendantOf inh ty transTypes = meth `Map.member` transMethodEffectTags
  | otherwise                        = False

-- | Effect tags for a method call on a resolved receiver type. Mirrors
-- 'isTypedSuspend's dwTypes/transTypes dispatch, replacing each flat
-- membership check with a per-method tag lookup against the same tables.
typedEffectTags :: Map.Map Ident Ident -> Text -> Text -> Set.Set EffectTag
typedEffectTags inh ty meth
  | isDescendantOf inh ty dwTypes    = Map.findWithDefault Set.empty meth dwMethodEffectTags
  | isDescendantOf inh ty transTypes = Map.findWithDefault Set.empty meth transMethodEffectTags
  | otherwise                        = Set.empty

-- | Resolve an lvalue's declared/effective type. A bare single segment is
-- first checked as a param\/local\/instance\/global variable (or the
-- @this@\/@super@ keyword, via 'lookupScopedVarOrSelf'); on a miss it falls
-- back to a 1-hop 'ControlIndex' lookup, since a visual control (e.g.
-- @dw_1@) is declared as its own nested 'TypeBlock', never as a
-- 'BsLocalVar' -- 'lookupScopedVar' alone can never see it. Two or more
-- segments is a dotted control chain (e.g. @tab1.page1.uo_epidom@),
-- resolved via the same workspace-wide 'ControlIndex' starting from the
-- enclosing object ('steObject'). Falls back to 'Nothing' on any
-- unresolvable hop rather than guessing.
resolveLvalueType :: ScopedTypeEnv -> Lvalue -> Maybe Text
resolveLvalueType env lv = case segments lv of
  []   -> Nothing
  [s]  -> fmap (T.toLower . renderPbType) (lookupScopedVarOrSelf (segName s) env)
          <|> resolveMemberChainType (steControlIndex env) (steHierarchy env)
                                     (steObject env) [identCanon (segName s)]
  segs -> resolveMemberChainType (steControlIndex env) (steHierarchy env)
                                 (steObject env) (map (identCanon . segName) segs)

-- | Resolve the declared type name of a receiver expression (not walked to root).
resolveReceiverType :: ScopedTypeEnv -> Expr -> Maybe Text
resolveReceiverType env (ExLvalue lv) = resolveLvalueType env lv
resolveReceiverType env (ExCall lv _) =
  case segments lv of
    [single] -> fmap (T.toLower . renderPbType) (lookupScopedVar (segName single) env)
    _        -> Nothing
resolveReceiverType _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Effect naming

calleeName :: Expr -> Text
calleeName (ExCall lv _)          = T.intercalate "." (map (identOrig . segName) (segments lv))
calleeName (ExMethodCall recv m _) =
  let recvName = case recv of
        ExLvalue lv -> T.intercalate "." (map (identOrig . segName) (segments lv))
        _            -> "?"
  in recvName <> "." <> identOrig m
calleeName _ = "?"

lvHead :: Lvalue -> Text
lvHead lv = case segments lv of { (s:_) -> identOrig (segName s); [] -> "_" }

-- | Detect `TriggerEvent(...)` or `this.TriggerEvent(...)` call sites that
-- should be lowered to a `InstrCallProc "triggerevent"` dispatch node rather
-- than a normal InstrCall/InstrSuspend.
isTriggerEvent :: Lvalue -> Bool
isTriggerEvent lv = case map (identCanon . segName) (segments lv) of
  [s]   -> s == "triggerevent"
  [t,s] -> t == "this" && s == "triggerevent"
  _     -> False

-- ---------------------------------------------------------------------------
-- Local variable collection

-- | Seed a procedure's local-variable type map from its own body's
-- 'BsLocalVar' declarations, so a locally-declared datastore/datawindow/
-- transaction variable's type can be resolved by classification (e.g.
-- 'classifyExpr') before that variable's first use.
collectBodyLocals :: [Located BodyStmt] -> Map.Map Ident PbType
collectBodyLocals stmts =
  Map.fromList
    [ (varName, varType)
    | Located _ (BsLocalVar _ varType varName _) <- stmts
    ]

-- ---------------------------------------------------------------------------
-- Per-procedure env construction (Plan 197 Finding 7)

-- | One procedure's static shape plus the fully-scoped 'ScopedTypeEnv' built
-- for it -- 'procEnv' seeded from this procedure's own params, with
-- 'collectBodyLocals' folded into 'steLocal' on top. 'forProcedures' builds
-- this once per procedure so callers needing this same env (call-site/
-- var-ref extraction, runtime DataWindow-alias scanning, type checking)
-- don't each rebuild it from scratch.
data ProcUnit = ProcUnit
  { puKind        :: Text          -- ^ "function" | "subroutine" | "event" | "on"
  , puName        :: Text
  , puOwner       :: Text          -- ^ owning control name for a control-owned event
                                    -- ('EventBlock.evOwner'); the enclosing object's own
                                    -- name for everything else, including window-level events
  , puParams      :: [Param]
  , puRetType     :: Text          -- ^ "" for subroutine\/event\/on-block (no return type)
  , puRetTypeSpan :: Maybe SourceSpan
  , puBody        :: [Located BodyStmt]
  , puEnv         :: ScopedTypeEnv
  } deriving (Eq, Show)

-- | Every procedure in a file, in @functions ++ subroutines ++ events ++
-- on-blocks@ order -- the same order 'PB.Pipeline.Runner.compileOne' zips
-- its own per-block-type 'SourceSpans' against -- each paired with the
-- 'ScopedTypeEnv' 'procEnv'\/'collectBodyLocals' together produce for it.
forProcedures :: WorkspaceEnv -> ControlIndex -> Text -> SrFile -> [ProcUnit]
forProcedures wsEnv controlIdx obj sf = concat
  [ [ mkUnit "function" (identOrig (fnsName (fbSig fb))) obj (fnsParams (fbSig fb))
        (fnsReturnType (fbSig fb)) (Just (fnsReturnTypeSpan (fbSig fb))) (fbBody fb)
    | fb <- srFunctions sf ]
  , [ mkUnit "subroutine" (identOrig (ssName (sbSig sb))) obj (ssParams (sbSig sb)) "" Nothing (sbBody sb)
    | sb <- srSubroutines sf ]
  , [ mkUnit "event" (identOrig (esName (evSig ev))) (fromMaybe obj (evOwner ev)) (esParams (evSig ev)) "" Nothing (evBody ev)
    | ev <- srEvents sf ]
  , [ mkUnit "on" (identOrig (obEvent ob)) obj [] "" Nothing (obBody ob)
    | ob <- srOnBlocks sf ]
  ]
  where
    mkUnit kind name owner params retType retTypeSpan body = ProcUnit
      { puKind        = kind
      , puName        = name
      , puOwner       = owner
      , puParams      = params
      , puRetType     = retType
      , puRetTypeSpan = retTypeSpan
      , puBody        = body
      , puEnv         = baseEnv { steLocal = collectBodyLocals body <> steLocal baseEnv }
      }
      where baseEnv = procEnv wsEnv controlIdx (mkIdent obj) params
