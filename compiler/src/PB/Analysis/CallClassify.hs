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
import PB.Lexing.Token   (Token (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Call kind

-- | Classification of an expression: pure call or suspending call with
-- the effect name already computed.  Eliminates the separate @effectName@
-- function and its @[Expr]@ parameter.
data CallKind = PureCall | SuspendCall Text deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Side-effect classification

-- | Classify an expression as Pure or Suspend using type information when
-- available.  Without type info the fallback is conservative: PureCall.
-- Free functions in 'isBuiltinSuspendFn' are always Suspend regardless of type.
-- The effect name is computed inline — no separate @effectName@ call needed.
classifyExpr :: ScopedTypeEnv -> Expr -> CallKind
classifyExpr env expr@(ExCall lv rawArgs) =
  let lnames = map (T.toLower . segName) (segments lv)
      cn     = T.toLower (calleeName expr)
  in case lnames of
       [name]
         | isBuiltinSuspendFn name -> SuspendCall (computeEffectName cn rawArgs)
       [headN, meth]
         | Just pty <- lookupScopedVar headN env
         , let ty = T.toLower (renderPbType pty)
         , isTypedSuspend (steHierarchy env) ty meth ->
             SuspendCall (computeEffectName cn rawArgs)
       _ -> PureCall
classifyExpr env expr@(ExMethodCall recv meth rawArgs) =
  let cn = T.toLower (calleeName expr)
  in case resolveReceiverType env recv of
       Just ty | isTypedSuspend (steHierarchy env) ty (T.toLower meth) ->
         -- For ExMethodCall, reconstruct callee name from receiver for effect naming
         let effCn = case recv of
               ExLvalue lv -> T.toLower (lvHead lv) <> "." <> T.toLower meth
               ExCall lv _ -> T.toLower (lvHead lv) <> "." <> T.toLower meth
               _           -> cn
         in SuspendCall (computeEffectName effCn rawArgs)
       _ -> PureCall
classifyExpr _ _ = PureCall

-- ---------------------------------------------------------------------------
-- Effect naming (internal)

-- | Compute the effect tag from the callee name and raw token arguments.
-- Only called for expressions that 'classifyExpr' deemed Suspend.
computeEffectName :: Text -> [[Token]] -> Text
computeEffectName cn rawArgs
  | cn == "fn_retrievechild" =
      let dwCtrl = case rawArgs of
            (dArg:_) -> case dArg of { [t] -> T.toLower (tkText t); _ -> "?" }
            [] -> "?"
          col = case rawArgs of
            (_:cArg:_) -> case cArg of { [t] -> T.toLower (stripQuotes (tkText t)); _ -> "?" }
            _ -> "?"
      in "retrieve:child_" <> col <> ":" <> dwCtrl
  | cn `elem` ["open", "opensheet"] = "open"
  | "close" `T.isSuffixOf` cn = "close"
  | ".retrieve" `T.isSuffixOf` cn = "retrieve:" <> T.takeWhile (/= '.') cn
  | otherwise = "executeSql"

-- | Strip surrounding quotes from a token text (for string literals).
stripQuotes :: Text -> Text
stripQuotes t
  | T.length t >= 2
  , (T.head t == '"' && T.last t == '"') || (T.head t == '\'' && T.last t == '\'')
  = T.init (T.drop 1 t)
  | otherwise = t

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
