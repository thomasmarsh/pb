{-# LANGUAGE StrictData #-}
-- | 'CatOp' → flat @InstrGraph@ flattening, plus 'LowCat' — the monomorphic
-- intermediary that bridges the GADT-indexed 'CatOp' to the flat,
-- PC-indexed 'InstrGraph' the current TS runtime executes — and the public
-- one-call pipeline entry point, 'compileProcedureViaCatOp'. Flattening goes
-- via a named graph ('PB.Analysis.InstrGraph.InstrGraph''/'linearize', Plan
-- 167 Phase 6 Approach C): 'LowCat' nodes are compiled into a 'Text'-keyed
-- graph (dedup on blockId alone, no continuation-keyed memo) and then
-- numbered by a single pure BFS pass.
--
-- Pure module — no I/O (the @NamedBuilder@ monad is a bare 'State', never
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
  , toLowCatOp
  , extractCondLowCat
    -- * Wiring diagrams (Plan 149 Phase 1)
  , WiringPayload (..)
  , collectWiring
    -- * Named-graph InstrGraph' construction (Plan 167 Phase 6, Approach C)
  , buildInstrGraphNamed
  , InstrNode (..)
  , InstrGraph (..)
    -- * Pipeline entry point
  , compileProcedureViaCatOp
  , compileProcedureToLowCat
  , compileProcedureToCatOp
  , compileProcedureToCatTerm
  , compileProcedureToEff
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import PB.AST.Expr (Expr (..))
import PB.AST.BodyStmt (BodyStmt)
import PB.AST.Located  (Located (..))
import PB.Analysis.CatOp (CatOp (..), EffTerm (..), extractTable, inlineTable, CatTerm (..))
import PB.Analysis.CatLower (compileSsa)
import PB.Analysis.CatLowerEff (compileSsaToEff)
import PB.Analysis.InstrGraph (InstrNode (..), InstrGraph (..), InstrNode' (..), InstrGraph' (..), linearize)
import PB.Analysis.CallClassify (collectBodyLocals)
import PB.Analysis.SSA (buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import Control.Monad.State.Strict (State, evalState, gets, modify, runState)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

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
--
-- Memoized by 'CatTagged'\'s blockId (threaded via an internal 'State', not
-- exposed in the signature): 'compileBlock'/'compileLoopBody' (CatLower.hs)
-- already memoize compilation by blockId, so a merge point reached by N
-- predecessors is compiled once and the SAME 'CatOp' heap value is embedded
-- at all N call sites — real Haskell sharing. Without this memo, walking
-- that shared DAG here would re-run the full recursive conversion once per
-- embedding, and — because every switch's N-way fan-in reconverges on the
-- single block that starts the next switch — that cost compounds
-- multiplicatively across a chain of switches (fn_dateolografos.srf's real
-- shape: 7 sequential/nested choose/case blocks). This is safe because a
-- given blockId's tagged content is identical at every occurrence within
-- one procedure's compiled term, by construction of that same
-- 'compileBlock'/'compileLoopBody' memo — so caching by blockId text alone
-- (ignoring the GADT's type parameters) is sound: a repeat encounter always
-- carries the same content, never a different one under the same tag.
--
-- __Phase 4 (table-native).__ 'toLowCat' now takes a 'CatTerm' (spine +
-- table) and resolves 'CatLetRef bid' by consulting the table, folding the
-- body once and caching the result in the 'State' memo — the same memo
-- mechanism the 'CatTagged' clause uses, with the body sourced from the
-- table instead of inline. No 'unsafeCoerce' is needed (unlike 'foldCat'\'s
-- 'CatLetRef' clause): 'go' is polymorphic and produces monomorphic
-- 'LowCat', so the table\'s 'CatOp () ()' body folds directly. The
-- 'CatTagged' clause is retained (defensive; removed in Phase 7). The
-- produced 'LowCat' still carries 'LTagged bid inner' (body inlined into
-- LowCat) — NOT a name-only reference — so 'compileLowCatToInstrNamed' and
-- 'collectWiring' see the identical term they see today; their own memos
-- ('nbsBlockMemo', 'walkShared') remain load-bearing. 'toLowCatOp' is the
-- pre-Phase-4 signature for callers lowering bare 'CatOp' terms with no
-- sharing.
toLowCat :: CatTerm a b -> LowCat
toLowCat (CatTerm spine table) = evalState (go spine) Map.empty
  where
    go :: CatOp x y -> State (Map.Map Text LowCat) LowCat
    go CatId              = pure LId
    go (CatAssignWithRhs v e) = pure (LAssignWithRhs v e)
    go (CatCompose g f)   = LCompose <$> go g <*> go f
    go (CatFanIn t f)     = LFanIn <$> go t <*> go f
    go (CatLoop body)     = LLoop <$> go body
    go CatInl             = pure LInl
    go CatInr             = pure LInr
    go CatSplitValue      = pure LSplitValue
    go (CatEval e)        = pure (LEval e)
    go (CatFork l r)      = LFork <$> go l <*> go r
    go (CatCall n args)   = pure (LCall n args)
    go (CatSuspend e args) = pure (LSuspend e args)
    go CatReturn          = pure LReturn
    go (CatTagged bid f)  = do
      cached <- gets (Map.lookup bid)
      case cached of
        Just inner -> pure (LTagged bid inner)
        Nothing    -> do
          inner <- go f
          modify (Map.insert bid inner)
          pure (LTagged bid inner)
    go (CatLetRef bid)    = do
      cached <- gets (Map.lookup bid)
      case cached of
        Just inner -> pure (LTagged bid inner)
        Nothing    -> case Map.lookup bid table of
          Just body -> do
            inner <- go body
            modify (Map.insert bid inner)
            pure (LTagged bid inner)
          Nothing   -> error ("toLowCat: unbound CatLetRef " <> show bid)
    go _                  = pure LErasable  -- CatExl, CatExr, CatConst, CatLookup, CatAssign, CatTry

-- | Lower a bare 'CatOp' (no shared-term table) — the pre-Phase-4 signature
-- of 'toLowCat', kept as a convenience for callers that fold hand-built
-- 'CatOp' terms with no 'CatLetRef' use sites ('buildInstrGraphNamed', and
-- the CatOp-level unit tests in @CatOpTest@ that call it directly).
-- Equivalent to @toLowCat (CatTerm op Map.empty)@. 'toLowCat' itself now
-- takes a 'CatTerm' so it can consult the table at 'CatLetRef' use sites.
toLowCatOp :: CatOp a b -> LowCat
toLowCatOp op = toLowCat (CatTerm op Map.empty)

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
-- block's content, collected once per blockId. Mirrors 'nbsBlockMemo'\'s
-- contract: the first encounter of a given blockId records its content and
-- recurses into it (to find any further tags nested inside); a repeat
-- encounter is skipped outright, since its content — and everything nested
-- inside it — was already collected the first time.
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

-- ============================================================================
-- 2. Named-graph InstrGraph' construction (Plan 167 Phase 6, Approach C)
-- ============================================================================
--
-- 'compileLowCatToInstrNamed' (below) mirrors what the retired PC-threaded
-- lowering used to do equation for equation (same branch-pattern detection,
-- same join-point-free special case, same loop-header patch shape) — the
-- only difference is that a node's address is a 'Text' name minted (or
-- reused) here instead of an 'Int' pc allocated by a threaded 'State'. A
-- merge block's dedup is 'Map.Map' key uniqueness in 'nbsBlockMemo' (keyed
-- on blockId alone) — the continuation component a PC-threaded design would
-- need is provably redundant for a genuine merge: every predecessor of the
-- same blockId is threaded the same downstream continuation by the same
-- CPS-threading argument this module has relied on since Plan 150, so
-- caching on blockId alone is sound.
--
-- 'buildInstrGraphNamed' is the sole production flattening path
-- ('compileProcedureViaCatOp' below); it also gives the CatOp-level unit
-- tests in "CatOpTest" a direct entry point equivalent to the old
-- @buildInstrGraph@.
buildInstrGraphNamed :: CatOp a b -> InstrGraph
buildInstrGraphNamed = linearize P.. buildLowCatGraphNamed P.. toLowCatOp

-- | Unified entry point: compile a procedure body via the SSA → CatOp pipeline.
--
-- Seeds 'steLocal' with the body's own local variable declarations before
-- compiling, mirroring 'PB.Analysis.InstrGraph.compileProcedure' exactly —
-- without this, 'classifyExpr' can never resolve a *locally-declared*
-- datastore/datawindow/transaction variable's type, so a suspend method call
-- on it (retrieve/update/commit/…) always falls through to the conservative
-- 'PureCall' default (Plan 146 Phase 2e).
-- Plan 167 Phase 6 (Approach C): flattens via the named-graph builder +
-- 'linearize' ('buildInstrGraphNamed' composed with 'compileProcedureToLowCat',
-- inlined here) instead of the retired PC-threaded 'BuilderState'\/
-- 'bsBlockPcMemo' lowering.
compileProcedureViaCatOp :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> InstrGraph
compileProcedureViaCatOp env userFns body =
  linearize (buildLowCatGraphNamed (compileProcedureToLowCat env userFns body))

-- | Same SSA → CatOp pipeline as 'compileProcedureViaCatOp', stopping at the
-- 'LowCat' term instead of flattening to 'InstrGraph' (Plan 149 Phase 1 —
-- wiring diagrams need the term itself).
--
-- Plan 167 Phase 4 (table-native): now lowers via 'compileProcedureToCatTerm'
-- (the 'CatTerm' spine + table) and the table-native 'toLowCat', which
-- resolves 'CatLetRef' use sites from the table. The produced 'LowCat' still
-- carries 'LTagged bid inner' (body inlined) — the identical shape
-- 'compileLowCatToInstrNamed'/'collectWiring' consume — so 'walkShared'
-- remains load-bearing.
compileProcedureToLowCat :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> LowCat
compileProcedureToLowCat env userFns body =
  toLowCat (compileProcedureToCatTerm env userFns body)

-- | Same SSA → CatOp pipeline as 'compileProcedureViaCatOp'/
-- 'compileProcedureToLowCat', stopping at the raw compiled 'CatOp' term
-- (Plan 163 Phase 3 — 'PB.Analysis.SchFootprint.foldSchFootprint' folds
-- over exactly this type via 'PB.Analysis.CatOp.foldCat', and no existing
-- entry point exposed it). Deliberately not factored to share code with
-- the other two, same rationale as 'compileProcedureToLowCat''s own doc
-- comment: duplicating this one small env-seeding expression is a smaller
-- risk than refactoring the verified production hot path.
compileProcedureToCatOp :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> CatOp () ()
compileProcedureToCatOp env userFns body =
  inlineTable (compileProcedureToCatTerm env userFns body)

-- | Plan 167 Phase 5b Step 1 — same SSA → Eff pipeline as
-- 'compileProcedureToCatOp', stopping at the 'EffTerm' (the Freyd
-- premonoidal category, spine + shared-term table — Phase 7 Step 2)
-- instead of 'CatOp'. Parallel to 'compileProcedureToCatOp', kept
-- side-by-side for cross-checking; Phase 7 Step 6 will switch the entry
-- points once the cross-check is green over the fixture corpus. Same
-- env-seeding preamble, duplicated per the convention documented at
-- 'compileProcedureToLowCat'.
compileProcedureToEff :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> EffTerm () ()
compileProcedureToEff env userFns body =
  let env' = env { steLocal = collectBodyLocals body `Map.union` steLocal env }
  in compileSsaToEff env' userFns (buildSsa env' "proc" body)

-- | Plan 167 Phase 3 — the compiled term WITH its shared-term table.
-- Same SSA → CatOp pipeline as 'compileProcedureToCatOp' (and the same
-- env-seeding preamble, duplicated per the convention documented at
-- 'compileProcedureToLowCat' — the production hot path is NOT factored
-- to share this one expression), stopping at the 'CatTerm' (spine +
-- table) instead of the bare 'CatOp'. The spine's 'CatTagged' nodes are
-- rewritten to name-only 'CatLetRef'; each body lives once in the table.
--
-- 'compileProcedureToCatOp' is redefined below as
-- @inlineTable . compileProcedureToCatTerm@, so the two are
-- observationally identical for every existing consumer.
compileProcedureToCatTerm :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> CatTerm () ()
compileProcedureToCatTerm env userFns body =
  let env' = env { steLocal = collectBodyLocals body `Map.union` steLocal env }
  in extractTable (compileSsa env' userFns (buildSsa env' "proc" body))

-- | State for the named-graph builder.
data NamedBuilderState = NamedBuilderState
  { nbsNodes     :: Map.Map Text (InstrNode' Text)
  , nbsCounter   :: Int
  , nbsExitName  :: Text
    -- ^ The one true exit name, fixed for the whole build regardless of
    -- loop nesting.
  , nbsBlockMemo :: Map.Map Text Text
    -- ^ blockId -> the entry name already compiled for it.
  }

newtype NamedBuilder a = NamedBuilder { runNamedBuilder :: State NamedBuilderState a }

instance Functor NamedBuilder where
  fmap f (NamedBuilder m) = NamedBuilder (fmap f m)

instance Applicative NamedBuilder where
  pure a = NamedBuilder (pure a)
  NamedBuilder f <*> NamedBuilder a = NamedBuilder (f <*> a)

instance Monad NamedBuilder where
  NamedBuilder m >>= f = NamedBuilder (m >>= (runNamedBuilder P.. f))

initNamedState :: NamedBuilderState
initNamedState = NamedBuilderState
  { nbsNodes = Map.empty, nbsCounter = 0, nbsExitName = "", nbsBlockMemo = Map.empty }

-- | Mint a fresh, globally-unique synthetic node name.
freshName :: NamedBuilder Text
freshName = NamedBuilder $ do
  n <- gets nbsCounter
  modify $ \s -> s { nbsCounter = n P.+ 1 }
  return ("n" <> T.pack (show n))

-- | Define a node under a given name.
defineNode :: Text -> InstrNode' Text -> NamedBuilder ()
defineNode name node = NamedBuilder $ modify $ \s -> s { nbsNodes = Map.insert name node (nbsNodes s) }

-- | Compile a 'LowCat' into a named graph, given the name execution
-- continues at afterward. Returns the name of the compiled subgraph's entry.
compileLowCatToInstrNamed :: LowCat -> Text -> NamedBuilder Text
compileLowCatToInstrNamed LId nextName = return nextName
compileLowCatToInstrNamed (LAssignWithRhs var expr) nextName = do
  n <- freshName
  defineNode n (InstrAssign' { anVar' = var, anRhs' = expr, anNext' = nextName })
  return n
-- Branch pattern: intercept LFanIn + condition before LCompose tears them apart.
compileLowCatToInstrNamed (LCompose g f) nextName = case inspectBranchLowCat g of
  Just (tOp, fOp) -> do
    -- No join node: both arms fall through directly to nextName (Plan 145
    -- Finding A — the compiler never allocates a node purely to serve as a
    -- join point).
    let branchCond = extractCondLowCat f
    elseEntry <- compileLowCatToInstrNamed fOp nextName
    thenEntry <- compileLowCatToInstrNamed tOp nextName
    n <- freshName
    defineNode n (InstrBranch' { brCond' = branchCond, brThenPc' = thenEntry, brElsePc' = elseEntry })
    compileLowCatToInstrNamed f n
  Nothing -> do
    gEntry <- compileLowCatToInstrNamed g nextName
    compileLowCatToInstrNamed f gEntry
compileLowCatToInstrNamed (LFanIn tOp fOp) nextName = do
  elseEntry <- compileLowCatToInstrNamed fOp nextName
  thenEntry <- compileLowCatToInstrNamed tOp nextName
  n <- freshName
  defineNode n (InstrBranch' { brCond' = ExNull, brThenPc' = thenEntry, brElsePc' = elseEntry })
  return n
compileLowCatToInstrNamed (LLoop body) nextName = do
  loopHeaderName <- freshName
  patchLoopHeaderNamed body loopHeaderName nextName
  return loopHeaderName
compileLowCatToInstrNamed (LCall name args) nextName = do
  n <- freshName
  defineNode n (InstrCallProc' { cpCallee' = name, cpArgs' = args, cpNext' = nextName })
  return n
compileLowCatToInstrNamed (LSuspend eff args) nextName = do
  n <- freshName
  defineNode n (InstrSuspend' { suEffect' = eff, suArgs' = args, suVar' = Nothing, suContinuation' = nextName })
  return n
-- | True procedure return: resolve straight to the one true exit, ignoring
-- whatever local continuation this call site threaded in.
compileLowCatToInstrNamed LReturn _nextName = NamedBuilder (gets nbsExitName)
-- | A merge block's tagged content. On the first encounter, compile it for
-- real and remember its entry name; on every later encounter, reuse that
-- name — this IS the structural dedup ('nbsBlockMemo' is 'Map.Map' key
-- uniqueness on blockId alone; see this section's headnote).
compileLowCatToInstrNamed (LTagged bid inner) nextName = do
  memo <- NamedBuilder (gets nbsBlockMemo)
  case Map.lookup bid memo of
    Just entry -> return entry
    Nothing -> do
      entry <- compileLowCatToInstrNamed inner nextName
      NamedBuilder $ modify $ \s -> s { nbsBlockMemo = Map.insert bid entry (nbsBlockMemo s) }
      return entry
-- Structural / erased constructors: LInl/LInr/LEval/LFork/LSplitValue/
-- LErasable outside loop context resolve straight to nextName, no node.
compileLowCatToInstrNamed _ nextName = return nextName

-- | Compiles the loop header/body content and defines 'loopHeaderName' with
-- the resulting node. No "reserve then patch" two-step is needed — unlike
-- an 'Int' pc, a 'Text' name doesn't need a concrete value before children
-- can reference it; 'defineNode' after computing the children is
-- sufficient.
patchLoopHeaderNamed :: LowCat -> Text -> Text -> NamedBuilder ()
patchLoopHeaderNamed (LCompose g f) loopHeaderName nextName
  | Just (tOp, fOp) <- inspectBranchLowCat g = do
      let branchCond = extractCondLowCat f
      elseEntry <- compileLoopBodyLowCatNamed fOp loopHeaderName nextName
      thenEntry <- compileLoopBodyLowCatNamed tOp loopHeaderName nextName
      defineNode loopHeaderName (InstrBranch' { brCond' = branchCond, brThenPc' = thenEntry, brElsePc' = elseEntry })
patchLoopHeaderNamed body loopHeaderName nextName = do
  bodyEntry <- compileLoopBodyLowCatNamed body loopHeaderName nextName
  defineNode loopHeaderName (InstrNop' { npNext' = bodyEntry })

-- | Compiles a loop body. 'LInl'\/'LInr' resolve directly to
-- 'loopHeaderName'\/'nextName' — no node allocated for the implicit loop
-- continue\/break (Plan 145).
compileLoopBodyLowCatNamed :: LowCat -> Text -> Text -> NamedBuilder Text
compileLoopBodyLowCatNamed LInl loopHeaderName _nextName = return loopHeaderName
compileLoopBodyLowCatNamed LInr _loopHeaderName nextName = return nextName
compileLoopBodyLowCatNamed (LCompose g f) loopHeaderName nextName
  | Just (tOp, fOp) <- inspectBranchLowCat g = do
      let branchCond = extractCondLowCat f
      elseEntry <- compileLoopBodyLowCatNamed fOp loopHeaderName nextName
      thenEntry <- compileLoopBodyLowCatNamed tOp loopHeaderName nextName
      n <- freshName
      defineNode n (InstrBranch' { brCond' = branchCond, brThenPc' = thenEntry, brElsePc' = elseEntry })
      compileLoopBodyLowCatNamed f loopHeaderName n
compileLoopBodyLowCatNamed (LCompose g f) loopHeaderName nextName = do
  gEntry <- compileLoopBodyLowCatNamed g loopHeaderName nextName
  compileLoopBodyLowCatNamed f loopHeaderName gEntry
compileLoopBodyLowCatNamed (LFanIn tOp fOp) loopHeaderName nextName = do
  thenEntry <- compileLoopBodyLowCatNamed tOp loopHeaderName nextName
  elseEntry <- compileLoopBodyLowCatNamed fOp loopHeaderName nextName
  n <- freshName
  defineNode n (InstrBranch' { brCond' = ExNull, brThenPc' = thenEntry, brElsePc' = elseEntry })
  return n
-- | A merge block inside a loop body — must recurse via
-- 'compileLoopBodyLowCatNamed' (not delegate to the loop-unaware
-- 'compileLowCatToInstrNamed'): a nested 'LInl'\/'LInr' inside must still
-- resolve against 'loopHeaderName'\/'nextName', not lose the back-edge.
-- Shares 'nbsBlockMemo' with the top-level compiler (global to the whole
-- build).
compileLoopBodyLowCatNamed (LTagged bid inner) loopHeaderName nextName = do
  memo <- NamedBuilder (gets nbsBlockMemo)
  case Map.lookup bid memo of
    Just entry -> return entry
    Nothing -> do
      entry <- compileLoopBodyLowCatNamed inner loopHeaderName nextName
      NamedBuilder $ modify $ \s -> s { nbsBlockMemo = Map.insert bid entry (nbsBlockMemo s) }
      return entry
compileLoopBodyLowCatNamed linearOp _loopHeaderName nextName =
  compileLowCatToInstrNamed linearOp nextName

-- | Build a named graph from a 'LowCat' term. The sole production
-- flattening path, via 'compileProcedureViaCatOp'/'buildInstrGraphNamed'.
buildLowCatGraphNamed :: LowCat -> InstrGraph' Text
buildLowCatGraphNamed lowCat =
  let (entryName, finalState) = runState (runNamedBuilder $ do
        exitName <- freshName
        defineNode exitName (InstrReturn' { reValue' = Nothing })
        NamedBuilder $ modify $ \s -> s { nbsExitName = exitName }
        compileLowCatToInstrNamed lowCat exitName
        ) initNamedState
  in InstrGraph' { igNodes' = nbsNodes finalState, igEntry' = entryName }
