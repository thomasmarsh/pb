{-# LANGUAGE StrictData #-}
-- | Parallel SSA → 'Eff' compilation — mirrors 'PB.Compile.LoopAnalysis'
-- exactly, emitting 'Eff' instead of the older categorical IR. Kept side-by-side for
-- cross-checking; Phase 5b Step 2 will switch entry points.
module PB.Compile.FromSSA
  ( compileSsaToEff
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.AST.Expr (Expr (..), Lvalue (..), BinOp (BopEq))
import PB.AST.Ident (Ident, identCanon, identOrig, mkIdentSynthetic)
import PB.AST.Type (PbType)
import PB.Compile.IR (Category (..), Eff (..), EffTerm (..), Pure (..), branchEff)
import PB.Compile.LoopAnalysis (CompileCtx (..), computeMergePoints, ssaValToExpr,
                              computeLoopHeaders, computeAllLoopExits, isLoopExit)
import PB.Analysis.CallClassify (CallKind (..), EffectTag (..), classifyExpr, classifyEffects,
                                 effectName, calleeName, isTriggerEvent, segName)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..), lookupScopedVarOrSelf, lookupScopedIdent)
import PB.Analysis.Taint (classifyOperation, writeOps, execOps)
import PB.Analysis.Dataflow (hasIntoClause, intoTargetSpan, extractSqlHostVars)
import PB.Compile.SSA (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                         SsaTerm (..), SsaProc (..), noSubscriptLhs)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
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
      in (postLoopOp . ELoop loopBodyOp (loopHeaderLine proc blockId), finalMemo, table2)
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
      in (afterOp . ELoop innerBody (loopHeaderLine proc blockId), v2, table2)
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

-- | A loop header block's own terminator is usually reconstructed by
-- 'PB.Compile.SSA.cfgTermToSsa''s header-only fallback as an 'SsaBranch'
-- carrying the originating @BsFor@\/@BsDo@'s line (see
-- 'PB.Compile.SSA.findLoopHeaderStmts') -- this is the one place that line
-- is available to give the 'Eff' 'ELoop' node built around it its own line.
-- Confirmed against the real corpus (BACKLOG.md): a header
-- 'PB.Compile.LoopAnalysis.computeLoopHeaders' identifies structurally
-- sometimes compiles to a plain 'SsaGoto' instead, when
-- 'PB.Compile.SSA.findLoopHeaderStmts''s single-predecessor-edge heuristic
-- doesn't recognize the preceding block as the loop's sole entry -- a
-- pre-existing SSA-lowering gap, not introduced here. 0 is the same "no
-- source line available" sentinel 'PB.Compile.SSA.cfgTermToSsa' itself uses
-- for its own no-originating-statement case, not a crash.
loopHeaderLine :: SsaProc -> Text -> Int
loopHeaderLine proc blockId = case Map.lookup blockId (spBlocks proc) of
  Just block -> case sbTerm block of
    SsaBranch ln _ _ _ -> ln
    _ -> 0
  Nothing -> 0

-- | Standard terminators (outside loops).
-- Mirrors 'compileTerm' exactly.
compileTermToEff :: CompileCtx -> SsaProc -> Map.Map Text (Eff () ()) -> Map.Map Text (Eff () ())
                 -> Set.Set Text -> Map.Map Text Text
                 -> Maybe Text -> SsaTerm -> (Eff () (), Map.Map Text (Eff () ()), Map.Map Text (Eff () ()))
-- 'PB.Compile.SSA.cfgTermToSsa'' emits @SsaReturn 0 Nothing@ as its own
-- structural sentinel (line 0 = "no originating statement") for a block
-- with no outgoing CFG edges, i.e. a procedure simply falling off its own
-- end -- not a real source-level @return@, so it stays structural identity
-- with no leaf at all.
compileTermToEff _ctx _proc memo table _headers _exits _activeLoop (SsaReturn 0 Nothing) = (J PId, memo, table)
-- Every other valueless 'return' (a real source line) and every
-- value-carrying 'return' compile to a real 'EReturn' terminal, mirroring
-- 'compileLoopTermToEff' below exactly: 'ExNull' is the "no value" sentinel
-- for the valueless case ('walkExprIdents ExNull' is empty, so
-- 'PB.Analysis.TaintEdges.ret' contributes no spurious returned var for it,
-- same as the value-carrying case needs for a different reason -- see
-- doc/plan/182b-move2-intra.md Section 1 point 2). A real leaf here (not
-- 'J PId' structural identity) is what lets 'PB.Explain' render a non-loop
-- early exit at all -- see doc/plan/228-bare-return-fromssa-leaf.md.
compileTermToEff _ctx _proc memo table _headers _exits _activeLoop (SsaReturn ln Nothing) = (EReturn ExNull ln, memo, table)
compileTermToEff _ctx _proc memo table _headers _exits _activeLoop (SsaReturn ln (Just v)) = (EReturn (ssaValToExpr v) ln, memo, table)
compileTermToEff ctx proc memo table headers exits activeLoop (SsaGoto _ln target) =
  compileBlockToEff ctx proc target memo table headers exits activeLoop
compileTermToEff ctx proc memo table headers exits activeLoop (SsaBranch ln cond t f) =
  let (tOp, m1, table1) = compileBlockToEff ctx proc t memo table headers exits activeLoop
      (fOp, m2, table2) = compileBlockToEff ctx proc f m1 table1 headers exits activeLoop
      combined  = branchEff (ssaValToExpr cond) tOp fOp ln
  in (combined, m2, table2)
compileTermToEff _ctx _proc memo table _ _ _ (SsaBreak _ln)    = (J PId, memo, table)
compileTermToEff _ctx _proc memo table _ _ _ (SsaContinue _ln) = (J PId, memo, table)
compileTermToEff ctx proc memo table headers exits activeLoop (SsaSwitch ln scrutinee pairs defaultTarget) =
  let seed = compileBlockToEff ctx proc defaultTarget memo table headers exits activeLoop
      step (val, target) (accOp, m, t) =
        let (targetOp, m', t') = compileBlockToEff ctx proc target m t headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branchEff cond targetOp accOp ln, m', t')
  in foldr step seed pairs

-- | Loop terminators. Returns @(Eff () (Either () ()), visited, table)@.
-- Mirrors 'compileLoopTerm' exactly.
compileLoopTermToEff :: CompileCtx -> SsaProc -> Map.Map Text (Eff () (Either () ())) -> Map.Map Text (Eff () ())
                     -> Set.Set Text -> Map.Map Text Text
                     -> Maybe Text -> SsaTerm -> (Eff () (Either () ()), Map.Map Text (Eff () (Either () ())), Map.Map Text (Eff () ()))
compileLoopTermToEff ctx proc visited table headers exits activeLoop (SsaGoto _ln target)
  | Just target == activeLoop = (J PInl, visited, table)
  | isLoopExit headers exits proc activeLoop target = (J PInr, visited, table)
  | otherwise = compileLoopBodyToEff ctx proc target visited table headers exits activeLoop
compileLoopTermToEff ctx proc visited table headers exits activeLoop (SsaBranch ln cond t f) =
  let (tOp, v1, table1) = compileLoopBranchPathToEff ctx proc t visited table headers exits activeLoop
      (fOp, v2, table2) = compileLoopBranchPathToEff ctx proc f v1 table1 headers exits activeLoop
      combined  = branchEff (ssaValToExpr cond) tOp fOp ln
  in (combined, v2, table2)
-- A return inside a loop must fully escape the loop (unlike the non-loop
-- case above, 'J PId' can't express that here), so both shapes compile to
-- a real 'EReturn'; 'ExNull' is the "no value" sentinel for the valueless
-- case ('walkExprIdents ExNull' is empty, so it contributes no spurious
-- returned var to 'PB.Analysis.TaintEdges.ret').
compileLoopTermToEff _ctx _proc visited table _ _ _ (SsaReturn ln Nothing)  = (EReturn ExNull ln, visited, table)
compileLoopTermToEff _ctx _proc visited table _ _ _ (SsaReturn ln (Just v)) = (EReturn (ssaValToExpr v) ln, visited, table)
compileLoopTermToEff _ctx _proc visited table _ _ _ (SsaBreak _ln)      = (J PInr, visited, table)
compileLoopTermToEff _ctx _proc visited table _ _ _ (SsaContinue _ln)   = (J PInl, visited, table)
compileLoopTermToEff ctx proc visited table headers exits activeLoop (SsaSwitch ln scrutinee pairs defaultTarget) =
  let seed = compileLoopBranchPathToEff ctx proc defaultTarget visited table headers exits activeLoop
      step (val, target) (accOp, v, t) =
        let (targetOp, v', t') = compileLoopBranchPathToEff ctx proc target v t headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branchEff cond targetOp accOp ln, v', t')
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
-- Mirrors 'compileAssign' exactly. The declared-type lookup
-- ('lookupScopedVarOrSelf') resolves @this@\/@super@ too, matching every
-- other single-segment type lookup in the codebase; 'Nothing' (an SSA temp
-- with no scope entry) is not an error, just an untyped assign.
--
-- Dispatch is on @rhs@\'s own shape first (not, as previously, gated
-- entirely behind "is the target discarded"): a call-shaped RHS
-- ('ExCall'\/'ExMethodCall'\/other 'classifyExpr'-recognized calls) always
-- computes its 'classifyEffects' tag set via the shared helpers below,
-- whether the target is the discarded @_@ sentinel (compiles straight to a
-- bare 'ECall'\/'ESuspend', as before) or a real variable (compiles to
-- 'EAssignWithRhs', now carrying those same tags instead of silently
-- dropping them — the fix for the gap where @ll_nrows = idw.rowcount()@
-- had no way to record that @rowcount@ is 'ReadsControlState').
compileAssignToEff :: CompileCtx -> SsaAssign -> Eff () ()
compileAssignToEff ctx (SsaAssign sv rhs lhs ln) = case rhs of
    SsaConst expr@(ExCall lv parsedArgs)
      | isDiscarded -> compileCallExprToEff ctx sv expr lv parsedArgs ln
      | otherwise   -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType (classifyEffects (ccEnv ctx) expr)
    SsaConst expr@(ExMethodCall _recv _meth parsedArgs)
      | isDiscarded ->
          case classifyExpr (ccEnv ctx) expr of
               SuspendCall -> ESuspend (effectName expr parsedArgs) parsedArgs ln (classifyEffects (ccEnv ctx) expr)
               PureCall    -> ECall (calleeName expr) parsedArgs ln (classifyEffects (ccEnv ctx) expr)
      | otherwise -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType (classifyEffects (ccEnv ctx) expr)
    SsaConst expr
      | isDiscarded ->
          case classifyExpr (ccEnv ctx) expr of
            SuspendCall -> ESuspend (effectName expr []) [] ln (classifyEffects (ccEnv ctx) expr)
            PureCall    -> ECall (calleeName expr) [] ln (classifyEffects (ccEnv ctx) expr)
      | otherwise -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType (classifyEffects (ccEnv ctx) expr)
    SsaVarRef _ -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType Set.empty
    SsaBinOp {} -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType Set.empty
    SsaNot _    -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType Set.empty
    SsaNull     -> EAssignWithRhs (identOrig (svName sv)) lhs (ssaValToExpr rhs) ln declaredType Set.empty
    SsaRaw txt  ->
      let tags    = sqlStmtEffectTags txt
          name    = sqlRawDisplayName txt
          callEff = if Set.member Suspends tags
                    then ESuspend name [] ln tags
                    else ECall name [] ln tags
          defEff (v, ty) = EAssignWithRhs (identOrig v) (noSubscriptLhs v) (ExRaw []) ln ty Set.empty
      in foldl' (\acc d -> defEff d . acc) callEff (intoTargetIdents (ccEnv ctx) txt)
  where
    isDiscarded = identCanon (svName sv) == "_"
    declaredType = lookupScopedVarOrSelf (svName sv) (ccEnv ctx)

-- | Shared logic for compiling an ExCall expression.
-- Mirrors 'compileCallExpr' exactly.
compileCallExprToEff :: CompileCtx -> SsaVar -> Expr -> Lvalue -> [Expr] -> Int -> Eff () ()
compileCallExprToEff ctx _sv expr lv parsedArgs ln
  | isTriggerEvent lv =
      ECall "triggerevent" [evArg] ln (classifyEffects (ccEnv ctx) expr)
  | [seg] <- segments lv
  , identCanon (segName seg) == "fn_retrievechild" =
      ESuspend (effectName expr parsedArgs) paramArg ln (classifyEffects (ccEnv ctx) expr)
  | [seg] <- segments lv
  , identCanon (segName seg) `Set.member` ccUserFns ctx =
      ECall (identOrig (segName seg)) parsedArgs ln (classifyEffects (ccEnv ctx) expr)
  | otherwise = case classifyExpr (ccEnv ctx) expr of
      SuspendCall -> ESuspend (effectName expr parsedArgs) parsedArgs ln (classifyEffects (ccEnv ctx) expr)
      PureCall -> ECall (calleeName expr) parsedArgs ln (classifyEffects (ccEnv ctx) expr)
  where
    evArg = case parsedArgs of { (a:_) -> a; [] -> ExRaw [] }
    paramArg = case parsedArgs of { (_:_:p:_) -> [p]; _ -> [] }

-- | Effect tags for a bare SQL\/transaction-control keyword statement
-- ('BsRaw', compiled via 'PB.Compile.SSA.SsaRaw') -- these were previously
-- invisible to effect classification, compiling to no 'Eff' node at all.
-- Keyed off 'PB.Analysis.Taint.classifyOperation', reusing its
-- 'writeOps'\/'execOps' vocabulary rather than re-deriving it. An
-- unrecognized or empty 'classifyOperation' result (a non-SQL 'BsRaw', or a
-- SQL keyword 'PB.Analysis.Taint.sqlKeywords' doesn't yet list) is
-- 'Set.empty', not an error.
sqlStmtEffectTags :: Text -> Set.Set EffectTag
sqlStmtEffectTags txt = case classifyOperation txt of
  ""       -> Set.empty
  "SELECT" -> Set.singleton ReadsDb
  op
    | op `Set.member` writeOps                      -> Set.singleton WritesDb
    | op `Set.member` execOps                        -> Set.fromList [WritesDb, Suspends]
    | op `elem` ["COMMIT", "ROLLBACK"]                -> Set.fromList [WritesDb, Suspends]
    | op `elem` ["CONNECT", "DISCONNECT"]             -> Set.singleton Suspends
    | op `elem` ["DECLARE", "OPEN", "FETCH", "CLOSE"] -> Set.singleton Suspends
    | otherwise                                       -> Set.empty

-- | A short, human-readable display name for a raw SQL\/statement 'BsRaw'
-- text -- the SQL verb, lowercased, or a fixed placeholder for anything
-- 'classifyOperation' doesn't recognize. Used as the 'ECall'\/'ESuspend'
-- callee-name field instead of the entire raw statement text, which
-- otherwise renders as garbled pseudocode (a confirmed real-corpus bug,
-- not just latent risk -- see BACKLOG.md).
sqlRawDisplayName :: Text -> Text
sqlRawDisplayName txt = case classifyOperation txt of
  "" -> "raw_stmt"
  op -> T.toLower op

-- | The INTO-target host variables of a raw SQL statement (a @SELECT ...
-- INTO :var FROM ...@), each paired with its real, already-minted 'Ident'
-- recovered from 'ScopedTypeEnv' when the variable is in scope (a
-- local\/param\/instance\/global var declared elsewhere in the same
-- procedure -- the overwhelmingly common real-world shape for a
-- PowerScript host variable, per 'lookupScopedIdent'), or a 'Synthetic'
-- fallback 'Ident' when it genuinely isn't tracked (never re-minted from a
-- real span that doesn't exist -- see the ident-minting skill). @[]@ when
-- the statement has no INTO clause.
intoTargetIdents :: ScopedTypeEnv -> Text -> [(Ident, Maybe PbType)]
intoTargetIdents env txt
  | hasIntoClause txt = [ resolve v | v <- extractSqlHostVars (intoTargetSpan txt) ]
  | otherwise         = []
  where
    resolve v =
      let key = mkIdentSynthetic "PB.Compile.FromSSA: BsRaw INTO-target host-var lookup key" v
      in case lookupScopedIdent key env of
           Just real -> (real, lookupScopedVarOrSelf real env)
           Nothing   -> (mkIdentSynthetic "PB.Compile.FromSSA: BsRaw INTO-target host-var not in ScopedTypeEnv" v, Nothing)
