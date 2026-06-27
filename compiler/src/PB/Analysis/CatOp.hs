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
    -- * GraphBuilder
  , GraphBuilder (..)
  , CpsNode (..)
  , runGraphBuilder
    -- * Interpreter
  , Interp (..)
    -- * Interpreter loop
  , interpretLoop
    -- * Placeholder types
  , Value (..)
  , Continuation (..)
  ) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import Unsafe.Coerce (unsafeCoerce)
import PB.AST.Expr (Expr (..), LvSegment (..), Lvalue (..))
import PB.Analysis.CpsCompile (CpsNode (..))
import PB.Analysis.SSA (SsaVal (..), SsaAssign (..), SsaBlock (..),
                         SsaTerm (..), SsaPhi (..), SsaProc (..), renderSsaVar)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- ============================================================================
-- Placeholder types
-- ============================================================================

-- | Runtime value.  In production this would be a sum type covering
-- PB's primitive types (int, real, string, boolean, date, time, blob).
data Value
  = VInt Int
  | VReal Double
  | VStr Text
  | VBool Bool
  | VNull
  deriving (Eq, Show, Generic)

-- | Continuation handle for a suspended computation.
data Continuation = Continuation Int  -- PC to resume at
  deriving (Eq, Show, Generic)

-- ============================================================================
-- 1. Core Typeclasses
-- ============================================================================

-- | The base category: sequential composition.
class Category k where
  id  :: k a a
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
  suspend    :: Text -> k args Continuation
  callProc   :: Text -> k args ()
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
  CatAssign  :: Text -> CatOp (env, Value) env
  CatLookup  :: Text -> CatOp env Value

  -- Loops (via coproduct: Left = continue, Right = break)
  CatLoop    :: CatOp a (Either a b) -> CatOp a b

  -- Effects
  CatEval       :: Expr -> CatOp env Value
  CatCall       :: Text -> CatOp args ()
  CatSuspend    :: Text -> CatOp args Continuation
  CatSplitValue :: CatOp (env, Value) (Either env env)

  -- Error handling
  CatTry     :: CatOp a b -> CatOp (a, Value) b -> CatOp a b

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
  show (CatFanIn _ _) = "CatFanIn .."
  show (CatAssign t) = "CatAssign " <> show t
  show (CatLookup t) = "CatLookup " <> show t
  show (CatLoop _) = "CatLoop .."
  show (CatEval _) = "CatEval .."
  show (CatCall t) = "CatCall " <> show t
  show (CatSuspend t) = "CatSuspend " <> show t
  show CatSplitValue = "CatSplitValue"
  show (CatTry _ _) = "CatTry .."

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
    go (CatFanIn f g) (CatFanIn f' g') = feq f f' P.&& feq g g'
    go (CatAssign t) (CatAssign t') = t == t'
    go (CatLookup t) (CatLookup t') = t == t'
    go (CatLoop f) (CatLoop f') = feq f f'
    go (CatEval e) (CatEval e') = e == e'
    go (CatCall t) (CatCall t') = t == t'
    go (CatSuspend t) (CatSuspend t') = t == t'
    go CatSplitValue CatSplitValue = True
    go (CatTry f g) (CatTry f' g') = feq f f' P.&& feq g g'
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

-- | Compile an SSA procedure into a categorical combinator.
--
-- The SSA form ensures every variable is assigned exactly once, so the
-- environment type parameter can be () — all variable storage is by name.
--
-- Compilation rules:
--   * Linear assigns: fold with CatCompose via @(assign . (id &&& eval))@
--   * @SsaGoto target@: CatId (structural connection, not a jump)
--   * @SsaBranch cond t f@: @branch@ combinator (splitValue + |||)
--   * @SsaReturn@: CatId (terminal)
--   * Phi nodes: CatFanIn at join points (pushed into predecessor branches)
--   * Loops: CatLoop wrapping the loop body (detected via back-edge analysis)
--   * Back-edges: CatInl (continue loop) / CatInr (break loop)
--
-- The visited set is threaded globally through all branches to prevent
-- double-compilation of shared successor blocks (O(V+E) instead of exponential).
compileSsa :: SsaProc -> CatOp () ()
compileSsa proc =
  let headers = computeLoopHeaders proc
      (result, _finalVisited) = compileBlock proc (spEntry proc) Set.empty headers Nothing
  in result

-- | Extract all destination blocks from an SSA terminator.
termSuccessors :: SsaTerm -> [Text]
termSuccessors (SsaGoto t)       = [t]
termSuccessors (SsaBranch _ t f) = [t, f]
termSuccessors _                 = []

-- | Detect loop headers by DFS with onStack tracking.
-- A loop header is any block that is the target of a back-edge
-- (an edge to a block already on the current DFS path).
computeLoopHeaders :: SsaProc -> Set.Set Text
computeLoopHeaders proc = go (spEntry proc) Set.empty Set.empty
  where
    go blockId onStack visited
      | Set.member blockId onStack = Set.singleton blockId
      | Set.member blockId visited = Set.empty
      | otherwise = case Map.lookup blockId (spBlocks proc) of
          Nothing    -> Set.empty
          Just block ->
            let onStack' = Set.insert blockId onStack
                succs    = termSuccessors (sbTerm block)
                childHeaders = Set.unions
                  [ go s onStack' (Set.insert blockId visited) | s <- succs ]
            in childHeaders

-- | Find all blocks that form the loop body via cycle-aware reachability.
-- A block is in the body only if it is reachable from the header AND
-- can transitively reach back to the header (strong connectivity).
-- The forward walk stops at other loop headers to avoid escaping into nested loops.
computeLoopBodyBlocks :: SsaProc -> Text -> Set.Set Text
computeLoopBodyBlocks proc headerId =
  let headerSuccs = case Map.lookup headerId (spBlocks proc) of
        Nothing -> []
        Just block -> termSuccessors (sbTerm block)
      allReachable = foldl' (\bs s -> discoverReachable proc headerId s bs) (Set.singleton headerId) headerSuccs
      loopBody     = Set.filter (\bId -> canReach proc bId headerId Set.empty) allReachable
  in Set.insert headerId loopBody

-- | Forward-reachability walk bounded by loop headers.
-- Stops at other loop headers to prevent escaping into nested/outer loops.
discoverReachable :: SsaProc -> Text -> Text -> Set.Set Text -> Set.Set Text
discoverReachable proc headerId currentBlock visited
  | Set.member currentBlock visited = visited
  | currentBlock /= headerId && isLoopHeader proc currentBlock = visited
  | otherwise = case Map.lookup currentBlock (spBlocks proc) of
      Nothing -> visited
      Just block ->
        let visited' = Set.insert currentBlock visited
            succs    = termSuccessors (sbTerm block)
        in foldl' (\v s -> discoverReachable proc headerId s v) visited' succs

-- | Check if a block is a loop header (has a back-edge targeting it).
isLoopHeader :: SsaProc -> Text -> Bool
isLoopHeader proc blockId =
  let headers = computeLoopHeaders proc
  in Set.member blockId headers

-- | Returns True if startBlock can transitively reach targetBlock.
canReach :: SsaProc -> Text -> Text -> Set.Set Text -> Bool
canReach proc startBlock targetBlock visited
  | startBlock == targetBlock = True
  | Set.member startBlock visited = False
  | otherwise = case Map.lookup startBlock (spBlocks proc) of
      Nothing -> False
      Just block ->
        let visited' = Set.insert startBlock visited
            succs    = termSuccessors (sbTerm block)
        in any (\s -> canReach proc s targetBlock visited') succs

-- | Robust exit target extraction: collect every successor of every block
-- in the loop body; the exit is any successor NOT in the body itself.
determineLoopExitTarget :: SsaProc -> Text -> Text
determineLoopExitTarget proc headerId =
  let bodyBlocks  = computeLoopBodyBlocks proc headerId
      allSuccs    = Set.fromList
        [ suc
        | bId <- Set.toList bodyBlocks
        , Just block <- [Map.lookup bId (spBlocks proc)]
        , suc <- termSuccessors (sbTerm block)
        ]
      exits = Set.filter (/= headerId) (Set.difference allSuccs bodyBlocks)
  in case Set.toList exits of
       (exitTarget : _) -> exitTarget
       []               -> ""

-- | Main compiler orchestrator. Returns @(CatOp, updatedVisited)@ to
-- thread the global visited set across all branches.
compileBlock :: SsaProc
             -> Text              -- ^ Current block ID
             -> Set.Set Text      -- ^ Global visited registry
             -> Set.Set Text      -- ^ Pre-computed loop headers
             -> Maybe Text        -- ^ Active loop header context
             -> (CatOp () (), Set.Set Text)
compileBlock proc blockId visited headers activeLoop
  | Just blockId == activeLoop = (CatId, visited)
  | Set.member blockId visited = (CatId, visited)
  | Set.member blockId headers =
      let (loopBodyOp, visitedFromLoop) = compileLoopBody proc blockId visited headers (Just blockId)
          exitBlockId = determineLoopExitTarget proc blockId
          (postLoopOp, finalVisited) = compileBlock proc exitBlockId visitedFromLoop headers activeLoop
      in (postLoopOp . CatLoop loopBodyOp, finalVisited)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (CatId, visited)
      Just block ->
        let visited'   = Set.insert blockId visited
            assignsOp  = compileAssigns (sbAssigns block)
            (termOp, finalVisited) = compileTerm proc blockId visited' headers activeLoop (sbTerm block)
            result = case (assignsOp, termOp) of
                       (CatId, _) -> termOp
                       (_, CatId) -> assignsOp
                       _          -> termOp . assignsOp
        in (result, finalVisited)

-- | Compile the body of a loop. Returns @(CatOp () (Either () ()), visited)@:
--   * @Left ()@ — continue the loop (back-edge or continue)
--   * @Right ()@ — break out of loop (return / break / exit)
compileLoopBody :: SsaProc -> Text -> Set.Set Text -> Set.Set Text
                -> Maybe Text -> (CatOp () (Either () ()), Set.Set Text)
compileLoopBody proc blockId visited headers activeLoop
  | Set.member blockId visited = (CatInl, visited)
  | Set.member blockId headers && Just blockId /= activeLoop =
      -- Nested loop header: compile as CatLoop, lift into Either frame.
      -- Do NOT pre-insert blockId into visited — let compileLoopBody add it
      -- so the initial guard doesn't short-circuit.
      let (innerBody, v1) = compileLoopBody proc blockId visited headers (Just blockId)
      in (CatInl . CatLoop innerBody, v1)
  | otherwise = case Map.lookup blockId (spBlocks proc) of
      Nothing    -> (CatInr, visited)
      Just block ->
        let visited'   = Set.insert blockId visited
            assignsOp  = compileAssigns (sbAssigns block)
            (termOp, finalVisited) = compileLoopTerm proc blockId visited' headers activeLoop (sbTerm block)
            result = case assignsOp of
                       CatId -> termOp
                       _     -> termOp . assignsOp
        in (result, finalVisited)

-- | Compile an SSA value to a CatOp that produces a Value.
compileSsaVal :: SsaVal -> CatOp env Value
compileSsaVal (SsaVarRef sv) = CatLookup (renderSsaVar sv)
compileSsaVal ssaVal         = eval (ssaValToExpr ssaVal)

-- | Convert an SSA value back to an Expr so it can be passed to @eval@.
ssaValToExpr :: SsaVal -> Expr
ssaValToExpr (SsaConst e)       = e
ssaValToExpr (SsaVarRef sv)     = ExLvalue (Lvalue [LvSegment (renderSsaVar sv) Nothing])
ssaValToExpr (SsaBinOp op l r)  = ExBinOp (ssaValToExpr l) op (ssaValToExpr r)
ssaValToExpr (SsaNot v)         = ExNot (ssaValToExpr v)
ssaValToExpr SsaNull            = ExNull

-- | Emit named assignments for any Phi nodes requiring resolution
-- when transitioning from @prevBlock@ into @currentBlock@.
compilePhiAssignments :: SsaProc -> Text -> Text -> CatOp () ()
compilePhiAssignments proc prevBlock currentBlock =
  case Map.lookup currentBlock (spPhis proc) of
    Nothing   -> CatId
    Just phis -> compileAssigns (mapMaybe findMatchingSource phis)
  where
    findMatchingSource phi =
      case [ sv | (src, sv) <- spSources phi, src == prevBlock ] of
        (sourceVar : _) -> Just (SsaAssign (spResult phi) (SsaVarRef sourceVar))
        []              -> Nothing

-- | Standard terminators (outside loops). Injects phi resolution before target blocks.
-- Returns @(CatOp, updatedVisited)@ to thread the global registry.
compileTerm :: SsaProc -> Text -> Set.Set Text -> Set.Set Text
            -> Maybe Text -> SsaTerm -> (CatOp () (), Set.Set Text)
compileTerm _proc _blockId visited _headers _activeLoop (SsaReturn _) = (CatId, visited)
compileTerm proc blockId visited headers activeLoop (SsaGoto target) =
  let (targetOp, v1) = compileBlock proc target visited headers activeLoop
  in (targetOp . compilePhiAssignments proc blockId target, v1)
compileTerm proc blockId visited headers activeLoop (SsaBranch cond t f) =
  let (tOp, v1) = compileBlock proc t visited headers activeLoop
      (fOp, v2) = compileBlock proc f v1 headers activeLoop
      combined  = branch (ssaValToExpr cond)
                    (tOp . compilePhiAssignments proc blockId t)
                    (fOp . compilePhiAssignments proc blockId f)
  in (combined, v2)
compileTerm _ _ visited _ _ SsaBreak    = (CatId, visited)
compileTerm _ _ visited _ _ SsaContinue = (CatId, visited)

-- | Loop terminators. Returns @(CatOp () (Either () ()), visited)@.
compileLoopTerm :: SsaProc -> Text -> Set.Set Text -> Set.Set Text
                -> Maybe Text -> SsaTerm -> (CatOp () (Either () ()), Set.Set Text)
compileLoopTerm proc blockId visited headers activeLoop (SsaGoto target)
  | Just target == activeLoop = (CatInl, visited)
  | isLoopExit proc activeLoop target = (CatInr, visited)
  | otherwise =
      let (targetOp, v1) = compileLoopBody proc target visited headers activeLoop
      in (targetOp . compilePhiAssignments proc blockId target, v1)
compileLoopTerm proc blockId visited headers activeLoop (SsaBranch cond t f) =
  let (tOp, v1) = compileLoopBranchPath proc blockId t visited headers activeLoop
      (fOp, v2) = compileLoopBranchPath proc blockId f v1 headers activeLoop
      combined  = branch (ssaValToExpr cond) tOp fOp
  in (combined, v2)
compileLoopTerm _ _ visited _ _ (SsaReturn _) = (CatInr, visited)
compileLoopTerm _ _ visited _ _ SsaBreak      = (CatInr, visited)
compileLoopTerm _ _ visited _ _ SsaContinue   = (CatInl, visited)

-- | Compile a branch target inside a loop, wrapping in the appropriate Either.
compileLoopBranchPath :: SsaProc -> Text -> Text -> Set.Set Text -> Set.Set Text
                      -> Maybe Text -> (CatOp () (Either () ()), Set.Set Text)
compileLoopBranchPath proc prevBlock target visited headers activeLoop
  | Just target == activeLoop = (CatInl, visited)
  | isLoopExit proc activeLoop target = (CatInr, visited)
  | otherwise =
      let (targetOp, v1) = compileLoopBody proc target visited headers activeLoop
      in (targetOp . compilePhiAssignments proc prevBlock target, v1)

-- | Check if a target block is outside the current loop cycle.
-- A block is a loop exit if it is not part of the loop body.
isLoopExit :: SsaProc -> Maybe Text -> Text -> Bool
isLoopExit _ Nothing _ = False
isLoopExit proc (Just headerId) targetId =
  let bodyBlocks = computeLoopBodyBlocks proc headerId
  in not (Set.member targetId bodyBlocks)

-- | Compile a list of SSA assignments by folding with CatCompose.
-- Composes right-to-left so the first assign executes first.
compileAssigns :: [SsaAssign] -> CatOp () ()
compileAssigns [] = CatId
compileAssigns [a] = compileAssign a
compileAssigns (a:as) = compileAssigns as . compileAssign a

-- | Compile a single SSA assignment.
-- @x_1 = expr@ becomes @assign \"x_1\" . (id &&& eval (ssaValToExpr expr))@
compileAssign :: SsaAssign -> CatOp () ()
compileAssign (SsaAssign sv rhs) =
  assign (renderSsaVar sv) . (id &&& compileSsaVal rhs)

-- ============================================================================
-- 6. GraphBuilder: CpsGraph Target Category
-- ============================================================================

-- | The target category for CpsGraph emission.
-- Wraps a function that allocates PC labels linearly.
-- Reuses 'CpsNode' from 'PB.Analysis.CpsCompile'.
newtype GraphBuilder a b = GraphBuilder
  { buildNodes :: Int -> ([CpsNode], Int) }

instance Category GraphBuilder where
  id = GraphBuilder (\currentPc -> ([], currentPc))
  (GraphBuilder f) . (GraphBuilder g) = GraphBuilder (\currentPc ->
    let (ng, pc')  = g currentPc
        (nf, pc'') = f pc'
    in (ng P.++ nf, pc''))

instance Cartesian GraphBuilder where
  exl = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  exr = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  (GraphBuilder f) &&& (GraphBuilder g) = GraphBuilder (\currentPc ->
    let (nf, pc')  = f currentPc
        (ng, pc'') = g pc'
    in (nf P.++ ng, pc''))

instance Cocartesian GraphBuilder where
  inl = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  inr = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  -- ||| emits a conditional dispatcher: branch node at pc, then-branch at pc+1,
  -- goto at end of then-branch to skip else, else-branch after goto, exit after else.
  -- The goto occupies a PC slot so it doesn't break the then-branch's next pointers.
  (|||) (GraphBuilder f) (GraphBuilder g) = GraphBuilder (\currentPc ->
    let thenEntry  = currentPc P.+ 1
        (nf, pcAfterThen) = f thenEntry
        gotoPc            = pcAfterThen
        elseEntry         = gotoPc P.+ 1
        (ng, pcAfterElse) = g elseEntry
        exitPc            = pcAfterElse
        branchNode = CpsBranch { brCond = ExNull, brThenPc = thenEntry, brElsePc = elseEntry }
        thenGoto   = CpsGoto { goTarget = exitPc }
    in ([branchNode] P.++ nf P.++ [thenGoto] P.++ ng, exitPc))

instance Effectful GraphBuilder where
  eval _expr  = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))
  assign var  = GraphBuilder (\currentPc -> ([CpsAssign { anVar = var, anRhs = ExNull, anNext = currentPc + 1 }], currentPc + 1))
  lookup _var = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))  -- TODO: emit real load node
  suspend eff = GraphBuilder (\currentPc -> ([CpsSuspend { suEffect = eff, suArgs = [], suVar = Nothing, suContinuation = currentPc + 1 }], currentPc + 1))
  callProc n  = GraphBuilder (\currentPc -> ([CpsCallProc { cpCallee = n, cpArgs = [], cpNext = currentPc + 1 }], currentPc + 1))
  splitValue  = GraphBuilder (\currentPc -> ([CpsNop { npNext = currentPc + 1 }], currentPc + 1))

-- | Run a GraphBuilder from PC 0, returning the emitted nodes.
runGraphBuilder :: GraphBuilder a b -> [CpsNode]
runGraphBuilder (GraphBuilder f) = P.fst (f 0)

-- ============================================================================
-- 6. Interpreter: Direct Haskell Execution
-- ============================================================================

-- | An execution interpreter category that maps 'CatOp a b' to
-- direct Haskell functions @a -> IO b@.
newtype Interp a b = Interp { runInterp :: a -> IO b }

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
  eval _expr  = Interp (\_env -> P.pure (VInt 0))  -- TODO: real eval
  assign _var = Interp (\(env, _val) -> P.pure env)  -- TODO: real assign
  lookup _var = Interp (\_env -> P.pure VNull)  -- TODO: real lookup
  suspend _e  = Interp (\_args -> P.pure (Continuation 0))  -- TODO
  callProc _n = Interp (\_args -> P.pure ())  -- TODO
  splitValue = Interp (\(env, val) -> P.pure (case val of
    VBool True  -> Left env
    VBool False -> Right env
    _           -> Right env
    ))

-- | Execute a loop via recursion.  The body returns 'Left' to continue
-- with updated state, or 'Right' to break with a final value.
interpretLoop :: Interp a (Either a b) -> Interp a b
interpretLoop (Interp body) = Interp go
  where
    go x = body x P.>>= \case
      Left  continueState -> go continueState
      Right breakState    -> P.pure breakState
