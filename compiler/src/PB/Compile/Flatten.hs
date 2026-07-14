{-# LANGUAGE StrictData #-}
-- | 'NamedGraphBuilder' — the 'EffTerm'-native flattener whose entry point,
-- 'compileProcedureViaEffTerm', is the production one-call pipeline entry
-- point to flat @InstrGraph@ (the PC-indexed representation the TS runtime
-- executes) — plus 'WiringBuilder', the sibling 'EffTerm'-native flattener
-- for wiring diagrams. Flattening goes via a named graph
-- ('PB.Compile.InstrTypes.InstrGraph''/'linearize'): nodes are compiled
-- into a 'Text'-keyed graph (dedup on blockId alone, no continuation-keyed
-- memo) and then numbered by a single pure BFS pass.
--
-- Pure module — no I/O (the @NamedBuilder@ monad is a bare 'State', never
-- 'IO'). This module is the last stage of the categorical compiler
-- pipeline, producing the artifact ('InstrGraph') the rest of the compiler
-- pipeline and the TS runtime actually consume.
module PB.Compile.Flatten
  ( -- * Named-graph InstrGraph' construction
    InstrNode (..)
  , InstrGraph (..)
    -- * NamedGraphBuilder: Effectful instance over EffTerm
  , NGB (..)
  , buildEffGraphNamed
  , compileProcedureViaEffTerm
    -- * WiringBuilder: Effectful instance over EffTerm for wiring diagrams
  , WiringNode (..)
  , WiringGraph (..)
  , WB (..)
  , buildEffGraphWiring
  , compileProcedureToWiring
    -- * Pipeline entry point
  , compileProcedureToEff
  ) where

import PB.Prelude hiding (id, (.), lookup)
import qualified Prelude as P
import PB.AST.Expr (Expr (..))
import PB.AST.BodyStmt (BodyStmt)
import PB.AST.Located  (Located (..))
import PB.Compile.IR
  ( EffTerm (..)
  , Category (..), Cartesian (..), Cocartesian (..), Effectful (..), foldFreyd, branch
  )
import PB.Compile.FromSSA (compileSsaToEff)
import PB.Compile.InstrTypes (InstrNode (..), InstrGraph (..), InstrNode' (..), InstrGraph' (..), linearize)
import PB.Analysis.CallClassify (collectBodyLocals)
import PB.Analysis.SSA (buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import Control.Monad.State.Strict (State, gets, modify, runState)
import GHC.Generics (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

-- | Compile a procedure body via the SSA → 'Eff' pipeline, stopping at the
-- 'EffTerm' (the Freyd premonoidal category, spine + shared-term table).
-- Seeds 'steLocal' with the body's own local variable declarations before
-- compiling, mirroring 'PB.Compile.InstrTypes.compileProcedure' exactly —
-- without this, 'classifyExpr' can never resolve a *locally-declared*
-- datastore/datawindow/transaction variable's type, so a suspend method
-- call on it (retrieve/update/commit/…) always falls through to the
-- conservative 'PureCall' default.
compileProcedureToEff :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> EffTerm () ()
compileProcedureToEff env userFns body =
  let env' = env { steLocal = collectBodyLocals body `Map.union` steLocal env }
  in compileSsaToEff env' userFns (buildSsa env' "proc" body)

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
-- ============================================================================
-- 3. NamedGraphBuilder: an 'Effectful' instance over 'EffTerm'
-- ============================================================================
--
-- 'NGB' is a genuine 'Category'/'Cartesian'/'Cocartesian'/'Effectful' instance
-- that compiles 'EffTerm' directly into a named 'InstrGraph'' graph. Its
-- representation is a continuation category over 'NamedBuilder': "given where
-- control continues after this morphism, return where control enters it".
--
-- Carries a second 'Text' continuation for loop body resolution: a loop body's
-- 'Eff a (Either a b)' resolves 'Left' (continue) and 'Right' (exit) to two
-- different targets. A single continuation cannot encode that split; every
-- 'Cocartesian'/'Effectful' method threads the second ("innermost enclosing
-- loop's re-entry point") argument unchanged, and only 'inl' reads it (a
-- loop-continue) while everything else ignores it. Outside any loop it is
-- never read — 'inl'/'inr' at the top level fold to a no-op.
newtype NGB a b = NGB { runNGB :: Text -> Text -> NamedBuilder Text }
-- ^ @runNGB morphism next loopCont@.

instance Category NGB where
  id = NGB (\next _loopCont -> return next)
  NGB g . NGB f = NGB (\next loopCont -> do
    gEntry <- g next loopCont
    f gEntry loopCont)

-- | Vestigial: a cartesian fork over 'Eff' never typechecks (see 'Eff'\'s own
-- header note), so no compiled 'EffTerm' can ever call these — needed only
-- because 'foldFreyd'\'s signature requires 'Cartesian k'. Erasing to a no-op
-- matches the treatment in the old LowCat compiler's catch-all (structural
-- routing, no node).
instance Cartesian NGB where
  exl = NGB (\next _loopCont -> return next)
  exr = NGB (\next _loopCont -> return next)
  _ &&& _ = NGB (\next _loopCont -> return next)

instance Cocartesian NGB where
  inl = NGB (\_next loopCont -> return loopCont)
  inr = NGB (\next _loopCont -> return next)
  -- Generic fan-in: used only by a hand-built 'EFanIn' with no recognized
  -- condition (production compiled terms exclusively go through 'EBranch',
  -- dispatched via 'branchK'). Placeholder 'ExNull' condition included.
  NGB t ||| NGB f = NGB (\next loopCont -> do
    elseEntry <- f next loopCont
    thenEntry <- t next loopCont
    n <- freshName
    defineNode n (InstrBranch' { brCond' = ExNull, brThenPc' = thenEntry, brElsePc' = elseEntry })
    return n)

instance Effectful NGB where
  -- Vestigial (same reasoning as 'Cartesian'\'s instance): a bare 'eval'\/
  -- 'assign' pair is never emitted by compiled terms (only the fused
  -- 'EAssignWithRhs', via 'assignWithRhs' below); erase to no-ops.
  eval _   = NGB (\next _loopCont -> return next)
  assign _ = NGB (\next _loopCont -> return next)
  lookup _ = NGB (\next _loopCont -> return next)
  suspend eff args = NGB (\next _loopCont -> do
    n <- freshName
    defineNode n (InstrSuspend' { suEffect' = eff, suArgs' = args, suVar' = Nothing, suContinuation' = next })
    return n)
  callProc name args = NGB (\next _loopCont -> do
    n <- freshName
    defineNode n (InstrCallProc' { cpCallee' = name, cpArgs' = args, cpNext' = next })
    return n)
  splitValue = NGB (\next _loopCont -> return next)
  ret = NGB (\_next _loopCont -> NamedBuilder (gets nbsExitName))
  -- Installs a fresh loop-header name as the new 'loopCont' for the body's
  -- own fold, while the body's "next" stays THIS loopK call's own incoming
  -- 'next' (the true post-loop exit target). Passing 'loopHeaderName' for
  -- both makes 'inr' — the loop's own exit case — resolve back to the header
  -- instead of out of the loop, so the loop never terminates. Then defines
  -- that header as an unconditional jump to the body's entry. Correct but not
  -- shape-minimal: the NGB always emits an 'InstrNop'' header.
  loopK (NGB body) = NGB (\next _loopCont -> do
    loopHeaderName <- freshName
    bodyEntry <- body next loopHeaderName
    defineNode loopHeaderName (InstrNop' { npNext' = bodyEntry })
    return loopHeaderName)
  -- The whole point: direct, simultaneous access to the condition and both
  -- arms instead of peeking a generically-folded structure apart after the fact.
  branchK cond (NGB t) (NGB f) = NGB (\next loopCont -> do
    elseEntry <- f next loopCont
    thenEntry <- t next loopCont
    n <- freshName
    defineNode n (InstrBranch' { brCond' = cond, brThenPc' = thenEntry, brElsePc' = elseEntry })
    return n)
  -- Direct access to the variable and the expression together — the generic
  -- derivation (@assign var . (id &&& eval e)@) would erase through this
  -- carrier's no-value-channel 'eval'\/'(&&&)', silently dropping the RHS.
  assignWithRhs var e = NGB (\next _loopCont -> do
    n <- freshName
    defineNode n (InstrAssign' { anVar' = var, anRhs' = e, anNext' = next })
    return n)
  -- The 'nbsBlockMemo'-equivalent cache: memoizes by blockId in
  -- 'NamedBuilder'\'s own state, so a shared body is *materialized* once
  -- regardless of how many syntactic 'ELetRef' occurrences 'foldFreyd'\'s
  -- own (fold-time-only) cache lets reach here. Without this, each
  -- occurrence would re-invoke the folded 'NGB' action and allocate a
  -- fresh copy of the whole shared block's nodes — the exact multiplicative
  -- blowup this memoization exists to prevent.
  memoTag bid (NGB action) = NGB (\next loopCont -> do
    memo <- NamedBuilder (gets nbsBlockMemo)
    case Map.lookup bid memo of
      Just entry -> return entry
      Nothing -> do
        entry <- action next loopCont
        NamedBuilder $ modify $ \s -> s { nbsBlockMemo = Map.insert bid entry (nbsBlockMemo s) }
        return entry)

-- | Build a named graph directly from an 'EffTerm' via 'foldFreyd' specialized
-- to 'NGB'. No enclosing loop at the top level, so the initial
-- loop-continuation argument is never read (see 'NGB'\'s header note).
buildEffGraphNamed :: EffTerm () () -> InstrGraph' Text
buildEffGraphNamed effTerm =
  let (entryName, finalState) = runState (runNamedBuilder $ do
        exitName <- freshName
        defineNode exitName (InstrReturn' { reValue' = Nothing })
        NamedBuilder $ modify $ \s -> s { nbsExitName = exitName }
        runNGB (foldFreyd effTerm) exitName exitName
        ) initNamedState
  in InstrGraph' { igNodes' = nbsNodes finalState, igEntry' = entryName }

-- | Same SSA -> 'Eff' pipeline as 'compileProcedureToEff', flattened via the
-- 'foldFreyd'/'NGB' path. The production entry point (both 'PB.Pipeline.Emit'
-- and 'PB.Pipeline.Runner' call this).
compileProcedureViaEffTerm :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> InstrGraph
compileProcedureViaEffTerm env userFns body =
  linearize (buildEffGraphNamed (compileProcedureToEff env userFns body))

-- ============================================================================
-- 4. WiringBuilder: an 'Effectful' instance over 'EffTerm' for wiring
--    diagrams, replacing the old 'collectWiring'/'WiringPayload'
-- ============================================================================
--
-- Answers a different question than 'NGB': not "what flat instruction
-- sequence executes this" but "what does this program's shape look like as
-- a shared DAG". 'InstrGraph'' (a 'Text'-keyed 'Map' + entry name) already
-- IS a flat, shared, name-addressed graph — a node is defined once per name
-- and referenced by name elsewhere — so no bespoke second pass over a
-- tree-shaped intermediate is needed: dedup falls out of 'Map.Map' key
-- uniqueness in 'wbsBlockMemo', the same argument that already makes
-- 'NGB'\'s 'memoTag' sound.
--
-- 'WiringNode' is a sibling type to 'InstrNode'', not a reuse of it: unlike
-- 'NGB', a wiring diagram wants the branch condition as its own visible node
-- ('WireCond'), with a separate join\/fork node ('WireBranch', no condition
-- of its own — it already appeared upstream). Reusing 'InstrNode'' would
-- force 'linearize'\/'toInstrNode' (the execution-ISA path, shared with
-- 'NGB') to grow a dead-but-mandatory case for a node no execution path ever
-- produces.
data WiringNode p
  = WireAssign  { waVar :: Text, waRhs :: Expr, waNext :: p }
  | WireCond    { wcExpr :: Expr, wcNext :: p }
    -- ^ The branch condition, evaluated for display — a single-successor
    -- node with no fork of its own.
  | WireBranch  { wtThen :: p, wtElse :: p }
    -- ^ The then\/else fork\/join. No condition field: 'branchK'\'s generic
    -- derivation (below) always runs 'eval' (a 'WireCond') immediately
    -- upstream of this, so the condition is already visible one node back.
  | WireCall    { wclCallee :: Text, wclArgs :: [Expr], wclNext :: p }
  | WireSuspend { wsEffect :: Text, wsArgs :: [Expr], wsNext :: p }
  | WireReturn
  | WireNop     { wnNext :: p }
  deriving (Eq, Show, Generic)

-- | A procedure's wiring diagram: every distinct node, keyed by name, plus
-- the entry name — the same "nodes keyed by name, edges by reference" shape
-- 'InstrGraph'' already has. Serializes directly (no 'WiringPayload'-style
-- term/shared split needed).
data WiringGraph p = WiringGraph
  { wgNodes :: Map.Map Text (WiringNode p)
  , wgEntry :: p
  } deriving (Eq, Show, Generic)

-- | State for the wiring-diagram builder. Sibling to 'NamedBuilderState',
-- keyed to 'WiringNode' instead of 'InstrNode''.
data WiringBuilderState = WiringBuilderState
  { wbsNodes     :: Map.Map Text (WiringNode Text)
  , wbsCounter   :: Int
  , wbsExitName  :: Text
  , wbsBlockMemo :: Map.Map Text Text
  }

newtype WiringB a = WiringB { runWiringB :: State WiringBuilderState a }

instance Functor WiringB where
  fmap f (WiringB m) = WiringB (fmap f m)

instance Applicative WiringB where
  pure a = WiringB (pure a)
  WiringB f <*> WiringB a = WiringB (f <*> a)

instance Monad WiringB where
  WiringB m >>= f = WiringB (m >>= (runWiringB P.. f))

initWiringState :: WiringBuilderState
initWiringState = WiringBuilderState
  { wbsNodes = Map.empty, wbsCounter = 0, wbsExitName = "", wbsBlockMemo = Map.empty }

freshWireName :: WiringB Text
freshWireName = WiringB $ do
  n <- gets wbsCounter
  modify $ \s -> s { wbsCounter = n P.+ 1 }
  return ("w" <> T.pack (show n))

defineWireNode :: Text -> WiringNode Text -> WiringB ()
defineWireNode name node = WiringB $ modify $ \s -> s { wbsNodes = Map.insert name node (wbsNodes s) }

-- | @runWB morphism next loopCont@ — same continuation shape as 'NGB'
-- (see its own header note for why a loop needs two distinct
-- continuations).
newtype WB a b = WB { runWB :: Text -> Text -> WiringB Text }

instance Category WB where
  id = WB (\next _loopCont -> return next)
  WB g . WB f = WB (\next loopCont -> do
    gEntry <- g next loopCont
    f gEntry loopCont)

instance Cartesian WB where
  -- Vestigial, same reasoning as 'NGB'\'s instance: a cartesian fork over
  -- an effectful subterm never typechecks, so no compiled 'EffTerm' can
  -- ever reach these directly.
  exl = WB (\next _loopCont -> return next)
  exr = WB (\next _loopCont -> return next)
  -- NOT erased like 'NGB'\'s (deliberately): 'branchK'\'s generic
  -- derivation below relies on @id &&& eval cond@ actually building
  -- 'eval'\'s node ('g', the RHS) — erasing both arguments the way 'NGB'
  -- does would silently drop the condition, since 'NGB' never routes
  -- through this operator at all (it overrides 'branchK' directly).
  -- 'f' (always 'id' at every real call site) contributes nothing, so
  -- only 'g' need run.
  WB f &&& WB g = WB (\next loopCont -> do
    gEntry <- g next loopCont
    f gEntry loopCont)

instance Cocartesian WB where
  inl = WB (\_next loopCont -> return loopCont)
  inr = WB (\next _loopCont -> return next)
  WB t ||| WB f = WB (\next loopCont -> do
    elseEntry <- f next loopCont
    thenEntry <- t next loopCont
    n <- freshWireName
    defineWireNode n (WireBranch { wtThen = thenEntry, wtElse = elseEntry })
    return n)

instance Effectful WB where
  -- The whole point of 'WiringBuilder': unlike 'NGB', 'eval' is NOT erased
  -- — it builds a real, visible 'WireCond' node, so 'branchK'\'s generic
  -- derivation (below) surfaces the condition as its own node instead of
  -- fusing it into the fork.
  eval e = WB (\next _loopCont -> do
    n <- freshWireName
    defineWireNode n (WireCond { wcExpr = e, wcNext = next })
    return n)
  assign _ = WB (\next _loopCont -> return next)
  lookup _ = WB (\next _loopCont -> return next)
  suspend eff args = WB (\next _loopCont -> do
    n <- freshWireName
    defineWireNode n (WireSuspend { wsEffect = eff, wsArgs = args, wsNext = next })
    return n)
  callProc name args = WB (\next _loopCont -> do
    n <- freshWireName
    defineWireNode n (WireCall { wclCallee = name, wclArgs = args, wclNext = next })
    return n)
  splitValue = WB (\next _loopCont -> return next)
  ret = WB (\_next _loopCont -> WiringB (gets wbsExitName))
  -- Structurally identical to 'NGB'\'s 'loopK' — loop-header fusion is an
  -- NGB-only ISA concern, not a wiring-diagram one.
  loopK (WB body) = WB (\next _loopCont -> do
    loopHeaderName <- freshWireName
    bodyEntry <- body next loopHeaderName
    defineWireNode loopHeaderName (WireNop { wnNext = bodyEntry })
    return loopHeaderName)
  -- "Default": the generic 'branch' derivation, not a fused primitive like
  -- 'NGB'\'s override — a wiring diagram wants cond/then/else as separate
  -- visible nodes, which running the derivation for real (given this
  -- instance's non-erased 'eval'/'(&&&)') produces directly: a 'WireCond'
  -- node immediately upstream of the 'WireBranch' fork built by '(|||)'.
  branchK cond t f = branch cond t f
  assignWithRhs var e = WB (\next _loopCont -> do
    n <- freshWireName
    defineWireNode n (WireAssign { waVar = var, waRhs = e, waNext = next })
    return n)
  -- Same reasoning as 'NGB'\'s 'memoTag': without this, a shared 'ELetRef'
  -- body would be re-materialized (fresh node names allocated) once per
  -- syntactic occurrence, reintroducing the multiplicative blowup this
  -- memoization exists to prevent.
  memoTag bid (WB action) = WB (\next loopCont -> do
    memo <- WiringB (gets wbsBlockMemo)
    case Map.lookup bid memo of
      Just entry -> return entry
      Nothing -> do
        entry <- action next loopCont
        WiringB $ modify $ \s -> s { wbsBlockMemo = Map.insert bid entry (wbsBlockMemo s) }
        return entry)

-- | Build a wiring diagram directly from an 'EffTerm' via 'foldFreyd'
-- specialized to 'WB' — the replacement for 'collectWiring'\/'WiringPayload'.
-- No enclosing loop at the top level, so the initial loop-continuation
-- argument is never read (see 'WB'\'s header note, same as 'NGB'\'s).
buildEffGraphWiring :: EffTerm () () -> WiringGraph Text
buildEffGraphWiring effTerm =
  let (entryName, finalState) = runState (runWiringB $ do
        exitName <- freshWireName
        defineWireNode exitName WireReturn
        WiringB $ modify $ \s -> s { wbsExitName = exitName }
        runWB (foldFreyd effTerm) exitName exitName
        ) initWiringState
  in WiringGraph { wgNodes = wbsNodes finalState, wgEntry = entryName }

-- | Same SSA -> 'Eff' pipeline as 'compileProcedureToEff', flattened via
-- 'buildEffGraphWiring' instead of 'buildEffGraphNamed' — the wiring
-- diagram's own entry point.
compileProcedureToWiring :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> WiringGraph Text
compileProcedureToWiring env userFns body =
  buildEffGraphWiring (compileProcedureToEff env userFns body)
