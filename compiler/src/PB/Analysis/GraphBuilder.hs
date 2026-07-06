{-# LANGUAGE StrictData #-}
-- | 'CatOp' → flat @CpsGraph@ flattening (the @GraphBuilder@ target), plus
-- 'LowCat' — the monomorphic intermediary that bridges the GADT-indexed
-- 'CatOp' to the flat, PC-indexed 'CpsGraph' the current TS runtime
-- executes — and the public one-call pipeline entry point,
-- 'compileProcedureViaCatOp'.
--
-- Pure module — no I/O (the @GraphBuilder@ monad is a bare 'State', never
-- 'IO'). Split out of 'PB.Analysis.CatOp' in Plan 151, alongside
-- 'PB.Analysis.CatLower' (SSA → 'CatOp') and 'PB.Analysis.CatInterp'
-- (direct 'CatOp' execution) — those three plus the core 'CatOp' module
-- together are "the categorical compiler pipeline"; this module is
-- specifically its last stage, the one that produces the artifact
-- ('CpsGraph') the rest of the compiler pipeline and the TS runtime
-- actually consume.
module PB.Analysis.GraphBuilder
  ( -- * LowCat intermediary
    LowCat (..)
  , toLowCat
  , extractCondLowCat
    -- * GraphBuilder
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
    -- * Pipeline entry point
  , compileProcedureViaCatOp
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import PB.AST.Expr (Expr (..))
import PB.AST.BodyStmt (BodyStmt)
import PB.AST.Located  (Located (..))
import PB.Analysis.CatOp (CatOp (..))
import PB.Analysis.CatLower (compileSsa)
import PB.Analysis.CpsCompile (CpsNode (..), CpsGraph (..), collectBodyLocals)
import PB.Analysis.SSA (buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import Control.Monad.State.Strict (State, gets, modify, runState)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- ============================================================================
-- 1. LowCat: Monomorphic Categorical Intermediate Representation
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
-- 2. GraphBuilder: CpsGraph Target (Phase 4 — backward chaining)
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
