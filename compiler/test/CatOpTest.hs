module CatOpTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..),
                            DispatchExpr (..), DispatchMode (..))
import PB.AST.Type         (PbType (..))
import PB.AST.BodyStmt     (BodyStmt (..), PbCall (..), IfStmt (..), ForStmt (..), DoStmt (..), DoCondition (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.CatOp
import PB.Analysis.CpsCompile (ShapeNode (..), canonicalize, compileProcedure, normalizeCallTag)
import PB.Analysis.CpsInterp (runCpsGraphTrace)
import PB.Analysis.SSA     (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                            SsaTerm (..), SsaProc (..), renderSsaVar, buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import Control.Monad.State.Strict (runStateT)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.List       as L
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, assertEqual, testCase, (@?=))

-- | Default compileSsa with empty type env and no user functions.
compileSsaDefault :: SsaProc -> CatOp () ()
compileSsaDefault = compileSsa emptyEnv Set.empty

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty

-- | Build a minimal SsaProc with a single entry block.
mkSsa :: [SsaAssign] -> SsaTerm -> SsaProc
mkSsa assigns term = SsaProc
  { spName   = "test"
  , spBlocks = Map.fromList
      [ ("entry", SsaBlock { sbAssigns = assigns, sbTerm = term }) ]
  , spPhis   = Map.empty
  , spEntry  = "entry"
  , spVars   = [saVar a | a <- assigns]
  }

-- | Check if a CatOp tree contains a CatAssign or CatAssignWithRhs for a given variable name.
hasAssign :: Text -> CatOp a b -> Bool
hasAssign _ CatId = False
hasAssign n (CatAssign t) = n == t
hasAssign n (CatAssignWithRhs t _) = n == t
hasAssign n (CatCompose f g) = hasAssign n f P.|| hasAssign n g
hasAssign n (CatFork f g) = hasAssign n f P.|| hasAssign n g
hasAssign n (CatFanIn f g) = hasAssign n f P.|| hasAssign n g
hasAssign n (CatLoop f) = hasAssign n f
hasAssign n (CatTry f g) = hasAssign n f P.|| hasAssign n g
hasAssign _ _ = False

-- | Check if a CatOp tree contains a CatAssignWithRhs for a given variable name.
hasAssignWithRhs :: Text -> CatOp a b -> Bool
hasAssignWithRhs _ CatId = False
hasAssignWithRhs n (CatAssignWithRhs t _) = n == t
hasAssignWithRhs n (CatCompose f g) = hasAssignWithRhs n f P.|| hasAssignWithRhs n g
hasAssignWithRhs n (CatFork f g) = hasAssignWithRhs n f P.|| hasAssignWithRhs n g
hasAssignWithRhs n (CatFanIn f g) = hasAssignWithRhs n f P.|| hasAssignWithRhs n g
hasAssignWithRhs n (CatLoop f) = hasAssignWithRhs n f
hasAssignWithRhs n (CatTry f g) = hasAssignWithRhs n f P.|| hasAssignWithRhs n g
hasAssignWithRhs _ _ = False

-- | Check if a CatOp tree contains a CatSplitValue (branch discriminator).
hasSplitValue :: CatOp a b -> Bool
hasSplitValue CatSplitValue = True
hasSplitValue (CatCompose f g) = hasSplitValue f P.|| hasSplitValue g
hasSplitValue (CatFork f g) = hasSplitValue f P.|| hasSplitValue g
hasSplitValue (CatFanIn f g) = hasSplitValue f P.|| hasSplitValue g
hasSplitValue (CatLoop f) = hasSplitValue f
hasSplitValue (CatTry f g) = hasSplitValue f P.|| hasSplitValue g
hasSplitValue _ = False

-- | Check if a CatOp tree contains a CatLoop.
hasCatLoop :: CatOp a b -> Bool
hasCatLoop (CatLoop _) = True
hasCatLoop (CatCompose f g) = hasCatLoop f P.|| hasCatLoop g
hasCatLoop (CatFork f g) = hasCatLoop f P.|| hasCatLoop g
hasCatLoop (CatFanIn f g) = hasCatLoop f P.|| hasCatLoop g
hasCatLoop (CatTry f g) = hasCatLoop f P.|| hasCatLoop g
hasCatLoop _ = False

-- | Count CatLoop nodes in a CatOp tree.
countCatLoop :: CatOp a b -> Int
countCatLoop (CatLoop _) = 1
countCatLoop (CatCompose f g) = countCatLoop f P.+ countCatLoop g
countCatLoop (CatFork f g) = countCatLoop f P.+ countCatLoop g
countCatLoop (CatFanIn f g) = countCatLoop f P.+ countCatLoop g
countCatLoop (CatTry f g) = countCatLoop f P.+ countCatLoop g
countCatLoop _ = 0

-- | Check if a CatOp tree contains any CatSuspend node.
hasAnyCatSuspend :: CatOp a b -> Bool
hasAnyCatSuspend (CatSuspend _ _) = True
hasAnyCatSuspend (CatCompose f g) = hasAnyCatSuspend f P.|| hasAnyCatSuspend g
hasAnyCatSuspend (CatFork f g)    = hasAnyCatSuspend f P.|| hasAnyCatSuspend g
hasAnyCatSuspend (CatFanIn f g)   = hasAnyCatSuspend f P.|| hasAnyCatSuspend g
hasAnyCatSuspend (CatLoop f)      = hasAnyCatSuspend f
hasAnyCatSuspend (CatTry f g)     = hasAnyCatSuspend f P.|| hasAnyCatSuspend g
hasAnyCatSuspend _                = False

-- | Check if a CatOp tree contains a CatSuspend with a specific effect name.
hasCatSuspendEffect :: Text -> CatOp a b -> Bool
hasCatSuspendEffect eff (CatSuspend e _) = eff == e
hasCatSuspendEffect eff (CatCompose f g) = hasCatSuspendEffect eff f P.|| hasCatSuspendEffect eff g
hasCatSuspendEffect eff (CatFork f g)    = hasCatSuspendEffect eff f P.|| hasCatSuspendEffect eff g
hasCatSuspendEffect eff (CatFanIn f g)   = hasCatSuspendEffect eff f P.|| hasCatSuspendEffect eff g
hasCatSuspendEffect eff (CatLoop f)      = hasCatSuspendEffect eff f
hasCatSuspendEffect eff (CatTry f g)     = hasCatSuspendEffect eff f P.|| hasCatSuspendEffect eff g
hasCatSuspendEffect _   _                = False

-- | Check if a CatOp tree contains any CatCall node.
hasAnyCatCall :: CatOp a b -> Bool
hasAnyCatCall (CatCall _ _)    = True
hasAnyCatCall (CatCompose f g) = hasAnyCatCall f P.|| hasAnyCatCall g
hasAnyCatCall (CatFork f g)    = hasAnyCatCall f P.|| hasAnyCatCall g
hasAnyCatCall (CatFanIn f g)   = hasAnyCatCall f P.|| hasAnyCatCall g
hasAnyCatCall (CatLoop f)      = hasAnyCatCall f
hasAnyCatCall (CatTry f g)     = hasAnyCatCall f P.|| hasAnyCatCall g
hasAnyCatCall _                = False

-- | ShapeNode predicates for the (Plan 145 SSA fix) for/do-loop tests.
-- SCall/SCProc are treated as equivalent (pure tag-naming divergence — see
-- Phase 1B's category breakdown in doc/plan/145-dual-cps-debug.md).
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
-- actually reachable. Used by the Plan 145 Bug A regression tests below instead of exact
-- shape equality, since fixing 'PB.Analysis.CatOp.compileBlock' to stop dropping content
-- also stopped it from matching the old compiler's specific physical node-sharing
-- pattern — a separate, not-yet-implemented architectural gap (see
-- doc/plan/145-dual-cps-debug.md), not a correctness regression. Assumes a DAG (no
-- SNop/SGoto back-edges) — fine for the non-loop shapes these tests construct.
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
  { steGlobal    = Map.fromList [("dw_foo", PtPrimitive "datawindow"), ("sqlca", PtPrimitive "transaction")]
  , steInstance  = Map.empty
  , steLocal     = Map.empty
  , steHierarchy = Map.empty
  }

-- | Run a compiled 'CatOp' term through 'runCat'\/'Interp', returning the
-- final environment and the trace in chronological order — the Interp-side
-- counterpart to 'runCpsGraphTrace' (Plan 146 Phase 1D).
runInterpTrace :: CatOp () () -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runInterpTrace term initEnv = do
  (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState initEnv [])
  return (isEnv st, P.reverse (isTrace st))

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "CatOp"
  [ testGroup "Category laws (structural)"
    [ testCase "id . id produces CatCompose" $
        assertBool "is CatCompose" (case (id . id :: CatOp Int Int) of CatCompose _ _ -> True; _ -> False)

    , testCase "id . id is structurally distinct from id" $
        assertBool "distinct" ((id :: CatOp Int Int) /= (id . id :: CatOp Int Int))
    ]

  , testGroup "Cocartesian"
    [ testCase "inl produces CatInl" $
        assertBool "is CatInl" (case (inl :: CatOp Int (Either Int Int)) of CatInl -> True; _ -> False)

    , testCase "inr produces CatInr" $
        assertBool "is CatInr" (case (inr :: CatOp Int (Either Int Int)) of CatInr -> True; _ -> False)

    , testCase "fanin produces CatFanIn" $
        assertBool "is CatFanIn" (case (CatFanIn id id :: CatOp (Either Int Int) Int) of CatFanIn _ _ -> True; _ -> False)
    ]

  , testGroup "Cartesian"
    [ testCase "fork produces CatFork" $
        assertBool "is CatFork" (case (id &&& id :: CatOp Int (Int, Int)) of CatFork _ _ -> True; _ -> False)
    ]

  , testGroup "CatOp constructors"
    [ testCase "CatId round-trips via Eq" $
        (CatId :: CatOp Int Int) @?= CatId

    , testCase "CatCompose equality" $
        CatCompose CatId (CatId :: CatOp Int Int) @?= CatCompose CatId CatId

    , testCase "CatLoop equality" $
        assertBool "CatLoop wraps inner" (case CatLoop (inl :: CatOp Int (Either Int Int)) of CatLoop _ -> True; _ -> False)
    ]

  , testGroup "SSA data types"
    [ testCase "SsaVar renders correctly" $
        renderSsaVar (SsaVar "x" 1) @?= "x_1"

    , testCase "SsaVar ordering" $
        assertBool "x_1 < x_2" (SsaVar "x" 1 P.< SsaVar "x" 2)

    , testCase "SsaProc placeholder" $
        let sa = buildSsa P.undefined "test_proc" [] :: SsaProc
        in spName sa @?= "test_proc"
    ]

  , testGroup "compileSsa"
    [ testCase "empty body compiles to CatId" $
        let sa = mkSsa [] (SsaReturn Nothing)
            result = compileSsaDefault sa
        in result @?= (CatId :: CatOp () ())

    , testCase "single assign with SsaReturn" $
        let sa = mkSsa
              [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in assertBool "contains x_1 assign" (hasAssign "x_1" result)

    , testCase "single assign structure: CatAssignWithRhs with embedded RHS" $
        let sa = mkSsa
              [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in case result of
             CatAssignWithRhs v (ExInt "1") ->
               assertEqual "assigns to x_1" "x_1" v
             other -> assertBool ("unexpected structure: " <> show other) False

    , testCase "two linear assigns fold via CatCompose" $
        let sa = mkSsa
              [ SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y" 1) (SsaConst (ExInt "2"))
              ]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in assertBool "contains x_1 assign" (hasAssign "x_1" result)
           P.>> assertBool "contains y_1 assign" (hasAssign "y_1" result)

    , testCase "SsaReturn compiles to CatId" $
        let sa = mkSsa [] (SsaReturn Nothing)
            result = compileSsaDefault sa
        in result @?= (CatId :: CatOp () ())

    , testCase "SsaReturn with value compiles to CatId" $
        let sa = mkSsa [] (SsaReturn (Just (SsaConst (ExInt "42"))))
            result = compileSsaDefault sa
        in result @?= (CatId :: CatOp () ())

    , testCase "assign with SsaVarRef embeds ExLvalue in RHS" $
        let sa = mkSsa
              [ SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y" 1) (SsaVarRef (SsaVar "x" 1))
              ]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in assertBool "contains y_1 assign with ExLvalue RHS" (hasAssignWithRhs "y_1" result)

    , testCase "SsaGoto compiles to CatCompose of block assigns" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
                      , sbTerm = SsaGoto "target" })
                  , ("target", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "y" 1) (SsaConst (ExInt "2"))]
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
        in assertBool "contains x_1 assign" (hasAssign "x_1" result)
           P.>> assertBool "contains y_1 assign" (hasAssign "y_1" result)

    , testCase "SsaBranch compiles to branch combinator" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "then" "else" })
                  , ("then", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
                      , sbTerm = SsaReturn Nothing })
                  , ("else", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "y" 1) (SsaConst (ExInt "2"))]
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
        in assertBool "contains x_1 in then branch" (hasAssign "x_1" result)
           P.>> assertBool "contains y_1 in else branch" (hasAssign "y_1" result)
           P.>> assertBool "contains splitValue for branch" (hasSplitValue result)

    , testCase "loop compiles to CatLoop with back-edge" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "i" 1) (SsaConst (ExInt "1"))]
                      , sbTerm = SsaGoto "header" })
                  , ("header", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "i" 2) (SsaVarRef (SsaVar "i" 1))]
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "body" "exit" })
                  , ("body", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "i" 3) (SsaBinOp BopAdd (SsaVarRef (SsaVar "i" 2)) (SsaConst (ExInt "1")))]
                      , sbTerm = SsaGoto "header" })
                  , ("exit", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
        in assertBool "contains CatLoop" (hasCatLoop result)

    , testCase "nested loops produce nested CatLoop" $
        -- entry → outer_header → inner_header → inner_body → inner_header
        --                                       inner_exit → outer_header
        --                          outer_exit → return
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
                      , sbTerm = SsaGoto "outer" })
                  , ("outer", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "inner" "outer_exit" })
                  , ("inner", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x" 2) (SsaBinOp BopAdd (SsaVarRef (SsaVar "x" 1)) (SsaConst (ExInt "1")))]
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "inner_body" "inner_exit" })
                  , ("inner_body", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaGoto "inner" })
                  , ("inner_exit", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaGoto "outer" })
                  , ("outer_exit", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
        in assertBool "contains at least 2 CatLoop nodes" (countCatLoop result P.>= 2)

    , testCase "loop with multiple exits finds correct exit target" $ do
        -- entry → header → body → header  (back-edge)
        --                → exit → return
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaGoto "header" })
                  , ("header", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "body" "exit" })
                  , ("body", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "42"))]
                      , sbTerm = SsaGoto "header" })
                  , ("exit", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
        assertBool "contains CatLoop" (hasCatLoop result)
           P.>> assertBool "contains x_1 assign" (hasAssign "x_1" result)
    ]

  , testGroup "call classification"
    [ testCase "ExCall with DW receiver emits CatSuspend not CatCall" $
        -- dw_foo.retrieve() — multi-segment ExCall classified as SuspendCall
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "should contain CatSuspend with effect retrieve:dw_foo"
             (hasCatSuspendEffect "retrieve:dw_foo" result)

    , testCase "ExMethodCall on Transaction emits CatSuspend not CatCall" $
        -- sqlca.commit() — ExMethodCall on a transaction-typed receiver
        let callExpr = ExMethodCall
              { receiver   = ExLvalue (Lvalue [LvSegment "sqlca" Nothing])
              , method     = "commit"
              , methodArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "should contain CatSuspend with effect executeSql"
             (hasCatSuspendEffect "executeSql" result)

    , testCase "ExCall pure user function does not emit CatSuspend" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "my_func" Nothing], callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa emptyEnv Set.empty sa
        in assertBool "pure call should produce no CatSuspend" (not (hasAnyCatSuspend result))

    , testCase "end-to-end: BsCall dw_foo.retrieve() → CpsSuspend node in CpsGraph" $
        -- buildSsa from a standalone BsCall; CpsSuspend must appear in the graph
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            body     = [Located 1 (BsCall callExpr)]
            ssaProc  = buildSsa dwEnv "proc" body
            catTree  = compileSsa dwEnv Set.empty ssaProc
            graph    = buildCpsGraph catTree
            hasCpsSuspend = any (\n -> case n of { CpsSuspend {} -> True; _ -> False }) (cgNodes graph)
        in assertBool "CpsGraph should contain a CpsSuspend node" hasCpsSuspend
    ]

  , testGroup "assign-with-call-RHS (Plan 145 Phase 1B re-sample Finding B)"
    -- x = f() / x = obj.method() used to silently drop the assignment target and
    -- compile to a bare CatCall/CatSuspend — the call ran but its result was
    -- never stored. PB.Analysis.CpsCompile (the old, confirmed-correct compiler)
    -- never special-cases a call RHS on BsAssign; it always emits one CpsAssign.
    [ testCase "x = my_func() (pure) assigns, does not emit a bare CatCall" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "my_func" Nothing], callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa emptyEnv Set.empty sa
        in assertBool "x_1 assign present, no bare CatCall"
             (hasAssign "x_1" result P.&& not (hasAnyCatCall result))

    , testCase "x = dw_foo.retrieve() (suspend) assigns, does not emit CatSuspend" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "x_1 assign present, no CatSuspend"
             (hasAssign "x_1" result P.&& not (hasAnyCatSuspend result))

    , testCase "standalone (discard) suspend call is unaffected" $
        -- Sanity: the "_" discard target must still classify and emit CatSuspend.
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "should still contain CatSuspend" (hasAnyCatSuspend result)

    , testCase "end-to-end: x = messagebox() matches old compiler's [SAsgn, SRet]" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "messagebox" Nothing], callArgs = [] }
            body     = [Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) callExpr)]
            graph    = compileProcedureViaCatOp emptyEnv Set.empty body
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

  , testGroup "Interp / runCat"
    [ testCase "runCat CatId is identity, no trace" $ do
        (result, st) <- runStateT (runInterp (runCat (CatId :: CatOp () ())) ()) (InterpState Map.empty [])
        result @?= ()
        isTrace st @?= []

    , testCase "runCat CatAssignWithRhs updates env and emits TeAssign" $ do
        let term = CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [])
        Map.lookup "x_1" (isEnv st) @?= Just (VInt 42)
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 42)]

    , testCase "runCat CatCompose threads env through both assigns in order" $ do
        let term = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [])
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 1), TeAssign "y_1" (VInt 2)]

    , testCase "runCat branch emits TeBranch True and takes the then-arm" $ do
        let term = branch (ExBool True)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [])
        P.reverse (isTrace st) @?= [TeBranch True, TeAssign "then_taken" (VInt 1)]

    , testCase "runCat branch emits TeBranch False and takes the else-arm" $ do
        let term = branch (ExBool False)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [])
        P.reverse (isTrace st) @?= [TeBranch False, TeAssign "else_taken" (VInt 2)]

    , testCase "runCat CatSuspend records TeSuspend with evaluated args" $ do
        let term = CatSuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [])
        P.reverse (isTrace st) @?= [TeSuspend "retrieve:dw_foo" [VInt 1, VStr "bar"]]

    , testCase "runCat CatCall records TeCall with evaluated args" $ do
        let term = CatCall "my_func" [ExInt "5"] :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [])
        P.reverse (isTrace st) @?= [TeCall "my_func" [VInt 5]]
    ]

  , testGroup "Phase 4: buildCpsGraph"
    [ testCase "CatId compiles to just exit node" $
        let graph = buildCpsGraph (CatId :: CatOp () ())
        in do
          cgEntry graph @?= 0
          case cgNodes graph of
            [CpsReturn Nothing] -> return ()
            other -> assertBool ("expected 1 exit node, got " <> show (P.length other)) False

    , testCase "CatAssignWithRhs compiles to CpsAssign + exit" $
        let graph = buildCpsGraph (CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ())
        in do
          cgEntry graph @?= 1
          case cgNodes graph of
            [CpsReturn Nothing, CpsAssign { anVar = "x_1", anRhs = ExInt "42", anNext = 0 }] ->
              return ()
            other -> assertBool ("expected exit + assign, got " <> show (P.length other)) False

    , testCase "two assigns chain entry→x_1→y_1→exit" $
        let op = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            graph = buildCpsGraph op
        in do
          cgEntry graph @?= 2
          P.length (cgNodes graph) @?= 3
          case cgNodes graph of
            (CpsReturn Nothing : CpsAssign { anVar = "y_1" } : CpsAssign { anVar = "x_1" } : []) -> return ()
            _ -> assertBool "expected [exit, y_1, x_1]" False

    , testCase "branch compiles to CpsBranch diamond with no unconditional join nop (Plan 145 Finding A)" $
        let thenK = CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            elseK = CatAssignWithRhs "y_1" (ExInt "2")
            op = branch (ExBool True) thenK elseK :: CatOp () ()
            graph = buildCpsGraph op
        in do
          P.length (cgNodes graph) @?= 4
          case cgNodes graph of
            ( CpsReturn Nothing
              : CpsAssign { anVar = "y_1", anNext = 0 }
              : CpsAssign { anVar = "x_1", anNext = 0 }
              : CpsBranch { brThenPc = 2, brElsePc = 1 }
              : [] ) -> return ()
            nodes -> assertBool ("expected 4 nodes [exit, else, then, branch], got " <> show (P.length nodes) <> ": " <> show nodes) False

    , testCase "branch condition preserved through LowCat (not ExNull)" $
        let thenK = CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            elseK = CatAssignWithRhs "y_1" (ExInt "2")
            op = branch (ExBool True) thenK elseK :: CatOp () ()
            graph = buildCpsGraph op
            branches = filter (\n -> case n of CpsBranch {} -> True; _ -> False) (cgNodes graph)
        in case branches of
             [CpsBranch { brCond = ExBool True }] -> return ()
             other -> assertBool ("expected branch with ExBool True, got " <> show other) False

    , testCase "structural erasure preserves assignments" $
        let op = (CatExl :: CatOp (Int, Int) Int) `seq`
                 CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            graph = buildCpsGraph op
        in do
          P.length (cgNodes graph) @?= 2
          case cgNodes graph of
            (CpsReturn Nothing : CpsAssign { anVar = "x_1" } : []) -> return ()
            _ -> assertBool "expected [exit, assign]" False

    , testCase "end-to-end: SSA loop → CpsGraph preserves assignments and back-edge" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock [] (SsaGoto "header"))
                  , ("header", SsaBlock [] (SsaBranch (SsaConst (ExBool True)) "body" "exit"))
                  , ("body", SsaBlock [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "42"))] (SsaGoto "header"))
                  , ("exit", SsaBlock [] (SsaReturn Nothing))
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            catTree  = compileSsaDefault sa
            graph    = buildCpsGraph catTree
            nodes    = cgNodes graph
            hasCpsAssign v = any (\n -> case n of CpsAssign { anVar = v' } -> v' == v; _ -> False) nodes
            hasGoto        = any (\n -> case n of CpsGoto _ -> True; _ -> False) nodes
            hasBranch      = any (\n -> case n of CpsBranch {} -> True; _ -> False) nodes
        in do
          assertBool "should contain x_1 assign" (hasCpsAssign "x_1")
          -- No CpsGoto: the back-edge is the body assign's own anNext pointing
          -- straight at the header pc, matching the old compiler (Plan 145
          -- LInl/LInr fix — see "no wrapper CpsGoto" group below).
          assertBool "should contain no wrapper CpsGoto for the back-edge" (not hasGoto)
          assertBool "should contain CpsBranch" hasBranch

    , testCase "unit: CatLoop lowers to correct header patch, no wrapper CpsGoto" $
        -- Headerless loop body (no CatFanIn branch to patch in place — falls
        -- back to the forwarding CpsNop path). Even here, LInl resolves
        -- directly to the header pc (Plan 145 LInl/LInr fix): the assign's
        -- own anNext closes the cycle, no CpsGoto is ever allocated.
        let loopBody = CatCompose CatInl (CatAssignWithRhs "counter" (ExInt "42")) :: CatOp () (Either () ())
            catTree  = CatLoop loopBody :: CatOp () ()
            graph    = buildCpsGraph catTree
        in canonicalize graph @?= [SNop 1, SAsgn 0]

    , testCase "end-to-end: simple linear SSA → CpsGraph" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = [ SsaAssign (SsaVar "a" 1) (SsaConst (ExInt "1"))
                                     , SsaAssign (SsaVar "b" 1) (SsaConst (ExInt "2")) ]
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            catTree  = compileSsaDefault sa
            graph    = buildCpsGraph catTree
            nodes    = cgNodes graph
        in do
          assertBool ("should have 3 nodes (exit + 2 assigns), got " <> show (P.length nodes))
            (P.length nodes == 3)
          assertBool "should contain a_1"
            (any (\n -> case n of CpsAssign { anVar = "a_1" } -> True; _ -> False) nodes)
          assertBool "should contain b_1"
            (any (\n -> case n of CpsAssign { anVar = "b_1" } -> True; _ -> False) nodes)
    ]

  , testGroup "compileProcedureViaCatOp"
    [ testCase "empty body produces non-empty graph" $
        let graph = compileProcedureViaCatOp emptyEnv Set.empty []
        in assertBool "should have at least one node (exit)" (not (null (cgNodes graph)))

    , testCase "single BsCall produces non-empty graph" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "foo" Nothing], callArgs = [] }
            body     = [Located 1 (BsCall callExpr)]
            graph    = compileProcedureViaCatOp emptyEnv Set.empty body
        in assertBool "should have more than one node" (P.length (cgNodes graph) P.> 1)

    , testCase "DW suspend call produces CpsSuspend in graph" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            body  = [Located 1 (BsCall callExpr)]
            graph = compileProcedureViaCatOp dwEnv Set.empty body
        in assertBool "should contain CpsSuspend"
             (any (\n -> case n of CpsSuspend {} -> True; _ -> False) (cgNodes graph))

    -- Plan 145 Phase 1C/3: BsPbCall (`call ancestor::event`) used to be dropped
    -- entirely by PB.Analysis.SSA.stmtToAssigns's catch-all. Confirms the fix
    -- makes the new pipeline match PB.Analysis.CpsCompile's old-compiler output
    -- for the exact m_ole_example::destroy regression case (CpsCompileTest.hs's
    -- "2B" hand-trace test) bit-for-bit, not just structurally equivalent.
    , testCase "BsPbCall (call ancestor::event) matches old compiler's [SCProc, SRet]" $
        let body  = [Located 1 (BsPbCall (PbCall "m_ole_frame" "destroy"))]
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
        in canonicalize graph @?= [SCProc 1, SRet]
    ]

  , testGroup "no unconditional join CpsNop (Plan 145 Finding A)"
    -- PB.Analysis.CatOp.compileLowCatToCps's LCompose/LFanIn branch case (and the
    -- analogous case in compileLoopBodyLowCat) used to unconditionally allocate a
    -- join CpsNop before both arms, even when nothing structurally requires one.
    -- The old compiler (PB.Analysis.CpsCompile, confirmed-correct reference) never
    -- allocates this node — both arms just point their fallthrough straight at the
    -- shared continuation. Cosmetic (no data loss), but common (every if/if-else).
    [ testCase "if without else, nothing follows — matches old compiler exactly" $
        -- w_notepad::ue_key_up pattern: if cond then <call> end if.
        let body  = [Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsPbCall (PbCall "m_ole_frame" "destroy"))] [] Nothing))]
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
        in canonicalize graph @?= [SBrnch 1 2, SCProc 2, SRet]

    , testCase "if/else, both arms, nothing follows — matches old compiler exactly" $
        let body  = [Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsPbCall (PbCall "m_ole_frame" "destroy"))] []
                       (Just [Located 3 (BsPbCall (PbCall "m_ole_frame" "create"))])))]
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
        in canonicalize graph @?= [SBrnch 1 2, SCProc 3, SCProc 3, SRet]

    , testCase "branch inside a loop body has no join CpsNop" $
        -- Direct CatOp construction (bypassing SSA/BsFor) isolates
        -- compileLoopBodyLowCat's branch case from an unrelated, separate bug
        -- where a for-loop containing an if collapses entirely (logged to BACKLOG).
        --
        -- Also verifies the compileLoopLowCat header-patch fix (Plan 145,
        -- "u_ddcal root cause and fix" follow-up): the loop header used to
        -- allocate a persistent CpsNop placeholder and re-patch it with a
        -- *forwarding* CpsNop to a separately-allocated CpsBranch, instead of
        -- resolving the placeholder to the branch node in place. Since this
        -- loop's body is itself exactly a branch, the header IS that branch —
        -- no SNop should appear at all.
        --
        -- Also verifies the LInl/LInr fix (Plan 145): neither the continue
        -- (LInl, then-arm) nor the break (LInr, else-arm) allocates a wrapper
        -- CpsGoto — the assign's anNext closes the back-edge directly onto
        -- the branch, and the break routes straight to the exit/return, so
        -- the whole loop is exactly 3 nodes (branch, assign, return).
        let innerBranch = branch (ExBool True)
              (CatCompose CatInl (CatAssignWithRhs "x_1" (ExInt "1")) :: CatOp () (Either () ()))
              (CatInr :: CatOp () (Either () ()))
            catTree = CatLoop innerBranch :: CatOp () ()
            graph   = buildCpsGraph catTree
        in canonicalize graph @?= [SBrnch 1 2, SAsgn 0, SRet]
    ]

  , testGroup "no wrapper CpsGoto for loop continue/break (Plan 145 LInl/LInr fix)"
    -- compileLoopBodyLowCat's LInl/LInr cases used to each allocate a genuine
    -- CpsGoto node for the loop's implicit continue/break, where the old
    -- compiler (PB.Analysis.CpsCompile's BsFor/BsDo) threads the raw target
    -- pcs straight through with zero wrapper nodes. This was the last
    -- blocker for --dual-cps exact-match parity on loop-containing
    -- procedures (the header-CpsNop fix above didn't move the diff count
    -- because of this sibling bug). Fixed by resolving LInl/LInr directly to
    -- loopHeaderPc/nextPc as entry pcs (structural/erased, like
    -- LEval/LFork/LSplitValue) instead of allocateNode-ing a CpsGoto.
    --
    -- These are end-to-end bit-for-bit equality checks against the old
    -- compiler for the exact minimal for/do-loop shapes traced in the plan
    -- (doc/plan/145-dual-cps-debug.md, "New finding: LInl/LInr residual
    -- CpsGoto hops"). Only SCall vs SCProc differs — the pre-existing,
    -- documented cosmetic call-tag divergence (Phase 1B), not a real
    -- difference — so both sides are normalized before comparing.
    [ testCase "for loop containing one call matches old compiler exactly (mod SCall/SCProc tag)" $
        let body = [Located 1 (BsFor (ForStmt (Lvalue [LvSegment "li_count" Nothing])
                      (ExInt "1") (ExInt "10") Nothing
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))]))]
            oldShape = normalizeCallTag <$> canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= oldShape

    , testCase "do-while loop containing one call matches old compiler exactly (mod SCall/SCProc tag)" $
        let body = [Located 1 (BsDo (DoStmt (Just (DoWhile (ExBool True)))
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))] Nothing))]
            oldShape = normalizeCallTag <$> canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= oldShape
    ]

  , testGroup "for/do-loop header collapse (Plan 145 post-Finding-A block-collapse bug)"
    -- Root cause: PB.Analysis.CfgBuild.lowerFor/lowerDo (top-condition) flush the
    -- raw BsFor/BsDo node onto the *predecessor* block and give the actual
    -- condition/header block zero statements of its own. SSA.cfgTermToSsa used to
    -- look for a control statement only in the header block's own stmts, find
    -- none, and fall back to `SsaReturn Nothing` (the header has two edges, not
    -- one) — silently truncating the whole procedure at the first loop. Confirmed
    -- via a read-only GHCi hand-trace of u_ddcal::enter_day_numbers (old=17
    -- nodes, new=1 — collapsed to bare [SRet]) before writing these tests.
    --
    -- A second, distinct root cause was found while writing these tests and is
    -- now fixed: PB.Analysis.CatOp.compileLoopLowCat used to unconditionally
    -- allocate a persistent loop-header CpsNop as a forward-reference
    -- placeholder, then re-patch it with *another* forwarding CpsNop instead of
    -- resolving it to the real CpsBranch in place. Fixed by patching the
    -- reserved header pc directly with the branch node (mirroring
    -- CpsCompile.hs's BsFor patchNode pattern) via the new
    -- patchLoopHeaderLowCat helper — see "no unconditional join CpsNop (Plan
    -- 145 Finding A)" → "branch inside a loop body has no join CpsNop" above
    -- for the isolated regression test.
    --
    -- Still open, out of scope here (logged to BACKLOG): compileLoopBodyLowCat's
    -- LInl/LInr cases still allocate a genuine CpsGoto node for the implicit
    -- loop back-edge/break, where the old compiler routes continue/break
    -- directly to the real target pc with no wrapper node at all. This is a
    -- separate, smaller residual cosmetic gap (same family, different call
    -- site) blocking full bit-for-bit --dual-cps parity on loop bodies. These
    -- tests assert the properties the SSA fix guarantees: the loop's
    -- condition, body call, init, and increment are all real, present nodes
    -- (nothing vanishes), independent of the remaining cosmetic Goto hops.
    [ testCase "for loop containing one call: condition, body, init, and increment are all preserved" $
        let body = [Located 1 (BsFor (ForStmt (Lvalue [LvSegment "li_count" Nothing])
                      (ExInt "1") (ExInt "10") Nothing
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))]))]
            shape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
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
            shape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in do
          assertEqual "exactly one branch (the loop condition check)"
            1 (length (filter isBrnchNode shape))
          assertEqual "exactly one call node (the loop body)"
            1 (length (filter isCallishNode shape))
    ]

  , testGroup "no CatAssignWithRhs for standalone dispatch statements (Plan 145 ExDispatch fix)"
    -- compileAssign's "_"-discard case only pattern-matched SsaConst
    -- (ExCall ...)/(ExMethodCall ...), so a standalone dispatch statement
    -- (`.Post`/`.Trigger`/`Dynamic ... Event(...)` — PB's inter-object
    -- messaging idiom, e.g. `ParentWindow.Dynamic Post of_run_report()` or
    -- `Post Event ue_GetValues()`) fell through to CatAssignWithRhs, producing
    -- a real CpsAssign{anVar="_"} node instead of a bare call node. The old
    -- compiler (PB.Analysis.CpsCompile's BsCall `otherwise` branch) never has
    -- this gap: it calls classifyExpr/calleeName generically regardless of
    -- expr shape, both defaulting to PureCall/"?" for anything that isn't
    -- ExCall/ExMethodCall — confirmed as the exact ground-truth reference
    -- shape via a read-only cabal repl session parsing the real source text
    -- through PB.Grammar.Body.parseExpr (not hand-built), matching the
    -- m_main::clicked / w_registry_functions::open ("Post Event
    -- ue_GetValues()") diffs found in a fresh Plan 145 corpus re-sample.
    [ testCase "ExDispatch (Dynamic Post) matches old compiler exactly (mod SCall/SCProc tag)" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Just (Lvalue [LvSegment "ParentWindow" Nothing]), mode = DmPost
              , dynamic = True, event = False, name = "of_run_report", args = [] })
            body = [Located 1 (BsCall dispatchExpr)]
            oldShape = normalizeCallTag <$> canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= oldShape

    , testCase "ExDispatch (bare Post Event) matches old compiler exactly (mod SCall/SCProc tag)" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Nothing, mode = DmPost, dynamic = False
              , event = True, name = "ue_getvalues", args = [] })
            body = [Located 1 (BsCall dispatchExpr)]
            oldShape = normalizeCallTag <$> canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= oldShape

    , testCase "no CatAssignWithRhs is emitted for a standalone dispatch statement" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Just (Lvalue [LvSegment "ParentWindow" Nothing]), mode = DmPost
              , dynamic = True, event = False, name = "of_run_report", args = [] })
            body  = [Located 1 (BsCall dispatchExpr)]
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
            hasAssignNode = any (\n -> case n of CpsAssign {} -> True; _ -> False) (cgNodes graph)
        in assertBool "should contain no CpsAssign node" (not hasAssignNode)
    ]

  , testGroup "compileBlock memoization: shared-tail content survives on every predecessor (Plan 145 Bug A)"
    -- PB.Analysis.CatOp.compileBlock's `Set.member blockId visited = (CatId, visited)`
    -- (a global registry to avoid re-descending into an already-compiled block) returns
    -- a no-op identity morphism on any revisit instead of the block's actual compiled
    -- content. This is only safe when the shared block is a bare empty return; for any
    -- block with real assigns/calls, the second (and later) predecessor to reach it
    -- silently drops that content. Confirmed via direct buildCfg/buildSsa hand-tracing
    -- (the SSA/CFG layer is correct; the bug is introduced here) against real corpus
    -- procedures (w_dw_functions::clicked, w_frame_menu_functions::destroy — see
    -- doc/plan/145-dual-cps-debug.md §Findings — Root cause found).
    -- Assertions compare 'pathCallCounts' (root-to-return call counts per path), not
    -- raw shape equality, against the old compiler: the fix stops content from being
    -- silently dropped, but it does not (and isn't trying to) replicate the old
    -- compiler's specific physical node-sharing — GraphBuilder's CatOp/LowCat lowering
    -- has no node-level memoization of its own, so a merge block reached by more than
    -- one predecessor gets emitted once per predecessor (duplicated) rather than shared
    -- as a single physical node. Both are semantically correct; only exact
    -- `--dual-cps` node-count parity is affected (tracked separately, not this fix's
    -- goal — see doc/plan/145-dual-cps-debug.md §Findings — Root cause found).
    [ testCase "if without else: trailing calls after merge execute regardless of branch" $
        -- Mirrors w_frame_menu_functions::destroy: the implicit "condition false"
        -- edge and the then-arm's fallthrough both converge on the same merge block,
        -- which holds the real trailing calls. Pre-fix, the else-path reached SRet
        -- directly (0 calls) instead of the required callB+callC (2 calls).
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True) [Located 2 (BsCall (call "callA"))] [] Nothing))
                   , Located 3 (BsCall (call "callB"))
                   , Located 4 (BsCall (call "callC"))
                   ]
            oldShape = canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= pathCallCounts oldShape

    , testCase "if/else, both arms: shared trailing calls survive on both paths" $
        -- Mirrors the mechanism behind w_dw_functions::clicked: both the then-arm and
        -- the else-arm converge on the same merge block holding real trailing calls.
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   , Located 5 (BsCall (call "callD"))
                   ]
            oldShape = canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= pathCallCounts oldShape

    , testCase "nested if inside if/else with shared trailing calls (real corpus shape: w_dw_functions::clicked)" $
        -- Mirrors the exact real-world procedure this bug was root-caused from:
        -- an outer if containing an inner if/else, followed by two more calls that
        -- both inner arms must reach.
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            innerIf = BsIf (IfStmt (ExBool True)
                        [Located 3 (BsCall (call "callA"))] []
                        (Just [Located 4 (BsCall (call "callB"))]))
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [ Located 2 innerIf
                       , Located 5 (BsCall (call "callC"))
                       , Located 6 (BsCall (call "callD"))
                       ] [] Nothing))
                   ]
            oldShape = canonicalize (compileProcedure emptyEnv Set.empty body)
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= pathCallCounts oldShape
    ]

  , testGroup "Phase 1D: Interp vs GraphBuilder trace equivalence (Plan 146)"
    -- Same CatOp term, run through both of CatOp's execution backends:
    -- Interp (direct Haskell execution) and GraphBuilder (flat CpsGraph, the
    -- shape the TS runtime consumes). A divergence here is a real backend
    -- bug, independent of anything upstream in the AST/SSA/CatOp compilation
    -- stages. Reuses the exact terms hand-built in the "Interp / runCat"
    -- group above (narrow, fixture-driven pass per Plan 146 Phase 1 Step 1D
    -- — a generator is deferred until this passes).
    [ testCase "CatId: no trace, no env change" $ do
        let term = CatId :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= []
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatAssignWithRhs: same assign trace, same env" $ do
        let term = CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= [TeAssign "x_1" (VInt 42)]
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatCompose: two assigns execute in the same order" $ do
        let term = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branch True: then-arm taken on both backends" $ do
        let term = branch (ExBool True)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branch False: else-arm taken on both backends" $ do
        let term = branch (ExBool False)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatSuspend: same effect name and evaluated args" $ do
        let term = CatSuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatCall: same callee and evaluated args" $ do
        let term = CatCall "my_func" [ExInt "5"] :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatLoop: counts to 3 identically on both backends" $ do
        -- A hand-built loop with a real terminating condition — unlike the
        -- shape-only SSA loop fixtures elsewhere in this file, which all use
        -- a constant `ExBool True` condition and would loop forever if
        -- actually executed rather than just inspected for shape.
        let iVar = ExLvalue (Lvalue [LvSegment "i" Nothing])
            cond = ExBinOp iVar BopLt (ExInt "3")
            incr = ExBinOp iVar BopAdd (ExInt "1")
            loopBody = branch cond
                         (CatInl . CatAssignWithRhs "i" incr)
                         CatInr :: CatOp () (Either () ())
            term = CatLoop loopBody :: CatOp () ()
            initEnv = Map.fromList [("i", VInt 0)]
        (ienv, itrace) <- runInterpTrace term initEnv
        let (genv, gtrace) = runCpsGraphTrace (buildCpsGraph term) initEnv
        itrace @?= gtrace
        ienv @?= genv
        Map.lookup "i" ienv @?= Just (VInt 3)
    ]
  ]
