{-# LANGUAGE StrictData #-}
-- | Parallel SSA → 'Eff' compilation — mirrors 'PB.Compile.LoopAnalysis'
-- exactly, emitting 'Eff' instead of the older categorical IR. Kept side-by-side for
-- cross-checking; Phase 5b Step 2 will switch entry points.
module PB.Compile.FromSSA
  ( compileSsaToEff
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.AST.Expr (Expr (..), Lvalue (..), BinOp (BopEq))
import PB.AST.Ident (identCanon, identOrig)
import PB.Compile.IR (Category (..), Eff (..), EffTerm (..), Pure (..), branchEff)
import PB.Compile.LoopAnalysis (CompileCtx (..), computeMergePoints, ssaValToExpr,
                              computeLoopHeaders, computeAllLoopExits, isLoopExit)
import PB.Analysis.CallClassify (CallKind (..), classifyExpr, effectName,
                                 calleeName, isTriggerEvent, segName, parseArgList)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.SSA (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                         SsaTerm (..), SsaProc (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Unsafe.Coerce (unsafeCoerce)

-- | Parallel to 'compileSsa': compile an SSA procedure into an 'EffTerm'.
-- The table is built during compilation (not by a later generic walk):
-- 'ELetRef' carries no body, so 'PB.Compile.IR.extractEffTable' cannot
-- recover one from a bare 'Eff' value — see that function's headnote.
compileSsaToEff :: ScopedTypeEnv -> Set.Set Text -> SsaProc -> EffTerm () ()
compileSsaToEff env userFns proc =
  let ctx     = CompileCtx env userFns (computeMergePoints proc)
      headers = computeLoopHeaders proc
      exits   = computeAllLoopExits headers proc
      (result, _finalMemo, table) =
        compileBlockToEff ctx proc (spEntry proc) Map.empty Map.empty headers exits Nothing
  in EffTerm result table

-- | Main compiler orchestrator. Returns @(Eff, updatedMemo, updatedTable)@.
-- A merge point emits 'ELetRef' in the spine and records the untagged
-- @rawResult@ in @table@ under @blockId@. Unlike the older 'CatTagged'
-- (which carried the body inline, letting 'extractTable' rediscover it
-- later), 'ELetRef' has nowhere to carry it, so @table@ is built here,
-- eagerly, at the same point the value is computed.
compileBlockToEff :: CompileCtx -> SsaProc
                  -> Text
                  -> Map.Map Text (Eff () ())
                  -> Map.Map Text (Eff () ())
                  -> Set.Set Text
                  -> Map.Map Text Text
                  -> Maybe Text
                  -> (Eff () (), Map.Map Text (Eff () ()), Map.Map Text (Eff () ()))
compileBlockToEff ctx proc blockId memo table headers exits activeLoop
  | Just blockId == activeLoop = (J PId, memo, table)
  | Just cached <- Map.lookup blockId memo = (cached, memo, table)
  | Set.member blockId headers =
      let seedVisited = Map.fromList [ (bid, J PInl) | bid <- Map.keys memo ]
          (loopBodyOp, visitedFromLoop, table1) =
            compileLoopBodyToEff ctx proc blockId seedVisited table headers exits (Just blockId)
          memoFromLoop = Map.union memo (Map.fromSet (const (J PId)) (Map.keysSet visitedFromLoop))
          exitBlockId = Map.findWithDefault
            (error "impossible: every element of 'headers' is resolved by computeAllLoopExits before compileBlock runs")
            blockId exits
          (postLoopOp, finalMemo, table2) =
            compileBlockToEff ctx proc exitBlockId memoFromLoop table1 headers exits activeLoop
      in (postLoopOp . ELoop loopBodyOp, finalMemo, table2)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (J PId, memo, table)
      Just block ->
        let assignsOp  = compileAssignsToEff ctx (sbAssigns block)
            (termOp, memo1, table1) = compileTermToEff ctx proc memo table headers exits activeLoop (sbTerm block)
            rawResult = case (assignsOp, termOp) of
                       (J PId, _) -> termOp
                       (_, J PId) -> assignsOp
                       _          -> EComp termOp assignsOp
            isMerge = Set.member blockId (ccMergePoints ctx)
            result  = if isMerge then ELetRef blockId else rawResult
            memo2   = Map.insert blockId result memo1
            table2  = if isMerge then Map.insert blockId rawResult table1 else table1
        in (result, memo2, table2)

-- | Compile the body of a loop. Returns @(Eff, updatedVisited, updatedTable)@.
-- Mirrors 'compileBlockToEff' exactly, with the same 'ELetRef'/table addition
-- (a loop body can itself contain a merge point reached by 2+ predecessors).
compileLoopBodyToEff :: CompileCtx -> SsaProc -> Text -> Map.Map Text (Eff () (Either () ()))
                     -> Map.Map Text (Eff () ())
                     -> Set.Set Text -> Map.Map Text Text -> Maybe Text
                     -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())), Map.Map Text (Eff () ()))
compileLoopBodyToEff ctx proc blockId visited table headers exits activeLoop
  | Just cached <- Map.lookup blockId visited = (cached, visited, table)
  | Set.member blockId headers && Just blockId /= activeLoop =
      let nestedExit = Map.findWithDefault
            (error "impossible: every element of 'headers' is resolved by computeAllLoopExits")
            blockId exits
          (innerBody, v1, table1) = compileLoopBodyToEff ctx proc blockId visited table headers exits (Just blockId)
          (afterOp, v2, table2) = compileLoopBodyToEff ctx proc nestedExit v1 table1 headers exits activeLoop
      in (afterOp . ELoop innerBody, v2, table2)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (J PInr, visited, table)
      Just block ->
        let assignsOp  = compileAssignsToEff ctx (sbAssigns block)
            (termOp, v1, table1) = compileLoopTermToEff ctx proc visited table headers exits activeLoop (sbTerm block)
            rawResult = case assignsOp of
                       J PId -> termOp
                       _     -> EComp termOp assignsOp
            isMerge = Set.member blockId (ccMergePoints ctx)
            result  = if isMerge then ELetRef blockId else rawResult
            -- table entries are uniformly 'Eff () ()' even though a loop
            -- body's own rawResult is really 'Eff () (Either () ())' here;
            -- foldFreyd's 'ELetRef' clause coerces back to whatever the use
            -- site's type index expects.
            table2  = if isMerge then Map.insert blockId (unsafeCoerce rawResult) table1 else table1
        in (result, Map.insert blockId result v1, table2)

-- | Standard terminators (outside loops).
-- Mirrors 'compileTerm' exactly.
compileTermToEff :: CompileCtx -> SsaProc -> Map.Map Text (Eff () ()) -> Map.Map Text (Eff () ())
                 -> Set.Set Text -> Map.Map Text Text
                 -> Maybe Text -> SsaTerm -> (Eff () (), Map.Map Text (Eff () ()), Map.Map Text (Eff () ()))
-- A valueless 'return' stays structural identity (matches the pre-existing
-- treatment of every other non-loop terminator here); a return WITH a
-- value must become a real 'EReturn' terminal so
-- 'PB.Analysis.TaintEdges.ret' can see it -- see
-- doc/plan/182b-move2-intra.md Section 1 point 2.
compileTermToEff _ctx _proc memo table _headers _exits _activeLoop (SsaReturn Nothing) = (J PId, memo, table)
compileTermToEff _ctx _proc memo table _headers _exits _activeLoop (SsaReturn (Just v)) = (EReturn (ssaValToExpr v), memo, table)
compileTermToEff ctx proc memo table headers exits activeLoop (SsaGoto target) =
  compileBlockToEff ctx proc target memo table headers exits activeLoop
compileTermToEff ctx proc memo table headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, m1, table1) = compileBlockToEff ctx proc t memo table headers exits activeLoop
      (fOp, m2, table2) = compileBlockToEff ctx proc f m1 table1 headers exits activeLoop
      combined  = branchEff (ssaValToExpr cond) tOp fOp
  in (combined, m2, table2)
compileTermToEff _ctx _proc memo table _ _ _ SsaBreak    = (J PId, memo, table)
compileTermToEff _ctx _proc memo table _ _ _ SsaContinue = (J PId, memo, table)
compileTermToEff ctx proc memo table headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let seed = compileBlockToEff ctx proc defaultTarget memo table headers exits activeLoop
      step (val, target) (accOp, m, t) =
        let (targetOp, m', t') = compileBlockToEff ctx proc target m t headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branchEff cond targetOp accOp, m', t')
  in foldr step seed pairs

-- | Loop terminators. Returns @(Eff () (Either () ()), visited, table)@.
-- Mirrors 'compileLoopTerm' exactly.
compileLoopTermToEff :: CompileCtx -> SsaProc -> Map.Map Text (Eff () (Either () ())) -> Map.Map Text (Eff () ())
                     -> Set.Set Text -> Map.Map Text Text
                     -> Maybe Text -> SsaTerm -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())), Map.Map Text (Eff () ()))
compileLoopTermToEff ctx proc visited table headers exits activeLoop (SsaGoto target)
  | Just target == activeLoop = (J PInl, visited, table)
  | isLoopExit headers exits proc activeLoop target = (J PInr, visited, table)
  | otherwise = compileLoopBodyToEff ctx proc target visited table headers exits activeLoop
compileLoopTermToEff ctx proc visited table headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, v1, table1) = compileLoopBranchPathToEff ctx proc t visited table headers exits activeLoop
      (fOp, v2, table2) = compileLoopBranchPathToEff ctx proc f v1 table1 headers exits activeLoop
      combined  = branchEff (ssaValToExpr cond) tOp fOp
  in (combined, v2, table2)
-- A return inside a loop must fully escape the loop (unlike the non-loop
-- case above, 'J PId' can't express that here), so both shapes compile to
-- a real 'EReturn'; 'ExNull' is the "no value" sentinel for the valueless
-- case ('walkExprIdents ExNull' is empty, so it contributes no spurious
-- returned var to 'PB.Analysis.TaintEdges.ret').
compileLoopTermToEff _ctx _proc visited table _ _ _ (SsaReturn Nothing)  = (EReturn ExNull, visited, table)
compileLoopTermToEff _ctx _proc visited table _ _ _ (SsaReturn (Just v)) = (EReturn (ssaValToExpr v), visited, table)
compileLoopTermToEff _ctx _proc visited table _ _ _ SsaBreak      = (J PInr, visited, table)
compileLoopTermToEff _ctx _proc visited table _ _ _ SsaContinue   = (J PInl, visited, table)
compileLoopTermToEff ctx proc visited table headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let seed = compileLoopBranchPathToEff ctx proc defaultTarget visited table headers exits activeLoop
      step (val, target) (accOp, v, t) =
        let (targetOp, v', t') = compileLoopBranchPathToEff ctx proc target v t headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branchEff cond targetOp accOp, v', t')
  in foldr step seed pairs

-- | Compile a branch target inside a loop.
-- Mirrors 'compileLoopBranchPath' exactly.
compileLoopBranchPathToEff :: CompileCtx -> SsaProc -> Text -> Map.Map Text (Eff () (Either () ())) -> Map.Map Text (Eff () ())
                           -> Set.Set Text -> Map.Map Text Text
                           -> Maybe Text -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())), Map.Map Text (Eff () ()))
compileLoopBranchPathToEff ctx proc target visited table headers exits activeLoop
  | Just target == activeLoop = (J PInl, visited, table)
  | isLoopExit headers exits proc activeLoop target = (J PInr, visited, table)
  | otherwise = compileLoopBodyToEff ctx proc target visited table headers exits activeLoop

-- | Compile a list of SSA assignments by folding with composition.
-- Mirrors 'compileAssigns' exactly.
compileAssignsToEff :: CompileCtx -> [SsaAssign] -> Eff () ()
compileAssignsToEff _ctx [] = J PId
compileAssignsToEff ctx [a] = compileAssignToEff ctx a
compileAssignsToEff ctx (a:as) = compileAssignsToEff ctx as . compileAssignToEff ctx a

-- | Compile a single SSA assignment.
-- Mirrors 'compileAssign' exactly.
compileAssignToEff :: CompileCtx -> SsaAssign -> Eff () ()
compileAssignToEff ctx (SsaAssign sv rhs lhs)
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
      SsaVarRef _ -> EAssignWithRhs (svName sv) lhs (ssaValToExpr rhs)
      SsaBinOp {} -> EAssignWithRhs (svName sv) lhs (ssaValToExpr rhs)
      SsaNot _    -> EAssignWithRhs (svName sv) lhs (ssaValToExpr rhs)
      SsaNull     -> EAssignWithRhs (svName sv) lhs (ssaValToExpr rhs)
  | otherwise = EAssignWithRhs (svName sv) lhs (ssaValToExpr rhs)

-- | Shared logic for compiling an ExCall expression.
-- Mirrors 'compileCallExpr' exactly.
compileCallExprToEff :: CompileCtx -> SsaVar -> Expr -> Lvalue -> [Expr] -> Eff () ()
compileCallExprToEff ctx _sv expr lv parsedArgs
  | isTriggerEvent lv =
      ECall "triggerevent" [evArg]
  | [seg] <- segments lv
  , identCanon (segName seg) == "fn_retrievechild" =
      ESuspend (effectName expr parsedArgs) paramArg
  | [seg] <- segments lv
  , identCanon (segName seg) `Set.member` ccUserFns ctx =
      ECall (identOrig (segName seg)) parsedArgs
  | otherwise = case classifyExpr (ccEnv ctx) expr of
      SuspendCall -> ESuspend (effectName expr parsedArgs) parsedArgs
      PureCall -> ECall (calleeName expr) parsedArgs
  where
    evArg = case parsedArgs of { (a:_) -> a; [] -> ExRaw [] }
    paramArg = case parsedArgs of { (_:_:p:_) -> [p]; _ -> [] }
