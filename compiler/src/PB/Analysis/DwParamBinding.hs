{-# LANGUAGE StrictData #-}
-- | Trace a @ref datawindow@ parameter (or any parameter typed as a
-- DataWindow-family class with no static binding on its own declaration)
-- back to the literal @.srd@ every caller passes at that position -- the
-- harder half of Plan 196 Phase 4 item 1's @object.\<column\>@ resolution.
--
-- A parameter's own declaration never carries a @dataobject=@ the way a
-- visual control does ('PB.Analysis.ControlHierarchy.resolveMemberChainDwBinding'),
-- so the only way to know which DataWindow a @ref datawindow adw@ parameter
-- actually refers to is to look at every call site across the workspace and
-- see what literal, statically-bound control gets passed there. This is a
-- one-hop trace (caller argument -> callee parameter), not a fixpoint: it
-- does not follow a parameter's value through further re-assignment or
-- another level of indirection.
module PB.Analysis.DwParamBinding
  ( DwParamBindings
  , buildDwParamBindings
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr (Expr (..), Lvalue (..), foldExprs, segments)
import PB.AST.Ident (Ident, IdentMap, IdentSet, identCanon, mkIdentSynthetic)
import PB.AST.Located (Located (..))
import PB.AST.SourceFile
import PB.AST.Type (renderPbType)
import PB.Analysis.CallClassify (segName)
import PB.Analysis.ControlHierarchy (ControlIndex, resolveMemberChainDwBinding)
import PB.Analysis.TypeCheck (ProcSignature (..), selectSignature)
import PB.Analysis.TypeResolve (resolveVirtual, isDwFamilyType, srFileObject)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | (callee object, callee proc, 0-based param index) -> the one literal
-- @.srd@ name every caller passing an argument at that position agrees on.
-- Absent from the map when no caller passes a resolvable literal, or when
-- callers disagree (ambiguous -- resolved to "no binding," never a guess).
type DwParamBindings = Map.Map (Text, Text, Int) Text

-- | Build the workspace-wide table. @procMap@\/@inherits@\/@paramsMap@ are
-- exactly 'PB.Analysis.TypeCheck.TypeCheckWorkspace''s own fields (built
-- once, shared with type-checking) so this adds no duplicate computation
-- beyond its own call-site walk.
buildDwParamBindings
  :: IdentMap IdentSet
  -> Map.Map Ident Ident
  -> Map.Map (Text, Text) [ProcSignature]
  -> ControlIndex
  -> [SrFile]
  -> DwParamBindings
buildDwParamBindings procMap inherits paramsMap controlIdx sfs =
  Map.mapMaybe onlyCandidate grouped
  where
    grouped = Map.fromListWith Set.union
      [ (k, Set.singleton v) | (k, v) <- concatMap (fileCandidates procMap inherits paramsMap controlIdx) sfs ]
    onlyCandidate s = case Set.toList s of
      [v] -> Just v
      _   -> Nothing

-- | Every candidate binding found in one file's procedure bodies.
fileCandidates
  :: IdentMap IdentSet -> Map.Map Ident Ident -> Map.Map (Text, Text) [ProcSignature]
  -> ControlIndex -> SrFile -> [((Text, Text, Int), Text)]
fileCandidates procMap inherits paramsMap controlIdx sf = concat
  [ concatMap (bodyCandidates . fbBody) (srFunctions sf)
  , concatMap (bodyCandidates . sbBody) (srSubroutines sf)
  , concatMap (bodyCandidates . evBody) (srEvents sf)
  , concatMap (bodyCandidates . obBody) (srOnBlocks sf)
  ]
  where
    obj = srFileObject sf
    -- 'srFileObject' already flattened the file's own primary-object 'Ident'
    -- to 'Text'; no token span survives to bridge back through here (see
    -- the ident-minting skill's "mixed case" reference).
    objIdent = mkIdentSynthetic "enclosing object name, flattened by srFileObject" obj

    bodyCandidates = foldStmts classifyStmt

    classifyStmt (Located _ stmt) = case stmt of
      BsCall expr        -> exprCandidates expr
      BsAssign _ rhs     -> exprCandidates rhs
      BsAssignExpr l rhs -> exprCandidates l <> exprCandidates rhs
      BsReturn (Just e)  -> exprCandidates e
      BsLocalVar { varInit = Just e } -> exprCandidates e
      BsIf IfStmt { ifCond = c } -> exprCandidates c
      BsFor ForStmt { forFrom = fr, forTo = to_, forStep = step } ->
        exprCandidates fr <> exprCandidates to_ <> maybe [] exprCandidates step
      BsDo DoStmt { doCond = pre, doLoop = post } -> condCandidates pre <> condCandidates post
      BsChoose ChooseStmt { chooseExpr = x } -> exprCandidates x
      _ -> []

    condCandidates Nothing               = []
    condCandidates (Just (DoWhile e))    = exprCandidates e
    condCandidates (Just (DoUntil e))    = exprCandidates e

    exprCandidates = foldExprs classifyExpr

    -- Deliberately 'ExCall' only (a bare, same-object-or-ancestor call,
    -- matching 'resolveVirtual''s own dispatch semantics) -- an
    -- 'ExMethodCall' receiver would need the *receiver's* resolved type to
    -- know which object's signature to look up, a different and more
    -- involved resolution this phase's real-corpus evidence didn't call
    -- for (BACKLOG, if ever needed).
    classifyExpr ExCall { callee = lv, callArgs = args }
      | [single] <- segments lv = candidatesForCall (segName single) args
    classifyExpr _ = []

    candidatesForCall calleeName args =
      case resolveVirtual calleeName objIdent procMap inherits of
        (Just targetObj, Just targetProc, _, _) ->
          case Map.lookup (targetObj, targetProc) paramsMap of
            Just sigs -> case selectSignature sigs (length args) of
              Just sig -> concatMap (candidateForArg targetObj targetProc)
                                     (zip3 [0 ..] args (psParams sig))
              Nothing  -> []
            Nothing -> []
        _ -> []

    candidateForArg targetObj targetProc (idx, ExLvalue argLv, (_, paramTy))
      | isDwFamilyType inherits (renderPbType paramTy)
      , Just dwName <- resolveMemberChainDwBinding controlIdx inherits objIdent
                         (map (identCanon . segName) (segments argLv))
      = [ ((targetObj, targetProc, idx), dwName) ]
    candidateForArg _ _ _ = []
