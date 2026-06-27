{-# LANGUAGE StrictData #-}
-- | Pure call classification helpers.
--
-- Shared by 'PB.Analysis.CpsCompile' (old compiler) and the new
-- SSA→CatOp pipeline.  No monadic state, no CpsNode emission — just
-- classification logic and name utilities.
--
-- 'classifyExpr' returns 'PureCall' or 'SuspendCall' with the effect
-- name baked in — callers never need a separate effect-name computation.
module PB.Analysis.CallClassify
  ( CallKind (..)
  , classifyExpr
  , effectName
  , calleeName
  , isTriggerEvent
  , isBuiltinSuspendFn
  , isTypedSuspend
  , resolveReceiverType
  , segName
  , lvHead
  ) where

import PB.Prelude
import PB.AST.Expr
import PB.AST.Type       (renderPbType)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..), lookupScopedVar, isDescendantOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Call kind

-- | Classification of an expression: pure call or suspending call.
-- The effect name is computed separately by 'effectName' (takes pre-parsed
-- '[Expr]' args to avoid importing Grammar.Body).
data CallKind = PureCall | SuspendCall deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Side-effect classification

-- | Classify an expression as Pure or Suspend using type information when
-- available.  Without type info the fallback is conservative: PureCall.
-- Free functions in 'isBuiltinSuspendFn' are always Suspend regardless of type.
-- The effect name is computed separately by 'effectName'.
classifyExpr :: ScopedTypeEnv -> Expr -> CallKind
classifyExpr env (ExCall lv _) =
  let lnames = map (T.toLower . segName) (segments lv)
  in case lnames of
       [name]
         | isBuiltinSuspendFn name -> SuspendCall
       [headN, meth]
         | Just pty <- lookupScopedVar headN env
         , let ty = T.toLower (renderPbType pty)
         , isTypedSuspend (steHierarchy env) ty meth -> SuspendCall
       _ -> PureCall
classifyExpr env (ExMethodCall recv meth _) =
  case resolveReceiverType env recv of
    Just ty | isTypedSuspend (steHierarchy env) ty (T.toLower meth) -> SuspendCall
    _       -> PureCall
classifyExpr _ _ = PureCall

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
              let dwCtrl = case segments dv of { (s:_) -> T.toLower (segName s); [] -> "?" }
              in "retrieve:child_" <> T.toLower col <> ":" <> dwCtrl
            (_:ExStr col:_) -> "retrieve:child_" <> T.toLower col <> ":?"
            _               -> "retrieve:child_?:?"
     else if cn `elem` ["open", "opensheet"] then "open"
     else if "close" `T.isSuffixOf` cn       then "close"
     else if ".retrieve" `T.isSuffixOf` cn   then "retrieve:" <> head_
     else "executeSql"

-- | Free functions that are always suspending regardless of receiver type.
isBuiltinSuspendFn :: Text -> Bool
isBuiltinSuspendFn n = n `elem`
  ["open", "opensheet", "close", "execute", "run", "fn_retrievechild"]

-- | Return True when a method on a type (given by declared name) is side-effecting.
-- Uses isDescendantOf so user-defined DW/Transaction subclasses are handled
-- correctly even when the full stdlib inheritance chain is loaded.
isTypedSuspend :: Map.Map Text Text -> Text -> Text -> Bool
isTypedSuspend inh ty meth
  | isDescendantOf inh ty dwTypes    = meth `elem` dwMethods
  | isDescendantOf inh ty transTypes = meth `elem` transMethods
  | otherwise                        = False
  where
    dwTypes    = Set.fromList ["datawindow", "datastore", "datawindowchild"]
    transTypes = Set.singleton "transaction"
    dwMethods  = ["retrieve", "update", "delete", "reset",
                  "rowscopy", "rowsmove", "sharedata", "print", "modify"]
    transMethods = ["commit", "rollback", "connect", "disconnect", "autocommit"]

-- | Resolve the declared type name of a receiver expression (not walked to root).
resolveReceiverType :: ScopedTypeEnv -> Expr -> Maybe Text
resolveReceiverType env (ExLvalue lv) =
  case segments lv of
    (s:_) -> fmap (T.toLower . renderPbType) (lookupScopedVar (segName s) env)
    []    -> Nothing
resolveReceiverType env (ExCall lv _) =
  case segments lv of
    [single] -> fmap (T.toLower . renderPbType) (lookupScopedVar (segName single) env)
    _        -> Nothing
resolveReceiverType _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Effect naming

calleeName :: Expr -> Text
calleeName (ExCall lv _)          = T.intercalate "." (map segName (segments lv))
calleeName (ExMethodCall recv m _) =
  let recvName = case recv of
        ExLvalue lv -> T.intercalate "." (map segName (segments lv))
        _            -> "?"
  in recvName <> "." <> m
calleeName _ = "?"

segName :: LvSegment -> Text
segName (LvSegment n _) = n

lvHead :: Lvalue -> Text
lvHead lv = case segments lv of { (s:_) -> segName s; [] -> "_" }

-- | Detect `TriggerEvent(...)` or `this.TriggerEvent(...)` call sites that
-- should be lowered to a `CpsCallProc "triggerevent"` dispatch node rather
-- than a normal CpsCall/CpsSuspend (Plan 115 item 2).
isTriggerEvent :: Lvalue -> Bool
isTriggerEvent lv = case map (T.toLower . segName) (segments lv) of
  [s]   -> s == "triggerevent"
  [t,s] -> t == "this" && s == "triggerevent"
  _     -> False
