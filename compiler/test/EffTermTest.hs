module EffTermTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Ident        (mkIdent)
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..),
                            DispatchExpr (..), DispatchMode (..))
import PB.AST.Type         (PbType (..))
import PB.AST.BodyStmt     (BodyStmt (..), PbCall (..), IfStmt (..), ElseIf (..), ForStmt (..), DoStmt (..), DoCondition (..),
                            TryStmt (..), CatchClause (..), ChooseStmt (..), CaseClause (..))
import PB.AST.Located      (Located (..))
import PB.Compile.IR
import PB.Compile.FromSSA (compileSsaToEff)
import PB.Compile.Flatten
import PB.Compile.Interp
import PB.Compile.ValueModel (Value (..), TraceEvent (..))
import PB.Analysis.SchFootprint (FunctorCtx (..), SchFootprint (..))
import PB.Analysis.SchemaCategory (StmtId (..), SchMorphism (..), SchObject (..), LegKind (..), LegSource (..))
import PB.Pipeline.SqlParse (TableRef (..))
import PB.Compile.InstrTypes (ShapeNode (..), canonicalize, normalizeCallTag, linearize)
import PB.Analysis.CallClassify (collectBodyLocals)
import PB.Compile.InstrInterp (runInstrGraphTrace, TraceOutcome (..))
import PB.Compile.SSA     (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                            SsaTerm (..), SsaProc (..), buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Lexing.Lexer     (tokenizeLine, LexLine (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (mkLogicalLine)
import Control.Monad.State.Strict (runStateT)
import qualified Control.Exception as CE
import GHC.Conc             (getAllocationCounter, setAllocationCounter)
import Data.Int              (Int64)
import System.Timeout       (timeout)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.List       as L
import qualified Data.Text       as T
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, assertEqual, assertFailure, testCase, (@?=))

-- | Bytes allocated (on this capability) while running an action, via GHC's
-- allocation-counter primitive -- deterministic across machines of differing
-- speed/load, unlike a wall-clock measurement (see its use below).
measureAllocBytes :: IO a -> IO Int64
measureAllocBytes act = do
  setAllocationCounter maxBound
  _ <- act
  remaining <- getAllocationCounter
  pure (maxBound P.- remaining)

-- | Default compileSsaToEff with empty type env and no user functions.
compileSsaToEffDefault :: SsaProc -> EffTerm () ()
compileSsaToEffDefault = compileSsaToEff emptyEnv Set.empty

-- | Flatten a compiled 'EffTerm' to 'InstrGraph' via the production
-- NamedGraphBuilder path.
buildInstrGraphFromEffTerm :: EffTerm () () -> InstrGraph
buildInstrGraphFromEffTerm = linearize P.. buildEffGraphNamed

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

-- | Tokenize a single source snippet into one 'Token' via the real lexer
-- (mirrors 'InstrGraphTest.hs's identical helper) — used to build genuine
-- 'ExCall' @callArgs@ ([[Token]]) for tests that need real argument shapes
-- (e.g. a string literal arg) rather than empty argument lists.
-- | Real-lex a single value for its correct TokenKind, then normalize its
-- span to a constant dummy -- callers compare against hand-built ASTs that
-- carry the same dummy span, not a real per-character position.
tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk { tkSpan = SourceSpan 1 1 1 1 }
  _            -> Token TkIdent t (SourceSpan 1 1 1 1)
  where ll = mkLogicalLine t 1

-- | Build a minimal SsaProc with a single entry block.
mkSsa :: [SsaAssign] -> SsaTerm -> SsaProc
mkSsa assigns term = SsaProc
  { spName   = "test"
  , spBlocks = Map.fromList
      [ ("entry", SsaBlock { sbAssigns = assigns, sbTerm = term }) ]
  , spEntry  = "entry"
  , spVars   = [saVar a | a <- assigns]
  }

-- | Check if an 'EffTerm' contains an 'EAssign'/'EAssignWithRhs' for a given
-- variable name, resolving 'ELetRef' via the term's own table.
hasEffAssign :: Text -> EffTerm a b -> Bool
hasEffAssign n (EffTerm spine table) = go spine
  where
    go :: Eff x y -> Bool
    go (EAssign t) = n == t
    go (EAssignWithRhs t _ _) = n == t
    go (EComp f g) = go f P.|| go g
    go (EFanIn f g) = go f P.|| go g
    go (EBranch _ f g) = go f P.|| go g
    go (ELoop f) = go f
    go (ELetRef bid) = maybe False go (Map.lookup bid table)
    go _ = False

-- | Check if an 'EffTerm' contains an 'EReturn' (the true procedure-terminal
-- escape, distinct from 'J PInr'/break).
hasEffReturn :: EffTerm a b -> Bool
hasEffReturn (EffTerm spine table) = go spine
  where
    go :: Eff x y -> Bool
    go (EReturn _) = True
    go (EComp f g) = go f P.|| go g
    go (EFanIn f g) = go f P.|| go g
    go (EBranch _ f g) = go f P.|| go g
    go (ELoop f) = go f
    go (ELetRef bid) = maybe False go (Map.lookup bid table)
    go _ = False

-- | Check if an 'EffTerm' contains any 'ESuspend' node.
hasAnyEffSuspend :: EffTerm a b -> Bool
hasAnyEffSuspend (EffTerm spine table) = go spine
  where
    go :: Eff x y -> Bool
    go (ESuspend _ _) = True
    go (EComp f g) = go f P.|| go g
    go (EFanIn f g) = go f P.|| go g
    go (EBranch _ f g) = go f P.|| go g
    go (ELoop f) = go f
    go (ELetRef bid) = maybe False go (Map.lookup bid table)
    go _ = False

-- | Check if an 'EffTerm' contains an 'ESuspend' with a specific effect name.
hasEffSuspendEffect :: Text -> EffTerm a b -> Bool
hasEffSuspendEffect eff (EffTerm spine table) = go spine
  where
    go :: Eff x y -> Bool
    go (ESuspend e _) = eff == e
    go (EComp f g) = go f P.|| go g
    go (EFanIn f g) = go f P.|| go g
    go (EBranch _ f g) = go f P.|| go g
    go (ELoop f) = go f
    go (ELetRef bid) = maybe False go (Map.lookup bid table)
    go _ = False

-- | Check if an 'EffTerm' contains any 'ECall' node.
hasAnyEffCall :: EffTerm a b -> Bool
hasAnyEffCall (EffTerm spine table) = go spine
  where
    go :: Eff x y -> Bool
    go (ECall _ _) = True
    go (EComp f g) = go f P.|| go g
    go (EFanIn f g) = go f P.|| go g
    go (EBranch _ f g) = go f P.|| go g
    go (ELoop f) = go f
    go (ELetRef bid) = maybe False go (Map.lookup bid table)
    go _ = False

-- | ShapeNode predicates for the for/do-loop tests. SCall/SCProc are
-- treated as equivalent (pure tag-naming divergence).
isBrnchNode :: ShapeNode -> Bool
isBrnchNode (SBrnch {}) = True
isBrnchNode _           = False

isCallishNode :: ShapeNode -> Bool
isCallishNode (SCall _)  = True
isCallishNode (SCProc _) = True
isCallishNode _          = False

isAsgnNode :: ShapeNode -> Bool
isAsgnNode (SAsgn _) = True
isAsgnNode _         = False

-- | Enumerate every root-to-@SRet@ path through a canonicalized shape list, as the
-- sorted list of "how many callish nodes (SCall\/SCProc\/SSusp) are traversed before
-- reaching a return" on each path. Deliberately architecture-agnostic: it doesn't care
-- whether a compiler shares one physical node across two predecessors or duplicates it
-- (both give the same per-path counts), only whether every path's *required* content is
-- actually reachable. Assumes a DAG (no SNop/SGoto back-edges) — fine for the non-loop
-- shapes these tests construct.
pathCallCounts :: [ShapeNode] -> [Int]
pathCallCounts nodes = L.sort (go 0 0)
  where
    at i = nodes P.!! i
    go i acc = case at i of
      SRet         -> [acc]
      SAsgn n      -> go n acc
      SGoto n      -> go n acc
      SNop n       -> if n P.< 0 then [acc] else go n acc
      SCall n      -> go n (acc P.+ 1)
      SCProc n     -> go n (acc P.+ 1)
      SSusp _ n    -> go n (acc P.+ 1)
      SBrnch t f   -> go t acc P.++ go f acc

-- | Environment with datawindow and transaction typed variables.
dwEnv :: ScopedTypeEnv
dwEnv = ScopedTypeEnv
  { steGlobal       = Map.fromList [("dw_foo", PtPrimitive "datawindow"), ("sqlca", PtPrimitive "transaction")]
  , steInstance     = Map.empty
  , steLocal        = Map.empty
  , steHierarchy    = Map.empty
  , steObject       = ""
  , steControlIndex = Map.empty, steParams = Set.empty, steParamIndex = Map.empty
  }

-- | Run a bare, sharing-free 'Eff' term through 'foldFreydOp' to 'Interp',
-- returning the final environment and the trace in chronological order.
runEffTrace :: Eff a a -> a -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runEffTrace eff input initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (foldFreydOp eff) input) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
  return (isEnv st, P.reverse (isTrace st))

-- | Run a compiled 'EffTerm' (with a real shared-term table) through
-- 'foldFreyd' to 'Interp' — the 'EffTerm' counterpart of 'runEffTrace',
-- for terms produced by 'compileProcedureToEff' (which may contain
-- 'ELetRef' merge-point markers).
runEffTermTrace :: EffTerm a a -> a -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runEffTermTrace effTerm input initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (foldFreyd effTerm) input) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
  return (isEnv st, P.reverse (isTrace st))

-- | Generic version of 'runEffTermTrace' for non-@()@ types.
runEffTermTraceGen :: a -> EffTerm a b -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runEffTermTraceGen input effTerm initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (foldFreyd effTerm) input) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
  return (isEnv st, P.reverse (isTrace st))

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "EffTerm"
  [ testGroup "SSA data types"
    [ testCase "SsaProc placeholder" $
        let sa = buildSsa P.undefined "test_proc" [] :: SsaProc
        in spName sa @?= "test_proc"
    ]

  , testGroup "call classification"
    [ testCase "ExCall with DW receiver emits ESuspend not ECall" $
        -- dw_foo.retrieve() — multi-segment ExCall classified as SuspendCall
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr) (ExInt "0")] (SsaReturn Nothing)
            result = compileSsaToEff dwEnv Set.empty sa
        in assertBool "should contain ESuspend with effect retrieve:dw_foo"
             (hasEffSuspendEffect "retrieve:dw_foo" result)

    , testCase "ExMethodCall on Transaction emits ESuspend not ECall" $
        -- sqlca.commit() — ExMethodCall on a transaction-typed receiver
        let callExpr = ExMethodCall
              { receiver   = ExLvalue (Lvalue [LvSegment "sqlca" Nothing])
              , method     = "commit"
              , methodArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr) (ExInt "0")] (SsaReturn Nothing)
            result = compileSsaToEff dwEnv Set.empty sa
        in assertBool "should contain ESuspend with effect executeSql"
             (hasEffSuspendEffect "executeSql" result)

    , testCase "ExCall pure user function does not emit ESuspend" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "my_func" Nothing], callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr) (ExInt "0")] (SsaReturn Nothing)
            result = compileSsaToEff emptyEnv Set.empty sa
        in assertBool "pure call should produce no ESuspend" (not (hasAnyEffSuspend result))

    , testCase "end-to-end: BsCall dw_foo.retrieve() → InstrSuspend node in InstrGraph" $
        -- buildSsa from a standalone BsCall; InstrSuspend must appear in the graph
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            body     = [Located 1 (BsCall callExpr)]
            ssaProc  = buildSsa dwEnv "proc" body
            effTerm  = compileSsaToEff dwEnv Set.empty ssaProc
            graph    = buildInstrGraphFromEffTerm effTerm
            hasInstrSuspend = any (\n -> case n of { InstrSuspend {} -> True; _ -> False }) (igNodes graph)
        in assertBool "InstrGraph should contain a InstrSuspend node" hasInstrSuspend
    ]

  , testGroup "assign-with-call-RHS (Plan 145 Phase 1B re-sample Finding B)"
    -- x = f() / x = obj.method() used to silently drop the assignment target and
    -- compile to a bare call/suspend — the call ran but its result was never
    -- stored. PB.Analysis.InstrGraph (the old, confirmed-correct compiler)
    -- never special-cases a call RHS on BsAssign; it always emits one InstrAssign.
    [ testCase "x = my_func() (pure) assigns, does not emit a bare ECall" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "my_func" Nothing], callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x") (SsaConst callExpr) (ExInt "0")] (SsaReturn Nothing)
            result = compileSsaToEff emptyEnv Set.empty sa
        in assertBool "x assign present, no bare ECall"
             (hasEffAssign "x" result P.&& not (hasAnyEffCall result))

    , testCase "x = dw_foo.retrieve() (suspend) assigns, does not emit ESuspend" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x") (SsaConst callExpr) (ExInt "0")] (SsaReturn Nothing)
            result = compileSsaToEff dwEnv Set.empty sa
        in assertBool "x assign present, no ESuspend"
             (hasEffAssign "x" result P.&& not (hasAnyEffSuspend result))

    , testCase "standalone (discard) suspend call is unaffected" $
        -- Sanity: the "_" discard target must still classify and emit ESuspend.
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr) (ExInt "0")] (SsaReturn Nothing)
            result = compileSsaToEff dwEnv Set.empty sa
        in assertBool "should still contain ESuspend" (hasAnyEffSuspend result)

    , testCase "end-to-end: x = messagebox() matches old compiler's [SAsgn, SRet]" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "messagebox" Nothing], callArgs = [] }
            body     = [Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) callExpr)]
            graph    = compileProcedureViaEffTerm emptyEnv Set.empty body
        in canonicalize graph @?= [SAsgn 1, SRet]
    ]

  , testGroup "Interp"
    [ testCase "id returns input" $
        runInterpIO (id :: Interp Int Int) 42 P.>>= \v -> v @?= 42

    , testCase "composition chains effects" $
        let f = Interp (\x -> P.pure (x P.+ 1)) :: Interp Int Int
            g = Interp (\x -> P.pure (x P.* 2))
        in runInterpIO (f . g) 3 P.>>= \v -> v @?= 7

    , testCase "inl injects left" $
        runInterpIO (inl :: Interp Int (Either Int Text)) 42 P.>>= \v -> v @?= Left 42

    , testCase "inr injects right" $
        runInterpIO (inr :: Interp Text (Either Int Text)) "hi" P.>>= \v -> v @?= Right "hi"

    , testCase "fanin dispatches" $
        let f = Interp (\_ -> P.pure "left") :: Interp Int P.String
            g = Interp (\_ -> P.pure "right")
        in runInterpIO (f ||| g) (Right "x" :: Either Int Text) P.>>= \v -> v @?= "right"

    , testCase "splitValue routes True to Left" $
        runInterpIO (splitValue :: Interp ((), Value) (Either () ())) ((), VBool True) P.>>= \v -> v @?= Left ()

    , testCase "splitValue routes False to Right" $
        runInterpIO (splitValue :: Interp ((), Value) (Either () ())) ((), VBool False) P.>>= \v -> v @?= Right ()
    ]

  , testGroup "Interp / runEff (Plan 167 Phase 7 Step 6: uniformity with runCat)"
    -- 'runEff' is 'foldFreyd' specialized to 'Interp', added alongside
    -- 'runCat' for parity — no production caller (Interp is test-only), same
    -- as 'runCat' itself.
    [ testCase "runEff (id :: Eff () ()) is identity, no trace" $ do
        (result, st) <- runStateT (runInterp (runEff (extractEffTable (id :: Eff () ()))) ()) (InterpState Map.empty [] Map.empty)
        result @?= ()
        isTrace st @?= []

    , testCase "runEff EAssignWithRhs updates env and emits TeAssign" $ do
        let term = EAssignWithRhs "x_1" (ExInt "0") (ExInt "42") :: Eff () ()
        (_, st) <- runStateT (runInterp (runEff (extractEffTable term)) ()) (InterpState Map.empty [] Map.empty)
        Map.lookup "x_1" (isEnv st) @?= Just (VInt 42)
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 42)]

    , testCase "runEff EComp threads env through both assigns in order" $ do
        let term = EAssignWithRhs "y_1" (ExInt "0") (ExInt "2") . EAssignWithRhs "x_1" (ExInt "0") (ExInt "1") :: Eff () ()
        (_, st) <- runStateT (runInterp (runEff (extractEffTable term)) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 1), TeAssign "y_1" (VInt 2)]

    , testCase "runEff branchEff emits TeBranch True and takes the then-arm" $ do
        let term = branchEff (ExBool True)
                     (EAssignWithRhs "then_taken" (ExInt "0") (ExInt "1"))
                     (EAssignWithRhs "else_taken" (ExInt "0") (ExInt "2")) :: Eff () ()
        (_, st) <- runStateT (runInterp (runEff (extractEffTable term)) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeBranch True, TeAssign "then_taken" (VInt 1)]

    , testCase "runEff branchEff emits TeBranch False and takes the else-arm" $ do
        let term = branchEff (ExBool False)
                     (EAssignWithRhs "then_taken" (ExInt "0") (ExInt "1"))
                     (EAssignWithRhs "else_taken" (ExInt "0") (ExInt "2")) :: Eff () ()
        (_, st) <- runStateT (runInterp (runEff (extractEffTable term)) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeBranch False, TeAssign "else_taken" (VInt 2)]

    , testCase "runEff ESuspend records TeSuspend with evaluated args" $ do
        let term = ESuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: Eff () ()
        (_, st) <- runStateT (runInterp (runEff (extractEffTable term)) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeSuspend "retrieve:dw_foo" [VInt 1, VStr "bar"]]

    , testCase "runEff ECall records TeCall with evaluated args" $ do
        let term = ECall "my_func" [ExInt "5"] :: Eff () ()
        (_, st) <- runStateT (runInterp (runEff (extractEffTable term)) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeCall "my_func" [VInt 5]]
    ]

  , testGroup "compileProcedureViaEffTerm"
    [ testCase "empty body produces non-empty graph" $
        let graph = compileProcedureViaEffTerm emptyEnv Set.empty []
        in assertBool "should have at least one node (exit)" (not (null (igNodes graph)))

    , testCase "single BsCall produces non-empty graph" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "foo" Nothing], callArgs = [] }
            body     = [Located 1 (BsCall callExpr)]
            graph    = compileProcedureViaEffTerm emptyEnv Set.empty body
        in assertBool "should have more than one node" (P.length (igNodes graph) P.> 1)

    , testCase "DW suspend call produces InstrSuspend in graph" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            body  = [Located 1 (BsCall callExpr)]
            graph = compileProcedureViaEffTerm dwEnv Set.empty body
        in assertBool "should contain InstrSuspend"
             (any (\n -> case n of InstrSuspend {} -> True; _ -> False) (igNodes graph))

    -- Plan 145 Phase 1C/3: BsPbCall (`call ancestor::event`) used to be dropped
    -- entirely by PB.Compile.SSA.stmtToAssigns's catch-all. Confirms the fix
    -- makes the pipeline match PB.Analysis.InstrGraph's old-compiler output
    -- for the exact m_ole_example::destroy regression case bit-for-bit, not
    -- just structurally equivalent.
    , testCase "BsPbCall (call ancestor::event) matches old compiler's [SCProc, SRet]" $
        let body  = [Located 1 (BsPbCall (PbCall "m_ole_frame" "destroy"))]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
        in canonicalize graph @?= [SCProc 1, SRet]
    ]

  , testGroup "no unconditional join InstrNop (Plan 145 Finding A)"
    -- The old compiler's lowering used to unconditionally allocate a join
    -- InstrNop before both arms of a branch, even when nothing structurally
    -- requires one. The reference compiler never allocates this node — both
    -- arms just point their fallthrough straight at the shared continuation.
    -- Cosmetic (no data loss), but common (every if/if-else); the NGB/Eff
    -- pipeline preserves the fix.
    [ testCase "if without else, nothing follows — matches old compiler exactly" $
        -- w_notepad::ue_key_up pattern: if cond then <call> end if.
        let body  = [Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsPbCall (PbCall "m_ole_frame" "destroy"))] [] Nothing))]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
        in canonicalize graph @?= [SBrnch 1 2, SCProc 2, SRet]

    , testCase "if/else, both arms, nothing follows — matches old compiler exactly" $
        let body  = [Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsPbCall (PbCall "m_ole_frame" "destroy"))] []
                       (Just [Located 3 (BsPbCall (PbCall "m_ole_frame" "create"))])))]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
        in canonicalize graph @?= [SBrnch 1 2, SCProc 3, SCProc 3, SRet]
    ]

  , testGroup "for/do-loop header collapse (Plan 145 post-Finding-A block-collapse bug)"
    -- Root cause: PB.Analysis.Cfg.lowerFor/lowerDo (top-condition) flush the
    -- raw BsFor/BsDo node onto the *predecessor* block and give the actual
    -- condition/header block zero statements of its own. SSA.cfgTermToSsa used to
    -- look for a control statement only in the header block's own stmts, find
    -- none, and fall back to `SsaReturn Nothing` (the header has two edges, not
    -- one) — silently truncating the whole procedure at the first loop.
    --
    -- These tests assert the properties the SSA fix guarantees: the loop's
    -- condition, body call, init, and increment are all real, present nodes
    -- (nothing vanishes) — count-based, so independent of the accepted
    -- loop-header InstrNop shape gap between NGB and the retired LowCat path.
    [ testCase "for loop containing one call: condition, body, init, and increment are all preserved" $
        let body = [Located 1 (BsFor (ForStmt (Lvalue [LvSegment "li_count" Nothing])
                      (ExInt "1") (ExInt "10") Nothing
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))]))]
            shape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in do
          assertEqual "exactly one branch (the loop condition check)"
            1 (length (filter isBrnchNode shape))
          assertEqual "exactly one call node (the loop body)"
            1 (length (filter isCallishNode shape))
          assertEqual "exactly two assigns (init + increment)"
            2 (length (filter isAsgnNode shape))

    , testCase "do-while loop containing one call: condition and body are preserved" $
        let body = [Located 1 (BsDo (DoStmt (Just (DoWhile (ExBool True)))
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))] Nothing))]
            shape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in do
          assertEqual "exactly one branch (the loop condition check)"
            1 (length (filter isBrnchNode shape))
          assertEqual "exactly one call node (the loop body)"
            1 (length (filter isCallishNode shape))
    ]

  , testGroup "no EAssignWithRhs for standalone dispatch statements (Plan 145 ExDispatch fix)"
    -- compileAssign's "_"-discard case only pattern-matched SsaConst
    -- (ExCall ...)/(ExMethodCall ...), so a standalone dispatch statement
    -- (`.Post`/`.Trigger`/`Dynamic ... Event(...)` — PB's inter-object
    -- messaging idiom, e.g. `ParentWindow.Dynamic Post of_run_report()` or
    -- `Post Event ue_GetValues()`) fell through to an assign-with-rhs,
    -- producing a real InstrAssign{anVar="_"} node instead of a bare call
    -- node. The old compiler (PB.Analysis.InstrGraph's BsCall `otherwise`
    -- branch) never has this gap: it calls classifyExpr/calleeName
    -- generically regardless of expr shape, both defaulting to
    -- PureCall/"?" for anything that isn't ExCall/ExMethodCall.
    [ testCase "ExDispatch (Dynamic Post) matches old compiler exactly (mod SCall/SCProc tag)" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Just (Lvalue [LvSegment "ParentWindow" Nothing]), mode = DmPost
              , dynamic = True, event = False, name = "of_run_report", args = [] })
            body = [Located 1 (BsCall dispatchExpr)]
            -- Frozen expected shape: captured from the old compiler before its
            -- deletion, when this test last passed bit-for-bit.
            expectedShape = [SCall 1, SRet]
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in newShape @?= expectedShape

    , testCase "ExDispatch (bare Post Event) matches old compiler exactly (mod SCall/SCProc tag)" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Nothing, mode = DmPost, dynamic = False
              , event = True, name = "ue_getvalues", args = [] })
            body = [Located 1 (BsCall dispatchExpr)]
            expectedShape = [SCall 1, SRet]
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in newShape @?= expectedShape

    , testCase "no EAssignWithRhs is emitted for a standalone dispatch statement" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Just (Lvalue [LvSegment "ParentWindow" Nothing]), mode = DmPost
              , dynamic = True, event = False, name = "of_run_report", args = [] })
            body  = [Located 1 (BsCall dispatchExpr)]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
            hasAssignNode = any (\n -> case n of InstrAssign {} -> True; _ -> False) (igNodes graph)
        in assertBool "should contain no InstrAssign node" (not hasAssignNode)
    ]

  , testGroup "compileBlock memoization: shared-tail content survives on every predecessor (Plan 145 Bug A)"
    -- Assertions compare 'pathCallCounts' (root-to-return call counts per
    -- path), not raw shape equality, against the old compiler: the fix stops
    -- content from being silently dropped when a merge block is reached by
    -- more than one predecessor.
    [ testCase "if without else: trailing calls after merge execute regardless of branch" $
        -- Mirrors w_frame_menu_functions::destroy: the implicit "condition false"
        -- edge and the then-arm's fallthrough both converge on the same merge block,
        -- which holds the real trailing calls.
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True) [Located 2 (BsCall (call "callA"))] [] Nothing))
                   , Located 3 (BsCall (call "callB"))
                   , Located 4 (BsCall (call "callC"))
                   ]
            -- Frozen expected path-call-counts: captured from the old
            -- compiler before its deletion, when this test last passed.
            expectedCounts = [2, 3]
            newShape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts

    , testCase "if/else, both arms: shared trailing calls survive on both paths" $
        -- Mirrors the mechanism behind w_dw_functions::clicked: both the then-arm and
        -- the else-arm converge on the same merge block holding real trailing calls.
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   , Located 5 (BsCall (call "callD"))
                   ]
            expectedCounts = [3, 3]
            newShape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts

    , testCase "nested if inside if/else with shared trailing calls (real corpus shape: w_dw_functions::clicked)" $
        -- Mirrors the exact real-world procedure this bug was root-caused from:
        -- an outer if containing an inner if/else, followed by two more calls that
        -- both inner arms must reach.
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            innerIf = BsIf (IfStmt (ExBool True)
                        [Located 3 (BsCall (call "callA"))] []
                        (Just [Located 4 (BsCall (call "callB"))]))
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [ Located 2 innerIf
                       , Located 5 (BsCall (call "callC"))
                       , Located 6 (BsCall (call "callD"))
                       ] [] Nothing))
                   ]
            expectedCounts = [0, 3, 3]
            newShape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts
    ]

  , testGroup "GraphBuilder node-sharing: sequential merge points stay linear, not exponential (Plan 150)"
    [ testCase "4 sequential if/else groups: node count stays linear, not 2^4 = 16x" $
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group (thenN, elseN, tailN, base) =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call thenN))] []
                  (Just [Located (base P.+ 3) (BsCall (call elseN))])))
              , Located (base P.+ 4) (BsCall (call tailN))
              ]
            body = concatMap group
              [ ("callA1", "callB1", "ctail1", 0), ("callA2", "callB2", "ctail2", 4)
              , ("callA3", "callB3", "ctail3", 8), ("callA4", "callB4", "ctail4", 12)
              ]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
            nodeCount = length (igNodes graph)
        in assertBool
             ("node count should stay roughly linear in 4 groups (~5-6 nodes/group); got " <> show nodeCount)
             (nodeCount P.< 40)

    , testCase "4 sequential if/else groups: old and new compilers agree on call counts per path" $
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group (thenN, elseN, tailN, base) =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call thenN))] []
                  (Just [Located (base P.+ 3) (BsCall (call elseN))])))
              , Located (base P.+ 4) (BsCall (call tailN))
              ]
            body = concatMap group
              [ ("callA1", "callB1", "ctail1", 0), ("callA2", "callB2", "ctail2", 4)
              , ("callA3", "callB3", "ctail3", 8), ("callA4", "callB4", "ctail4", 12)
              ]
            expectedCounts = [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]
            newShape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts
    ]

  , testGroup "Phase 7 Step 7: WiringBuilder (WB) Effectful instance over EffTerm"
    -- 'compileProcedureToWiring' replaces 'collectWiring'\/'WiringPayload':
    -- 'WiringGraph'\'s 'wgNodes' is already a flat, 'Text'-keyed 'Map', so
    -- dedup falls out of 'Map.Map' key uniqueness (via 'memoTag', the same
    -- mechanism\/argument Step 4's 'NGB' already established) instead of a
    -- bespoke second pass over a tree-shaped 'LowCat'. The one behavioral
    -- difference from 'NGB': 'branchK' is the *generic* derivation (@branch@
    -- itself, "default"), not a fused primitive — a real condition-eval node
    -- ('WireCond') sits immediately upstream of the fork ('WireBranch'),
    -- instead of being folded into one instruction the way 'NGB'\'s
    -- 'InstrBranch'' is.
    [ testCase "single assignment compiles to exactly one WireAssign node carrying the real var and expr" $
        let body = [Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "42"))]
            graph = compileProcedureToWiring emptyEnv Set.empty body
            assigns = [n | n@WireAssign{} <- Map.elems (wgNodes graph)]
        in case assigns of
             [WireAssign { waVar, waRhs }] -> do
               waVar @?= "x"
               waRhs @?= ExInt "42"
             other -> assertFailure ("expected exactly 1 WireAssign node, got " <> show (length other))

    , testCase "branch condition is its own WireCond node, immediately upstream of a condition-free WireBranch fork" $
        let cond = ExBinOp (ExLvalue (Lvalue [LvSegment "x" Nothing])) BopGt (ExInt "0")
            body = [Located 1 (BsIf (IfStmt cond
                      [Located 2 (BsPbCall (PbCall "obj" "then_event"))] []
                      (Just [Located 3 (BsPbCall (PbCall "obj" "else_event"))])))]
            graph = compileProcedureToWiring emptyEnv Set.empty body
            nodes = wgNodes graph
            conds    = [(n, c) | (n, c@WireCond{}) <- Map.toList nodes]
            branches = [n | n@WireBranch{} <- Map.elems nodes]
        in case (conds, branches) of
             ([(_condName, WireCond { wcExpr, wcNext })], [_]) -> do
               wcExpr @?= cond
               assertBool "the WireCond's own successor is a WireBranch (fork sits directly downstream)"
                 (case Map.lookup wcNext nodes of { Just WireBranch{} -> True; _ -> False })
             other -> assertFailure ("expected exactly 1 WireCond + 1 WireBranch, got " <> show (length (fst other), length (snd other)))

    , testCase "shared tail (if/else, both arms) is collected exactly once, referenced from both arms" $
        -- Same fixture as the compileBlock-memoization tests above: the
        -- trailing callC/callD block is reached from both the then-arm and
        -- the else-arm.
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   , Located 5 (BsCall (call "callD"))
                   ]
            graph = compileProcedureToWiring emptyEnv Set.empty body
            nodes = wgNodes graph
            callCNames = [n | (n, WireCall { wclCallee }) <- Map.toList nodes, wclCallee == "callC"]
            successorsOf p = case p of
              WireAssign { waNext }   -> [waNext]
              WireCond   { wcNext }   -> [wcNext]
              WireBranch { wtThen, wtElse } -> [wtThen, wtElse]
              WireCall   { wclNext }  -> [wclNext]
              WireSuspend{ wsNext }   -> [wsNext]
              WireReturn              -> []
              WireNop    { wnNext }   -> [wnNext]
            allSuccessors = concatMap successorsOf (Map.elems nodes)
        in case callCNames of
             [callCName] -> assertBool "callC's node is referenced by at least 2 predecessors (real sharing)"
               (L.length (L.filter (== callCName) allSuccessors) P.>= 2)
             other -> assertFailure ("expected exactly 1 distinct callC node, got " <> show (length other))

    , testCase "4 sequential if/else groups: shared-tail call counts stay uniform (memoTag prevents duplication)" $
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group (thenN, elseN, tailN, base) =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call thenN))] []
                  (Just [Located (base P.+ 3) (BsCall (call elseN))])))
              , Located (base P.+ 4) (BsCall (call tailN))
              ]
            body = concatMap group
              [ ("callA1", "callB1", "ctail1", 0), ("callA2", "callB2", "ctail2", 4)
              , ("callA3", "callB3", "ctail3", 8), ("callA4", "callB4", "ctail4", 12)
              ]
            graph = compileProcedureToWiring emptyEnv Set.empty body
            calls = [wclCallee | WireCall { wclCallee } <- Map.elems (wgNodes graph)]
        in L.sort calls @?= L.sort
             [ "callA1", "callB1", "ctail1", "callA2", "callB2", "ctail2"
             , "callA3", "callB3", "ctail3", "callA4", "callB4", "ctail4"
             ]
    ]

  , testGroup "Interp vs GraphBuilder trace equivalence (Eff/NGB)"
    -- Same 'Eff' term, run through both of 'Eff's execution backends: Interp
    -- (direct Haskell execution, via foldFreyd) and GraphBuilder (flat
    -- InstrGraph, the shape the TS runtime consumes, via NGB/foldFreyd). A
    -- divergence here is a real backend bug, independent of anything
    -- upstream in the AST/SSA/Eff compilation stages.
    [ testCase "J PId: no trace, no env change" $ do
        let term = extractEffTable (id :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= []
        itrace @?= gtrace
        ienv @?= genv

    , testCase "EAssignWithRhs: same assign trace, same env" $ do
        let term = extractEffTable (EAssignWithRhs "x_1" (ExInt "0") (ExInt "42") :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= [TeAssign "x_1" (VInt 42)]
        itrace @?= gtrace
        ienv @?= genv

    , testCase "EComp: two assigns execute in the same order" $ do
        let term = extractEffTable (EAssignWithRhs "y_1" (ExInt "0") (ExInt "2") . EAssignWithRhs "x_1" (ExInt "0") (ExInt "1") :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branchEff True: then-arm taken on both backends" $ do
        let term = extractEffTable (branchEff (ExBool True)
                     (EAssignWithRhs "then_taken" (ExInt "0") (ExInt "1"))
                     (EAssignWithRhs "else_taken" (ExInt "0") (ExInt "2")) :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branchEff False: else-arm taken on both backends" $ do
        let term = extractEffTable (branchEff (ExBool False)
                     (EAssignWithRhs "then_taken" (ExInt "0") (ExInt "1"))
                     (EAssignWithRhs "else_taken" (ExInt "0") (ExInt "2")) :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "ESuspend: same effect name and evaluated args" $ do
        let term = extractEffTable (ESuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "ECall: same callee and evaluated args" $ do
        let term = extractEffTable (ECall "my_func" [ExInt "5"] :: Eff () ())
        (ienv, itrace) <- runEffTermTrace term () Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "ELoop: counts to 3 identically on both backends" $ do
        -- A hand-built loop with a real terminating condition — unlike the
        -- shape-only SSA loop fixtures elsewhere in this file, which all use
        -- a constant `ExBool True` condition and would loop forever if
        -- actually executed rather than just inspected for shape.
        let iVar = ExLvalue (Lvalue [LvSegment "i" Nothing])
            cond = ExBinOp iVar BopLt (ExInt "3")
            incr = ExBinOp iVar BopAdd (ExInt "1")
            loopBody = branchEff cond
                         (J PInl . EAssignWithRhs "i" (ExInt "0") incr)
                         (J PInr) :: Eff () (Either () ())
            term = extractEffTable (ELoop loopBody :: Eff () ())
            initEnv = Map.fromList [("i", VInt 0)]
        (ienv, itrace) <- runEffTermTrace term () initEnv
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphFromEffTerm term) initEnv
        itrace @?= gtrace
        ienv @?= genv
        Map.lookup "i" ienv @?= Just (VInt 3)
    ]

  , testGroup "PureCall callee name preserves source case (Plan 146 Phase 2d)"
    -- compileCallExpr's `otherwise` branch and compileAssign's ExMethodCall
    -- PureCall case both wrap the callee name in T.toLower before building
    -- the call node, but PB.Analysis.InstrGraph's mirror (the
    -- confirmed-correct old compiler) uses calleeName's result verbatim via
    -- `clCallee = calleeName expr`. calleeName never itself lowercases.
    [ testCase "bare ExCall with mixed-case callee: TeCall preserves case" $
        let body = [Located 1 (BsCall (ExCall (Lvalue [LvSegment "GlobalMemoryStatus" Nothing]) []))]
            -- Frozen expected trace: captured from the old compiler before
            -- its deletion, when this test last passed bit-for-bit.
            expectedTrace = (Map.empty, [TeCall "GlobalMemoryStatus" []], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace

    , testCase "ExMethodCall with mixed-case receiver/method: TeCall preserves case" $
        let recv = ExLvalue (Lvalue [LvSegment "parentwindow" Nothing])
            body = [Located 1 (BsCall (ExMethodCall recv "TriggerEvent" [ExRaw []]))]
            expectedTrace = (Map.empty, [TeCall "parentwindow.TriggerEvent" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace

    , testCase "ExMethodCall whose receiver is itself a call (chained method call) matches old compiler" $
        -- Real corpus idiom: `ParentWindow.GetActiveSheet().TriggerEvent(...)`.
        -- compileAssign's ExMethodCall branch special-cased an `ExCall`
        -- receiver as `lvHead rlv <> "." <> meth` (grabbing just the callee's
        -- own head segment, "ParentWindow"), diverging from `calleeName`'s
        -- reference behaviour of falling back to `"?." <> meth` for any
        -- receiver that isn't a plain `ExLvalue`.
        let recv = ExCall (Lvalue [LvSegment "ParentWindow" Nothing, LvSegment "GetActiveSheet" Nothing]) []
            body = [Located 1 (BsCall (ExMethodCall recv "TriggerEvent" [ExRaw []]))]
            expectedTrace = (Map.empty, [TeCall "?.TriggerEvent" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace
    ]

  , testGroup "fn_retrievechild suspend args match old compiler (Plan 146 Phase 2i)"
    -- Real corpus idiom: `fn_retrievechild(adw, "col", var)`.
    -- 'PB.Analysis.InstrGraph' special-cases this exact callee (before its
    -- generic call-compilation path) to trace only the third argument (the
    -- bound variable) as the suspend's args, since the datawindow control and
    -- column name are already encoded directly in the effect name string
    -- itself (`"retrieve:child_<col>:<dwCtrl>"`, via 'effectName').
    [ testCase "fn_retrievechild(adw, \"col\", var): suspend args are just [var], matching old compiler" $
        let body = [Located 1 (BsCall (ExCall
              { callee   = Lvalue [LvSegment "fn_retrievechild" Nothing]
              , callArgs = [ ExLvalue (Lvalue [LvSegment "dw_misth_final" Nothing])
                           , ExStr "kodkat"
                           , ExLvalue (Lvalue [LvSegment "gs_kodxrisi" Nothing])
                           ]
              }))]
            expectedTrace = (Map.empty, [TeSuspend "retrieve:child_kodkat:dw_misth_final" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace
    ]

  , testGroup "local DataStore/Transaction variable suspend-classification (Plan 146 Phase 2e)"
    -- A *locally-declared* datastore/transaction variable's type can never be
    -- resolved by classifyExpr's lookupScopedVar unless steLocal is seeded
    -- from the body's own BsLocalVar decls before compiling, and a suspend
    -- method call on it would otherwise fall through to the conservative
    -- PureCall default.
    [ testCase "local datastore var .retrieve() classifies as SuspendCall" $
        let body = [ Located 1 (BsLocalVar [] (PtPrimitive "datastore") "lds_x" Nothing)
                   , Located 2 (BsCall (ExMethodCall (ExLvalue (Lvalue [LvSegment "lds_x" Nothing])) "retrieve" [ExRaw []]))
                   ]
            expectedTrace = (Map.empty, [TeSuspend "retrieve:lds_x" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace

    , testCase "local transaction var .commit() classifies as SuspendCall" $
        let body = [ Located 1 (BsLocalVar [] (PtPrimitive "transaction") "ltrans_x" Nothing)
                   , Located 2 (BsCall (ExMethodCall (ExLvalue (Lvalue [LvSegment "ltrans_x" Nothing])) "commit" [ExRaw []]))
                   ]
            expectedTrace = (Map.empty, [TeSuspend "executeSql" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace
    ]

  , testGroup "nested loop exit-target resolution (Plan 146 Phase 2f)"
    -- 'computeLoopBodyBlocks' (via 'discoverReachable'/'canReach', shared by
    -- both the retired CatOp pipeline and this Eff one) has no boundary for
    -- the case where one loop is nested inside another. Fixture: an outer
    -- counted loop whose body always enters an inner counted loop (with a
    -- structural bypass edge, matching the real "if without else" shape)
    -- before looping back.
    [ let oiV = SsaVarRef (SsaVar "oi")
          iiV = SsaVarRef (SsaVar "ii")
          yV  = SsaVarRef (SsaVar "y")
          nestedLoopsSsa = SsaProc
            { spName   = "test"
            , spEntry  = "entry"
            , spVars   = []
            , spBlocks = Map.fromList
                [ ("entry", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "oi") (SsaConst (ExInt "0")) (ExInt "0")
                                  , SsaAssign (SsaVar "y") (SsaConst (ExInt "0")) (ExInt "0") ]
                    , sbTerm = SsaGoto "outer_header" })
                , ("outer_header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt oiV (SsaConst (ExInt "2"))) "outer_if" "outer_exit" })
                , ("outer_if", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaConst (ExBool True)) "outer_enter_inner" "outer_merge" })
                , ("outer_enter_inner", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "ii") (SsaConst (ExInt "0")) (ExInt "0")]
                    , sbTerm = SsaGoto "inner_header" })
                , ("inner_header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt iiV (SsaConst (ExInt "3"))) "inner_body" "inner_exit" })
                , ("inner_body", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "ii") (SsaBinOp BopAdd iiV (SsaConst (ExInt "1"))) (ExInt "0")
                                  , SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) (ExInt "0") ]
                    , sbTerm = SsaGoto "inner_header" })
                , ("inner_exit", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "outer_merge" })
                , ("outer_merge", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "oi") (SsaBinOp BopAdd oiV (SsaConst (ExInt "1"))) (ExInt "0")]
                    , sbTerm = SsaGoto "outer_header" })
                , ("outer_exit", SsaBlock { sbAssigns = [], sbTerm = SsaReturn Nothing })
                ]
            }
          initEnv = Map.fromList [("oi", VInt 0), ("y", VInt 0), ("ii", VInt 0)]
          -- Bounded via 'runInstrGraphTrace' (never raw, unbounded interp)
          -- because the pre-fix bug reproduces a genuine runtime infinite loop for
          -- this shape (confirmed empirically before writing this assertion), not
          -- just a wrong-but-terminating result.
          maxSteps = 500 :: Int
          (finalEnv, trc, _) = runInstrGraphTrace maxSteps Map.empty
                              (buildInstrGraphFromEffTerm (compileSsaToEffDefault nestedLoopsSsa)) initEnv
      in testCase "outer loop containing an inner loop terminates with the correct final environment, not a runaway trace" $ do
           assertBool ("trace should terminate well under the " <> show maxSteps <> "-step fuel bound, got "
                         <> show (length trc) <> " steps (indicates the outer/inner loop headers were resolved as each other's exit target)")
                      (length trc P.< maxSteps)
           Map.lookup "oi" finalEnv @?= Just (VInt 2)
           Map.lookup "y"  finalEnv @?= Just (VInt 6)
           Map.lookup "ii" finalEnv @?= Just (VInt 3)
    ]

  , testGroup "loop-exit-target skips continue blocks (Plan 146 Phase 2g)"
    -- 'canReach' (via 'computeLoopBodyBlocks') walks a block's
    -- 'termSuccessors', which is '[]' for 'SsaContinue'/'SsaBreak' by design
    -- (they're handled as special-cased control transfers elsewhere, not
    -- graph edges) — so a block ending in 'SsaContinue' can never "reach
    -- back" to its own loop header via this walk, and gets wrongly excluded
    -- from the loop's body set.
    -- Fixture: a 3-iteration counted loop whose body takes a `continue` on
    -- exactly one iteration before reaching a real post-loop block with its
    -- own distinguishing assign. Block names are chosen so "c_continue"
    -- sorts before "z_exit" — reproducing the exact alphabetical-tiebreak
    -- failure mode, not a coincidence-proof shape.
    [ let xV  = SsaVarRef (SsaVar "x")
          yV  = SsaVarRef (SsaVar "y")
          scV = SsaVarRef (SsaVar "skip_count")
          continueSsa = SsaProc
            { spName   = "test"
            , spEntry  = "entry"
            , spVars   = []
            , spBlocks = Map.fromList
                [ ("entry", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "x") (SsaConst (ExInt "0")) (ExInt "0")
                                  , SsaAssign (SsaVar "y") (SsaConst (ExInt "0")) (ExInt "0")
                                  , SsaAssign (SsaVar "skip_count") (SsaConst (ExInt "0")) (ExInt "0")
                                  , SsaAssign (SsaVar "done") (SsaConst (ExInt "0")) (ExInt "0") ]
                    , sbTerm = SsaGoto "header" })
                , ("header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt xV (SsaConst (ExInt "3"))) "body_entry" "z_exit" })
                , ("body_entry", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopEq xV (SsaConst (ExInt "1"))) "c_continue" "normal_body" })
                , ("c_continue", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "x") (SsaBinOp BopAdd xV (SsaConst (ExInt "1"))) (ExInt "0")
                                  , SsaAssign (SsaVar "skip_count") (SsaBinOp BopAdd scV (SsaConst (ExInt "1"))) (ExInt "0") ]
                    , sbTerm = SsaContinue })
                , ("normal_body", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) (ExInt "0")
                                  , SsaAssign (SsaVar "x") (SsaBinOp BopAdd xV (SsaConst (ExInt "1"))) (ExInt "0") ]
                    , sbTerm = SsaGoto "header" })
                , ("z_exit", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "done") (SsaConst (ExInt "1")) (ExInt "0")]
                    , sbTerm = SsaReturn Nothing })
                ]
            }
          initEnv = Map.fromList [("x", VInt 0), ("y", VInt 0), ("skip_count", VInt 0), ("done", VInt 0)]
          (finalEnv, _trc, _) = runInstrGraphTrace 100 Map.empty
                                (buildInstrGraphFromEffTerm (compileSsaToEffDefault continueSsa)) initEnv
      in testCase "continue mid-loop still reaches the real post-loop block, not the continue block's own content" $ do
           Map.lookup "x" finalEnv @?= Just (VInt 3)
           Map.lookup "y" finalEnv @?= Just (VInt 2)
           Map.lookup "skip_count" finalEnv @?= Just (VInt 1)
           Map.lookup "done" finalEnv @?= Just (VInt 1)
    ]

  , testGroup "if/elseif chain: each elseif tests its own condition (Plan 146 next bug)"
    -- CfgBuild.lowerIf never referenced 'eifCond' at all — every elseif body
    -- was unconditionally reachable once the prior test failed. This fixture
    -- reproduces the shape end-to-end (AST -> CFG -> SSA -> Eff), comparing
    -- against the old, reference-correct compiler's trace.
    [ let xLv    = Lvalue [LvSegment "x" Nothing]
          yLv    = Lvalue [LvSegment "y" Nothing]
          doneLv = Lvalue [LvSegment "done" Nothing]
          eqX n  = ExBinOp (ExLvalue xLv) BopEq (ExInt n)
          body =
            [ Located 1 (BsIf (IfStmt (eqX "1")
                [Located 2 (BsAssign yLv (ExInt "10"))]
                [ ElseIf (eqX "2") [Located 3 (BsAssign yLv (ExInt "20"))]
                , ElseIf (eqX "3") [Located 4 (BsAssign yLv (ExInt "30"))]
                ]
                Nothing))
            , Located 5 (BsAssign doneLv (ExInt "1"))
            ]
          expectedTrace = (Map.fromList [("done", VInt 1)], [TeBranch False, TeBranch False, TeBranch False, TeAssign "done" (VInt 1)], NaturalHalt)
          newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
      in testCase "no elseif clause matches (x unset) -> falls through to the trailing assign, matching the old compiler" $
           newTrace @?= expectedTrace
    ]

  , testGroup "loop-exit-target skips return blocks (Plan 146 Phase 2i)"
    -- Two independent bugs, both needed fixing:
    --
    -- (1) The loop-terminator compilation for a body-internal 'SsaReturn' used
    -- to compile identically to 'SsaBreak', so hitting a return mid-loop
    -- would fall through to the loop's post-loop continuation instead of
    -- truly ending the procedure. Fixed via a true 'EReturn' terminal plus
    -- 'isLoopExit' now refusing to treat a block whose own terminator is
    -- 'SsaReturn' as a loop exit.
    --
    -- (2) 'determineLoopExitTarget' can see a body-internal early-return
    -- block as a second, spurious "successor not in body" candidate
    -- alongside the loop's real post-loop successor. Fixed by preferring a
    -- non-return-terminated candidate whenever one exists.
    --
    -- Fixture: a 3-iteration counted loop whose body branches to a `return`
    -- on a separate `trigger` flag (independent of the loop counter), run
    -- twice with different initial envs to isolate the two defects.
    (let xV  = SsaVarRef (SsaVar "x")
         yV  = SsaVarRef (SsaVar "y")
         trV = SsaVarRef (SsaVar "trigger")
         returnSsa = SsaProc
           { spName   = "test"
           , spEntry  = "entry"
           , spVars   = []
           , spBlocks = Map.fromList
               [ ("entry", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "header" })
               , ("header", SsaBlock
                   { sbAssigns = []
                   , sbTerm = SsaBranch (SsaBinOp BopLt xV (SsaConst (ExInt "3"))) "body_entry" "z_exit" })
               , ("body_entry", SsaBlock
                   { sbAssigns = []
                   , sbTerm = SsaBranch (SsaBinOp BopEq trV (SsaConst (ExInt "1"))) "return_block" "normal_body" })
               , ("return_block", SsaBlock
                   { sbAssigns = [SsaAssign (SsaVar "y") (SsaConst (ExInt "999")) (ExInt "0")]
                   , sbTerm = SsaReturn Nothing })
               , ("normal_body", SsaBlock
                   { sbAssigns = [ SsaAssign (SsaVar "x") (SsaBinOp BopAdd xV (SsaConst (ExInt "1"))) (ExInt "0")
                                 , SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) (ExInt "0") ]
                   , sbTerm = SsaGoto "header" })
               , ("z_exit", SsaBlock
                   { sbAssigns = [SsaAssign (SsaVar "done") (SsaConst (ExInt "1")) (ExInt "0")]
                   , sbTerm = SsaReturn Nothing })
               ]
           }
         compiled = compileSsaToEffDefault returnSsa
         runIt trigger = runInstrGraphTrace 100 Map.empty
                           (buildInstrGraphFromEffTerm compiled)
                           (Map.fromList [("x", VInt 0), ("y", VInt 0), ("done", VInt 0), ("trigger", VInt trigger)])
     in
     [ testCase "compiles to an EReturn (not a break) for the return block" $
         assertBool "expected an EReturn node in the compiled term" (hasEffReturn compiled)

     , testCase "loop completes normally (trigger never fires) and reaches real post-loop trailing code" $
         let (finalEnv, _, _) = runIt 0
         in do
           Map.lookup "x" finalEnv @?= Just (VInt 3)
           Map.lookup "y" finalEnv @?= Just (VInt 3)
           Map.lookup "done" finalEnv @?= Just (VInt 1)

     , testCase "return mid-loop terminates immediately, skipping the rest of the loop and all post-loop code" $
         let (finalEnv, _, _) = runIt 1
         in do
           Map.lookup "x" finalEnv @?= Just (VInt 0)
           Map.lookup "y" finalEnv @?= Just (VInt 999)
           Map.lookup "done" finalEnv @?= Just (VInt 0)
     ])

  , testGroup "if/elseif-with-return inside a do-while loop matches old compiler (Plan 146 Phase 2i)"
    -- Direct regression test for the w_customer_report::open-class corpus
    -- idiom: a SQL cursor-fetch loop whose elseif branch returns on error,
    -- followed by real trailing code after the loop.
    [ let sqlcodeLv = Lvalue [LvSegment "sqlcode" Nothing]
          sqlcodeE  = ExLvalue sqlcodeLv
          call n    = ExCall (Lvalue [LvSegment n Nothing]) []
          ifStmt = IfStmt
            (ExBinOp sqlcodeE BopEq (ExInt "0"))
            [Located 3 (BsCall (call "AddItem"))]
            [ ElseIf (ExBinOp sqlcodeE BopLt (ExInt "0"))
                [ Located 4 (BsCall (call "MessageBox"))
                , Located 5 (BsReturn Nothing)
                ]
            ]
            (Just [Located 6 BsExit])
          body =
            [ Located 1 (BsDo (DoStmt
                (Just (DoWhile (ExBinOp sqlcodeE BopEq (ExInt "0"))))
                [Located 2 (BsIf ifStmt)]
                Nothing))
            , Located 7 (BsCall (call "trailing"))
            ]
          expectedTrace = (Map.empty, [TeBranch False, TeCall "trailing" []], NaturalHalt)
          newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
      in testCase "do-while with if/elseif-return, followed by trailing code, matches old compiler" $
           newTrace @?= expectedTrace
    ]

  , testGroup "if/else where one branch reaches the implicit end before a later loop is compiled (Plan 146 Phase 2i correction)"
    -- Regression test for a real corpus bug an earlier version of the Phase
    -- 2i fix introduced: a plain @if/else@ with a @for...next@ loop in the
    -- else branch and nothing after the whole if/else, where the shared
    -- implicit-end block (reached both from the if-branch directly and from
    -- the for-loop's own exit edge) must not be memoized before the for-loop
    -- is compiled, or the loop's real exit turns into a self-referencing
    -- infinite loop. Bounded via a small 'maxSteps' so a regression here
    -- fails loudly (hits the bound) rather than hanging the test suite.
    (let flagLv = Lvalue [LvSegment "flag" Nothing]
         flagE  = ExLvalue flagLv
         zLv    = Lvalue [LvSegment "z" Nothing]
         iLv    = Lvalue [LvSegment "i" Nothing]
         wLv    = Lvalue [LvSegment "w" Nothing]
         wE     = ExLvalue wLv
         body =
           [ Located 1 (BsIf (IfStmt (ExBinOp flagE BopEq (ExInt "1"))
               [Located 2 (BsAssign zLv (ExInt "99"))]
               []
               (Just [Located 3 (BsFor (ForStmt iLv (ExInt "1") (ExInt "3") Nothing
                   [Located 4 (BsAssign wLv (ExBinOp wE BopAdd (ExInt "1")))]))])))
           ]
         maxSteps = 50 :: Int
         expectedTrace = ( Map.fromList [("i", VInt 4), ("w", VReal 3.0)]
                          , [ TeBranch False
                            , TeAssign "i" (VInt 1), TeBranch True, TeAssign "w" (VReal 1.0)
                            , TeAssign "i" (VInt 2), TeBranch True, TeAssign "w" (VReal 2.0)
                            , TeAssign "i" (VInt 3), TeBranch True, TeAssign "w" (VReal 3.0)
                            , TeAssign "i" (VInt 4), TeBranch False
                            ]
                          , NaturalHalt )
         newTrace = runInstrGraphTrace maxSteps Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
         (_, elseTrc, _) = newTrace
     in
     [ testCase "else-branch for-loop terminates well under the step bound, not a runaway trace" $
         assertBool ("expected well under " <> show maxSteps <> " steps, got " <> show (length elseTrc))
                    (length elseTrc P.< maxSteps)

     , testCase "else-branch (for-loop) matches old compiler" $
         newTrace @?= expectedTrace
     ])

  , testGroup "BsTry (Plan 146 Phase 3 follow-on: CfgBuild now lowers try-body statements)"
    -- Before this fix, CfgBuild's generic dispatcher treated a whole
    -- try/catch block as one opaque pending statement, and
    -- SSA.stmtToAssigns (BsTry {}) = [] meant the try-body's own assigns
    -- never reached SSA at all — silently dropped by the new compiler while
    -- the old compiler (InstrGraph.hs's explicit BsTry case) executed them
    -- sequentially.
    [ testCase "try-body assign now reaches the new compiler's trace, matching old" $
        let body = [ Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "0"))
                   , Located 2 (BsTry (TryStmt
                       [Located 3 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "1"))]
                       [CatchClause "Exception" "e" [Located 4 (BsAssign (Lvalue [LvSegment "y" Nothing]) (ExInt "99"))]]))
                   , Located 5 (BsAssign (Lvalue [LvSegment "z" Nothing]) (ExInt "2"))
                   ]
            expectedTrace = ( Map.fromList [("x", VInt 1), ("z", VInt 2)]
                            , [TeAssign "x" (VInt 0), TeAssign "x" (VInt 1), TeAssign "z" (VInt 2)]
                            , NaturalHalt )
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaEffTerm emptyEnv Set.empty body) Map.empty
            (newEnv, _, _) = newTrace
        in do
             newTrace @?= expectedTrace
             Map.lookup "x" newEnv @?= Just (VInt 1)
             Map.lookup "y" newEnv @?= Nothing
             Map.lookup "z" newEnv @?= Just (VInt 2)

    , testCase "try-body nodes appear in graph shape (canonicalize)" $
        let body = [ Located 1 (BsTry (TryStmt
                       [Located 2 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "1"))]
                       []))
                   ]
            shape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in shape @?= [SAsgn 1, SRet]

    , testCase "BsThrow in isolation — no extra node, falls through to return" $
        let body = [Located 1 (BsThrow (ExLvalue (Lvalue [LvSegment "err" Nothing])))]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
        in canonicalize graph @?= [SRet]

    , testCase "BsThrow after an assign — assign executes, throw produces no node" $
        let body = [ Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "1"))
                   , Located 2 (BsThrow (ExLvalue (Lvalue [LvSegment "err" Nothing])))
                   ]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
        in canonicalize graph @?= [SAsgn 1, SRet]
    ]

  , testGroup "collectBodyLocals (retained helper, Plan 144 Phase 5 Step 7)"
    -- Ported from the now-deleted InstrGraphTest.hs's "body locals" group:
    -- this exercised a PB.Analysis.InstrGraph helper that survives the old
    -- compiler's deletion (still imported directly by PB.Analysis.CatLowerEff)
    -- indirectly, through compileProcedure. Direct unit test on the pure
    -- function itself, rather than losing the coverage. ('parseArgList' had
    -- its own sibling group here pre-Plan-195-Phase-C; it was deleted along
    -- with the function once call/method arguments became typed 'Expr' at
    -- construction time -- 'PB.Grammar.Body.parseExpr' is already covered by
    -- 'ExprTest'.)
    [ testCase "collects BsLocalVar declarations, lower-casing the variable name" $
        let body = [ Located 1 (BsLocalVar [] (PtPrimitive "datawindow") "dw" Nothing)
                   , Located 2 (BsLocalVar [] (PtPrimitive "integer") "Li_Count" Nothing)
                   ]
        in collectBodyLocals body @?= Map.fromList
             [ ("dw", PtPrimitive "datawindow"), ("li_count", PtPrimitive "integer") ]
    ]

  , testGroup "Plan 167 Phase 7 Step 2: EffTerm table + inlineEffTable rehydration"
    -- 'ELetRef' carries no body (unlike the retired 'CatTagged'), so
    -- 'extractEffTable' cannot discover a non-trivial table from a bare
    -- term — see its own headnote in CatOp.hs. It is still the correct
    -- answer (not an approximation) on any sharing-free term, which is
    -- every term these tests construct by hand. 'Eff' has no 'Eq' instance,
    -- so equivalence here is checked observationally, via trace comparison.
    [ testCase "extractEffTable wraps a sharing-free term with an empty table" $ do
        let eff = ECall "shared_proc" [] :: Eff () ()
            EffTerm spine table = extractEffTable eff
        Map.null table @?= True
        (_, spineTrace) <- runEffTrace spine () Map.empty
        (_, effTrace)   <- runEffTrace eff () Map.empty
        spineTrace @?= effTrace

    , testCase "inlineEffTable rehydrates ELetRef back to the table's body" $ do
        let body       = ECall "shared_proc" [] :: Eff () ()
            effTerm     = EffTerm (ELetRef "blk") (Map.fromList [("blk", body)])
            rehydrated = inlineEffTable effTerm
        (_, rehydratedTrace) <- runEffTrace rehydrated () Map.empty
        (_, bodyTrace)       <- runEffTrace body () Map.empty
        rehydratedTrace @?= bodyTrace

    , testCase "inlineEffTable . extractEffTable == id on a sharing-free term (observational)" $ do
        let eff = EComp (ECall "b" []) (ECall "a" []) :: Eff () ()
        (_, roundTripTrace) <- runEffTrace (inlineEffTable (extractEffTable eff)) () Map.empty
        (_, origTrace)      <- runEffTrace eff () Map.empty
        roundTripTrace @?= origTrace
    ]

  , testGroup "EffTerm sharing: ELetRef resolves via the table, fold-caches on first encounter"
    [ testCase "ELetRef at both arms of an EFanIn executes the shared body exactly once regardless of arm taken" $ do
        -- The real merge-point shape: 'ELetRef "shared"' appears at BOTH
        -- arms of an 'EFanIn' (mutually exclusive branches reconverging on
        -- one block). foldFreyd folds the table's body once (first
        -- 'ELetRef' encounter), caches the k () () result under "shared",
        -- and the second 'ELetRef' occurrence reuses the CACHED FOLD — not
        -- a re-traversal of the body term. Because '(|||)' is CHOICE
        -- (Interp dispatches exactly one arm at runtime), the shared body
        -- executes exactly once regardless of which arm is taken.
        let body    = ECall "shared_proc" [] :: Eff () ()
            spine   = EFanIn (ELetRef "shared") (ELetRef "shared") :: Eff (Either () ()) ()
            effTerm = EffTerm spine (Map.fromList [("shared", body)])
            callCount tr = length [() | TeCall "shared_proc" _ <- tr]
        (_, leftTrace)  <- runEffTermTraceGen (Left ())  effTerm Map.empty
        (_, rightTrace) <- runEffTermTraceGen (Right ()) effTerm Map.empty
        callCount leftTrace  @?= 1
        callCount rightTrace @?= 1

    , testCase "ELetRef composed with unrelated effects: only the named block is shared" $ do
        -- 'ELetRef "x"' appears once, sequenced after an unrelated call —
        -- the table lookup must not disturb ordinary composition.
        let body    = ECall "setup" [] :: Eff () ()
            spine   = EComp (ECall "teardown" []) (ELetRef "x") :: Eff () ()
            effTerm = EffTerm spine (Map.fromList [("x", body)])
        (_effEnv, effTrace) <- runEffTermTrace effTerm () Map.empty
        let setupCount = length [() | TeCall "setup" _ <- effTrace]
            teardownCount = length [() | TeCall "teardown" _ <- effTrace]
        setupCount @?= 1
        teardownCount @?= 1
    ]

  , testGroup "Phase 7 Step 4: NamedGraphBuilder (NGB) Effectful instance over EffTerm"
    -- 'compileProcedureViaEffTerm' folds an 'EffTerm' directly to a named
    -- graph via 'NGB' (GraphBuilder.hs), a genuine
    -- 'Category'/'Cartesian'/'Cocartesian'/'Effectful' instance. These
    -- assertions gate the 3 fold-target primitives Step 4 needed beyond
    -- 'branchK' itself: 'branchK' is reachable via the 'EBranch' term
    -- primitive; 'assignWithRhs' gives a carrier with no value channel
    -- direct access to the RHS (the generic 'assign . (id &&& eval)'
    -- derivation erases through NGB's no-op 'eval'/'(&&&)', silently
    -- dropping it); 'memoTag' guards against re-*materializing* a shared
    -- 'ELetRef' body once per occurrence ('foldFreyd's own cache only
    -- prevents re-*folding* it).
    [ testCase "single assignment compiles to exactly one node carrying the real var and expr" $
        let body = [Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "42"))]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
            assigns = [n | n@InstrAssign{} <- igNodes graph]
        in case assigns of
             [InstrAssign { anVar, anRhs }] -> do
               anVar @?= "x"
               anRhs @?= ExInt "42"
             other -> assertFailure ("expected exactly 1 InstrAssign node, got " <> show (length other))

    , testCase "branch node carries the real condition, not a placeholder" $
        let cond = ExBinOp (ExLvalue (Lvalue [LvSegment "x" Nothing])) BopGt (ExInt "0")
            body = [Located 1 (BsIf (IfStmt cond
                      [Located 2 (BsPbCall (PbCall "obj" "then_event"))] []
                      (Just [Located 3 (BsPbCall (PbCall "obj" "else_event"))])))]
            graph = compileProcedureViaEffTerm emptyEnv Set.empty body
            branches = [n | n@InstrBranch{} <- igNodes graph]
        in case branches of
             [InstrBranch { brCond }] -> brCond @?= cond
             other -> assertFailure ("expected exactly 1 InstrBranch node, got " <> show (length other))

    , testCase "if/else with shared tail: canonical shape" $
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   , Located 5 (BsCall (call "callD"))
                   ]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SCall 3, SCall 3, SCall 4, SCall 5, SRet]

    , testCase "nested if inside if/else with shared trailing calls: canonical shape" $
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            innerIf = BsIf (IfStmt (ExBool True)
                        [Located 3 (BsCall (call "callA"))] []
                        (Just [Located 4 (BsCall (call "callB"))]))
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [ Located 2 innerIf
                       , Located 5 (BsCall (call "callC"))
                       , Located 6 (BsCall (call "callD"))
                       ] [] Nothing))
                   ]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SBrnch 3 4, SRet, SCall 5, SCall 5, SCall 6, SCall 2]

    , testCase "choose with 3 cases + default: canonical shape" $
        let clauses = [ CaseClause (Just [tok "1"]) [Located 2 (BsPbCall (PbCall "obj" "case1_event"))]
                      , CaseClause (Just [tok "2"]) [Located 3 (BsPbCall (PbCall "obj" "case2_event"))]
                      , CaseClause (Just [tok "3"]) [Located 4 (BsPbCall (PbCall "obj" "case3_event"))]
                      , CaseClause Nothing          [Located 5 (BsPbCall (PbCall "obj" "default_event"))]
                      ]
            body = [Located 1 (BsChoose (ChooseStmt (ExLvalue (Lvalue [LvSegment "sel" Nothing])) clauses))]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SCall 3, SBrnch 4 5, SRet, SCall 3, SBrnch 6 7, SCall 3, SCall 3]

    , testCase "if/elseif/else chain: canonical shape" $
        let body = [ Located 1 (BsIf (IfStmt (ExBool True)
                      [Located 2 (BsPbCall (PbCall "obj" "first_event"))]
                      [ ElseIf (ExBool False) [Located 3 (BsPbCall (PbCall "obj" "second_event"))]
                      , ElseIf (ExBool False) [Located 4 (BsPbCall (PbCall "obj" "third_event"))]
                      ]
                      (Just [Located 5 (BsPbCall (PbCall "obj" "default_event"))])))]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SCall 3, SBrnch 4 5, SRet, SCall 3, SBrnch 6 7, SCall 3, SCall 3]

    , testCase "4 sequential if/else groups: per-path call counts stay uniform (memoTag prevents duplication)" $
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group (thenN, elseN, tailN, base) =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call thenN))] []
                  (Just [Located (base P.+ 3) (BsCall (call elseN))])))
              , Located (base P.+ 4) (BsCall (call tailN))
              ]
            body = concatMap group
              [ ("callA1", "callB1", "ctail1", 0), ("callA2", "callB2", "ctail2", 4)
              , ("callA3", "callB3", "ctail3", 8), ("callA4", "callB4", "ctail4", 12)
              ]
            expectedCounts = [8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]
            shape = canonicalize (compileProcedureViaEffTerm emptyEnv Set.empty body)
        in pathCallCounts shape @?= expectedCounts

    , testCase "18 sequential if/else groups via foldFreyd/NGB: allocates < 20MB, not 2^18 blowup (memoTag)" $ do
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (length (igNodes (compileProcedureViaEffTerm emptyEnv Set.empty body)))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (memoTag should keep the \
             \foldFreyd/NGB path linear)")
            (bytes P.< 20 P.* 1000 P.* 1000)
    ]

  , testGroup "branchK (Plan 167 Phase 7 Step 1): primitive Effectful method matches its prior derivation"
    -- 'branchK' is promoted from a derived combinator ('branch'/'branchEff')
    -- to a primitive, no-default 'Effectful' method. Every instance's
    -- 'branchK' body is asserted byte-identical to the derivation it
    -- replaces; these tests are the behavioral proof, not just a
    -- compile-success check.
    [ testCase "branchK matches branchEff's trace for Eff (via foldFreyd/Interp)" $ do
        let te = EAssignWithRhs "then_taken" (ExInt "0") (ExInt "1") :: Eff () ()
            fe = EAssignWithRhs "else_taken" (ExInt "0") (ExInt "2") :: Eff () ()
            cond = ExBool True
            viaBranchEff = branchEff cond te fe
            viaBranchK   = branchK cond te fe :: Eff () ()
            golden = [TeBranch True, TeAssign "then_taken" (VInt 1)]
        (_, st1) <- runStateT (runInterp (foldFreydOp viaBranchEff) ()) (InterpState Map.empty [] Map.empty)
        (_, st2) <- runStateT (runInterp (foldFreydOp viaBranchK) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st1) @?= golden
        P.reverse (isTrace st2) @?= golden

    , testCase "branchK matches branch's footprint for SchFootprint (static over-approximation union)" $ do
        let morphismT = SchMorphism (ColumnObj (TableRef Nothing "t1") "a")
                          (StmtObj (SqlStmtId "f" "o" "p" 1)) LegReads SrcSqlText
            morphismF = SchMorphism (StmtObj (SqlStmtId "f" "o" "p" 2))
                          (ColumnObj (TableRef Nothing "t2") "b") LegWrites SrcSqlText
            t = SchFootprint (const (Set.singleton morphismT)) :: SchFootprint () ()
            f = SchFootprint (const (Set.singleton morphismF)) :: SchFootprint () ()
            cond = ExBool True
            ctx = FunctorCtx { fcStmtObj = SqlStmtId "f.srf" "obj" "proc" 1
                              , fcTypeEnv = emptyEnv
                              , fcDwColumns = Map.empty
                              , fcControlBindings = Map.empty }
            viaBranch  = branch cond t f
            viaBranchK = branchK cond t f :: SchFootprint () ()
            golden = Set.fromList [morphismT, morphismF]
        runSchFootprint viaBranch ctx @?= golden
        runSchFootprint viaBranchK ctx @?= golden
    ]
  ]
