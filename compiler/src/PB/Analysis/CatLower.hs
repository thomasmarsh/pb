{-# LANGUAGE StrictData #-}
-- | SSA → 'CatOp' compilation (the categorical-pipeline "lowering" pass).
--
-- Pure module — no I/O. Takes a 'SsaProc' (already in SSA form — see
-- 'PB.Analysis.SSA') and compiles it into a single 'CatOp' term via
-- 'compileSsa'. This is the largest and most intricate stage of the
-- categorical pipeline (all of Plan 144's loop-nesting machinery and most
-- of Plan 146's correctness fixes live here) — split out of
-- 'PB.Analysis.CatOp' on its own in Plan 151, so a session touching
-- loop-nesting/merge-point logic opens one focused file instead of a
-- 1367-line file mixing four unrelated pipeline stages.
--
-- Compilation rules:
--   * Linear assigns: fold with CatCompose via @(assign . (id &&& eval))@
--   * @SsaGoto target@: CatId (structural connection, not a jump)
--   * @SsaBranch cond t f@: @branch@ combinator (splitValue + |||)
--   * @SsaReturn@: CatId (terminal) outside a loop; CatReturn (Plan 146
--     Phase 2i) inside a loop — distinct from CatInr/break, since it must
--     bypass the loop's own post-loop continuation entirely
--   * Phi nodes: CatFanIn at join points (pushed into predecessor branches)
--   * Loops: CatLoop wrapping the loop body (detected via back-edge analysis)
--   * Back-edges: CatInl (continue loop) / CatInr (break loop)
--   * Calls: classified via 'classifyExpr'; pure → 'CatCall', suspend → 'CatSuspend'
module PB.Analysis.CatLower
  ( compileSsa
  , CompileCtx (..)
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import Data.List (sortOn)
import PB.AST.Expr (Expr (..), LvSegment (..), Lvalue (..), BinOp (BopEq))
import PB.Analysis.CatOp (Category (..), CatOp (..), branch)
import PB.Analysis.CallClassify (CallKind (..), classifyExpr, effectName, calleeName, isTriggerEvent, segName, parseArgList)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Analysis.SSA (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                         SsaTerm (..), SsaProc (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

-- | Compilation context threaded through all SSA→CatOp helpers.
data CompileCtx = CompileCtx
  { ccEnv         :: ScopedTypeEnv    -- ^ Type environment for call classification
  , ccUserFns     :: Set.Set Text     -- ^ User-defined function names (lower-cased)
  , ccMergePoints :: Set.Set Text
    -- ^ BlockIds reached by 2+ predecessor edges anywhere in the procedure
    -- (Plan 150). The only blocks 'compileBlock'/'compileLoopBody' can ever
    -- return via their memo's cache-hit branch — i.e. the only ones a
    -- second predecessor can reach the very same compiled 'CatOp' value
    -- for — so the only ones that need a 'CatTagged' identity for
    -- 'GraphBuilder' to physically share downstream instead of re-lowering
    -- (and re-allocating a full duplicate subgraph) on every encounter.
  }

-- | BlockIds reached by 2 or more predecessor edges in a procedure's CFG,
-- counting every terminator's successors (top-level and loop-body blocks
-- alike — a merge inside a loop body needs the same treatment as one at
-- the top level) — EXCLUDING loop headers. See 'ccMergePoints'.
--
-- A loop header always has 2+ predecessors (the initial forward entry, plus
-- at least one back-edge), so a naive predecessor count always flags it —
-- but a header is never actually at risk of the physical-duplication bug
-- this tagging exists to fix: 'compileLoopLowCat' lowers a loop's header
-- content exactly once, as the sole argument to 'CatLoop', never embedded
-- at a second tree position. Tagging it anyway broke
-- 'patchLoopHeaderLowCat'\'s @LCompose (LFanIn ..) ..@ structural detection
-- (it doesn't unwrap 'LTagged'), which silently fell back to its
-- unpatched-forwarding-'InstrNop' path — and, worse, mis-threaded the loop's
-- own back-edge, causing loops to stop after one iteration. Confirmed via
-- the regression this caused in the loop test suite (Plan 150 Phase 3).
computeMergePoints :: SsaProc -> Set.Set Text
computeMergePoints proc =
  Map.keysSet (Map.filter (P.> 1) predCounts) `Set.difference` computeLoopHeaders proc
  where
    allSuccessors = concatMap (termSuccessors P.. sbTerm) (Map.elems (spBlocks proc))
    predCounts    = Map.fromListWith (P.+) [ (bid, 1 :: Int) | bid <- allSuccessors ]

-- | Compile an SSA procedure into a categorical combinator.
--
-- The SSA form ensures every variable is assigned exactly once, so the
-- environment type parameter can be () — all variable storage is by name.
--
-- Compilation rules:
--   * Linear assigns: fold with CatCompose via @(assign . (id &&& eval))@
--   * @SsaGoto target@: CatId (structural connection, not a jump)
--   * @SsaBranch cond t f@: @branch@ combinator (splitValue + |||)
--   * @SsaReturn@: CatId (terminal) outside a loop; CatReturn (Plan 146
--     Phase 2i) inside a loop — distinct from CatInr/break, since it must
--     bypass the loop's own post-loop continuation entirely
--   * Phi nodes: CatFanIn at join points (pushed into predecessor branches)
--   * Loops: CatLoop wrapping the loop body (detected via back-edge analysis)
--   * Back-edges: CatInl (continue loop) / CatInr (break loop)
--   * Calls: classified via 'classifyExpr'; pure → 'CatCall', suspend → 'CatSuspend'
--
-- A memo cache (blockId -> its already-compiled CatOp value) is threaded globally
-- through all branches to prevent double-compilation of shared successor blocks
-- (O(V+E) instead of exponential) while still returning the block's real content —
-- not a no-op — to every predecessor that reaches it (Plan 145 Bug A: a bare
-- Set-of-visited-ids design returned CatId on a revisit, silently dropping any real
-- assigns/calls/branches in a block reached by more than one forward predecessor).
compileSsa :: ScopedTypeEnv -> Set.Set Text -> SsaProc -> CatOp () ()
compileSsa env userFns proc =
  let ctx     = CompileCtx env userFns (computeMergePoints proc)
      headers = computeLoopHeaders proc
      exits   = computeAllLoopExits headers proc
      (result, _finalMemo) = compileBlock ctx proc (spEntry proc) Map.empty headers exits Nothing
  in result

-- | Extract all destination blocks from an SSA terminator.
termSuccessors :: SsaTerm -> [Text]
termSuccessors (SsaGoto t)              = [t]
termSuccessors (SsaBranch _ t f)        = [t, f]
termSuccessors (SsaSwitch _ pairs def)  = def : map snd pairs
termSuccessors _                        = []

-- | Detect loop headers by DFS with onStack tracking.
-- A loop header is any block that is the target of a back-edge
-- (an edge to a block already on the current DFS path).
--
-- The 'visited' set is threaded across sibling successors (via 'foldl''), not
-- reset per-sibling — each block is fully explored at most once across the whole
-- walk, giving O(V+E). A per-sibling reset was fine when every block had at most
-- one real successor (a 'choose case' always collapsed to a single 'SsaGoto' —
-- Plan 145 Bug B), but 'SsaSwitch' genuinely fans out to N clause targets that
-- reconverge at one merge block; without this threading, that shared downstream
-- region gets re-explored from scratch once per sibling, compounding
-- multiplicatively across every subsequent branch/switch in the same procedure
-- (Plan 146 Phase 2b: this hung real corpus procedures once Bug B started
-- reporting real N-way fan-out instead of always exactly one edge).
computeLoopHeaders :: SsaProc -> Set.Set Text
computeLoopHeaders proc = fst (go (spEntry proc) Set.empty Set.empty)
  where
    go :: Text -> Set.Set Text -> Set.Set Text -> (Set.Set Text, Set.Set Text)
    go blockId onStack visited
      | Set.member blockId onStack = (Set.singleton blockId, visited)
      | Set.member blockId visited = (Set.empty, visited)
      | otherwise = case Map.lookup blockId (spBlocks proc) of
          Nothing    -> (Set.empty, visited)
          Just block ->
            let onStack' = Set.insert blockId onStack
                visited' = Set.insert blockId visited
                succs    = termSuccessors (sbTerm block)
                step (hs, vis) s = let (h, vis') = go s onStack' vis in (Set.union hs h, vis')
            in foldl' step (Set.empty, visited') succs

-- | For each loop header, its immediate enclosing loop header (if nested),
-- found by walking the CFG from the entry and threading "the innermost loop
-- header currently active" down the recursion — a header is labeled with
-- whichever header was active the first time it's visited. Needed so
-- 'computeAllLoopExits' can resolve nested (child) loops strictly before the
-- loops that contain them (Plan 146 Phase 2f — see its comment for why
-- resolution order matters).
computeLoopNestParents :: Set.Set Text -> SsaProc -> Map.Map Text (Maybe Text)
computeLoopNestParents headers proc = snd (go (spEntry proc) Nothing Set.empty Map.empty)
  where
    go :: Text -> Maybe Text -> Set.Set Text -> Map.Map Text (Maybe Text)
       -> (Set.Set Text, Map.Map Text (Maybe Text))
    go blockId innermost visited parents
      | Set.member blockId visited = (visited, parents)
      | otherwise = case Map.lookup blockId (spBlocks proc) of
          Nothing -> (Set.insert blockId visited, parents)
          Just block ->
            let visited' = Set.insert blockId visited
                parents' = if Set.member blockId headers
                             then Map.insert blockId innermost parents
                             else parents
                innermost' = if Set.member blockId headers then Just blockId else innermost
                succs = termSuccessors (sbTerm block)
            in foldl' (\(v, p) s -> go s innermost' v p) (visited', parents') succs

-- | Resolve every loop header's exit target in one pass, processing nested
-- (child) loops strictly before their enclosing (parent) loops — so an
-- outer loop's own reachability walk can treat an already-resolved nested
-- loop as an opaque single-exit region, instead of either stopping dead at
-- it (which used to drop real body blocks only reachable through the nested
-- loop) or walking through it unbounded (which can escape through an
-- *enclosing* loop's own back-edge and produce a bogus "exit" — the bug this
-- fixes). Confirmed via direct hand-trace of a real corpus --dual-trace diff
-- (w_dynsql_format4::ue_execute, whose do-while loop contains a for-loop):
-- the outer and inner loop headers were resolved as *each other's* exit
-- target, causing the new compiler's execution to run away past the
-- --dual-trace fuel bound where the old compiler terminated in a handful of
-- steps (Plan 146 Phase 2f).
computeAllLoopExits :: Set.Set Text -> SsaProc -> Map.Map Text Text
computeAllLoopExits headers proc =
  let parents = computeLoopNestParents headers proc
      depthOf h = case Map.lookup h parents of
        Just (Just p) -> 1 + depthOf p
        _             -> (0 :: Int)
      -- deepest (most nested) first, so each header's own resolution can
      -- look up any more-deeply-nested header it encounters
      order = sortOn (negate P.. depthOf) (Set.toList headers)
  in foldl' (\resolved h -> Map.insert h (determineLoopExitTarget headers resolved proc h) resolved)
            Map.empty order

-- | Find all blocks that form the loop body via cycle-aware reachability.
-- A block is in the body only if it is reachable from the header AND
-- can transitively reach back to the header (strong connectivity).
-- The forward walk stops at other loop headers to avoid escaping into nested loops.
-- Takes the already-computed loop-header set (see 'computeLoopHeaders') rather than
-- recomputing it — 'discoverReachable' below queries it once per visited block, and
-- recomputing an O(V+E) function that often would multiply the cost right back up.
-- 'resolvedExits' holds exit targets for headers already resolved by
-- 'computeAllLoopExits' at a strictly deeper nesting level than 'headerId' —
-- used to treat those nested loops as opaque single-exit regions (Plan 146
-- Phase 2f); a foreign header absent from it is an enclosing/unrelated loop,
-- handled exactly as before (a hard stop).
computeLoopBodyBlocks :: Set.Set Text -> Map.Map Text Text -> SsaProc -> Text -> Set.Set Text
computeLoopBodyBlocks headers resolvedExits proc headerId =
  let headerSuccs = case Map.lookup headerId (spBlocks proc) of
        Nothing -> []
        Just block -> termSuccessors (sbTerm block)
      allReachable = foldl' (\bs s -> discoverReachable headers resolvedExits proc headerId s bs) (Set.singleton headerId) headerSuccs
      loopBody     = Set.filter (\bId -> canReach headers resolvedExits proc bId headerId Set.empty) allReachable
  in Set.insert headerId loopBody

-- | Forward-reachability walk bounded by loop headers. A foreign header
-- already present in 'resolvedExits' (a more-deeply-nested loop) is treated
-- as an opaque pass-through: recorded as reachable, then the walk continues
-- from its own resolved exit target rather than its raw successors or a
-- dead stop (Plan 146 Phase 2f). A foreign header absent from 'resolvedExits'
-- (an enclosing or unrelated loop) still stops the walk, exactly as before.
discoverReachable :: Set.Set Text -> Map.Map Text Text -> SsaProc -> Text -> Text -> Set.Set Text -> Set.Set Text
discoverReachable headers resolvedExits proc headerId currentBlock visited
  | Set.member currentBlock visited = visited
  | currentBlock /= headerId && Set.member currentBlock headers =
      case Map.lookup currentBlock resolvedExits of
        Just exitTarget -> discoverReachable headers resolvedExits proc headerId exitTarget (Set.insert currentBlock visited)
        Nothing         -> visited
  | otherwise = case Map.lookup currentBlock (spBlocks proc) of
      Nothing -> visited
      Just block ->
        let visited' = Set.insert currentBlock visited
            succs    = termSuccessors (sbTerm block)
        in foldl' (\v s -> discoverReachable headers resolvedExits proc headerId s v) visited' succs

-- | Returns True if startBlock can transitively reach targetBlock.
-- Threads the discovered 'visited' set across sibling successors (via the
-- explicit fold in 'goSuccs', short-circuiting on the first True) for the same
-- reason 'computeLoopHeaders' does — see its comment. Mirrors
-- 'discoverReachable's foreign-header handling: a resolved (nested) header
-- redirects through its own exit target instead of freely walking its
-- internals (which used to let a nested loop's own exit block "reach back"
-- via escaping through an *enclosing* loop's back-edge — Plan 146 Phase 2f);
-- an unresolved (enclosing/unrelated) header still stops the walk.
--
-- A block terminating in 'SsaContinue'/'SsaBreak' is always treated as
-- reaching (Plan 146 Phase 2g). 'termSuccessors' deliberately returns @[]@
-- for both — they're handled as special-cased control transfers elsewhere
-- (@compileLoopTerm@/@compileLoopBranchPath@), not real graph edges — so a
-- pure forward walk can never step off of one. Left unhandled, that made
-- 'canReach' wrongly exclude such a block from the loop's own body: it then
-- surfaced as a spurious "successor not in the body" candidate in
-- 'determineLoopExitTarget', tying the resolved exit target to an arbitrary
-- alphabetically-first candidate instead of the loop's real exit whenever a
-- continue/break block's id happened to sort first — and independently made
-- 'isLoopExit' misclassify a genuine continue target as "outside the loop",
-- silently turning that 'continue' into a 'break'. Both are safe here
-- because this function's only caller ('computeLoopBodyBlocks') always asks
-- "is this block part of the loop currently being resolved" — continue/break
-- are that loop's own body by construction, regardless of where their
-- (elsewhere-handled) control transfer actually lands.
--
-- 'SsaReturn' deliberately does NOT get the same treatment (Plan 146 Phase
-- 2i tried this, and it was wrong — reverted). Unlike continue/break,
-- a return statement is not lexically restricted to loop bodies: a
-- return-terminated block reached by forwarding through a loop's own real
-- exit edge (e.g. an if/else merge block with nothing left in the
-- procedure, reached both from an unrelated earlier branch AND from this
-- loop's exit) is not a loop-body member at all, and treating it as one
-- here made it eligible for 'computeLoopBodyBlocks' — which then let
-- 'compileLoopBody' try to recompile a block that an *outer*, non-loop
-- branch had already compiled and memoized moments earlier as plain
-- 'CatId', via the 'seedVisited' \"already compiled outside this loop\"
-- placeholder in 'compileBlock'. That stale 'CatInl' placeholder silently
-- replaced the loop's real exit content, producing a branch node whose own
-- false edge pointed back at itself — an infinite loop (confirmed via
-- direct 'InstrGraph' inspection of the real corpus regression,
-- @w_regedit::itempopulate@). The genuine early-return-inside-a-loop case
-- (@w_customer_report::open@ et al.) is instead handled directly in
-- 'isLoopExit' below, which only special-cases a block whose *own*
-- terminator is 'SsaReturn' — never a block that merely forwards to one —
-- so it can't be confused with a loop's ordinary (non-return) exit chain.
canReach :: Set.Set Text -> Map.Map Text Text -> SsaProc -> Text -> Text -> Set.Set Text -> Bool
canReach headers resolvedExits proc startBlock0 targetBlock visited0 = fst (go startBlock0 visited0)
  where
    go current visited
      | current == targetBlock = (True, visited)
      | Set.member current visited = (False, visited)
      | Set.member current headers =
          case Map.lookup current resolvedExits of
            Just exitTarget -> go exitTarget (Set.insert current visited)
            Nothing         -> (False, Set.insert current visited)
      | otherwise = case Map.lookup current (spBlocks proc) of
          Nothing -> (False, visited)
          Just block
            | SsaContinue <- sbTerm block -> (True, Set.insert current visited)
            | SsaBreak    <- sbTerm block -> (True, Set.insert current visited)
            | otherwise ->
                let visited' = Set.insert current visited
                    succs    = termSuccessors (sbTerm block)
                in goSuccs visited' succs
    goSuccs visited [] = (False, visited)
    goSuccs visited (s:ss) = case go s visited of
      (True, visited')  -> (True, visited')
      (False, visited') -> goSuccs visited' ss

-- | Robust exit target extraction: collect every successor of every block
-- in the loop body; the exit is any successor NOT in the body itself.
-- A body block that is itself a strictly-more-nested, already-resolved
-- header contributes only its own resolved exit target here, not its raw
-- (purely internal to that nested loop) successors — otherwise a nested
-- loop's own body block leaks through as a spurious "exit" of the
-- enclosing loop (Plan 146 Phase 2f).
--
-- Prefers a non-return-terminated candidate when 'exits' has more than
-- one (Plan 146 Phase 2i): a body-internal early return (e.g. an elseif
-- branch's own @return@, handled directly by 'isLoopExit' below so it
-- never needs to appear here at all — see @w_customer_report::open@) can
-- still show up as a second, spurious "successor not in body" candidate
-- for the same reasons continue/break used to (Phase 2f/2g's alphabetical
-- tiebreak fragility) whenever the return-terminated block happens to be
-- reachable from some other body block's branch. Falling back to a
-- return-terminated candidate when it's the *only* one preserves the
-- legitimate "loop; return" shape (nothing else left in the procedure).
determineLoopExitTarget :: Set.Set Text -> Map.Map Text Text -> SsaProc -> Text -> Text
determineLoopExitTarget headers resolvedExits proc headerId =
  let bodyBlocks  = computeLoopBodyBlocks headers resolvedExits proc headerId
      succsOf bId
        | bId /= headerId, Just exitTarget <- Map.lookup bId resolvedExits = [exitTarget]
        | otherwise = case Map.lookup bId (spBlocks proc) of
            Nothing    -> []
            Just block -> termSuccessors (sbTerm block)
      allSuccs = Set.fromList [ suc | bId <- Set.toList bodyBlocks, suc <- succsOf bId ]
      exits = Set.filter (/= headerId) (Set.difference allSuccs bodyBlocks)
      isReturnTerminated bId = case Map.lookup bId (spBlocks proc) of
        Just block | SsaReturn _ <- sbTerm block -> True
        _                                        -> False
      (nonReturnExits, returnExits) = Set.partition (not P.. isReturnTerminated) exits
  in case Set.toList nonReturnExits of
       (exitTarget : _) -> exitTarget
       [] -> case Set.toList returnExits of
               (exitTarget : _) -> exitTarget
               []               -> ""

-- | Main compiler orchestrator. Returns @(CatOp, updatedMemo)@ to thread the global
-- memo across all branches.
--
-- The memo caches each block's actual compiled 'CatOp' value, keyed by block id — not
-- merely whether it has been visited (Plan 145 Bug A). A bare visited-only 'Set.Set'
-- forces a revisit to resolve to a no-op 'CatId', which silently drops any real
-- assigns/calls/branches for every predecessor after the first to reach an ordinary
-- (non-loop) merge block. Caching the real value instead preserves both correctness
-- (every predecessor gets the actual content) and the O(V+E) compile-time bound the
-- registry exists for (each block's value is still computed at most once) — safe
-- because 'computeLoopHeaders' already routes every genuine back-edge to the
-- 'compileLoopBody' path below, so a block reached via this "otherwise" case can never
-- legitimately cycle back to its own not-yet-cached entry.
compileBlock :: CompileCtx -> SsaProc
             -> Text                          -- ^ Current block ID
             -> Map.Map Text (CatOp () ())    -- ^ Global memo: blockId -> its compiled value
             -> Set.Set Text                  -- ^ Pre-computed loop headers
             -> Map.Map Text Text             -- ^ Pre-resolved loop exit targets (see 'computeAllLoopExits')
             -> Maybe Text                    -- ^ Active loop header context
             -> (CatOp () (), Map.Map Text (CatOp () ()))
compileBlock ctx proc blockId memo headers exits activeLoop
  | Just blockId == activeLoop = (CatId, memo)
  | Just cached <- Map.lookup blockId memo = (cached, memo)
  | Set.member blockId headers =
      let -- Seed with CatInl placeholders for every block already compiled outside this
          -- loop, preserving the exact old Set-based behaviour for that (never expected
          -- to trigger — see compileLoopBody's own docs) edge; genuine forward-merge
          -- revisits *within* this loop body's own traversal get the real fix below.
          seedVisited = Map.fromList [ (bid, CatInl) | bid <- Map.keys memo ]
          (loopBodyOp, visitedFromLoop) = compileLoopBody ctx proc blockId seedVisited headers exits (Just blockId)
          -- Preserve prior behaviour exactly: mark every block compileLoopBody touched
          -- as CatId for any later revisit from the post-loop continuation, matching
          -- what the old Set-based registry did here (Plan 145 Bug A's fix deliberately
          -- left this outer-memo interaction untouched; only compileLoopBody's own
          -- internal revisit handling changed in Plan 146 item 7).
          memoFromLoop = Map.union memo (Map.fromSet (const CatId) (Map.keysSet visitedFromLoop))
          exitBlockId = Map.findWithDefault
            (error "impossible: every element of 'headers' is resolved by computeAllLoopExits before compileBlock runs")
            blockId exits
          (postLoopOp, finalMemo) = compileBlock ctx proc exitBlockId memoFromLoop headers exits activeLoop
      in (postLoopOp . CatLoop loopBodyOp, finalMemo)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (CatId, memo)
      Just block ->
        let assignsOp  = compileAssigns ctx (sbAssigns block)
            (termOp, memo1) = compileTerm ctx proc memo headers exits activeLoop (sbTerm block)
            rawResult = case (assignsOp, termOp) of
                       (CatId, _) -> termOp
                       (_, CatId) -> assignsOp
                       _          -> termOp . assignsOp
            -- Plan 150: tag merge-point results so a repeat encounter
            -- (this exact value, embedded at a second tree position by a
            -- second predecessor) can be recognized and shared by
            -- 'GraphBuilder' instead of re-lowered as a physical duplicate.
            result = if Set.member blockId (ccMergePoints ctx)
                       then CatTagged blockId rawResult
                       else rawResult
            memo2 = Map.insert blockId result memo1
        in (result, memo2)

-- | Compile the body of a loop. Returns @(CatOp () (Either () ()), visited)@:
--   * @Left ()@ — continue the loop (back-edge or continue)
--   * @Right ()@ — break out of loop (return / break / exit)
--
-- The registry caches each visited block's actual compiled value, keyed by block id —
-- not merely whether it has been visited (Plan 146 item 7, the parallel to Plan 145 Bug
-- A one level down). Genuine back-edges to the active loop header are caught earlier, in
-- 'compileLoopTerm'/'compileLoopBranchPath's @Just target == activeLoop@ checks — so
-- every revisit that reaches this function's own @Map.lookup blockId visited@ hit is
-- necessarily an ordinary forward merge (e.g. an if/else's shared tail inside a loop
-- body), never a real back-edge. A bare visited-only 'Set.Set' forced such a revisit to
-- resolve to 'CatInl', silently dropping that block's real assigns/branches for every
-- predecessor after the first to reach it.
compileLoopBody :: CompileCtx -> SsaProc -> Text -> Map.Map Text (CatOp () (Either () ()))
                -> Set.Set Text -> Map.Map Text Text -> Maybe Text -> (CatOp () (Either () ()), Map.Map Text (CatOp () (Either () ())))
compileLoopBody ctx proc blockId visited headers exits activeLoop
  | Just cached <- Map.lookup blockId visited = (cached, visited)
  | Set.member blockId headers && Just blockId /= activeLoop =
      -- Nested loop header: compile as CatLoop, then CONTINUE from its own
      -- resolved exit target (in the *enclosing* loop's own activeLoop
      -- context) instead of assuming the nested loop's completion always
      -- means "continue the enclosing loop" outright. A nested loop's exit
      -- can flow through real content (assigns, more branches) before
      -- rejoining the enclosing loop — mirroring 'compileBlock's own
      -- top-level loop-header handling, which already continues from
      -- 'exitBlockId' rather than hardcoding a bare no-op there (Plan 146
      -- Phase 2f: the previous bare 'CatInl' here silently dropped any such
      -- content, e.g. an outer loop's own per-iteration counter increment
      -- living in the block between the nested loop's exit and the
      -- enclosing loop's back-edge).
      let nestedExit = Map.findWithDefault
            (error "impossible: every element of 'headers' is resolved by computeAllLoopExits")
            blockId exits
          (innerBody, v1) = compileLoopBody ctx proc blockId visited headers exits (Just blockId)
          (afterOp, v2) = compileLoopBody ctx proc nestedExit v1 headers exits activeLoop
      in (afterOp . CatLoop innerBody, v2)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (CatInr, visited)
      Just block ->
        let assignsOp  = compileAssigns ctx (sbAssigns block)
            (termOp, v1) = compileLoopTerm ctx proc visited headers exits activeLoop (sbTerm block)
            rawResult = case assignsOp of
                       CatId -> termOp
                       _     -> termOp . assignsOp
            -- Plan 150: same tagging as compileBlock's "otherwise" arm, for
            -- merge points reached by 2+ predecessors inside a loop body.
            result = if Set.member blockId (ccMergePoints ctx)
                       then CatTagged blockId rawResult
                       else rawResult
        in (result, Map.insert blockId result v1)

-- | Convert an SSA value back to an Expr so it can be passed to @eval@.
ssaValToExpr :: SsaVal -> Expr
ssaValToExpr (SsaConst e)       = e
ssaValToExpr (SsaVarRef sv)     = ExLvalue (Lvalue [LvSegment (svName sv) Nothing])
ssaValToExpr (SsaBinOp op l r)  = ExBinOp (ssaValToExpr l) op (ssaValToExpr r)
ssaValToExpr (SsaNot v)         = ExNot (ssaValToExpr v)
ssaValToExpr SsaNull            = ExNull

-- | Standard terminators (outside loops).
-- Returns @(CatOp, updatedMemo)@ to thread the global memo (see 'compileBlock').
compileTerm :: CompileCtx -> SsaProc -> Map.Map Text (CatOp () ()) -> Set.Set Text -> Map.Map Text Text
            -> Maybe Text -> SsaTerm -> (CatOp () (), Map.Map Text (CatOp () ()))
compileTerm _ctx _proc memo _headers _exits _activeLoop (SsaReturn _) = (CatId, memo)
compileTerm ctx proc memo headers exits activeLoop (SsaGoto target) =
  compileBlock ctx proc target memo headers exits activeLoop
compileTerm ctx proc memo headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, m1) = compileBlock ctx proc t memo headers exits activeLoop
      (fOp, m2) = compileBlock ctx proc f m1 headers exits activeLoop
      combined  = branch (ssaValToExpr cond) tOp fOp
  in (combined, m2)
compileTerm _ctx _proc memo _ _ _ SsaBreak    = (CatId, memo)
compileTerm _ctx _proc memo _ _ _ SsaContinue = (CatId, memo)
compileTerm ctx proc memo headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let seed = compileBlock ctx proc defaultTarget memo headers exits activeLoop
      step (val, target) (accOp, m) =
        let (targetOp, m') = compileBlock ctx proc target m headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branch cond targetOp accOp, m')
  in foldr step seed pairs

-- | Loop terminators. Returns @(CatOp () (Either () ()), visited)@.
compileLoopTerm :: CompileCtx -> SsaProc -> Map.Map Text (CatOp () (Either () ())) -> Set.Set Text -> Map.Map Text Text
                -> Maybe Text -> SsaTerm -> (CatOp () (Either () ()), Map.Map Text (CatOp () (Either () ())))
compileLoopTerm ctx proc visited headers exits activeLoop (SsaGoto target)
  | Just target == activeLoop = (CatInl, visited)
  | isLoopExit headers exits proc activeLoop target = (CatInr, visited)
  | otherwise = compileLoopBody ctx proc target visited headers exits activeLoop
compileLoopTerm ctx proc visited headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, v1) = compileLoopBranchPath ctx proc t visited headers exits activeLoop
      (fOp, v2) = compileLoopBranchPath ctx proc f v1 headers exits activeLoop
      combined  = branch (ssaValToExpr cond) tOp fOp
  in (combined, v2)
compileLoopTerm _ctx _proc visited _ _ _ (SsaReturn _) = (CatReturn, visited)
compileLoopTerm _ctx _proc visited _ _ _ SsaBreak      = (CatInr, visited)
compileLoopTerm _ctx _proc visited _ _ _ SsaContinue   = (CatInl, visited)
compileLoopTerm ctx proc visited headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let seed = compileLoopBranchPath ctx proc defaultTarget visited headers exits activeLoop
      step (val, target) (accOp, v) =
        let (targetOp, v') = compileLoopBranchPath ctx proc target v headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branch cond targetOp accOp, v')
  in foldr step seed pairs

-- | Compile a branch target inside a loop, wrapping in the appropriate Either.
compileLoopBranchPath :: CompileCtx -> SsaProc -> Text -> Map.Map Text (CatOp () (Either () ())) -> Set.Set Text -> Map.Map Text Text
                      -> Maybe Text -> (CatOp () (Either () ()), Map.Map Text (CatOp () (Either () ())))
compileLoopBranchPath ctx proc target visited headers exits activeLoop
  | Just target == activeLoop = (CatInl, visited)
  | isLoopExit headers exits proc activeLoop target = (CatInr, visited)
  | otherwise = compileLoopBody ctx proc target visited headers exits activeLoop

-- | Check if a target block is outside the current loop cycle.
-- A block is a loop exit if it is not part of the loop body.
--
-- A target whose own terminator is 'SsaReturn' is never treated as a loop
-- exit (Plan 146 Phase 2i), regardless of 'computeLoopBodyBlocks' membership
-- — it always recurses into 'compileLoopBody' so its own 'SsaReturn'
-- reaches 'compileLoopTerm's 'CatReturn' case (a true procedure-terminal
-- escape) instead of being treated as 'CatInr' (break). This only applies
-- when the target *itself* terminates in 'SsaReturn' — a block that merely
-- forwards to one (e.g. a loop's own ordinary exit edge, which may lead,
-- after further gotos, to the procedure's final implicit return) is
-- deliberately left to the normal body-membership check below, since
-- folding it in here caused a real regression (@w_regedit::itempopulate@):
-- treating such a forwarding block as "not an exit" made 'compileLoopBody'
-- try to recompile a block an *outer*, non-loop branch had already compiled
-- and memoized, landing on a stale placeholder that turned the loop's real
-- exit into a self-referencing infinite loop. See 'canReach's own comment
-- for the full history (Phase 2g → 2i → this fix).
isLoopExit :: Set.Set Text -> Map.Map Text Text -> SsaProc -> Maybe Text -> Text -> Bool
isLoopExit _ _ _ Nothing _ = False
isLoopExit _headers _exits proc (Just _headerId) targetId
  | Just block <- Map.lookup targetId (spBlocks proc), SsaReturn _ <- sbTerm block = False
isLoopExit headers exits proc (Just headerId) targetId =
  let bodyBlocks = computeLoopBodyBlocks headers exits proc headerId
  in not (Set.member targetId bodyBlocks)

-- | Compile a list of SSA assignments by folding with CatCompose.
-- Composes right-to-left so the first assign executes first.
compileAssigns :: CompileCtx -> [SsaAssign] -> CatOp () ()
compileAssigns _ctx [] = CatId
compileAssigns ctx [a] = compileAssign ctx a
compileAssigns ctx (a:as) = compileAssigns ctx as . compileAssign ctx a

-- | Compile a single SSA assignment.
-- The "_" target is the synthetic discard variable 'PB.Analysis.SSA.stmtToAssigns'
-- uses for statement-position calls with no captured result (@BsCall@/@BsPbCall@) —
-- only those go through call classification and emit a bare 'CatCall'/'CatSuspend'.
-- Any real variable target (@x = f()@ / @x = obj.method()@) always becomes
-- @CatAssignWithRhs "x" expr@ instead, matching 'PB.Analysis.InstrGraph'\'s old
-- compiler: it never special-cases a call RHS on 'BsAssign' (its 'InstrCall'
-- 'clResult' field, seemingly meant for this, is declared but never set to
-- anything but 'Nothing' anywhere) — it always emits one plain 'InstrAssign'
-- embedding the whole call expression in 'anRhs', suspend or not. Special-casing
-- the "_" target too used to silently drop the assignment target entirely for
-- @x = f()@ (Plan 145 Phase 1B re-sample Finding B).
--
-- Both this and 'ssaValToExpr'\'s 'SsaVarRef' case use 'svName' (the plain PB
-- variable name — 'PB.Analysis.SSA.SsaVar' carries nothing else since Plan
-- 155 F1 deleted its old SSA-version field): an imperative execution model
-- only ever has one mutable slot per real variable, and the old compiler
-- never renamed at all. An earlier revision of this code rendered a
-- version-suffixed name (e.g. \"x_1\") here instead, which leaked into the
-- observable trace/final-env — a divergence the Plan 145 shape oracle
-- couldn't see (it never compares variable names) but Plan 146's trace
-- oracle does — confirmed the dominant remaining bug class
-- (~70% of the OpenPay --dual-trace corpus diffs) via direct hand-trace of
-- @m_misth_final_details_list::create@ (Plan 146 Phase 2c).
compileAssign :: CompileCtx -> SsaAssign -> CatOp () ()
compileAssign ctx (SsaAssign sv rhs)
  | svName sv == "_" = case rhs of
      SsaConst expr@(ExCall lv rawArgs) ->
        let parsedArgs = map parseArgList rawArgs
        in compileCallExpr ctx sv expr lv parsedArgs
      -- Delegates the callee name entirely to 'calleeName' (Plan 146 Phase
      -- 2i): this arm used to special-case an 'ExCall' receiver as
      -- @lvHead rlv <> "." <> meth@ (e.g. "ParentWindow" for a chained
      -- @ParentWindow.GetActiveSheet().TriggerEvent(...)@ call), which
      -- diverged from 'calleeName's reference behaviour of falling back to
      -- @"?." <> meth@ for any receiver that isn't a plain 'ExLvalue' —
      -- confirmed via direct hand-trace of a real corpus diff
      -- (@m_graph::clicked@ and 4 sibling on-clicked handlers in the same
      -- file, all sharing this exact chained-call idiom).
      SsaConst expr@(ExMethodCall _recv _meth rawArgs) ->
        let parsedArgs = map parseArgList rawArgs
        in case classifyExpr (ccEnv ctx) expr of
             SuspendCall -> CatSuspend (effectName expr parsedArgs) parsedArgs
             PureCall    -> CatCall (calleeName expr) parsedArgs
      -- Any other call-shaped statement (e.g. ExDispatch: standalone
      -- `.Post`/`.Trigger`/`Dynamic ... Event(...)`, PB's inter-object
      -- messaging idiom) must still classify as a bare call rather than
      -- falling through to CatAssignWithRhs below — that produced a real
      -- InstrAssign{anVar="_"} node instead of a call/dispatch node (Plan 145).
      -- Mirrors PB.Analysis.InstrGraph's BsCall `otherwise` branch, which
      -- calls classifyExpr/calleeName generically regardless of expr shape
      -- (both default to PureCall/"?" for anything that isn't ExCall/
      -- ExMethodCall — matching the old compiler exactly, not improving on
      -- it, since that's this fix's confirmed reference behaviour).
      --
      -- Audited under Plan 146 Phase 4: this `SsaConst expr` arm is a
      -- deliberate wildcard over every remaining Expr constructor (ExBool,
      -- ExLvalue, ExBinOp, ExRaw, ...), not an oversight — a discard-target
      -- assign's classification doesn't depend on which of those shapes the
      -- RHS is, so there is no per-constructor behavior to enumerate here.
      SsaConst expr ->
        case classifyExpr (ccEnv ctx) expr of
          SuspendCall -> CatSuspend (effectName expr []) []
          PureCall    -> CatCall (calleeName expr) []
      -- Non-SsaConst RHS values can't arise from a "_"-targeted assign in
      -- practice — 'stmtToAssigns' only ever builds one for BsCall/BsPbCall,
      -- both always 'SsaConst' — but SsaVal has just 5 constructors, so
      -- listed explicitly (Plan 146 Phase 4) rather than behind a wildcard:
      -- a future SsaVal addition now trips -Wincomplete-patterns here
      -- instead of silently falling through to CatAssignWithRhs.
      SsaVarRef _ -> CatAssignWithRhs (svName sv) (ssaValToExpr rhs)
      SsaBinOp {} -> CatAssignWithRhs (svName sv) (ssaValToExpr rhs)
      SsaNot _    -> CatAssignWithRhs (svName sv) (ssaValToExpr rhs)
      SsaNull     -> CatAssignWithRhs (svName sv) (ssaValToExpr rhs)
  | otherwise = CatAssignWithRhs (svName sv) (ssaValToExpr rhs)

-- | Shared logic for compiling an ExCall expression: classify and emit CatCall.
compileCallExpr :: CompileCtx -> SsaVar -> Expr -> Lvalue -> [Expr] -> CatOp () ()
compileCallExpr ctx _sv expr lv parsedArgs
  | isTriggerEvent lv =
      CatCall "triggerevent" [evArg]
  -- fn_retrievechild(adw, "col", sqlParam): the datawindow control and
  -- column name are already encoded in the effect name itself
  -- ("retrieve:child_<col>:<dwCtrl>", via 'effectName'), so only the third
  -- argument (the bound variable) belongs in the suspend's traced args —
  -- mirrors 'PB.Analysis.InstrGraph's identical special case exactly
  -- (Plan 146 Phase 2i: this arm didn't exist here at all, so the generic
  -- 'otherwise' branch below passed all 3 parsed args through instead of
  -- just the third; confirmed via hand-trace of a real corpus diff,
  -- @wiz_misth_final_details_step1::of_stepadded@ and 3 sibling wizard-step
  -- handlers).
  | [seg] <- segments lv
  , T.toLower (segName seg) == "fn_retrievechild" =
      CatSuspend (effectName expr parsedArgs) paramArg
  | [seg] <- segments lv
  , T.toLower (segName seg) `Set.member` ccUserFns ctx =
      CatCall (segName seg) parsedArgs
  | otherwise = case classifyExpr (ccEnv ctx) expr of
      SuspendCall -> CatSuspend (effectName expr parsedArgs) parsedArgs
      PureCall -> CatCall (calleeName expr) parsedArgs
  where
    evArg = case parsedArgs of { (a:_) -> a; [] -> ExRaw [] }
    paramArg = case parsedArgs of { (_:_:p:_) -> [p]; _ -> [] }
