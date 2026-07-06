{-# LANGUAGE StrictData #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-inaccessible-code -Wno-overlapping-patterns #-}
-- | Categorical combinator GADT for PB procedure compilation.
--
-- Pure module — no I/O.  The 'CatOp' type is the initial algebra
-- implementing 'Category', 'Cartesian', 'Cocartesian', and 'Effectful'.
--
-- Compilation is polymorphic in the target category @k@:
--
--   * 'GraphBuilder' — flat CpsGraph (current TS runtime)
--   * 'WasmBuilder'  — WASM structured control flow (future)
--   * 'Interp'       — direct Haskell execution (testing)
--
-- Design: Monadic Freer Category with SSA variables.
-- After SSA, variables are immutable, so 'CatLookup' is a static
-- offset lookup (no dynamic string table).  'CatAssign' takes
-- @(env, Value) → env@, making the environment type active.
--
-- Branching is NOT a GADT constructor.  It is derived universally
-- from 'eval' + '(|||)': @branch cond t f = (t ||| f) . condToEither . eval cond@.
-- This eliminates redundant semantic opcodes.
module PB.Analysis.CatOp
  ( -- * Typeclasses
    Category (..)
  , Cartesian (..)
  , Cocartesian (..)
  , Effectful (..)
    -- * GADT
  , CatOp (..)
    -- * Derived combinators
  , branch
    -- * SSA → CatOp compilation
  , compileSsa
  , compileProcedureViaCatOp
  , CompileCtx (..)
    -- * LowCat intermediary
  , LowCat (..)
  , toLowCat
  , extractCondLowCat
    -- * GraphBuilder (Phase 4)
  , GraphBuilder (..)
  , BuilderState (..)
  , initState
  , allocateNode
  , peekNextPc
  , registerNodeAt
  , finalizeGraph
  , compileCatToCps
  , buildCpsGraph
  , CpsNode (..)
  , CpsGraph (..)
    -- * Interpreter
  , Interp (..)
  , InterpState (..)
  , ReturnUnwind (..)
  , runInterpIO
  , runCat
    -- * Interpreter loop
  , interpretLoop
    -- * Placeholder types
  , Value (..)
  , TraceEvent (..)
  , MockResponses
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import Data.List (sortOn)
import Unsafe.Coerce (unsafeCoerce)
import PB.AST.Expr (Expr (..), LvSegment (..), Lvalue (..), BinOp (BopEq))
import PB.Analysis.CatEval (Value (..), TraceEvent (..), MockResponses, evalExprMocked)
import PB.Analysis.CpsCompile (CpsNode (..), CpsGraph (..), parseArgList, collectBodyLocals)
import PB.Analysis.CallClassify (CallKind (..), classifyExpr, effectName, calleeName, isTriggerEvent, segName)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import Control.Monad.State.Strict (State, StateT, get, modify, modify', gets, runState, evalStateT)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (Exception, throwIO)
import PB.AST.BodyStmt     (BodyStmt)
import PB.AST.Located      (Located (..))
import PB.Analysis.SSA (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                         SsaTerm (..), SsaPhi (..), SsaProc (..), buildSsa)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

-- ============================================================================
-- 1b. LowCat: Monomorphic Categorical Intermediate Representation
-- ============================================================================

-- | A type-safe, untyped bridge between the GADT-indexed 'CatOp' and the
-- flat 'CpsGraph'.  Strips all existential type parameters so that pattern
-- matching is deterministic — no 'unsafeCoerce' needed.
data LowCat
  = LId
  | LCompose LowCat LowCat
  | LAssignWithRhs Text Expr
  | LFanIn LowCat LowCat
  | LLoop LowCat
  | LInl
  | LInr
  | LSplitValue
  | LEval Expr
  | LFork LowCat LowCat
  | LCall Text [Expr]
  | LSuspend Text [Expr]
  | LReturn
  | LTagged Text LowCat
  | LErasable
  deriving (Eq, Show, Generic)

-- | Lower a typed 'CatOp' to an untyped 'LowCat'.  Pure structural
-- traversal — no 'unsafeCoerce', no runtime type inspection.
toLowCat :: CatOp a b -> LowCat
toLowCat CatId              = LId
toLowCat (CatAssignWithRhs v e) = LAssignWithRhs v e
toLowCat (CatCompose g f)   = LCompose (toLowCat g) (toLowCat f)
toLowCat (CatFanIn t f)     = LFanIn (toLowCat t) (toLowCat f)
toLowCat (CatLoop body)     = LLoop (toLowCat body)
toLowCat CatInl             = LInl
toLowCat CatInr             = LInr
toLowCat CatSplitValue      = LSplitValue
toLowCat (CatEval e)        = LEval e
toLowCat (CatFork l r)      = LFork (toLowCat l) (toLowCat r)
toLowCat (CatCall n args)   = LCall n args
toLowCat (CatSuspend e args) = LSuspend e args
toLowCat CatReturn          = LReturn
toLowCat (CatTagged bid f)  = LTagged bid (toLowCat f)
toLowCat _                  = LErasable  -- CatExl, CatExr, CatConst, CatLookup, CatAssign, CatTry

-- ============================================================================
-- 2. Core Typeclasses
-- ============================================================================

-- | The base category: sequential composition.
class Category k where
  id  :: k a a
  infixr 9 .
  (.) :: k b c -> k a b -> k a c

-- | Cartesian category: products for variable bindings and tuples.
class Category k => Cartesian k where
  exl   :: k (a, b) a
  exr   :: k (a, b) b
  (&&&) :: k a b -> k a c -> k a (b, c)

-- | Cocartesian category: sums for branching and choice.
class Category k => Cocartesian k where
  inl   :: k a (Either a b)
  inr   :: k b (Either a b)
  (|||) :: k a c -> k b c -> k (Either a b) c

-- | Effectful category: PB-specific operations.
-- Separates pure structural routing from imperative side effects.
class Category k => Effectful k where
  eval       :: Expr -> k env Value
  assign     :: Text -> k (env, Value) env
  lookup     :: Text -> k env Value
  suspend    :: Text -> [Expr] -> k args ()
  callProc   :: Text -> [Expr] -> k args ()
  splitValue :: k (env, Value) (Either env env)

-- ============================================================================
-- 2. Derived Combinators
-- ============================================================================

-- | Universal categorical branching.
-- Evaluates a condition, keeps the environment context, and forks.
--
-- @branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)@
branch :: (Effectful k, Cartesian k, Cocartesian k) => Expr -> k env b -> k env b -> k env b
branch cond thenK elseK = (thenK ||| elseK) . splitValue . (id &&& eval cond)

-- ============================================================================
-- 3. The GADT: Initial Algebra
-- ============================================================================

-- | The initial algebra implementing the category interfaces for PB.
--
-- After SSA, variables are immutable definitions.  'CatLookup' resolves
-- a variable name to its SSA version (a static offset).  'CatAssign'
-- takes @(env, Value) → env@, threading the environment state.
--
-- Control flow:
--   * 'CatLoop' — iteration: body returns @Either a b@ (Left = continue, Right = break)
--   * 'CatInl'/'CatInr'/'CatFanIn' — coproduct injection and join (phi nodes)
--
-- Branching is NOT a constructor — it is derived via the @branch@ combinator.
data CatOp a b where
  -- Core Category
  CatId      :: CatOp a a
  CatCompose :: CatOp b c -> CatOp a b -> CatOp a c

  -- Cartesian (products for environment routing)
  CatFork    :: CatOp a b -> CatOp a c -> CatOp a (b, c)
  CatExl     :: CatOp (a, b) a
  CatExr     :: CatOp (a, b) b
  CatConst   :: Expr -> CatOp a Value

  -- Cocartesian (sums for branching / phi nodes)
  CatInl     :: CatOp a (Either a b)
  CatInr     :: CatOp b (Either a b)
  CatFanIn   :: CatOp a c -> CatOp b c -> CatOp (Either a b) c

  -- State Mutation (principled imperative variables)
  CatAssign       :: Text -> CatOp (env, Value) env
  CatAssignWithRhs :: Text -> Expr -> CatOp env env
  CatLookup       :: Text -> CatOp env Value

  -- Loops (via coproduct: Left = continue, Right = break)
  CatLoop    :: CatOp a (Either a b) -> CatOp a b

  -- | True procedure-terminal return (Plan 146 Phase 2i). Polymorphic in
  -- both type parameters, like 'error' — it never actually produces a
  -- value for its composition context. Unlike 'CatInr' (break), which
  -- resumes at whatever follows the *enclosing* 'CatLoop', 'CatReturn'
  -- unconditionally jumps to the true end of the whole procedure,
  -- bypassing every enclosing loop's break/post-loop continuation. Needed
  -- because 'CatLoop's own type (@CatOp a (Either a b) -> CatOp a b@) has
  -- no third state to distinguish "break" from "return" once a loop body
  -- is compiled — both used to collapse to the same 'CatInr', silently
  -- turning a 'return' inside a loop into a 'break'.
  CatReturn  :: CatOp a b

  -- Effects
  CatEval       :: Expr -> CatOp env Value
  CatCall       :: Text -> [Expr] -> CatOp args ()
  CatSuspend    :: Text -> [Expr] -> CatOp args ()
  CatSplitValue :: CatOp (env, Value) (Either env env)

  -- Error handling
  CatTry     :: CatOp a b -> CatOp (a, Value) b -> CatOp a b

  -- | Marks a subterm as the memoized compiled value of a specific SSA
  -- blockId (Plan 150). Identity in both types and execution (see 'runCat'
  -- and 'toLowCat') — its only purpose is to survive being embedded at
  -- multiple positions in the tree (once per predecessor of a merge block)
  -- so 'GraphBuilder' can recognize a repeat encounter of the same blockId
  -- and reuse the already-allocated pc instead of re-lowering (and
  -- re-allocating a full duplicate subgraph for) the same content again.
  CatTagged  :: Text -> CatOp a b -> CatOp a b

-- Manual Show instance (GADTs can't derive)
instance Show (CatOp a b) where
  show CatId = "CatId"
  show (CatCompose _ _) = "CatCompose .."
  show (CatFork _ _) = "CatFork .."
  show CatExl = "CatExl"
  show CatExr = "CatExr"
  show (CatConst _) = "CatConst .."
  show CatInl = "CatInl"
  show CatInr = "CatInr"
  show CatReturn = "CatReturn"
  show (CatFanIn _ _) = "CatFanIn .."
  show (CatAssign t) = "CatAssign " <> show t
  show (CatAssignWithRhs t e) = "CatAssignWithRhs " <> show t <> " " <> show e
  show (CatLookup t) = "CatLookup " <> show t
  show (CatLoop _) = "CatLoop .."
  show (CatEval _) = "CatEval .."
  show (CatCall t _) = "CatCall " <> show t
  show (CatSuspend t _) = "CatSuspend " <> show t
  show CatSplitValue = "CatSplitValue"
  show (CatTry _ _) = "CatTry .."
  show (CatTagged t _) = "CatTagged " <> show t <> " .."

-- Manual Eq instance (GADTs can't derive).
-- Delegates to feq which does the coercion + structural matching.
instance Eq (CatOp a b) where
  x == y = feq x y

-- | Structural equality across type parameters.
-- Coerces to CatOp () () and pattern-matches.  Children are compared
-- via feq (not go) to avoid infinite recursion: go does the matching,
-- feq does the coercion.
feq :: CatOp a b -> CatOp a' b' -> Bool
feq x y = go (unsafeCoerce x) (unsafeCoerce y)
  where
    -- All constructors matched because unsafeCoerce can create any constructor
    -- at the CatOp () () type level, regardless of original type constraints.
    go :: CatOp () () -> CatOp () () -> Bool
    go CatId CatId = True
    go (CatCompose f g) (CatCompose f' g') = feq f f' P.&& feq g g'
    go (CatFork f g) (CatFork f' g') = feq f f' P.&& feq g g'
    go CatExl CatExl = True
    go CatExr CatExr = True
    go (CatConst e) (CatConst e') = e == e'
    go CatInl CatInl = True
    go CatInr CatInr = True
    go CatReturn CatReturn = True
    go (CatFanIn f g) (CatFanIn f' g') = feq f f' P.&& feq g g'
    go (CatAssign t) (CatAssign t') = t == t'
    go (CatAssignWithRhs t e) (CatAssignWithRhs t' e') = t == t' P.&& e == e'
    go (CatLookup t) (CatLookup t') = t == t'
    go (CatLoop f) (CatLoop f') = feq f f'
    go (CatEval e) (CatEval e') = e == e'
    go (CatCall t es) (CatCall t' es') = t == t' && es == es'
    go (CatSuspend t es) (CatSuspend t' es') = t == t' && es == es'
    go CatSplitValue CatSplitValue = True
    go (CatTry f g) (CatTry f' g') = feq f f' P.&& feq g g'
    go (CatTagged t f) (CatTagged t' f') = t == t' P.&& feq f f'
    go _ _ = False

-- ============================================================================
-- 4. CatOp Instances
-- ============================================================================

instance Category CatOp where
  id  = CatId
  (.) = CatCompose

instance Cartesian CatOp where
  exl = CatExl
  exr = CatExr
  (&&&) = CatFork

instance Cocartesian CatOp where
  inl   = CatInl
  inr   = CatInr
  (|||) = CatFanIn

instance Effectful CatOp where
  eval       = CatEval
  assign     = CatAssign
  lookup     = CatLookup
  suspend    = CatSuspend
  callProc   = CatCall
  splitValue = CatSplitValue

-- ============================================================================
-- 5. SSA → CatOp Compilation
-- ============================================================================

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
-- unpatched-forwarding-'CpsNop' path — and, worse, mis-threaded the loop's
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
-- direct 'CpsGraph' inspection of the real corpus regression,
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
            (termOp, memo1) = compileTerm ctx proc blockId memo headers exits activeLoop (sbTerm block)
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
            (termOp, v1) = compileLoopTerm ctx proc blockId visited headers exits activeLoop (sbTerm block)
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

-- | Emit named assignments for any Phi nodes requiring resolution
-- when transitioning from @prevBlock@ into @currentBlock@.
compilePhiAssignments :: CompileCtx -> SsaProc -> Text -> Text -> CatOp () ()
compilePhiAssignments ctx proc prevBlock currentBlock =
  case Map.lookup currentBlock (spPhis proc) of
    Nothing   -> CatId
    Just phis -> compileAssigns ctx (mapMaybe findMatchingSource phis)
  where
    findMatchingSource phi =
      case [ sv | (src, sv) <- spSources phi, src == prevBlock ] of
        (sourceVar : _) -> Just (SsaAssign (spResult phi) (SsaVarRef sourceVar))
        []              -> Nothing

-- | Standard terminators (outside loops). Injects phi resolution before target blocks.
-- Returns @(CatOp, updatedMemo)@ to thread the global memo (see 'compileBlock').
compileTerm :: CompileCtx -> SsaProc -> Text -> Map.Map Text (CatOp () ()) -> Set.Set Text -> Map.Map Text Text
            -> Maybe Text -> SsaTerm -> (CatOp () (), Map.Map Text (CatOp () ()))
compileTerm _ctx _proc _blockId memo _headers _exits _activeLoop (SsaReturn _) = (CatId, memo)
compileTerm ctx proc blockId memo headers exits activeLoop (SsaGoto target) =
  let (targetOp, m1) = compileBlock ctx proc target memo headers exits activeLoop
  in (targetOp . compilePhiAssignments ctx proc blockId target, m1)
compileTerm ctx proc blockId memo headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, m1) = compileBlock ctx proc t memo headers exits activeLoop
      (fOp, m2) = compileBlock ctx proc f m1 headers exits activeLoop
      combined  = branch (ssaValToExpr cond)
                    (tOp . compilePhiAssignments ctx proc blockId t)
                    (fOp . compilePhiAssignments ctx proc blockId f)
  in (combined, m2)
compileTerm _ctx _proc _ memo _ _ _ SsaBreak    = (CatId, memo)
compileTerm _ctx _proc _ memo _ _ _ SsaContinue = (CatId, memo)
compileTerm ctx proc blockId memo headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let (defaultOp, m0) = compileBlock ctx proc defaultTarget memo headers exits activeLoop
      seed = (defaultOp . compilePhiAssignments ctx proc blockId defaultTarget, m0)
      step (val, target) (accOp, m) =
        let (targetOp, m') = compileBlock ctx proc target m headers exits activeLoop
            combined = targetOp . compilePhiAssignments ctx proc blockId target
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branch cond combined accOp, m')
  in foldr step seed pairs

-- | Loop terminators. Returns @(CatOp () (Either () ()), visited)@.
compileLoopTerm :: CompileCtx -> SsaProc -> Text -> Map.Map Text (CatOp () (Either () ())) -> Set.Set Text -> Map.Map Text Text
                -> Maybe Text -> SsaTerm -> (CatOp () (Either () ()), Map.Map Text (CatOp () (Either () ())))
compileLoopTerm ctx proc blockId visited headers exits activeLoop (SsaGoto target)
  | Just target == activeLoop = (CatInl, visited)
  | isLoopExit headers exits proc activeLoop target = (CatInr, visited)
  | otherwise =
      let (targetOp, v1) = compileLoopBody ctx proc target visited headers exits activeLoop
      in (targetOp . compilePhiAssignments ctx proc blockId target, v1)
compileLoopTerm ctx proc blockId visited headers exits activeLoop (SsaBranch cond t f) =
  let (tOp, v1) = compileLoopBranchPath ctx proc blockId t visited headers exits activeLoop
      (fOp, v2) = compileLoopBranchPath ctx proc blockId f v1 headers exits activeLoop
      combined  = branch (ssaValToExpr cond) tOp fOp
  in (combined, v2)
compileLoopTerm _ctx _proc _ visited _ _ _ (SsaReturn _) = (CatReturn, visited)
compileLoopTerm _ctx _proc _ visited _ _ _ SsaBreak      = (CatInr, visited)
compileLoopTerm _ctx _proc _ visited _ _ _ SsaContinue   = (CatInl, visited)
compileLoopTerm ctx proc blockId visited headers exits activeLoop (SsaSwitch scrutinee pairs defaultTarget) =
  let (defaultOp, v0) = compileLoopBranchPath ctx proc blockId defaultTarget visited headers exits activeLoop
      step (val, target) (accOp, v) =
        let (targetOp, v') = compileLoopBranchPath ctx proc blockId target v headers exits activeLoop
            cond = ExBinOp (ssaValToExpr scrutinee) BopEq (ssaValToExpr val)
        in (branch cond targetOp accOp, v')
  in foldr step (defaultOp, v0) pairs

-- | Compile a branch target inside a loop, wrapping in the appropriate Either.
compileLoopBranchPath :: CompileCtx -> SsaProc -> Text -> Text -> Map.Map Text (CatOp () (Either () ())) -> Set.Set Text -> Map.Map Text Text
                      -> Maybe Text -> (CatOp () (Either () ()), Map.Map Text (CatOp () (Either () ())))
compileLoopBranchPath ctx proc prevBlock target visited headers exits activeLoop
  | Just target == activeLoop = (CatInl, visited)
  | isLoopExit headers exits proc activeLoop target = (CatInr, visited)
  | otherwise =
      let (targetOp, v1) = compileLoopBody ctx proc target visited headers exits activeLoop
      in (targetOp . compilePhiAssignments ctx proc prevBlock target, v1)

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
-- @CatAssignWithRhs "x" expr@ instead, matching 'PB.Analysis.CpsCompile'\'s old
-- compiler: it never special-cases a call RHS on 'BsAssign' (its 'CpsCall'
-- 'clResult' field, seemingly meant for this, is declared but never set to
-- anything but 'Nothing' anywhere) — it always emits one plain 'CpsAssign'
-- embedding the whole call expression in 'anRhs', suspend or not. Special-casing
-- the "_" target too used to silently drop the assignment target entirely for
-- @x = f()@ (Plan 145 Phase 1B re-sample Finding B).
--
-- Both this and 'ssaValToExpr'\'s 'SsaVarRef' case use 'svName' (the plain PB
-- variable name), never 'renderSsaVar' (which appends the SSA version number,
-- e.g. \"x_1\"): the version number is an internal device for phi-node
-- placement during SSA construction, not part of the variable's real runtime
-- identity — the old compiler never renames at all, and an imperative
-- execution model only ever has one mutable slot per real variable regardless
-- of how many SSA versions it was split into. Using 'renderSsaVar' here leaked
-- the version suffix into the observable trace/final-env, a divergence the
-- Plan 145 shape oracle couldn't see (it never compares variable names) but
-- Plan 146's trace oracle does — confirmed the dominant remaining bug class
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
      -- CpsAssign{anVar="_"} node instead of a call/dispatch node (Plan 145).
      -- Mirrors PB.Analysis.CpsCompile's BsCall `otherwise` branch, which
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
  -- mirrors 'PB.Analysis.CpsCompile's identical special case exactly
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

-- ============================================================================
-- 6. GraphBuilder: CpsGraph Target (Phase 4 — backward chaining)
-- ============================================================================

-- | State for the graph builder.  Nodes are keyed by PC; allocation is sequential.
data BuilderState = BuilderState
  { bsNodes       :: Map.Map Int CpsNode
  , bsNextPc      :: Int
  , bsSourceLines :: [(Int, Int)]
  , bsExitPc      :: Int
    -- ^ The pc of the procedure's one true exit (the 'CpsReturn' node
    -- allocated first, in 'buildCpsGraph'). Fixed for the whole build
    -- regardless of loop nesting — 'LReturn' (Plan 146 Phase 2i) resolves
    -- here directly instead of whatever local @nextPc@ a loop's own
    -- break/post-loop threading passed in.
  , bsBlockPcMemo :: Map.Map (Text, Int) Int
    -- ^ Plan 150: (blockId, continuation pc) -> the pc already allocated
    -- the first time 'compileLowCatToCps' lowered a 'LTagged' node for this
    -- blockId with this continuation. A merge block is only ever tagged
    -- with the SAME blockId across every predecessor that reaches it, and
    -- (since all predecessors of a genuine merge converge on the same
    -- subsequent code) every encounter passes the same continuation pc —
    -- so keying on both together is safe and lets a repeat encounter reuse
    -- the existing pc instead of re-lowering (and re-allocating a full
    -- duplicate subgraph for) the same content again.
  }

-- | The graph builder monad.
newtype GraphBuilder a = GraphBuilder { runBuilder :: State BuilderState a }

instance Functor GraphBuilder where
  fmap f (GraphBuilder m) = GraphBuilder (fmap f m)

instance Applicative GraphBuilder where
  pure a = GraphBuilder (pure a)
  GraphBuilder f <*> GraphBuilder a = GraphBuilder (f <*> a)

instance Monad GraphBuilder where
  GraphBuilder m >>= f = GraphBuilder (m >>= (runBuilder P.. f))

-- | Get the next available PC without allocating.
peekNextPc :: GraphBuilder Int
peekNextPc = GraphBuilder (gets bsNextPc)

-- | Plan 150: look up a previously-lowered merge block's entry pc for this
-- exact (blockId, continuation) pair, if this is a repeat encounter.
lookupBlockPcMemo :: Text -> Int -> GraphBuilder (Maybe Int)
lookupBlockPcMemo bid nextPc = GraphBuilder (gets (Map.lookup (bid, nextPc) P.. bsBlockPcMemo))

-- | Plan 150: record a merge block's freshly-allocated entry pc so the next
-- encounter of the same (blockId, continuation) pair can reuse it.
registerBlockPcMemo :: Text -> Int -> Int -> GraphBuilder ()
registerBlockPcMemo bid nextPc pc = GraphBuilder $ modify $ \s ->
  s { bsBlockPcMemo = Map.insert (bid, nextPc) pc (bsBlockPcMemo s) }

-- | Allocate a node at the next available PC and return its PC.
allocateNode :: CpsNode -> GraphBuilder Int
allocateNode node = do
  pc <- peekNextPc
  GraphBuilder $ modify $ \s -> s { bsNextPc = bsNextPc s P.+ 1, bsNodes = Map.insert pc node (bsNodes s) }
  return pc

-- | Register a node at a specific PC (for patching, e.g. loop headers).
registerNodeAt :: Int -> CpsNode -> GraphBuilder ()
registerNodeAt pc node = GraphBuilder $ modify $ \s ->
  s { bsNodes = Map.insert pc node (bsNodes s) }

-- | Finalize: convert the node map to a sorted list for CpsGraph.
finalizeGraph :: Int -> BuilderState -> CpsGraph
finalizeGraph entryPc s = CpsGraph
  { cgNodes            = map P.snd (Map.toAscList (bsNodes s))
  , cgEntry            = entryPc
  , cgSuspensionPoints = []
  , cgSourceMap        = bsSourceLines s
  }

-- | Initial builder state.
initState :: BuilderState
initState = BuilderState { bsNodes = Map.empty, bsNextPc = 0, bsSourceLines = [], bsExitPc = 0, bsBlockPcMemo = Map.empty }

-- | Compile a CatOp into CPS nodes.
-- Lowers to 'LowCat' first (stripping GADT types), then compiles.
compileCatToCps :: CatOp a b -> Int -> GraphBuilder Int
compileCatToCps catOp nextPc = compileLowCatToCps (toLowCat catOp) nextPc

-- | Compile a 'LowCat' into CPS nodes using backward chaining.
-- Takes the continuation PC (where to jump after) and returns the entry PC.
-- All pattern matching is on plain constructors — no unsafeCoerce.
compileLowCatToCps :: LowCat -> Int -> GraphBuilder Int
compileLowCatToCps LId nextPc = return nextPc
compileLowCatToCps (LAssignWithRhs var expr) nextPc =
  allocateNode (CpsAssign { anVar = var, anRhs = expr, anNext = nextPc })
-- Branch pattern: intercept CatFanIn + condition before CatCompose tears them apart.
compileLowCatToCps (LCompose g f) nextPc = case inspectBranchLowCat g of
  Just (tOp, fOp) -> do
    -- No join CpsNop: both arms fall through directly to nextPc, matching the
    -- old compiler (PB.Analysis.CpsCompile never allocates a node purely to
    -- serve as a join point). See Plan 145 Finding A.
    let branchCond = extractCondLowCat f
    elseEntryPc <- compileLowCatToCps fOp nextPc
    thenEntryPc <- compileLowCatToCps tOp nextPc
    branchEntryPc <- allocateNode (CpsBranch { brCond = branchCond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
    compileLowCatToCps f branchEntryPc
  Nothing -> do
    gEntryPc <- compileLowCatToCps g nextPc
    fEntryPc <- compileLowCatToCps f gEntryPc
    return fEntryPc
compileLowCatToCps (LFanIn tOp fOp) nextPc =
  compileBranchDiamondLowCat ExNull tOp fOp nextPc
compileLowCatToCps (LLoop body) nextPc = compileLoopLowCat body nextPc
compileLowCatToCps (LCall name args) nextPc =
  allocateNode (CpsCallProc { cpCallee = name, cpArgs = args, cpNext = nextPc })
compileLowCatToCps (LSuspend eff args) nextPc =
  allocateNode (CpsSuspend { suEffect = eff, suArgs = args, suVar = Nothing, suContinuation = nextPc })
-- | True procedure return (Plan 146 Phase 2i): ignore whatever local
-- continuation this call site threaded in (a loop's own break/post-loop pc,
-- however deeply nested) and resolve straight to the one true exit recorded
-- in 'BuilderState' by 'buildCpsGraph'.
compileLowCatToCps LReturn _nextPc = GraphBuilder (gets bsExitPc)
-- | Plan 150: a merge block's tagged content. On the first encounter (for
-- this blockId + continuation), lower it for real and remember the pc; on
-- every later encounter, reuse that pc instead of re-lowering (and
-- re-allocating a full duplicate subgraph for) the same content again —
-- this is what stops sequential merge points (if/elseif chains,
-- choose/case) from compounding multiplicatively.
compileLowCatToCps (LTagged bid inner) nextPc = do
  cached <- lookupBlockPcMemo bid nextPc
  case cached of
    Just pc -> return pc
    Nothing -> do
      pc <- compileLowCatToCps inner nextPc
      registerBlockPcMemo bid nextPc pc
      return pc
-- Structural / erased constructors
compileLowCatToCps _ nextPc = return nextPc

-- | Detect a branch: is this LowCat a LFanIn?
inspectBranchLowCat :: LowCat -> Maybe (LowCat, LowCat)
inspectBranchLowCat (LFanIn t f) = Just (t, f)
inspectBranchLowCat _            = Nothing

-- | Extract the condition expression from a branch's inner routing chain.
-- Pure pattern matching on LowCat — no unsafeCoerce.
extractCondLowCat :: LowCat -> Expr
extractCondLowCat (LEval e)          = e
extractCondLowCat (LCompose _ inner) = extractCondLowCat inner
extractCondLowCat (LFork _ rhs)      = extractCondLowCat rhs
extractCondLowCat _                  = ExNull

-- | Emit a branch diamond: CpsBranch + then-path + else-path, converging at a join nop.
compileBranchDiamondLowCat :: Expr -> LowCat -> LowCat -> Int -> GraphBuilder Int
compileBranchDiamondLowCat cond tOp fOp nextPc = do
  joinPc <- allocateNode (CpsNop { npNext = nextPc })
  elseEntryPc <- compileLowCatToCps fOp joinPc
  thenEntryPc <- compileLowCatToCps tOp joinPc
  allocateNode (CpsBranch { brCond = cond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })

-- | Compile a loop: reserve a header pc, compile the body with a back-edge
-- to it, then patch the reserved pc directly with the header's real content
-- (typically a 'CpsBranch') instead of forwarding to a separately-allocated
-- node. Mirrors 'PB.Analysis.CpsCompile'\'s @BsFor@\/@BsDo@ pattern: emit a
-- placeholder pc, then @patchNode@ it in place once the real content is
-- known — no residual hop (Plan 145).
compileLoopLowCat :: LowCat -> Int -> GraphBuilder Int
compileLoopLowCat body nextPc = do
  loopHeaderPc <- allocateNode (CpsNop { npNext = -1 })
  patchLoopHeaderLowCat body loopHeaderPc nextPc
  return loopHeaderPc

-- | Compile the loop's header\/body content, patching the reserved
-- 'loopHeaderPc' directly with the node the header produces (a 'CpsBranch'
-- for for\/while loops — the common case) rather than allocating a fresh pc
-- and leaving 'loopHeaderPc' as a forwarding 'CpsNop'. Falls back to the old
-- forwarding-'CpsNop' behaviour for any other shape (e.g. a headerless
-- infinite @do...loop@), which is unchanged from before this fix.
patchLoopHeaderLowCat :: LowCat -> Int -> Int -> GraphBuilder ()
patchLoopHeaderLowCat (LCompose g f) loopHeaderPc nextPc
  | Just (tOp, fOp) <- inspectBranchLowCat g = do
      let branchCond = extractCondLowCat f
      elseEntryPc <- compileLoopBodyLowCat fOp loopHeaderPc nextPc
      thenEntryPc <- compileLoopBodyLowCat tOp loopHeaderPc nextPc
      registerNodeAt loopHeaderPc (CpsBranch { brCond = branchCond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
patchLoopHeaderLowCat body loopHeaderPc nextPc = do
  bodyEntryPc <- compileLoopBodyLowCat body loopHeaderPc nextPc
  registerNodeAt loopHeaderPc (CpsNop { npNext = bodyEntryPc })

-- | Compile a loop body. 'LInl'/'LInr' are pure value-routing markers (which
-- of the two known pcs execution resumes at) — structural/erased, like
-- 'LEval'\/'LFork'\/'LSplitValue' in 'compileLowCatToCps'. They resolve
-- directly to 'loopHeaderPc'\/'nextPc' as entry pcs; no node is allocated.
-- The old compiler ('PB.Analysis.CpsCompile') never allocates a node for
-- the implicit loop continue\/break either — it threads @(incrPc,
-- fallthrough)@ straight through as raw pcs (Plan 145).
compileLoopBodyLowCat :: LowCat -> Int -> Int -> GraphBuilder Int
compileLoopBodyLowCat LInl loopHeaderPc _nextPc = return loopHeaderPc
compileLoopBodyLowCat LInr _loopHeaderPc nextPc  = return nextPc
-- Branch pattern inside loops: intercept LFanIn + condition before LCompose tears them apart.
compileLoopBodyLowCat (LCompose g f) loopHeaderPc nextPc
  | Just (tOp, fOp) <- inspectBranchLowCat g = do
      -- No join CpsNop here either — same fix as the top-level branch case
      -- above (Plan 145 Finding A).
      let branchCond = extractCondLowCat f
      elseEntryPc <- compileLoopBodyLowCat fOp loopHeaderPc nextPc
      thenEntryPc <- compileLoopBodyLowCat tOp loopHeaderPc nextPc
      branchEntryPc <- allocateNode (CpsBranch { brCond = branchCond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
      compileLoopBodyLowCat f loopHeaderPc branchEntryPc
compileLoopBodyLowCat (LCompose g f) loopHeaderPc nextPc = do
  gEntryPc <- compileLoopBodyLowCat g loopHeaderPc nextPc
  compileLoopBodyLowCat f loopHeaderPc gEntryPc
compileLoopBodyLowCat (LFanIn tOp fOp) loopHeaderPc nextPc = do
  thenEntryPc <- compileLoopBodyLowCat tOp loopHeaderPc nextPc
  elseEntryPc <- compileLoopBodyLowCat fOp loopHeaderPc nextPc
  allocateNode (CpsBranch { brCond = ExNull, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
-- | Plan 150: a merge block inside a loop body (e.g. an if/else's shared
-- tail before the back-edge). Must recurse via 'compileLoopBodyLowCat'
-- (not delegate to the loop-unaware 'compileLowCatToCps', which would
-- resolve a nested 'LInl'\/'LInr' against the wrong continuation and lose
-- the back-edge to 'loopHeaderPc' — confirmed by the regression this exact
-- gap caused in "loop containing if/else with a shared tail", Phase 3)
-- so the tag's own back-edge/break markers still resolve correctly.
compileLoopBodyLowCat (LTagged bid inner) loopHeaderPc nextPc = do
  cached <- lookupBlockPcMemo bid nextPc
  case cached of
    Just pc -> return pc
    Nothing -> do
      pc <- compileLoopBodyLowCat inner loopHeaderPc nextPc
      registerBlockPcMemo bid nextPc pc
      return pc
compileLoopBodyLowCat linearOp _loopHeaderPc nextPc =
  compileLowCatToCps linearOp nextPc

-- | Build a flat CpsGraph from a structured CatOp.
buildCpsGraph :: CatOp () () -> CpsGraph
buildCpsGraph catOp =
  let (entryPc, finalState) = runState (runBuilder $ do
        exitPc <- allocateNode (CpsReturn Nothing)
        GraphBuilder $ modify $ \s -> s { bsExitPc = exitPc }
        compileCatToCps catOp exitPc
        ) initState
  in finalizeGraph entryPc finalState

-- | Unified entry point: compile a procedure body via the SSA → CatOp pipeline.
--
-- Seeds 'steLocal' with the body's own local variable declarations before
-- compiling, mirroring 'PB.Analysis.CpsCompile.compileProcedure' exactly —
-- without this, 'classifyExpr' can never resolve a *locally-declared*
-- datastore/datawindow/transaction variable's type, so a suspend method call
-- on it (retrieve/update/commit/…) always falls through to the conservative
-- 'PureCall' default (Plan 146 Phase 2e).
compileProcedureViaCatOp :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> CpsGraph
compileProcedureViaCatOp env userFns body =
  let env' = env { steLocal = collectBodyLocals body `Map.union` steLocal env }
  in buildCpsGraph (compileSsa env' userFns (buildSsa env' "proc" body))

-- ============================================================================
-- 6. Interpreter: Direct Haskell Execution
-- ============================================================================

-- | Persistent state threaded through an 'Interp' run: the named-variable
-- environment ('CatOp'\'s @env@ type parameter is structural wiring only —
-- 'compileSsa' always produces @CatOp () ()@ — so real variable storage
-- lives here instead), the accumulating observable trace, and the mocked
-- call\/suspend responses available for this run (Plan 146 Phase 2a) —
-- read-only from 'Interp'\'s own perspective, but threaded through the same
-- state for simplicity rather than adding a separate 'ReaderT' layer.
--
-- 'isTrace' accumulates newest-first (prepend is O(1)); reverse once when
-- reading it back out.
data InterpState = InterpState
  { isEnv   :: Map.Map Text Value
  , isTrace :: [TraceEvent]
  , isMocks :: MockResponses
  }

-- | Thrown by 'CatReturn' (Plan 146 Phase 2i) to unwind the 'Interp'
-- backend's plain function composition straight past every enclosing loop
-- (however deeply nested) and any post-loop continuation, landing exactly
-- where the currently-running procedure was invoked from. Carries the
-- 'InterpState' snapshot taken at the point of the throw — 'StateT's own
-- state isn't otherwise recoverable across an IO exception, since the whole
-- @(a, s)@ pair is discarded the instant the underlying 'IO' action throws.
-- A caller that wants the final env/trace after a return (e.g. a test
-- harness running one whole compiled procedure via 'runCat') catches this
-- and uses the carried state directly.
newtype ReturnUnwind = ReturnUnwind InterpState

instance Show ReturnUnwind where
  show _ = "ReturnUnwind"

instance Exception ReturnUnwind

-- | An execution interpreter category that maps 'CatOp a b' to direct
-- Haskell functions @a -> StateT InterpState IO b@.
newtype Interp a b = Interp { runInterp :: a -> StateT InterpState IO b }

instance Category Interp where
  id  = Interp P.pure
  (Interp f) . (Interp g) = Interp (\x -> g x P.>>= f)

instance Cartesian Interp where
  exl = Interp (\(a, _b) -> P.pure a)
  exr = Interp (\(_a, b) -> P.pure b)
  (Interp f) &&& (Interp g) = Interp (\x -> (,) P.<$> f x P.<*> g x)

instance Cocartesian Interp where
  inl = Interp (\a -> P.pure (Left a))
  inr = Interp (\b -> P.pure (Right b))
  (|||) (Interp f) (Interp g) = Interp (\x -> case x of
    Left  a -> f a
    Right b -> g b)

instance Effectful Interp where
  eval expr = Interp (\_env -> gets (\st -> evalExprMocked (isMocks st) (isEnv st) expr))

  assign var = Interp (\(env, val) -> do
    modify' (\st -> st { isEnv   = Map.insert var val (isEnv st)
                        , isTrace = TeAssign var val : isTrace st })
    P.pure env)

  lookup var = Interp (\_env -> gets (Map.findWithDefault VNull var P.. isEnv))

  suspend effect args = Interp (\_env -> do
    vals <- gets (\st -> map (evalExprMocked (isMocks st) (isEnv st)) args)
    modify' (\st -> st { isTrace = TeSuspend effect vals : isTrace st }))

  callProc name args = Interp (\_env -> do
    vals <- gets (\st -> map (evalExprMocked (isMocks st) (isEnv st)) args)
    modify' (\st -> st { isTrace = TeCall name vals : isTrace st }))

  splitValue = Interp (\(env, val) -> do
    let taken = case val of
          VBool b -> b
          _       -> False
    modify' (\st -> st { isTrace = TeBranch taken : isTrace st })
    P.pure (if taken then Left env else Right env))

-- | Execute a loop via recursion.  The body returns 'Left' to continue
-- with updated state, or 'Right' to break with a final value.
interpretLoop :: Interp a (Either a b) -> Interp a b
interpretLoop (Interp body) = Interp go
  where
    go x = body x P.>>= \case
      Left  continueState -> go continueState
      Right breakState    -> P.pure breakState

-- | Run an 'Interp' morphism against a fresh, empty environment/trace/mock
-- table, discarding the final 'InterpState' — a compatibility shim for tests
-- that only care about the plain @IO b@ result (predates trace/env
-- threading).
runInterpIO :: Interp a b -> a -> IO b
runInterpIO (Interp f) x = evalStateT (f x) (InterpState Map.empty [] Map.empty)

-- | Interpret a compiled 'CatOp' term directly via 'Interp' — the fold
-- 'CatOp' is initial for. Every constructor dispatches to the corresponding
-- 'Category'\/'Cartesian'\/'Cocartesian'\/'Effectful' method on 'Interp';
-- there is no other sensible definition per constructor, so this is
-- forced by the types rather than independent logic to get wrong.
--
-- 'CatAssign'\/'CatLookup'\/'CatExl'\/'CatExr'\/'CatConst' are declared by
-- the GADT/typeclasses but never emitted by 'compileSsa' (which always
-- emits 'CatAssignWithRhs' directly) — they're handled here for
-- completeness, not because real compiled terms use them.
--
-- 'CatTry' has no real interpretation yet: 'PB.Analysis.CfgBuild' doesn't
-- model try/catch, so 'compileSsa' never emits it either. Running the body
-- and ignoring the handler is a placeholder to keep this fold total; revisit
-- once try/catch compilation lands.
runCat :: CatOp a b -> Interp a b
runCat CatId                  = id
runCat (CatCompose g f)       = runCat g . runCat f
runCat (CatFork l r)          = runCat l &&& runCat r
runCat CatExl                 = exl
runCat CatExr                 = exr
runCat (CatConst e)           = eval e
runCat CatInl                  = inl
runCat CatInr                  = inr
runCat CatReturn               = Interp (\_ -> do
  st <- get
  liftIO (throwIO (ReturnUnwind st)))
runCat (CatFanIn t f)          = runCat t ||| runCat f
runCat (CatAssign var)         = assign var
runCat (CatAssignWithRhs var e) = Interp (\env -> do
  val <- gets (\st -> evalExprMocked (isMocks st) (isEnv st) e)
  modify' (\st -> st { isEnv   = Map.insert var val (isEnv st)
                      , isTrace = TeAssign var val : isTrace st })
  P.pure env)
runCat (CatLookup var)         = lookup var
runCat (CatLoop body)          = interpretLoop (runCat body)
runCat (CatEval e)             = eval e
runCat (CatCall name args)     = callProc name args
runCat (CatSuspend eff args)   = suspend eff args
runCat CatSplitValue           = splitValue
runCat (CatTry body _handler)  = runCat body
runCat (CatTagged _ f)         = runCat f
