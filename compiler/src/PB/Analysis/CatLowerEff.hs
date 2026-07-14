{-# LANGUAGE StrictData #-}
-- | Parallel SSA → 'Eff' compilation — mirrors 'PB.Analysis.CatLower'
-- exactly, emitting 'Eff' instead of 'CatOp'. Kept side-by-side for
-- cross-checking; Phase 5b Step 2 will switch entry points.
module PB.Analysis.CatLowerEff
  ( compileSsaToEff
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.AST.Expr (Expr (..), Lvalue (..), BinOp (BopEq))
import PB.Analysis.CatOp (Category (..), Eff (..), Pure (..), branchEff)
import PB.Analysis.CatLower (CompileCtx (..), computeMergePoints, ssaValToExpr,
                              computeLoopHeaders, computeAllLoopExits, isLoopExit)
import PB.Analysis.CallClassify (CallKind (..), classifyExpr, effectName,
                                 calleeName, isTriggerEvent, segName, parseArgList)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Analysis.SSA (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                         SsaTerm (..), SsaProc (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

-- | Parallel to 'compileSsa': compile an SSA procedure into an 'Eff' term.
compileSsaToEff :: ScopedTypeEnv -> Set.Set Text -> SsaProc -> Eff () ()
compileSsaToEff env userFns proc =
  let ctx     = CompileCtx env userFns (computeMergePoints proc)
      headers = computeLoopHeaders proc
      exits   = computeAllLoopExits headers proc
      (result, _finalMemo) = compileBlockToEff ctx proc (spEntry proc) Map.empty headers exits Nothing
  in result

-- | Main compiler orchestrator. Returns @(Eff, updatedMemo)@.
-- Mirrors 'compileBlock' exactly — only the output type changes.
compileBlockToEff :: CompileCtx -> SsaProc
                  -> Text
                  -> Map.Map Text (Eff () ())
                  -> Set.Set Text
                  -> Map.Map Text Text
                  -> Maybe Text
                  -> (Eff () (), Map.Map Text (Eff () ()))
compileBlockToEff ctx proc blockId memo headers exits activeLoop
  | Just blockId == activeLoop = (J PId, memo)
  | Just cached <- Map.lookup blockId memo = (cached, memo)
  | Set.member blockId headers =
      let seedVisited = Map.fromList [ (bid, J PInl) | bid <- Map.keys memo ]
          (loopBodyOp, visitedFromLoop) = compileLoopBodyToEff ctx proc blockId seedVisited headers exits (Just blockId)
          memoFromLoop = Map.union memo (Map.fromSet (const (J PId)) (Map.keysSet visitedFromLoop))
          exitBlockId = Map.findWithDefault
            (error "impossible: every element of 'headers' is resolved by computeAllLoopExits before compileBlock runs")
            blockId exits
          (postLoopOp, finalMemo) = compileBlockToEff ctx proc exitBlockId memoFromLoop headers exits activeLoop
      in (postLoopOp . ELoop loopBodyOp, finalMemo)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (J PId, memo)
      Just block ->
        let assignsOp  = compileAssignsToEff ctx (sbAssigns block)
            (termOp, memo1) = compileTermToEff ctx proc memo headers exits activeLoop (sbTerm block)
            rawResult = case (assignsOp, termOp) of
                       (J PId, _) -> termOp
                       (_, J PId) -> assignsOp
                       _          -> EComp termOp assignsOp
            -- CatTagged memoizes in foldCat (body folds once per blockId);
            -- ELet/EVar in foldFreyd runs the body at both the bind site and
            -- each use site (bK . bK). The compile-level memo already
            -- ensures each block compiles once; foldFreyd folding each
            -- occurrence independently is correct because only one branch
            -- executes at runtime. So we skip the ELet/EVar wrapping here.
            memo2 = Map.insert blockId rawResult memo1
        in (rawResult, memo2)

-- | Compile the body of a loop. Returns @(Eff () (Either () ()), visited)@.
-- Mirrors 'compileLoopBody' exactly.
compileLoopBodyToEff :: CompileCtx -> SsaProc -> Text -> Map.Map Text (Eff () (Either () ()))
                     -> Set.Set Text -> Map.Map Text Text -> Maybe Text
                     -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())))
compileLoopBodyToEff ctx proc blockId visited headers exits activeLoop
  | Just cached <- Map.lookup blockId visited = (cached, visited)
  | Set.member blockId headers && Just blockId /= activeLoop =
      let nestedExit = Map.findWithDefault
            (error "impossible: every element of 'headers' is resolved by computeAllLoopExits")
            blockId exits
          (innerBody, v1) = compileLoopBodyToEff ctx proc blockId visited headers exits (Just blockId)
          (afterOp, v2) = compileLoopBodyToEff ctx proc nestedExit v1 headers exits activeLoop
      in (afterOp . ELoop innerBody, v2)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (J PInr, visited)
      Just block ->
        let assignsOp  = compileAssignsToEff ctx (sbAssigns block)
            (termOp, v1) = compileLoopTermToEff ctx proc visited headers exits activeLoop (sbTerm block)
            rawResult = case assignsOp of
                       J PId -> termOp
                       _     -> EComp termOp assignsOp
        in (rawResult, Map.insert blockId rawResult v1)

-- | Standard terminators (outside loops).
-- Mirrors 'compileTerm' exactly.
compileTermToEff :: CompileCtx -> SsaProc -> Map.Map Text (Eff () ()) -> Set.Set Text -> Map.Map Text Text
                 -> Maybe Text -> SsaTerm -> (Eff () (), Map.Map Text (Eff () ()))
compileTermToEff _ctx _proc memo _headers _exits _activeLoop (SsaReturn _) = (J PId, memo)
compileTermToEff ctx proc memo headers exits activeLoop (SsaGoto target) =
  compileBlockToEff ctx proc target memo headers exits activeLoop
compileTermToEff ctx proc memo headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, m1) = compileBlockToEff ctx proc t memo headers exits activeLoop
      (fOp, m2) = compileBlockToEff ctx proc f m1 headers exits activeLoop
      combined  = branchEff (ssaValToExpr cond) tOp fOp
  in (combined, m2)
compileTermToEff _ctx _proc memo _ _ _ SsaBreak    = (J PId, memo)
compileTermToEff _ctx _proc memo _ _ _ SsaContinue = (J PId, memo)
compileTermToEff ctx proc memo headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let seed = compileBlockToEff ctx proc defaultTarget memo headers exits activeLoop
      step (val, target) (accOp, m) =
        let (targetOp, m') = compileBlockToEff ctx proc target m headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branchEff cond targetOp accOp, m')
  in foldr step seed pairs

-- | Loop terminators. Returns @(Eff () (Either () ()), visited)@.
-- Mirrors 'compileLoopTerm' exactly.
compileLoopTermToEff :: CompileCtx -> SsaProc -> Map.Map Text (Eff () (Either () ())) -> Set.Set Text -> Map.Map Text Text
                     -> Maybe Text -> SsaTerm -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())))
compileLoopTermToEff ctx proc visited headers exits activeLoop (SsaGoto target)
  | Just target == activeLoop = (J PInl, visited)
  | isLoopExit headers exits proc activeLoop target = (J PInr, visited)
  | otherwise = compileLoopBodyToEff ctx proc target visited headers exits activeLoop
compileLoopTermToEff ctx proc visited headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, v1) = compileLoopBranchPathToEff ctx proc t visited headers exits activeLoop
      (fOp, v2) = compileLoopBranchPathToEff ctx proc f v1 headers exits activeLoop
      combined  = branchEff (ssaValToExpr cond) tOp fOp
  in (combined, v2)
compileLoopTermToEff _ctx _proc visited _ _ _ (SsaReturn _) = (EReturn, visited)
compileLoopTermToEff _ctx _proc visited _ _ _ SsaBreak      = (J PInr, visited)
compileLoopTermToEff _ctx _proc visited _ _ _ SsaContinue   = (J PInl, visited)
compileLoopTermToEff ctx proc visited headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let seed = compileLoopBranchPathToEff ctx proc defaultTarget visited headers exits activeLoop
      step (val, target) (accOp, v) =
        let (targetOp, v') = compileLoopBranchPathToEff ctx proc target v headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branchEff cond targetOp accOp, v')
  in foldr step seed pairs

-- | Compile a branch target inside a loop.
-- Mirrors 'compileLoopBranchPath' exactly.
compileLoopBranchPathToEff :: CompileCtx -> SsaProc -> Text -> Map.Map Text (Eff () (Either () ())) -> Set.Set Text -> Map.Map Text Text
                           -> Maybe Text -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())))
compileLoopBranchPathToEff ctx proc target visited headers exits activeLoop
  | Just target == activeLoop = (J PInl, visited)
  | isLoopExit headers exits proc activeLoop target = (J PInr, visited)
  | otherwise = compileLoopBodyToEff ctx proc target visited headers exits activeLoop

-- | Compile a list of SSA assignments by folding with composition.
-- Mirrors 'compileAssigns' exactly.
compileAssignsToEff :: CompileCtx -> [SsaAssign] -> Eff () ()
compileAssignsToEff _ctx [] = J PId
compileAssignsToEff ctx [a] = compileAssignToEff ctx a
compileAssignsToEff ctx (a:as) = compileAssignsToEff ctx as . compileAssignToEff ctx a

-- | Compile a single SSA assignment.
-- Mirrors 'compileAssign' exactly.
compileAssignToEff :: CompileCtx -> SsaAssign -> Eff () ()
compileAssignToEff ctx (SsaAssign sv rhs)
  | svName sv == "_" = case rhs of
      SsaConst expr@(ExCall lv rawArgs) ->
        let parsedArgs = map parseArgList rawArgs
        in compileCallExprToEff ctx sv expr lv parsedArgs
      SsaConst expr@(ExMethodCall _recv _meth rawArgs) ->
        let parsedArgs = map parseArgList rawArgs
        in case classifyExpr (ccEnv ctx) expr of
             SuspendCall -> ESuspend (effectName expr parsedArgs) parsedArgs
             PureCall    -> ECall (calleeName expr) parsedArgs
      SsaConst expr ->
        case classifyExpr (ccEnv ctx) expr of
          SuspendCall -> ESuspend (effectName expr []) []
          PureCall    -> ECall (calleeName expr) []
      SsaVarRef _ -> EAssignWithRhs (svName sv) (ssaValToExpr rhs)
      SsaBinOp {} -> EAssignWithRhs (svName sv) (ssaValToExpr rhs)
      SsaNot _    -> EAssignWithRhs (svName sv) (ssaValToExpr rhs)
      SsaNull     -> EAssignWithRhs (svName sv) (ssaValToExpr rhs)
  | otherwise = EAssignWithRhs (svName sv) (ssaValToExpr rhs)

-- | Shared logic for compiling an ExCall expression.
-- Mirrors 'compileCallExpr' exactly.
compileCallExprToEff :: CompileCtx -> SsaVar -> Expr -> Lvalue -> [Expr] -> Eff () ()
compileCallExprToEff ctx _sv expr lv parsedArgs
  | isTriggerEvent lv =
      ECall "triggerevent" [evArg]
  | [seg] <- segments lv
  , T.toLower (segName seg) == "fn_retrievechild" =
      ESuspend (effectName expr parsedArgs) paramArg
  | [seg] <- segments lv
  , T.toLower (segName seg) `Set.member` ccUserFns ctx =
      ECall (segName seg) parsedArgs
  | otherwise = case classifyExpr (ccEnv ctx) expr of
      SuspendCall -> ESuspend (effectName expr parsedArgs) parsedArgs
      PureCall -> ECall (calleeName expr) parsedArgs
  where
    evArg = case parsedArgs of { (a:_) -> a; [] -> ExRaw [] }
    paramArg = case parsedArgs of { (_:_:p:_) -> [p]; _ -> [] }
