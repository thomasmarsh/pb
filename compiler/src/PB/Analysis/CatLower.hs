{-# LANGUAGE StrictData #-}
-- | Loop/merge-point analysis shared by the SSA → 'Eff' lowering pass
-- ('PB.Analysis.CatLowerEff').
--
-- Pure module — no I/O. Takes a 'SsaProc' (already in SSA form — see
-- 'PB.Analysis.SSA') and computes the loop-header/merge-point/loop-exit
-- structure 'PB.Analysis.CatLowerEff.compileSsaToEff' needs to lower it —
-- all of Plan 144's loop-nesting machinery and most of Plan 146's
-- correctness fixes live here. Split out of 'PB.Analysis.CatOp' in Plan
-- 151, alongside 'PB.Analysis.CatInterp' (direct execution) and
-- 'PB.Analysis.GraphBuilder' (flattening to 'InstrGraph').
module PB.Analysis.CatLower
  ( CompileCtx (..)
  , computeMergePoints
  , computeLoopHeaders
  , computeLoopNestParents
  , computeAllLoopExits
  , computeLoopBodyBlocks
  , discoverReachable
  , canReach
  , determineLoopExitTarget
  , isLoopExit
  , termSuccessors
  , ssaValToExpr
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import Data.List (sortOn)
import PB.AST.Expr (Expr (..), LvSegment (..), Lvalue (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Analysis.SSA (SsaVar (..), SsaVal (..), SsaBlock (..),
                         SsaTerm (..), SsaProc (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- | Compilation context threaded through all SSA→'Eff' lowering helpers
-- ('PB.Analysis.CatLowerEff').
data CompileCtx = CompileCtx
  { ccEnv         :: ScopedTypeEnv    -- ^ Type environment for call classification
  , ccUserFns     :: Set.Set Text     -- ^ User-defined function names (lower-cased)
  , ccMergePoints :: Set.Set Text
    -- ^ BlockIds reached by 2+ predecessor edges anywhere in the procedure
    -- (Plan 150). The only blocks 'PB.Analysis.CatLowerEff.compileBlockToEff'/
    -- 'compileLoopBodyToEff' can ever return via their memo's cache-hit
    -- branch — i.e. the only ones a second predecessor can reach the same
    -- compiled 'PB.Analysis.CatOp.Eff' value for — so the only ones that
    -- need an 'PB.Analysis.CatOp.ELetRef' identity for the table-native
    -- fold to physically share downstream instead of re-lowering (and
    -- re-allocating a full duplicate subterm) on every encounter.
  }

-- | BlockIds reached by 2 or more predecessor edges in a procedure's CFG,
-- counting every terminator's successors (top-level and loop-body blocks
-- alike — a merge inside a loop body needs the same treatment as one at
-- the top level) — EXCLUDING loop headers. See 'ccMergePoints'.
--
-- A loop header always has 2+ predecessors (the initial forward entry, plus
-- at least one back-edge), so a naive predecessor count always flags it —
-- but a header is never actually at risk of the physical-duplication bug
-- this tagging exists to fix: the loop-lowering machinery
-- (@compileLowCatToInstrNamed@'s @LLoop@ clause in
-- "PB.Analysis.GraphBuilder") lowers a loop's header content exactly once,
-- as the sole argument to 'CatLoop', never embedded at a second tree
-- position. Tagging it anyway broke @patchLoopHeaderNamed@'s @LCompose
-- (LFanIn ..) ..@ structural detection (it doesn't unwrap 'LTagged'), which
-- silently fell back to its unpatched-forwarding-'InstrNop' path — and,
-- worse, mis-threaded the loop's own back-edge, causing loops to stop
-- after one iteration. Confirmed via the regression this caused in the
-- loop test suite (Plan 150 Phase 3).
computeMergePoints :: SsaProc -> Set.Set Text
computeMergePoints proc =
  Map.keysSet (Map.filter (P.> 1) predCounts) `Set.difference` computeLoopHeaders proc
  where
    allSuccessors = concatMap (termSuccessors P.. sbTerm) (Map.elems (spBlocks proc))
    predCounts    = Map.fromListWith (P.+) [ (bid, 1 :: Int) | bid <- allSuccessors ]

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

-- | Convert an already-compiled SSA value expression back into a source
-- 'Expr' (for embedding a condition/rhs directly in a lowered term).
ssaValToExpr :: SsaVal -> Expr
ssaValToExpr (SsaConst e)       = e
ssaValToExpr (SsaVarRef sv)     = ExLvalue (Lvalue [LvSegment (svName sv) Nothing])
ssaValToExpr (SsaBinOp op l r)  = ExBinOp (ssaValToExpr l) op (ssaValToExpr r)
ssaValToExpr (SsaNot v)         = ExNot (ssaValToExpr v)
ssaValToExpr SsaNull            = ExNull

-- | Is @targetId@ an exit out of the loop headed by @headerId@ (or not
-- inside a loop at all)? A return-terminated target is never a loop exit
-- in the branch sense (it is its own terminal, handled separately).
isLoopExit :: Set.Set Text -> Map.Map Text Text -> SsaProc -> Maybe Text -> Text -> Bool
isLoopExit _ _ _ Nothing _ = False
isLoopExit _headers _exits proc (Just _headerId) targetId
  | Just block <- Map.lookup targetId (spBlocks proc), SsaReturn _ <- sbTerm block = False
isLoopExit headers exits proc (Just headerId) targetId =
  let bodyBlocks = computeLoopBodyBlocks headers exits proc headerId
  in not (Set.member targetId bodyBlocks)

