{-# LANGUAGE StrictData #-}
-- | 'CatOp' → flat @InstrGraph@ flattening (the @GraphBuilder@ target), plus
-- 'LowCat' — the monomorphic intermediary that bridges the GADT-indexed
-- 'CatOp' to the flat, PC-indexed 'InstrGraph' the current TS runtime
-- executes — and the public one-call pipeline entry point,
-- 'compileProcedureViaCatOp'.
--
-- Pure module — no I/O (the @GraphBuilder@ monad is a bare 'State', never
-- 'IO'). Split out of 'PB.Analysis.CatOp' in Plan 151, alongside
-- 'PB.Analysis.CatLower' (SSA → 'CatOp') and 'PB.Analysis.CatInterp'
-- (direct 'CatOp' execution) — those three plus the core 'CatOp' module
-- together are "the categorical compiler pipeline"; this module is
-- specifically its last stage, the one that produces the artifact
-- ('InstrGraph') the rest of the compiler pipeline and the TS runtime
-- actually consume.
module PB.Analysis.GraphBuilder
  ( -- * LowCat intermediary
    LowCat (..)
  , toLowCat
  , extractCondLowCat
    -- * Wiring diagrams (Plan 149 Phase 1)
  , WiringPayload (..)
  , collectWiring
    -- * GraphBuilder
  , GraphBuilder (..)
  , BuilderState (..)
  , initState
  , allocateNode
  , peekNextPc
  , registerNodeAt
  , finalizeGraph
  , compileCatToInstr
  , buildInstrGraph
  , InstrNode (..)
  , InstrGraph (..)
    -- * Pipeline entry point
  , compileProcedureViaCatOp
  , compileProcedureToLowCat
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import PB.AST.Expr (Expr (..))
import PB.AST.BodyStmt (BodyStmt)
import PB.AST.Located  (Located (..))
import PB.Analysis.CatOp (CatOp (..))
import PB.Analysis.CatLower (compileSsa)
import PB.Analysis.InstrGraph (InstrNode (..), InstrGraph (..))
import PB.Analysis.CallClassify (collectBodyLocals)
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
-- flat 'InstrGraph'.  Strips all existential type parameters so that pattern
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
-- 1b. Wiring diagrams (Plan 149 Phase 1): shared-block extraction
-- ============================================================================

-- | The wire payload for a procedure's wiring diagram: the term as compiled
-- (still containing 'LTagged' markers), plus every tagged merge block's real
-- content, keyed by its blockId, collected exactly once each.
--
-- 'ToJSON' (in "PB.Pipeline.Serialise") serialises 'LTagged' as a bare
-- reference (blockId only, no inlined payload) — the real content only ever
-- appears once, as a 'wpShared' entry. Without this split, a naive JSON
-- encoding of 'wpTerm' alone would inline a shared merge block's full
-- subtree once per predecessor, reproducing Plan 150's exact
-- multiplicative node-blowup bug at the serialization layer (found
-- empirically during Plan 149 Phase 0: a naive fold over 'LowCat' hung for
-- 15+ minutes on a real corpus procedure before this dedup was added).
data WiringPayload = WiringPayload
  { wpTerm   :: LowCat
  , wpShared :: Map.Map Text LowCat
  } deriving (Eq, Show, Generic)

-- | Split a compiled 'LowCat' term into itself (unchanged — 'LTagged'
-- markers stay in place) plus a side table of every distinct tagged merge
-- block's content, collected once per blockId. Mirrors
-- 'BuilderState.bsBlockPcMemo'\'s contract: the first encounter of a given
-- blockId records its content and recurses into it (to find any further
-- tags nested inside); a repeat encounter is skipped outright, since its
-- content — and everything nested inside it — was already collected the
-- first time.
collectWiring :: LowCat -> (LowCat, Map.Map Text LowCat)
collectWiring t = (t, walkShared Map.empty t)

walkShared :: Map.Map Text LowCat -> LowCat -> Map.Map Text LowCat
walkShared acc node = case node of
  LTagged bid inner
    | Map.member bid acc -> acc
    | otherwise          -> walkShared (Map.insert bid inner acc) inner
  LCompose a b -> walkShared (walkShared acc a) b
  LFanIn a b   -> walkShared (walkShared acc a) b
  LFork a b    -> walkShared (walkShared acc a) b
  LLoop a      -> walkShared acc a
  _            -> acc

-- ============================================================================
-- 2. GraphBuilder: InstrGraph Target (Phase 4 — backward chaining)
-- ============================================================================

-- | State for the graph builder.  Nodes are keyed by PC; allocation is sequential.
data BuilderState = BuilderState
  { bsNodes       :: Map.Map Int InstrNode
  , bsNextPc      :: Int
  , bsSourceLines :: [(Int, Int)]
  , bsExitPc      :: Int
    -- ^ The pc of the procedure's one true exit (the 'InstrReturn' node
    -- allocated first, in 'buildInstrGraph'). Fixed for the whole build
    -- regardless of loop nesting — 'LReturn' (Plan 146 Phase 2i) resolves
    -- here directly instead of whatever local @nextPc@ a loop's own
    -- break/post-loop threading passed in.
  , bsBlockPcMemo :: Map.Map (Text, Int) Int
    -- ^ Plan 150: (blockId, continuation pc) -> the pc already allocated
    -- the first time 'compileLowCatToInstr' lowered a 'LTagged' node for this
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
allocateNode :: InstrNode -> GraphBuilder Int
allocateNode node = do
  pc <- peekNextPc
  GraphBuilder $ modify $ \s -> s { bsNextPc = bsNextPc s P.+ 1, bsNodes = Map.insert pc node (bsNodes s) }
  return pc

-- | Register a node at a specific PC (for patching, e.g. loop headers).
registerNodeAt :: Int -> InstrNode -> GraphBuilder ()
registerNodeAt pc node = GraphBuilder $ modify $ \s ->
  s { bsNodes = Map.insert pc node (bsNodes s) }

-- | Finalize: convert the node map to a sorted list for InstrGraph.
finalizeGraph :: Int -> BuilderState -> InstrGraph
finalizeGraph entryPc s = InstrGraph
  { igNodes            = map P.snd (Map.toAscList (bsNodes s))
  , igEntry            = entryPc
  , igSuspensionPoints = []
  , igSourceMap        = bsSourceLines s
  }

-- | Initial builder state.
initState :: BuilderState
initState = BuilderState { bsNodes = Map.empty, bsNextPc = 0, bsSourceLines = [], bsExitPc = 0, bsBlockPcMemo = Map.empty }

-- | Compile a CatOp into InstrGraph nodes.
-- Lowers to 'LowCat' first (stripping GADT types), then compiles.
compileCatToInstr :: CatOp a b -> Int -> GraphBuilder Int
compileCatToInstr catOp nextPc = compileLowCatToInstr (toLowCat catOp) nextPc

-- | Compile a 'LowCat' into InstrGraph nodes using backward chaining.
-- Takes the continuation PC (where to jump after) and returns the entry PC.
-- All pattern matching is on plain constructors — no unsafeCoerce.
compileLowCatToInstr :: LowCat -> Int -> GraphBuilder Int
compileLowCatToInstr LId nextPc = return nextPc
compileLowCatToInstr (LAssignWithRhs var expr) nextPc =
  allocateNode (InstrAssign { anVar = var, anRhs = expr, anNext = nextPc })
-- Branch pattern: intercept CatFanIn + condition before CatCompose tears them apart.
compileLowCatToInstr (LCompose g f) nextPc = case inspectBranchLowCat g of
  Just (tOp, fOp) -> do
    -- No join InstrNop: both arms fall through directly to nextPc, matching the
    -- old compiler (PB.Analysis.InstrGraph never allocates a node purely to
    -- serve as a join point). See Plan 145 Finding A.
    let branchCond = extractCondLowCat f
    elseEntryPc <- compileLowCatToInstr fOp nextPc
    thenEntryPc <- compileLowCatToInstr tOp nextPc
    branchEntryPc <- allocateNode (InstrBranch { brCond = branchCond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
    compileLowCatToInstr f branchEntryPc
  Nothing -> do
    gEntryPc <- compileLowCatToInstr g nextPc
    fEntryPc <- compileLowCatToInstr f gEntryPc
    return fEntryPc
compileLowCatToInstr (LFanIn tOp fOp) nextPc =
  compileBranchDiamondLowCat ExNull tOp fOp nextPc
compileLowCatToInstr (LLoop body) nextPc = compileLoopLowCat body nextPc
compileLowCatToInstr (LCall name args) nextPc =
  allocateNode (InstrCallProc { cpCallee = name, cpArgs = args, cpNext = nextPc })
compileLowCatToInstr (LSuspend eff args) nextPc =
  allocateNode (InstrSuspend { suEffect = eff, suArgs = args, suVar = Nothing, suContinuation = nextPc })
-- | True procedure return (Plan 146 Phase 2i): ignore whatever local
-- continuation this call site threaded in (a loop's own break/post-loop pc,
-- however deeply nested) and resolve straight to the one true exit recorded
-- in 'BuilderState' by 'buildInstrGraph'.
compileLowCatToInstr LReturn _nextPc = GraphBuilder (gets bsExitPc)
-- | Plan 150: a merge block's tagged content. On the first encounter (for
-- this blockId + continuation), lower it for real and remember the pc; on
-- every later encounter, reuse that pc instead of re-lowering (and
-- re-allocating a full duplicate subgraph for) the same content again —
-- this is what stops sequential merge points (if/elseif chains,
-- choose/case) from compounding multiplicatively.
compileLowCatToInstr (LTagged bid inner) nextPc = do
  cached <- lookupBlockPcMemo bid nextPc
  case cached of
    Just pc -> return pc
    Nothing -> do
      pc <- compileLowCatToInstr inner nextPc
      registerBlockPcMemo bid nextPc pc
      return pc
-- Structural / erased constructors
compileLowCatToInstr _ nextPc = return nextPc

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

-- | Emit a branch diamond: InstrBranch + then-path + else-path, converging at a join nop.
compileBranchDiamondLowCat :: Expr -> LowCat -> LowCat -> Int -> GraphBuilder Int
compileBranchDiamondLowCat cond tOp fOp nextPc = do
  joinPc <- allocateNode (InstrNop { npNext = nextPc })
  elseEntryPc <- compileLowCatToInstr fOp joinPc
  thenEntryPc <- compileLowCatToInstr tOp joinPc
  allocateNode (InstrBranch { brCond = cond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })

-- | Compile a loop: reserve a header pc, compile the body with a back-edge
-- to it, then patch the reserved pc directly with the header's real content
-- (typically a 'InstrBranch') instead of forwarding to a separately-allocated
-- node. Mirrors 'PB.Analysis.InstrGraph'\'s @BsFor@\/@BsDo@ pattern: emit a
-- placeholder pc, then @patchNode@ it in place once the real content is
-- known — no residual hop (Plan 145).
compileLoopLowCat :: LowCat -> Int -> GraphBuilder Int
compileLoopLowCat body nextPc = do
  loopHeaderPc <- allocateNode (InstrNop { npNext = -1 })
  patchLoopHeaderLowCat body loopHeaderPc nextPc
  return loopHeaderPc

-- | Compile the loop's header\/body content, patching the reserved
-- 'loopHeaderPc' directly with the node the header produces (a 'InstrBranch'
-- for for\/while loops — the common case) rather than allocating a fresh pc
-- and leaving 'loopHeaderPc' as a forwarding 'InstrNop'. Falls back to the old
-- forwarding-'InstrNop' behaviour for any other shape (e.g. a headerless
-- infinite @do...loop@), which is unchanged from before this fix.
patchLoopHeaderLowCat :: LowCat -> Int -> Int -> GraphBuilder ()
patchLoopHeaderLowCat (LCompose g f) loopHeaderPc nextPc
  | Just (tOp, fOp) <- inspectBranchLowCat g = do
      let branchCond = extractCondLowCat f
      elseEntryPc <- compileLoopBodyLowCat fOp loopHeaderPc nextPc
      thenEntryPc <- compileLoopBodyLowCat tOp loopHeaderPc nextPc
      registerNodeAt loopHeaderPc (InstrBranch { brCond = branchCond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
patchLoopHeaderLowCat body loopHeaderPc nextPc = do
  bodyEntryPc <- compileLoopBodyLowCat body loopHeaderPc nextPc
  registerNodeAt loopHeaderPc (InstrNop { npNext = bodyEntryPc })

-- | Compile a loop body. 'LInl'/'LInr' are pure value-routing markers (which
-- of the two known pcs execution resumes at) — structural/erased, like
-- 'LEval'\/'LFork'\/'LSplitValue' in 'compileLowCatToInstr'. They resolve
-- directly to 'loopHeaderPc'\/'nextPc' as entry pcs; no node is allocated.
-- The old compiler ('PB.Analysis.InstrGraph') never allocates a node for
-- the implicit loop continue\/break either — it threads @(incrPc,
-- fallthrough)@ straight through as raw pcs (Plan 145).
compileLoopBodyLowCat :: LowCat -> Int -> Int -> GraphBuilder Int
compileLoopBodyLowCat LInl loopHeaderPc _nextPc = return loopHeaderPc
compileLoopBodyLowCat LInr _loopHeaderPc nextPc  = return nextPc
-- Branch pattern inside loops: intercept LFanIn + condition before LCompose tears them apart.
compileLoopBodyLowCat (LCompose g f) loopHeaderPc nextPc
  | Just (tOp, fOp) <- inspectBranchLowCat g = do
      -- No join InstrNop here either — same fix as the top-level branch case
      -- above (Plan 145 Finding A).
      let branchCond = extractCondLowCat f
      elseEntryPc <- compileLoopBodyLowCat fOp loopHeaderPc nextPc
      thenEntryPc <- compileLoopBodyLowCat tOp loopHeaderPc nextPc
      branchEntryPc <- allocateNode (InstrBranch { brCond = branchCond, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
      compileLoopBodyLowCat f loopHeaderPc branchEntryPc
compileLoopBodyLowCat (LCompose g f) loopHeaderPc nextPc = do
  gEntryPc <- compileLoopBodyLowCat g loopHeaderPc nextPc
  compileLoopBodyLowCat f loopHeaderPc gEntryPc
compileLoopBodyLowCat (LFanIn tOp fOp) loopHeaderPc nextPc = do
  thenEntryPc <- compileLoopBodyLowCat tOp loopHeaderPc nextPc
  elseEntryPc <- compileLoopBodyLowCat fOp loopHeaderPc nextPc
  allocateNode (InstrBranch { brCond = ExNull, brThenPc = thenEntryPc, brElsePc = elseEntryPc })
-- | Plan 150: a merge block inside a loop body (e.g. an if/else's shared
-- tail before the back-edge). Must recurse via 'compileLoopBodyLowCat'
-- (not delegate to the loop-unaware 'compileLowCatToInstr', which would
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
  compileLowCatToInstr linearOp nextPc

-- | Build a flat InstrGraph from a structured CatOp.
buildInstrGraph :: CatOp () () -> InstrGraph
buildInstrGraph catOp =
  let (entryPc, finalState) = runState (runBuilder $ do
        exitPc <- allocateNode (InstrReturn Nothing)
        GraphBuilder $ modify $ \s -> s { bsExitPc = exitPc }
        compileCatToInstr catOp exitPc
        ) initState
  in finalizeGraph entryPc finalState

-- | Unified entry point: compile a procedure body via the SSA → CatOp pipeline.
--
-- Seeds 'steLocal' with the body's own local variable declarations before
-- compiling, mirroring 'PB.Analysis.InstrGraph.compileProcedure' exactly —
-- without this, 'classifyExpr' can never resolve a *locally-declared*
-- datastore/datawindow/transaction variable's type, so a suspend method call
-- on it (retrieve/update/commit/…) always falls through to the conservative
-- 'PureCall' default (Plan 146 Phase 2e).
compileProcedureViaCatOp :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> InstrGraph
compileProcedureViaCatOp env userFns body =
  let env' = env { steLocal = collectBodyLocals body `Map.union` steLocal env }
  in buildInstrGraph (compileSsa env' userFns (buildSsa env' "proc" body))

-- | Same SSA → CatOp pipeline as 'compileProcedureViaCatOp', stopping at the
-- 'LowCat' term instead of flattening to 'InstrGraph' (Plan 149 Phase 1 —
-- wiring diagrams need the term itself). Deliberately NOT factored to share
-- code with 'compileProcedureViaCatOp' — that function is the verified
-- production hot path (Plan 146's oracle gated every change to it on a
-- byte-identical `--dual-trace` diff list), and duplicating this one small
-- env-seeding expression is a smaller risk than refactoring it.
compileProcedureToLowCat :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> LowCat
compileProcedureToLowCat env userFns body =
  let env' = env { steLocal = collectBodyLocals body `Map.union` steLocal env }
  in toLowCat (compileSsa env' userFns (buildSsa env' "proc" body))
