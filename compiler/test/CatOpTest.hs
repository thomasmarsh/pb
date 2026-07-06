module CatOpTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..),
                            DispatchExpr (..), DispatchMode (..))
import PB.AST.Type         (PbType (..))
import PB.AST.BodyStmt     (BodyStmt (..), PbCall (..), IfStmt (..), ElseIf (..), ForStmt (..), DoStmt (..), DoCondition (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.CatOp
import PB.Analysis.CpsCompile (ShapeNode (..), canonicalize, compileProcedure, normalizeCallTag)
import PB.Analysis.CpsInterp (runCpsGraphTrace)
import PB.Analysis.SSA     (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                            SsaTerm (..), SsaProc (..), renderSsaVar, buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Lexing.Lexer     (tokenizeLine, LexLine (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))
import Control.Monad.State.Strict (runStateT)
import qualified Control.Exception as CE

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

-- | Tokenize a single source snippet into one 'Token' via the real lexer
-- (mirrors 'CpsCompileTest.hs's identical helper) — used to build genuine
-- 'ExCall' @callArgs@ ([[Token]]) for tests that need real argument shapes
-- (e.g. a string literal arg) rather than empty argument lists.
tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk
  _            -> Token TkIdent t (SourceSpan 1 1 1)
  where ll = LogicalLine t 1 1

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

-- | Check if a CatOp tree contains a CatReturn (Plan 146 Phase 2i: the
-- true procedure-terminal escape, distinct from CatInr/break).
hasCatReturn :: CatOp a b -> Bool
hasCatReturn CatReturn = True
hasCatReturn (CatCompose f g) = hasCatReturn f P.|| hasCatReturn g
hasCatReturn (CatFork f g) = hasCatReturn f P.|| hasCatReturn g
hasCatReturn (CatFanIn f g) = hasCatReturn f P.|| hasCatReturn g
hasCatReturn (CatLoop f) = hasCatReturn f
hasCatReturn (CatTry f g) = hasCatReturn f P.|| hasCatReturn g
hasCatReturn _ = False

-- | Count CatLoop nodes in a CatOp tree, including ones nested inside
-- another CatLoop's own body (Plan 146 Phase 2f: a correctly-nested loop
-- compiles to a CatLoop *inside* the enclosing loop's body, not a sibling
-- one — the pre-fix shape had them side by side, purely a symptom of the
-- exit-target bug, not a structure worth preserving).
countCatLoop :: CatOp a b -> Int
countCatLoop (CatLoop f) = 1 P.+ countCatLoop f
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
-- counterpart to 'runCpsGraphTrace' (Plan 146 Phase 1D). Catches
-- 'ReturnUnwind' (Plan 146 Phase 2i): a 'CatReturn' inside the term throws
-- rather than returning normally, since 'Interp's plain function composition
-- has no other way to skip past an enclosing loop's continuation — the
-- carried 'InterpState' is exactly the state at the point of the throw.
runInterpTrace :: CatOp () () -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runInterpTrace term initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (runCat term) ()) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
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
        in assertBool "contains x assign" (hasAssign "x" result)

    , testCase "single assign structure: CatAssignWithRhs with embedded RHS" $
        let sa = mkSsa
              [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in case result of
             CatAssignWithRhs v (ExInt "1") ->
               assertEqual "assigns to x (SSA version erased, not x_1)" "x" v
             other -> assertBool ("unexpected structure: " <> show other) False

    , testCase "two linear assigns fold via CatCompose" $
        let sa = mkSsa
              [ SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y" 1) (SsaConst (ExInt "2"))
              ]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in assertBool "contains x assign" (hasAssign "x" result)
           P.>> assertBool "contains y assign" (hasAssign "y" result)

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
        in assertBool "contains y assign with ExLvalue RHS" (hasAssignWithRhs "y" result)

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
        in assertBool "contains x assign" (hasAssign "x" result)
           P.>> assertBool "contains y assign" (hasAssign "y" result)

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
        in assertBool "contains x in then branch" (hasAssign "x" result)
           P.>> assertBool "contains y in else branch" (hasAssign "y" result)
           P.>> assertBool "contains splitValue for branch" (hasSplitValue result)

    , testCase "SsaSwitch compiles to N-way branch chain, dispatches on scrutinee (Plan 146 Bug B)" $ do
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaSwitch (SsaVarRef (SsaVar "y" 0))
                          [ (SsaConst (ExInt "1"), "c1")
                          , (SsaConst (ExInt "2"), "c2")
                          ]
                          "cdef" })
                  , ("c1",   SsaBlock { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "10"))], sbTerm = SsaReturn Nothing })
                  , ("c2",   SsaBlock { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "20"))], sbTerm = SsaReturn Nothing })
                  , ("cdef", SsaBlock { sbAssigns = [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "99"))], sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
        (env1, _)   <- runInterpTrace result (Map.fromList [("y", VInt 1)])
        (env2, _)   <- runInterpTrace result (Map.fromList [("y", VInt 2)])
        (envDef, _) <- runInterpTrace result (Map.fromList [("y", VInt 99)])
        Map.lookup "x" env1   @?= Just (VInt 10)
        Map.lookup "x" env2   @?= Just (VInt 20)
        Map.lookup "x" envDef @?= Just (VInt 99)

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
        --
        -- Correctly compiles to one CatLoop (outer) whose own body contains
        -- a second, nested CatLoop (inner) — not two side-by-side CatLoop
        -- nodes at the same level. Before Plan 146 Phase 2f's exit-target
        -- fix, 'outer' and 'inner' resolved as *each other's* exit target,
        -- so the inner loop was wrongly recompiled a second time as if it
        -- were ordinary code following the outer loop — producing 2
        -- sibling CatLoops that 'countCatLoop's old (shallow, non-recursing)
        -- definition could see, which is why this test used to pass despite
        -- the underlying compile being wrong.
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
        in assertEqual "exactly 2 CatLoop nodes, one nested inside the other" 2 (countCatLoop result)

    , testCase "compileLoopBody: loop containing if/else with shared tail preserves tail assign on every path (Plan 146 item 7)" $ do
        -- entry -> header (iter += 1; loop while iter <= 2) -> body_cond (iter == 1)
        --   -> then_arm -> shared_tail (y += 1) -> header   [pass 1: iter 0->1, takes then_arm]
        --   -> else_arm -> shared_tail (y += 1) -> header   [pass 2: iter 1->2, takes else_arm]
        -- compileLoopTerm visits then_arm before else_arm (t before f), so shared_tail is compiled
        -- for real on the then_arm path and only *revisited* via else_arm. The pre-fix
        -- Set-based registry returned a bare CatInl on that revisit, silently dropping
        -- shared_tail's "y += 1" for every path after the first — exactly Bug A's shape,
        -- one level down. Loop termination here is controlled entirely by "iter" (mutated
        -- only in the header, which is never subject to this revisit path), so this fixture
        -- terminates deterministically whether or not the bug is present — unlike routing
        -- the loop bound through the shared tail itself, which would hang forever pre-fix.
        let iterV = SsaVarRef (SsaVar "iter" 0)
            yV    = SsaVarRef (SsaVar "y" 0)
            sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "header" })
                  , ("header", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "iter" 0) (SsaBinOp BopAdd iterV (SsaConst (ExInt "1")))]
                      , sbTerm = SsaBranch (SsaBinOp BopLe iterV (SsaConst (ExInt "2"))) "body_cond" "exit" })
                  , ("body_cond", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaBranch (SsaBinOp BopEq iterV (SsaConst (ExInt "1"))) "then_arm" "else_arm" })
                  , ("then_arm", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "shared_tail" })
                  , ("else_arm", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "shared_tail" })
                  , ("shared_tail", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "y" 0) (SsaBinOp BopAdd yV (SsaConst (ExInt "1")))]
                      , sbTerm = SsaGoto "header" })
                  , ("exit", SsaBlock { sbAssigns = [], sbTerm = SsaReturn Nothing })
                  ]
              , spPhis   = Map.empty
              , spEntry  = "entry"
              , spVars   = []
              }
            result = compileSsaDefault sa
            initEnv = Map.fromList [("iter", VInt 0), ("y", VInt 0)]
        (finalEnv, _) <- runInterpTrace result initEnv
        Map.lookup "iter" finalEnv @?= Just (VInt 3)
        Map.lookup "y" finalEnv @?= Just (VInt 2)

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
           P.>> assertBool "contains x assign" (hasAssign "x" result)
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
        in assertBool "x assign present, no bare CatCall"
             (hasAssign "x" result P.&& not (hasAnyCatCall result))

    , testCase "x = dw_foo.retrieve() (suspend) assigns, does not emit CatSuspend" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x" 1) (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "x assign present, no CatSuspend"
             (hasAssign "x" result P.&& not (hasAnyCatSuspend result))

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
        (result, st) <- runStateT (runInterp (runCat (CatId :: CatOp () ())) ()) (InterpState Map.empty [] Map.empty)
        result @?= ()
        isTrace st @?= []

    , testCase "runCat CatAssignWithRhs updates env and emits TeAssign" $ do
        let term = CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [] Map.empty)
        Map.lookup "x_1" (isEnv st) @?= Just (VInt 42)
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 42)]

    , testCase "runCat CatCompose threads env through both assigns in order" $ do
        let term = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 1), TeAssign "y_1" (VInt 2)]

    , testCase "runCat branch emits TeBranch True and takes the then-arm" $ do
        let term = branch (ExBool True)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeBranch True, TeAssign "then_taken" (VInt 1)]

    , testCase "runCat branch emits TeBranch False and takes the else-arm" $ do
        let term = branch (ExBool False)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeBranch False, TeAssign "else_taken" (VInt 2)]

    , testCase "runCat CatSuspend records TeSuspend with evaluated args" $ do
        let term = CatSuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeSuspend "retrieve:dw_foo" [VInt 1, VStr "bar"]]

    , testCase "runCat CatCall records TeCall with evaluated args" $ do
        let term = CatCall "my_func" [ExInt "5"] :: CatOp () ()
        (_, st) <- runStateT (runInterp (runCat term) ()) (InterpState Map.empty [] Map.empty)
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
          assertBool "should contain x assign" (hasCpsAssign "x")
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
          assertBool "should contain a"
            (any (\n -> case n of CpsAssign { anVar = "a" } -> True; _ -> False) nodes)
          assertBool "should contain b"
            (any (\n -> case n of CpsAssign { anVar = "b" } -> True; _ -> False) nodes)
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
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
        itrace @?= []
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatAssignWithRhs: same assign trace, same env" $ do
        let term = CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
        itrace @?= [TeAssign "x_1" (VInt 42)]
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatCompose: two assigns execute in the same order" $ do
        let term = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branch True: then-arm taken on both backends" $ do
        let term = branch (ExBool True)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branch False: else-arm taken on both backends" $ do
        let term = branch (ExBool False)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatSuspend: same effect name and evaluated args" $ do
        let term = CatSuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatCall: same callee and evaluated args" $ do
        let term = CatCall "my_func" [ExInt "5"] :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) Map.empty
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
        let (genv, gtrace) = runCpsGraphTrace 10000 Map.empty (buildCpsGraph term) initEnv
        itrace @?= gtrace
        ienv @?= genv
        Map.lookup "i" ienv @?= Just (VInt 3)
    ]

  , testGroup "PureCall callee name preserves source case (Plan 146 Phase 2d)"
    -- compileCallExpr's `otherwise` branch (PB.Analysis.CatOp) and
    -- compileAssign's ExMethodCall PureCall case both wrap the callee name in
    -- T.toLower before building CatCall, but PB.Analysis.CpsCompile's mirror
    -- (the confirmed-correct old compiler) uses calleeName's result verbatim
    -- via `clCallee = calleeName expr`. calleeName never itself lowercases —
    -- the divergence is CatOp.hs-only. Found via a read-only GHCi hand-trace
    -- of a real --dual-trace corpus diff (m_main_print_args_withform::clicked,
    -- "parentwindow.TriggerEvent(...)" trace as "parentwindow.triggerevent"
    -- in the new compiler) and confirmed to explain 1075/1198 (90%) of the
    -- Phase 2c-era --dual-trace baseline via a throwaway case-insensitive
    -- TeCall normalization over both corpora.
    [ testCase "bare ExCall with mixed-case callee: TeCall preserves case" $
        let body = [Located 1 (BsCall (ExCall (Lvalue [LvSegment "GlobalMemoryStatus" Nothing]) []))]
            oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
            newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= oldTrace

    , testCase "ExMethodCall with mixed-case receiver/method: TeCall preserves case" $
        let recv = ExLvalue (Lvalue [LvSegment "parentwindow" Nothing])
            body = [Located 1 (BsCall (ExMethodCall recv "TriggerEvent" [[]]))]
            oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
            newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= oldTrace

    , testCase "ExMethodCall whose receiver is itself a call (chained method call) matches old compiler" $
        -- Real corpus idiom (m_graph::clicked and 4 other on-clicked handlers
        -- in the same file): `ParentWindow.GetActiveSheet().TriggerEvent(...)`.
        -- compileAssign's ExMethodCall branch special-cased an `ExCall`
        -- receiver as `lvHead rlv <> "." <> meth` (grabbing just the callee's
        -- own head segment, "ParentWindow"), diverging from `calleeName`'s
        -- reference behaviour of falling back to `"?." <> meth` for any
        -- receiver that isn't a plain `ExLvalue` — confirmed via direct
        -- `cabal repl` hand-trace of `m_graph::clicked`'s compiled traces
        -- (`TeCall "?.TriggerEvent" ...` old vs `TeCall
        -- "ParentWindow.TriggerEvent" ...` new).
        let recv = ExCall (Lvalue [LvSegment "ParentWindow" Nothing, LvSegment "GetActiveSheet" Nothing]) []
            body = [Located 1 (BsCall (ExMethodCall recv "TriggerEvent" [[]]))]
            oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
            newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= oldTrace
    ]

  , testGroup "fn_retrievechild suspend args match old compiler (Plan 146 Phase 2i)"
    -- Real corpus idiom (openpay's wiz_misth_final_details_step1::of_stepadded
    -- and 3 sibling wizard-step handlers): `fn_retrievechild(adw, "col", var)`.
    -- 'PB.Analysis.CpsCompile' special-cases this exact callee (before its
    -- generic call-compilation path) to trace only the third argument (the
    -- bound variable) as the suspend's args, since the datawindow control and
    -- column name are already encoded directly in the effect name string
    -- itself (`"retrieve:child_<col>:<dwCtrl>"`, via 'effectName'). CatOp.hs
    -- has no equivalent special case, so 'compileCallExpr's generic
    -- `SuspendCall -> CatSuspend (effectName expr parsedArgs) parsedArgs`
    -- branch passed all 3 parsed args through instead of just the third —
    -- confirmed via direct hand-trace of the real corpus diff (old:
    -- `TeSuspend "retrieve:child_kodkat:dw_misth_final" [VNull]`, new: same
    -- effect name but `[VNull, VStr "kodkat", VNull]`).
    [ testCase "fn_retrievechild(adw, \"col\", var): suspend args are just [var], matching old compiler" $
        let body = [Located 1 (BsCall (ExCall
              { callee   = Lvalue [LvSegment "fn_retrievechild" Nothing]
              , callArgs = [[tok "dw_misth_final"], [tok "\"kodkat\""], [tok "gs_kodxrisi"]]
              }))]
            oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
            newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= oldTrace
    ]

  , testGroup "local DataStore/Transaction variable suspend-classification (Plan 146 Phase 2e)"
    -- ScopedTypeEnv.steLocal's own doc comment says "body locals added in
    -- P2b" but compileProcedureViaCatOp/compileSsa never actually do this —
    -- env flows in unchanged from the caller, so a *locally-declared*
    -- datastore/transaction variable's type can never be resolved by
    -- classifyExpr's lookupScopedVar, and a suspend method call on it falls
    -- through to the conservative PureCall default. PB.Analysis.CpsCompile's
    -- compileProcedure (the confirmed-correct old compiler) seeds steLocal
    -- from the body's own BsLocalVar decls via collectBodyLocals before
    -- compiling. Found via a read-only GHCi hand-trace of a real
    -- --dual-trace corpus diff (fn_transfer_param::fn_transfer_param, two
    -- local `datastore` vars calling `.retrieve()`) and confirmed (via a
    -- temporary, reverted local patch) to explain 9/123 of the Phase 2d-era
    -- --dual-trace baseline.
    [ testCase "local datastore var .retrieve() classifies as SuspendCall" $
        let body = [ Located 1 (BsLocalVar [] (PtPrimitive "datastore") "lds_x" Nothing)
                   , Located 2 (BsCall (ExMethodCall (ExLvalue (Lvalue [LvSegment "lds_x" Nothing])) "retrieve" [[]]))
                   ]
            oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
            newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= oldTrace

    , testCase "local transaction var .commit() classifies as SuspendCall" $
        let body = [ Located 1 (BsLocalVar [] (PtPrimitive "transaction") "ltrans_x" Nothing)
                   , Located 2 (BsCall (ExMethodCall (ExLvalue (Lvalue [LvSegment "ltrans_x" Nothing])) "commit" [[]]))
                   ]
            oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
            newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= oldTrace
    ]

  , testGroup "nested loop exit-target resolution (Plan 146 Phase 2f)"
    -- 'computeLoopBodyBlocks' (via 'discoverReachable'/'canReach') has no
    -- boundary for the case where one loop is nested inside another:
    -- 'discoverReachable's forward walk stops at a foreign loop header
    -- without recording it as part of the enclosing loop's body, while
    -- 'canReach's backward walk has no boundary at all, so a nested loop's
    -- own exit block can be judged to "reach back" to that loop's header via
    -- a path that actually escapes through the *enclosing* loop's back-edge.
    -- Net effect, confirmed via direct GHCi hand-trace of
    -- w_dynsql_format4::ue_execute (a real corpus --dual-trace diff): the
    -- outer and inner loop headers get resolved as *each other's* exit
    -- target. Fixture below mirrors that shape: an outer counted loop whose
    -- body always enters an inner counted loop (with a structural bypass
    -- edge, matching the real "if without else" shape) before looping back.
    [ let oiV = SsaVarRef (SsaVar "oi" 0)
          iiV = SsaVarRef (SsaVar "ii" 0)
          yV  = SsaVarRef (SsaVar "y" 0)
          nestedLoopsSsa = SsaProc
            { spName   = "test"
            , spEntry  = "entry"
            , spVars   = []
            , spPhis   = Map.empty
            , spBlocks = Map.fromList
                [ ("entry", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "oi" 0) (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "y" 0) (SsaConst (ExInt "0")) ]
                    , sbTerm = SsaGoto "outer_header" })
                , ("outer_header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt oiV (SsaConst (ExInt "2"))) "outer_if" "outer_exit" })
                , ("outer_if", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaConst (ExBool True)) "outer_enter_inner" "outer_merge" })
                , ("outer_enter_inner", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "ii" 0) (SsaConst (ExInt "0"))]
                    , sbTerm = SsaGoto "inner_header" })
                , ("inner_header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt iiV (SsaConst (ExInt "3"))) "inner_body" "inner_exit" })
                , ("inner_body", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "ii" 0) (SsaBinOp BopAdd iiV (SsaConst (ExInt "1")))
                                  , SsaAssign (SsaVar "y" 0) (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) ]
                    , sbTerm = SsaGoto "inner_header" })
                , ("inner_exit", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "outer_merge" })
                , ("outer_merge", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "oi" 0) (SsaBinOp BopAdd oiV (SsaConst (ExInt "1")))]
                    , sbTerm = SsaGoto "outer_header" })
                , ("outer_exit", SsaBlock { sbAssigns = [], sbTerm = SsaReturn Nothing })
                ]
            }
          initEnv = Map.fromList [("oi", VInt 0), ("y", VInt 0), ("ii", VInt 0)]
          -- Bounded via 'runCpsGraphTrace' (never raw, unbounded 'runInterpTrace')
          -- because the pre-fix bug reproduces a genuine runtime infinite loop for
          -- this shape (confirmed empirically before writing this assertion), not
          -- just a wrong-but-terminating result.
          maxSteps = 500 :: Int
          (finalEnv, trc) = runCpsGraphTrace maxSteps Map.empty
                              (buildCpsGraph (compileSsaDefault nestedLoopsSsa)) initEnv
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
    -- from the loop's body set. That exclusion has two knock-on effects: (1)
    -- 'determineLoopExitTarget' sees the continue-block as a spurious
    -- "successor not in the body" alongside the loop's real exit, and
    -- 'Set.toList exits'' head picks whichever sorts alphabetically first —
    -- for the real corpus case (`eon_appeon_resize::of_init`, the `window`
    -- overload, not the `userobject` one the original BACKLOG entry named)
    -- this wired the loop's post-loop continuation to the continue-block's
    -- own trailing assigns instead of the real code after the loop; (2)
    -- 'isLoopExit' (reusing the same broken body set) can independently
    -- misclassify a genuine continue-target as "outside the loop", silently
    -- turning that 'continue' into a 'break' — dropping every later
    -- iteration entirely. Confirmed via direct hand-trace in 'cabal repl'
    -- (both real-corpus and this fixture) before writing this assertion.
    -- Fixture: a 3-iteration counted loop whose body takes a `continue` on
    -- exactly one iteration (via an `if`-guarded branch, matching the real
    -- "if of_registered(...) then continue" shape) before reaching a real
    -- post-loop block with its own distinguishing assign. Block names are
    -- chosen so "c_continue" sorts before "z_exit" — reproducing the exact
    -- alphabetical-tiebreak failure mode, not a coincidence-proof shape.
    [ let xV  = SsaVarRef (SsaVar "x" 0)
          yV  = SsaVarRef (SsaVar "y" 0)
          scV = SsaVarRef (SsaVar "skip_count" 0)
          continueSsa = SsaProc
            { spName   = "test"
            , spEntry  = "entry"
            , spVars   = []
            , spPhis   = Map.empty
            , spBlocks = Map.fromList
                [ ("entry", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "x" 0) (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "y" 0) (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "skip_count" 0) (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "done" 0) (SsaConst (ExInt "0")) ]
                    , sbTerm = SsaGoto "header" })
                , ("header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt xV (SsaConst (ExInt "3"))) "body_entry" "z_exit" })
                , ("body_entry", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopEq xV (SsaConst (ExInt "1"))) "c_continue" "normal_body" })
                , ("c_continue", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "x" 0) (SsaBinOp BopAdd xV (SsaConst (ExInt "1")))
                                  , SsaAssign (SsaVar "skip_count" 0) (SsaBinOp BopAdd scV (SsaConst (ExInt "1"))) ]
                    , sbTerm = SsaContinue })
                , ("normal_body", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "y" 0) (SsaBinOp BopAdd yV (SsaConst (ExInt "1")))
                                  , SsaAssign (SsaVar "x" 0) (SsaBinOp BopAdd xV (SsaConst (ExInt "1"))) ]
                    , sbTerm = SsaGoto "header" })
                , ("z_exit", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "done" 0) (SsaConst (ExInt "1"))]
                    , sbTerm = SsaReturn Nothing })
                ]
            }
          initEnv = Map.fromList [("x", VInt 0), ("y", VInt 0), ("skip_count", VInt 0), ("done", VInt 0)]
          (finalEnv, _trc) = runCpsGraphTrace 100 Map.empty
                                (buildCpsGraph (compileSsaDefault continueSsa)) initEnv
      in testCase "continue mid-loop still reaches the real post-loop block, not the continue block's own content" $ do
           Map.lookup "x" finalEnv @?= Just (VInt 3)
           Map.lookup "y" finalEnv @?= Just (VInt 2)
           Map.lookup "skip_count" finalEnv @?= Just (VInt 1)
           Map.lookup "done" finalEnv @?= Just (VInt 1)
    ]

  , testGroup "if/elseif chain: each elseif tests its own condition (Plan 146 next bug)"
    -- CfgBuild.lowerIf never referenced 'eifCond' at all — every elseif body
    -- was unconditionally reachable once the prior test failed. Hand-traced
    -- via a real corpus --dual-trace diff (w_dwtostr::of_create_structure_export,
    -- old=18/new=16 steps): a block whose own body assign doubled as the
    -- chain link to the next elseif ended up with two outgoing edges, which
    -- makes cfgTermToSsa's single-edge fallback default to
    -- 'SsaReturn Nothing' — silently truncating the procedure at the first
    -- elseif clause that matches. This fixture reproduces the same shape
    -- end-to-end (AST -> CFG -> SSA -> CatOp), comparing the new pipeline's
    -- trace against the old, reference-correct compiler's.
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
          oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
          newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
      in testCase "no elseif clause matches (x unset) -> falls through to the trailing assign, matching the old compiler" $
           newTrace @?= oldTrace
    ]

  , testGroup "loop-exit-target skips return blocks (Plan 146 Phase 2i)"
    -- Two independent bugs, both needed fixing (see 'PB.Analysis.CatOp':
    -- 'isLoopExit', 'determineLoopExitTarget', 'canReach', 'compileLoopTerm'
    -- for the full history — an earlier version of this fix put the special
    -- case in 'canReach' itself, which regressed a real corpus procedure;
    -- see 'canReach's own comment):
    --
    -- (1) 'compileLoopTerm's own 'SsaReturn' case compiled to 'CatInr' --
    -- identical to 'SsaBreak' -- so hitting a return mid-loop would fall
    -- through to the loop's post-loop continuation instead of truly ending
    -- the procedure. Fixed via a new 'CatReturn' terminal (Phase 2i) plus
    -- 'isLoopExit' now refusing to treat a block whose own terminator is
    -- 'SsaReturn' as a loop exit, so it always reaches 'compileLoopTerm'
    -- rather than short-circuiting to 'CatInr' first.
    --
    -- (2) 'determineLoopExitTarget' can see a body-internal early-return
    -- block as a second, spurious "successor not in body" candidate
    -- alongside the loop's real post-loop successor, and used to pick
    -- between them via the same alphabetical tiebreak Phase 2f/2g had to
    -- work around elsewhere. Fixed by preferring a non-return-terminated
    -- candidate whenever one exists.
    --
    -- Fixture: a 3-iteration counted loop whose body branches to a `return`
    -- on a separate `trigger` flag (independent of the loop counter), run
    -- twice with different initial envs to isolate the two defects:
    -- (1) does the loop's real post-loop trailing code still run when the
    -- loop completes normally without ever hitting return; (2) does hitting
    -- return mid-loop actually terminate the procedure instead of falling
    -- through to that trailing code.
    (let xV  = SsaVarRef (SsaVar "x" 0)
         yV  = SsaVarRef (SsaVar "y" 0)
         trV = SsaVarRef (SsaVar "trigger" 0)
         returnSsa = SsaProc
           { spName   = "test"
           , spEntry  = "entry"
           , spVars   = []
           , spPhis   = Map.empty
           , spBlocks = Map.fromList
               [ ("entry", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "header" })
               , ("header", SsaBlock
                   { sbAssigns = []
                   , sbTerm = SsaBranch (SsaBinOp BopLt xV (SsaConst (ExInt "3"))) "body_entry" "z_exit" })
               , ("body_entry", SsaBlock
                   { sbAssigns = []
                   , sbTerm = SsaBranch (SsaBinOp BopEq trV (SsaConst (ExInt "1"))) "return_block" "normal_body" })
               , ("return_block", SsaBlock
                   { sbAssigns = [SsaAssign (SsaVar "y" 0) (SsaConst (ExInt "999"))]
                   , sbTerm = SsaReturn Nothing })
               , ("normal_body", SsaBlock
                   { sbAssigns = [ SsaAssign (SsaVar "x" 0) (SsaBinOp BopAdd xV (SsaConst (ExInt "1")))
                                 , SsaAssign (SsaVar "y" 0) (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) ]
                   , sbTerm = SsaGoto "header" })
               , ("z_exit", SsaBlock
                   { sbAssigns = [SsaAssign (SsaVar "done" 0) (SsaConst (ExInt "1"))]
                   , sbTerm = SsaReturn Nothing })
               ]
           }
         compiled = compileSsaDefault returnSsa
         runIt trigger = runCpsGraphTrace 100 Map.empty
                           (buildCpsGraph compiled)
                           (Map.fromList [("x", VInt 0), ("y", VInt 0), ("done", VInt 0), ("trigger", VInt trigger)])
     in
     [ testCase "compiles to a CatReturn (not CatInr) for the return block" $
         assertBool "expected a CatReturn node in the compiled tree" (hasCatReturn compiled)

     , testCase "loop completes normally (trigger never fires) and reaches real post-loop trailing code" $
         let (finalEnv, _) = runIt 0
         in do
           Map.lookup "x" finalEnv @?= Just (VInt 3)
           Map.lookup "y" finalEnv @?= Just (VInt 3)
           Map.lookup "done" finalEnv @?= Just (VInt 1)

     , testCase "return mid-loop terminates immediately, skipping the rest of the loop and all post-loop code" $
         let (finalEnv, _) = runIt 1
         in do
           Map.lookup "x" finalEnv @?= Just (VInt 0)
           Map.lookup "y" finalEnv @?= Just (VInt 999)
           Map.lookup "done" finalEnv @?= Just (VInt 0)
     ])

  , testGroup "if/elseif-with-return inside a do-while loop matches old compiler (Plan 146 Phase 2i)"
    -- Direct regression test for the w_customer_report::open-class corpus
    -- idiom found while diagnosing Phase 2h's 3 newly-surfaced diffs: a SQL
    -- cursor-fetch loop whose elseif branch returns on error, followed by
    -- real trailing code after the loop. Confirms compileProcedureViaCatOp
    -- now matches the old, reference-correct compiler's trace end-to-end
    -- (AST -> CFG -> SSA -> CatOp), not just the isolated SSA-level fixture
    -- above.
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
          oldTrace = runCpsGraphTrace 100 Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
          newTrace = runCpsGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
      in testCase "do-while with if/elseif-return, followed by trailing code, matches old compiler" $
           newTrace @?= oldTrace
    ]

  , testGroup "if/else where one branch reaches the implicit end before a later loop is compiled (Plan 146 Phase 2i correction)"
    -- Regression test for a real corpus bug an earlier version of the Phase
    -- 2i fix introduced: @w_regedit::itempopulate@, a plain @if/else@ with a
    -- @for...next@ loop in the else branch and nothing after the whole
    -- if/else. 'compileTerm's 'SsaBranch' case compiles the if-branch
    -- first, so the shared implicit-end block (reached both from the
    -- if-branch directly and from the for-loop's own exit edge) gets
    -- compiled and memoized as plain 'CatId' *before* the for-loop is ever
    -- touched. The since-reverted 'canReach' special case made the loop's
    -- exit-chain block eligible for 'computeLoopBodyBlocks', which made
    -- 'compileLoopBody' try to recompile the already-memoized end block —
    -- landing on a stale 'CatInl' seed placeholder instead of its real
    -- content, and turning the loop's real exit into a self-referencing
    -- infinite loop (confirmed via direct 'CpsGraph' inspection of the real
    -- procedure: a 'CpsBranch' whose own false edge pointed back at itself).
    -- Bounded via a small 'maxSteps' so a regression here fails loudly
    -- (hits the bound) rather than hanging the test suite.
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
         oldTrace = runCpsGraphTrace maxSteps Map.empty (compileProcedure emptyEnv Set.empty body) Map.empty
         newTrace = runCpsGraphTrace maxSteps Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
         (_, elseTrc) = newTrace
     in
     [ testCase "else-branch for-loop terminates well under the step bound, not a runaway trace" $
         assertBool ("expected well under " <> show maxSteps <> " steps, got " <> show (length elseTrc))
                    (length elseTrc P.< maxSteps)

     , testCase "else-branch (for-loop) matches old compiler" $
         newTrace @?= oldTrace
     ])
  ]
