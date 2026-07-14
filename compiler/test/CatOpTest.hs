module CatOpTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..),
                            DispatchExpr (..), DispatchMode (..))
import PB.AST.Type         (PbType (..))
import PB.AST.BodyStmt     (BodyStmt (..), PbCall (..), IfStmt (..), ElseIf (..), ForStmt (..), DoStmt (..), DoCondition (..),
                            TryStmt (..), CatchClause (..), ChooseStmt (..), CaseClause (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.CatOp
import PB.Analysis.CatLower (compileSsa)
import PB.Analysis.GraphBuilder
import PB.Analysis.CatInterp
import PB.Analysis.CatEval (Value (..), TraceEvent (..))
import PB.Analysis.SchFootprint (foldSchFootprint, FunctorCtx (..), SchFootprint (..))
import PB.Analysis.SchemaCategory (StmtId (..), SchMorphism (..), SchObject (..), LegKind (..), LegSource (..))
import PB.Pipeline.SqlParse (TableRef (..))
import PB.Analysis.InstrGraph (ShapeNode (..), canonicalize, normalizeCallTag)
import PB.Analysis.CallClassify (parseArgList, collectBodyLocals)
import PB.Analysis.InstrInterp (runInstrGraphTrace, TraceOutcome (..))
import PB.Analysis.SSA     (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                            SsaTerm (..), SsaProc (..), buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Lexing.Lexer     (tokenizeLine, LexLine (..))
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))
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

-- | Default compileSsa with empty type env and no user functions.
compileSsaDefault :: SsaProc -> CatOp () ()
compileSsaDefault = compileSsa emptyEnv Set.empty

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty "" Map.empty

-- | Tokenize a single source snippet into one 'Token' via the real lexer
-- (mirrors 'InstrGraphTest.hs's identical helper) — used to build genuine
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
  { steGlobal       = Map.fromList [("dw_foo", PtPrimitive "datawindow"), ("sqlca", PtPrimitive "transaction")]
  , steInstance     = Map.empty
  , steLocal        = Map.empty
  , steHierarchy    = Map.empty
  , steObject       = ""
  , steControlIndex = Map.empty
  }

-- | Run a compiled 'CatOp' term through 'runCat'\/'Interp', returning the
-- final environment and the trace in chronological order — the Interp-side
-- counterpart to 'runInstrGraphTrace' (Plan 146 Phase 1D). Catches
-- 'ReturnUnwind' (Plan 146 Phase 2i): a 'CatReturn' inside the term throws
-- rather than returning normally, since 'Interp's plain function composition
-- has no other way to skip past an enclosing loop's continuation — the
-- carried 'InterpState' is exactly the state at the point of the throw.
runInterpTrace :: CatOp () () -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runInterpTrace term initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (runCat term) ()) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
  return (isEnv st, P.reverse (isTrace st))

-- | Run a bare, sharing-free 'Eff' term through 'foldFreydOp' to 'Interp',
-- returning the final environment and the trace in chronological order.
runEffTrace :: Eff a a -> a -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runEffTrace eff input initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (foldFreydOp eff) input) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
  return (isEnv st, P.reverse (isTrace st))

-- | Generic version of 'runInterpTrace' for non-@()@ types.
runInterpTraceGen :: a -> CatOp a b -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runInterpTraceGen input term initEnv = do
  st <- (P.snd P.<$> runStateT (runInterp (runCat term) input) (InterpState initEnv [] Map.empty))
          `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
  return (isEnv st, P.reverse (isTrace st))

-- | Generic version of 'runEffTrace' for non-@()@ types.
runEffTraceGen :: a -> Eff a b -> Map.Map Text Value -> IO (Map.Map Text Value, [TraceEvent])
runEffTraceGen input eff initEnv = do
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

-- | Every distinct 'LTagged' blockId appearing anywhere in a 'LowCat' term
-- (Plan 149 Phase 1's 'collectWiring' tests) — deduplicated, since a shared
-- blockId's own nested tags are only reachable through one occurrence.
collectTagIds :: LowCat -> [Text]
collectTagIds = Set.toList P.. go Set.empty
  where
    go seen node = case node of
      LTagged bid inner
        | Set.member bid seen -> seen
        | otherwise           -> go (Set.insert bid seen) inner
      LCompose a b -> go (go seen a) b
      LFanIn a b   -> go (go seen a) b
      LFork a b    -> go (go seen a) b
      LLoop a      -> go seen a
      _            -> seen

-- | How many times a given blockId's 'LTagged' tag is referenced anywhere in
-- a raw (not yet 'collectWiring'-processed) 'LowCat' term — used to confirm
-- a test fixture exhibits real sharing (referenced 2+ times), not just an
-- incidental single tag.
countTagOccurrences :: Text -> LowCat -> Int
countTagOccurrences target = go
  where
    go node = case node of
      LTagged bid inner -> (if bid P.== target then 1 else 0) P.+ go inner
      LCompose a b -> go a P.+ go b
      LFanIn a b   -> go a P.+ go b
      LFork a b    -> go a P.+ go b
      LLoop a      -> go a
      _            -> 0

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
    [ testCase "SsaProc placeholder" $
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
              [SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in assertBool "contains x assign" (hasAssign "x" result)

    , testCase "single assign structure: CatAssignWithRhs with embedded RHS" $
        let sa = mkSsa
              [SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in case result of
             CatAssignWithRhs v (ExInt "1") ->
               assertEqual "assigns to x (SSA version erased, not x_1)" "x" v
             other -> assertBool ("unexpected structure: " <> show other) False

    , testCase "two linear assigns fold via CatCompose" $
        let sa = mkSsa
              [ SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y") (SsaConst (ExInt "2"))
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
              [ SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y") (SsaVarRef (SsaVar "x"))
              ]
              (SsaReturn Nothing)
            result = compileSsaDefault sa
        in assertBool "contains y assign with ExLvalue RHS" (hasAssignWithRhs "y" result)

    , testCase "SsaGoto compiles to CatCompose of block assigns" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))]
                      , sbTerm = SsaGoto "target" })
                  , ("target", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "y") (SsaConst (ExInt "2"))]
                      , sbTerm = SsaReturn Nothing })
                  ]
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
                      { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))]
                      , sbTerm = SsaReturn Nothing })
                  , ("else", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "y") (SsaConst (ExInt "2"))]
                      , sbTerm = SsaReturn Nothing })
                  ]
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
                      , sbTerm = SsaSwitch (SsaVarRef (SsaVar "y"))
                          [ (SsaConst (ExInt "1"), "c1")
                          , (SsaConst (ExInt "2"), "c2")
                          ]
                          "cdef" })
                  , ("c1",   SsaBlock { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "10"))], sbTerm = SsaReturn Nothing })
                  , ("c2",   SsaBlock { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "20"))], sbTerm = SsaReturn Nothing })
                  , ("cdef", SsaBlock { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "99"))], sbTerm = SsaReturn Nothing })
                  ]
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
                      { sbAssigns = [SsaAssign (SsaVar "i") (SsaConst (ExInt "1"))]
                      , sbTerm = SsaGoto "header" })
                  , ("header", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "i") (SsaVarRef (SsaVar "i"))]
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "body" "exit" })
                  , ("body", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "i") (SsaBinOp BopAdd (SsaVarRef (SsaVar "i")) (SsaConst (ExInt "1")))]
                      , sbTerm = SsaGoto "header" })
                  , ("exit", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaReturn Nothing })
                  ]
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
                      { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "1"))]
                      , sbTerm = SsaGoto "outer" })
                  , ("outer", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaBranch (SsaConst (ExBool True)) "inner" "outer_exit" })
                  , ("inner", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "x") (SsaBinOp BopAdd (SsaVarRef (SsaVar "x")) (SsaConst (ExInt "1")))]
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
        let iterV = SsaVarRef (SsaVar "iter")
            yV    = SsaVarRef (SsaVar "y")
            sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "header" })
                  , ("header", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "iter") (SsaBinOp BopAdd iterV (SsaConst (ExInt "1")))]
                      , sbTerm = SsaBranch (SsaBinOp BopLe iterV (SsaConst (ExInt "2"))) "body_cond" "exit" })
                  , ("body_cond", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaBranch (SsaBinOp BopEq iterV (SsaConst (ExInt "1"))) "then_arm" "else_arm" })
                  , ("then_arm", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "shared_tail" })
                  , ("else_arm", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "shared_tail" })
                  , ("shared_tail", SsaBlock
                      { sbAssigns = [SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1")))]
                      , sbTerm = SsaGoto "header" })
                  , ("exit", SsaBlock { sbAssigns = [], sbTerm = SsaReturn Nothing })
                  ]
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
                      { sbAssigns = [SsaAssign (SsaVar "x") (SsaConst (ExInt "42"))]
                      , sbTerm = SsaGoto "header" })
                  , ("exit", SsaBlock
                      { sbAssigns = []
                      , sbTerm = SsaReturn Nothing })
                  ]
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
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "should contain CatSuspend with effect retrieve:dw_foo"
             (hasCatSuspendEffect "retrieve:dw_foo" result)

    , testCase "ExMethodCall on Transaction emits CatSuspend not CatCall" $
        -- sqlca.commit() — ExMethodCall on a transaction-typed receiver
        let callExpr = ExMethodCall
              { receiver   = ExLvalue (Lvalue [LvSegment "sqlca" Nothing])
              , method     = "commit"
              , methodArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "should contain CatSuspend with effect executeSql"
             (hasCatSuspendEffect "executeSql" result)

    , testCase "ExCall pure user function does not emit CatSuspend" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "my_func" Nothing], callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa emptyEnv Set.empty sa
        in assertBool "pure call should produce no CatSuspend" (not (hasAnyCatSuspend result))

    , testCase "end-to-end: BsCall dw_foo.retrieve() → InstrSuspend node in InstrGraph" $
        -- buildSsa from a standalone BsCall; InstrSuspend must appear in the graph
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            body     = [Located 1 (BsCall callExpr)]
            ssaProc  = buildSsa dwEnv "proc" body
            catTree  = compileSsa dwEnv Set.empty ssaProc
            graph    = buildInstrGraphNamed catTree
            hasInstrSuspend = any (\n -> case n of { InstrSuspend {} -> True; _ -> False }) (igNodes graph)
        in assertBool "InstrGraph should contain a InstrSuspend node" hasInstrSuspend
    ]

  , testGroup "assign-with-call-RHS (Plan 145 Phase 1B re-sample Finding B)"
    -- x = f() / x = obj.method() used to silently drop the assignment target and
    -- compile to a bare CatCall/CatSuspend — the call ran but its result was
    -- never stored. PB.Analysis.InstrGraph (the old, confirmed-correct compiler)
    -- never special-cases a call RHS on BsAssign; it always emits one InstrAssign.
    [ testCase "x = my_func() (pure) assigns, does not emit a bare CatCall" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "my_func" Nothing], callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x") (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa emptyEnv Set.empty sa
        in assertBool "x assign present, no bare CatCall"
             (hasAssign "x" result P.&& not (hasAnyCatCall result))

    , testCase "x = dw_foo.retrieve() (suspend) assigns, does not emit CatSuspend" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "x") (SsaConst callExpr)] (SsaReturn Nothing)
            result = compileSsa dwEnv Set.empty sa
        in assertBool "x assign present, no CatSuspend"
             (hasAssign "x" result P.&& not (hasAnyCatSuspend result))

    , testCase "standalone (discard) suspend call is unaffected" $
        -- Sanity: the "_" discard target must still classify and emit CatSuspend.
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            sa = mkSsa [SsaAssign (SsaVar "_") (SsaConst callExpr)] (SsaReturn Nothing)
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

  , testGroup "foldCat generalizes runCat (Plan 148 Phase 3)"
    -- runCat is now `foldCat` specialized to Interp — these pin that
    -- `foldCat` (called directly, not via the `runCat` alias) reproduces the
    -- "Interp / runCat" group's behavior exactly, and cover `ret`/`loopK`,
    -- the two new Effectful methods CatReturn/CatLoop needed to make the
    -- fold fully generic (previously bespoke cases inside runCat's own
    -- per-constructor match).
    [ testCase "foldCat CatAssignWithRhs updates env and emits TeAssign" $ do
        let term = CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ()
        (_, st) <- runStateT (runInterp (foldCatOp term) ()) (InterpState Map.empty [] Map.empty)
        Map.lookup "x_1" (isEnv st) @?= Just (VInt 42)
        P.reverse (isTrace st) @?= [TeAssign "x_1" (VInt 42)]

    , testCase "foldCat branch emits TeBranch and takes the matching arm" $ do
        let term = branch (ExBool True)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (_, st) <- runStateT (runInterp (foldCatOp term) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st) @?= [TeBranch True, TeAssign "then_taken" (VInt 1)]

    , testCase "ret aborts via ReturnUnwind, matching CatReturn's prior direct-coded behavior" $ do
        let term = CatReturn :: CatOp () ()
        st <- (P.snd P.<$> runStateT (runInterp (foldCatOp term) ())
                 (InterpState (Map.fromList [("x", VInt 1)]) [] Map.empty))
                `CE.catch` (\(ReturnUnwind capturedSt) -> return capturedSt)
        isEnv st @?= Map.fromList [("x", VInt 1)]

    , testCase "loopK matches interpretLoop's prior direct-coded behavior for a terminating loop" $ do
        let iVar = ExLvalue (Lvalue [LvSegment "i" Nothing])
            cond = ExBinOp iVar BopLt (ExInt "3")
            incr = ExBinOp iVar BopAdd (ExInt "1")
            loopBody = branch cond
                         (CatInl . CatAssignWithRhs "i" incr)
                         CatInr :: CatOp () (Either () ())
            term = CatLoop loopBody :: CatOp () ()
        (_, st) <- runStateT (runInterp (foldCatOp term) ()) (InterpState (Map.fromList [("i", VInt 0)]) [] Map.empty)
        Map.lookup "i" (isEnv st) @?= Just (VInt 3)
    ]

  , testGroup "Phase 4: buildInstrGraphNamed"
    [ testCase "CatId compiles to just exit node" $
        let graph = buildInstrGraphNamed (CatId :: CatOp () ())
        in do
          igEntry graph @?= 0
          case igNodes graph of
            [InstrReturn Nothing] -> return ()
            other -> assertBool ("expected 1 exit node, got " <> show (P.length other)) False

    , testCase "CatAssignWithRhs compiles to InstrAssign + exit" $
        let graph = buildInstrGraphNamed (CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ())
        in do
          igEntry graph @?= 0
          case igNodes graph of
            [InstrAssign { anVar = "x_1", anRhs = ExInt "42", anNext = 1 }, InstrReturn Nothing] ->
              return ()
            other -> assertBool ("expected assign + exit, got " <> show (P.length other)) False

    , testCase "two assigns chain entry→x_1→y_1→exit" $
        let op = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            graph = buildInstrGraphNamed op
        in do
          igEntry graph @?= 0
          P.length (igNodes graph) @?= 3
          case igNodes graph of
            (InstrAssign { anVar = "x_1" } : InstrAssign { anVar = "y_1" } : InstrReturn Nothing : []) -> return ()
            _ -> assertBool "expected [x_1, y_1, exit]" False

    , testCase "branch compiles to InstrBranch diamond with no unconditional join nop (Plan 145 Finding A)" $
        let thenK = CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            elseK = CatAssignWithRhs "y_1" (ExInt "2")
            op = branch (ExBool True) thenK elseK :: CatOp () ()
            graph = buildInstrGraphNamed op
        in do
          P.length (igNodes graph) @?= 4
          case igNodes graph of
            ( InstrBranch { brThenPc = 1, brElsePc = 2 }
              : InstrAssign { anVar = "x_1", anNext = 3 }
              : InstrAssign { anVar = "y_1", anNext = 3 }
              : InstrReturn Nothing
              : [] ) -> return ()
            nodes -> assertBool ("expected 4 nodes [branch, then, else, exit], got " <> show (P.length nodes) <> ": " <> show nodes) False

    , testCase "branch condition preserved through LowCat (not ExNull)" $
        let thenK = CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            elseK = CatAssignWithRhs "y_1" (ExInt "2")
            op = branch (ExBool True) thenK elseK :: CatOp () ()
            graph = buildInstrGraphNamed op
            branches = filter (\n -> case n of InstrBranch {} -> True; _ -> False) (igNodes graph)
        in case branches of
             [InstrBranch { brCond = ExBool True }] -> return ()
             other -> assertBool ("expected branch with ExBool True, got " <> show other) False

    , testCase "structural erasure preserves assignments" $
        let op = (CatExl :: CatOp (Int, Int) Int) `seq`
                 CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            graph = buildInstrGraphNamed op
        in do
          P.length (igNodes graph) @?= 2
          case igNodes graph of
            (InstrAssign { anVar = "x_1" } : InstrReturn Nothing : []) -> return ()
            _ -> assertBool "expected [assign, exit]" False

    , testCase "end-to-end: SSA loop → InstrGraph preserves assignments and back-edge" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock [] (SsaGoto "header"))
                  , ("header", SsaBlock [] (SsaBranch (SsaConst (ExBool True)) "body" "exit"))
                  , ("body", SsaBlock [SsaAssign (SsaVar "x") (SsaConst (ExInt "42"))] (SsaGoto "header"))
                  , ("exit", SsaBlock [] (SsaReturn Nothing))
                  ]
              , spEntry  = "entry"
              , spVars   = []
              }
            catTree  = compileSsaDefault sa
            graph    = buildInstrGraphNamed catTree
            nodes    = igNodes graph
            hasInstrAssign v = any (\n -> case n of InstrAssign { anVar = v' } -> v' == v; _ -> False) nodes
            hasGoto        = any (\n -> case n of InstrGoto _ -> True; _ -> False) nodes
            hasBranch      = any (\n -> case n of InstrBranch {} -> True; _ -> False) nodes
        in do
          assertBool "should contain x assign" (hasInstrAssign "x")
          -- No InstrGoto: the back-edge is the body assign's own anNext pointing
          -- straight at the header pc, matching the old compiler (Plan 145
          -- LInl/LInr fix — see "no wrapper InstrGoto" group below).
          assertBool "should contain no wrapper InstrGoto for the back-edge" (not hasGoto)
          assertBool "should contain InstrBranch" hasBranch

    , testCase "unit: CatLoop lowers to correct header patch, no wrapper InstrGoto" $
        -- Headerless loop body (no CatFanIn branch to patch in place — falls
        -- back to the forwarding InstrNop path). Even here, LInl resolves
        -- directly to the header pc (Plan 145 LInl/LInr fix): the assign's
        -- own anNext closes the cycle, no InstrGoto is ever allocated.
        let loopBody = CatCompose CatInl (CatAssignWithRhs "counter" (ExInt "42")) :: CatOp () (Either () ())
            catTree  = CatLoop loopBody :: CatOp () ()
            graph    = buildInstrGraphNamed catTree
        in canonicalize graph @?= [SNop 1, SAsgn 0]

    , testCase "end-to-end: simple linear SSA → InstrGraph" $
        let sa = SsaProc
              { spName   = "test"
              , spBlocks = Map.fromList
                  [ ("entry", SsaBlock
                      { sbAssigns = [ SsaAssign (SsaVar "a") (SsaConst (ExInt "1"))
                                     , SsaAssign (SsaVar "b") (SsaConst (ExInt "2")) ]
                      , sbTerm = SsaReturn Nothing })
                  ]
              , spEntry  = "entry"
              , spVars   = []
              }
            catTree  = compileSsaDefault sa
            graph    = buildInstrGraphNamed catTree
            nodes    = igNodes graph
        in do
          assertBool ("should have 3 nodes (exit + 2 assigns), got " <> show (P.length nodes))
            (P.length nodes == 3)
          assertBool "should contain a"
            (any (\n -> case n of InstrAssign { anVar = "a" } -> True; _ -> False) nodes)
          assertBool "should contain b"
            (any (\n -> case n of InstrAssign { anVar = "b" } -> True; _ -> False) nodes)
    ]

  , testGroup "compileProcedureViaCatOp"
    [ testCase "empty body produces non-empty graph" $
        let graph = compileProcedureViaCatOp emptyEnv Set.empty []
        in assertBool "should have at least one node (exit)" (not (null (igNodes graph)))

    , testCase "single BsCall produces non-empty graph" $
        let callExpr = ExCall { callee = Lvalue [LvSegment "foo" Nothing], callArgs = [] }
            body     = [Located 1 (BsCall callExpr)]
            graph    = compileProcedureViaCatOp emptyEnv Set.empty body
        in assertBool "should have more than one node" (P.length (igNodes graph) P.> 1)

    , testCase "DW suspend call produces InstrSuspend in graph" $
        let callExpr = ExCall
              { callee   = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing]
              , callArgs = [] }
            body  = [Located 1 (BsCall callExpr)]
            graph = compileProcedureViaCatOp dwEnv Set.empty body
        in assertBool "should contain InstrSuspend"
             (any (\n -> case n of InstrSuspend {} -> True; _ -> False) (igNodes graph))

    -- Plan 145 Phase 1C/3: BsPbCall (`call ancestor::event`) used to be dropped
    -- entirely by PB.Analysis.SSA.stmtToAssigns's catch-all. Confirms the fix
    -- makes the new pipeline match PB.Analysis.InstrGraph's old-compiler output
    -- for the exact m_ole_example::destroy regression case (InstrGraphTest.hs's
    -- "2B" hand-trace test) bit-for-bit, not just structurally equivalent.
    , testCase "BsPbCall (call ancestor::event) matches old compiler's [SCProc, SRet]" $
        let body  = [Located 1 (BsPbCall (PbCall "m_ole_frame" "destroy"))]
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
        in canonicalize graph @?= [SCProc 1, SRet]
    ]

  , testGroup "no unconditional join InstrNop (Plan 145 Finding A)"
    -- PB.Analysis.CatOp.compileLowCatToInstr's LCompose/LFanIn branch case (and the
    -- analogous case in compileLoopBodyLowCat) used to unconditionally allocate a
    -- join InstrNop before both arms, even when nothing structurally requires one.
    -- The old compiler (PB.Analysis.InstrGraph, confirmed-correct reference) never
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

    , testCase "branch inside a loop body has no join InstrNop" $
        -- Direct CatOp construction (bypassing SSA/BsFor) isolates
        -- compileLoopBodyLowCat's branch case from an unrelated, separate bug
        -- where a for-loop containing an if collapses entirely (logged to BACKLOG).
        --
        -- Also verifies the compileLoopLowCat header-patch fix (Plan 145,
        -- "u_ddcal root cause and fix" follow-up): the loop header used to
        -- allocate a persistent InstrNop placeholder and re-patch it with a
        -- *forwarding* InstrNop to a separately-allocated InstrBranch, instead of
        -- resolving the placeholder to the branch node in place. Since this
        -- loop's body is itself exactly a branch, the header IS that branch —
        -- no SNop should appear at all.
        --
        -- Also verifies the LInl/LInr fix (Plan 145): neither the continue
        -- (LInl, then-arm) nor the break (LInr, else-arm) allocates a wrapper
        -- InstrGoto — the assign's anNext closes the back-edge directly onto
        -- the branch, and the break routes straight to the exit/return, so
        -- the whole loop is exactly 3 nodes (branch, assign, return).
        let innerBranch = branch (ExBool True)
              (CatCompose CatInl (CatAssignWithRhs "x_1" (ExInt "1")) :: CatOp () (Either () ()))
              (CatInr :: CatOp () (Either () ()))
            catTree = CatLoop innerBranch :: CatOp () ()
            graph   = buildInstrGraphNamed catTree
        in canonicalize graph @?= [SBrnch 1 2, SAsgn 0, SRet]
    ]

  , testGroup "no wrapper InstrGoto for loop continue/break (Plan 145 LInl/LInr fix)"
    -- compileLoopBodyLowCat's LInl/LInr cases used to each allocate a genuine
    -- InstrGoto node for the loop's implicit continue/break, where the old
    -- compiler (PB.Analysis.InstrGraph's BsFor/BsDo) threads the raw target
    -- pcs straight through with zero wrapper nodes. This was the last
    -- blocker for --dual-cps exact-match parity on loop-containing
    -- procedures (the header-InstrNop fix above didn't move the diff count
    -- because of this sibling bug). Fixed by resolving LInl/LInr directly to
    -- loopHeaderPc/nextPc as entry pcs (structural/erased, like
    -- LEval/LFork/LSplitValue) instead of allocateNode-ing a InstrGoto.
    --
    -- These are end-to-end bit-for-bit equality checks against the old
    -- compiler for the exact minimal for/do-loop shapes traced in the plan
    -- (doc/plan/145-dual-cps-debug.md, "New finding: LInl/LInr residual
    -- InstrGoto hops"). Only SCall vs SCProc differs — the pre-existing,
    -- documented cosmetic call-tag divergence (Phase 1B), not a real
    -- difference — so both sides are normalized before comparing.
    [ testCase "for loop containing one call matches old compiler exactly (mod SCall/SCProc tag)" $
        let body = [Located 1 (BsFor (ForStmt (Lvalue [LvSegment "li_count" Nothing])
                      (ExInt "1") (ExInt "10") Nothing
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))]))]
            -- Frozen expected shape (Plan 144 Phase 5 Step 7): captured from the old
            -- compiler before its deletion, when this test last passed bit-for-bit.
            expectedShape = [SAsgn 1, SBrnch 2 3, SCall 4, SRet, SAsgn 1]
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= expectedShape

    , testCase "do-while loop containing one call matches old compiler exactly (mod SCall/SCProc tag)" $
        let body = [Located 1 (BsDo (DoStmt (Just (DoWhile (ExBool True)))
                      [Located 2 (BsCall (ExCall (Lvalue [LvSegment "foo" Nothing]) []))] Nothing))]
            expectedShape = [SBrnch 1 2, SCall 0, SRet]
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= expectedShape
    ]

  , testGroup "for/do-loop header collapse (Plan 145 post-Finding-A block-collapse bug)"
    -- Root cause: PB.Analysis.Cfg.lowerFor/lowerDo (top-condition) flush the
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
    -- allocate a persistent loop-header InstrNop as a forward-reference
    -- placeholder, then re-patch it with *another* forwarding InstrNop instead of
    -- resolving it to the real InstrBranch in place. Fixed by patching the
    -- reserved header pc directly with the branch node (mirroring
    -- InstrGraph.hs's BsFor patchNode pattern) via the new
    -- patchLoopHeaderLowCat helper — see "no unconditional join InstrNop (Plan
    -- 145 Finding A)" → "branch inside a loop body has no join InstrNop" above
    -- for the isolated regression test.
    --
    -- Still open, out of scope here (logged to BACKLOG): compileLoopBodyLowCat's
    -- LInl/LInr cases still allocate a genuine InstrGoto node for the implicit
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
    -- a real InstrAssign{anVar="_"} node instead of a bare call node. The old
    -- compiler (PB.Analysis.InstrGraph's BsCall `otherwise` branch) never has
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
            -- Frozen expected shape (Plan 144 Phase 5 Step 7): captured from the old
            -- compiler before its deletion, when this test last passed bit-for-bit.
            expectedShape = [SCall 1, SRet]
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= expectedShape

    , testCase "ExDispatch (bare Post Event) matches old compiler exactly (mod SCall/SCProc tag)" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Nothing, mode = DmPost, dynamic = False
              , event = True, name = "ue_getvalues", args = [] })
            body = [Located 1 (BsCall dispatchExpr)]
            expectedShape = [SCall 1, SRet]
            newShape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in newShape @?= expectedShape

    , testCase "no CatAssignWithRhs is emitted for a standalone dispatch statement" $
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Just (Lvalue [LvSegment "ParentWindow" Nothing]), mode = DmPost
              , dynamic = True, event = False, name = "of_run_report", args = [] })
            body  = [Located 1 (BsCall dispatchExpr)]
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
            hasAssignNode = any (\n -> case n of InstrAssign {} -> True; _ -> False) (igNodes graph)
        in assertBool "should contain no InstrAssign node" (not hasAssignNode)
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
    -- silently dropped. At the time this comment was first written, GraphBuilder's
    -- CatOp/LowCat lowering had no node-level memoization of its own, so a merge
    -- block reached by more than one predecessor was emitted once per predecessor
    -- (duplicated) rather than shared as a single physical node — still semantically
    -- correct, but exponential in the number of sequential merge points for
    -- pathological real procedures (see doc/plan/150-graphbuilder-node-blowup.md).
    -- 'CatTagged'/'LTagged' (Plan 150) now gives 'GraphBuilder' its own node-level
    -- sharing, so the physical duplication described above no longer happens — see
    -- the "GraphBuilder node-sharing" test group below for the node-count assertion.
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
            -- Frozen expected path-call-counts (Plan 144 Phase 5 Step 7): captured
            -- from the old compiler before its deletion, when this test last passed.
            expectedCounts = [2, 3]
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts

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
            expectedCounts = [3, 3]
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts

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
            expectedCounts = [0, 3, 3]
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts
    ]

  , testGroup "GraphBuilder node-sharing: sequential merge points stay linear, not exponential (Plan 150)"
    -- GraphBuilder previously had no node-level sharing (see the previous
    -- test group's docstring): a merge block reached by 2+ predecessors was
    -- re-lowered, and re-allocated, once per predecessor. For a single
    -- if/else that's just a 2x cost; but for a CHAIN of N sequential
    -- if/else-with-shared-tail groups, each duplication compounds into the
    -- next merge's own duplication, giving O(2^N) node count for O(N)
    -- source statements. This is exactly the shape that made a real corpus
    -- procedure (fn_dateolografos: 6 sequential choose/case blocks) take
    -- 'GraphBuilder' from instant to a multi-minute, unbounded-memory hang
    -- (doc/plan/150-graphbuilder-node-blowup.md) — confirmed via a
    -- 41,603-node/2s-timeout hand-trace at the 16th of that procedure's 20
    -- statements, vs. 174 nodes/6ms for the old compiler on the whole body.
    -- The fix: 'CatTagged'/'LTagged' mark a merge block's compiled value
    -- with its originating blockId, and 'GraphBuilder' caches the pc it
    -- allocates for a given (blockId, continuation) pair, reusing it
    -- instead of re-lowering on a repeat encounter.
    [ testCase "4 sequential if/else groups: node count stays linear, not 2^4 = 16x" $
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
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
            graph = compileProcedureViaCatOp emptyEnv Set.empty body
            nodeCount = length (igNodes graph)
        in assertBool
             ("node count should stay roughly linear in 4 groups (~5-6 nodes/group); got " <> show nodeCount)
             (nodeCount P.< 40)

    , testCase "4 sequential if/else groups: old and new compilers agree on call counts per path" $
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
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
            newShape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts newShape @?= expectedCounts
    ]

  , testGroup "toLowCat merge-block memoization: sequential choose/case chains stay linear, not multiplicative"
    -- 'compileBlock' (CatLower.hs) already memoizes by blockId, so a merge point
    -- reached by N predecessors is compiled once and the SAME 'CatOp' heap value is
    -- embedded at all N call sites -- real Haskell sharing. But 'toLowCat'
    -- (GraphBuilder.hs) walks that shared DAG with no memo of its own: each of the
    -- N embeddings triggers an independent, full recursive conversion of the shared
    -- subtree into 'LowCat'. A chain of switches makes this compound
    -- multiplicatively: every switch's N-way fan-in reconverges on the single block
    -- that starts the next switch, so 'toLowCat' re-converts that next switch's
    -- entire (further-nested) content once per predecessor branch of the current
    -- one. This is exactly fn_dateolografos.srf's real shape (7 sequential/nested
    -- choose/case blocks, ~79 total clauses) -- cost-center profiling attributed
    -- 86-93% of that file's compile time and ~2GB of allocation to 'toLowCat' alone,
    -- even though Plan 150's CatTagged/bsBlockPcMemo already keeps the final
    -- InstrGraph's own node count linear (see the "GraphBuilder node-sharing" group
    -- above) -- that fix covers 'compileLowCatToInstr's re-lowering, a stage strictly
    -- after 'toLowCat', which still pays the full multiplicative cost constructing
    -- the (later-deduplicated) 'LowCat' tree in the first place.
    --
    -- Assertions are on *bytes allocated* (via 'GHC.Conc.getAllocationCounter'), not
    -- wall-clock time: allocation count is deterministic across CI machines of
    -- differing speed/load, where a wall-clock bound would be flaky. A generous
    -- 'timeout' wraps each as a hang-safety-net only (the fixed algorithm finishes
    -- in milliseconds; it exists so a regression fails fast instead of hanging the
    -- suite), not as the pass/fail signal.
    [ testCase "7 sequential choose/case blocks, 8 clauses each (fn_dateolografos shape): allocates < 20MB" $ do
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            chooseGroup g =
              Located (g P.* 100) (BsChoose (ChooseStmt
                (ExLvalue (Lvalue [LvSegment ("s" <> T.pack (show g)) Nothing]))
                [ CaseClause (Just [tok (T.pack (show i))])
                    [Located (g P.* 100 P.+ i) (BsCall (call ("c" <> T.pack (show g) <> "_" <> T.pack (show i))))]
                | i <- [1 .. 8 :: Int] ]))
            body = [ chooseGroup g | g <- [1 .. 7 :: Int] ]
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (length (igNodes (compileProcedureViaCatOp emptyEnv Set.empty body)))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (pre-fix: unmemoized toLowCat \
             \allocates hundreds of MB+ from combinatorial re-conversion across chained switches)")
            (bytes P.< 20 P.* 1000 P.* 1000)

    , testCase "18 sequential if/else groups: allocates < 20MB, not 2^18 blowup" $ do
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (length (igNodes (compileProcedureViaCatOp emptyEnv Set.empty body)))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (pre-fix: 2^18 node \
             \reconstructions in toLowCat)")
            (bytes P.< 20 P.* 1000 P.* 1000)
    ]

  , testGroup "foldCat CatTagged memoization: SchFootprint fold over a shared-merge-block DAG stays linear"
    -- The Plan 150 / toLowCat memo group above covers the lowering folds
    -- ('toLowCat', 'compileLowCatToInstr' via 'bsBlockPcMemo', 'collectWiring'
    -- via 'walkShared'). 'PB.Analysis.CatOp.foldCat' — the generic catamorphism
    -- over 'CatOp', used by both 'PB.Analysis.CatInterp.runCat' (test) and
    -- 'PB.Analysis.SchFootprint.foldSchFootprint' (production, per-procedure in
    -- 'PB.Pipeline.Runner.compileOne') — had NO matching 'CatTagged' memo until
    -- this fix: @foldCat (CatTagged _ f) = foldCat f@ recursed unconditionally,
    -- re-folding a shared merge-block subterm once per embedding. With each such
    -- subterm containing the next reconvergent fan-in, the cost is O(2^depth) in
    -- the number of sequential reconvergent switches — the same class of blowup
    -- the toLowCat memo group above guards against, one layer up.
    --
    -- Nothing folded a 'CatTagged'-bearing term on a hot path before Plan 163
    -- Phase 3 wired 'foldSchFootprint' into 'compileOne' (commit 6510af8), so
    -- the absence of the memo only surfaced as a real regression: a 1763-file
    -- ~300 KLOC corpus that previously compiled in ~7 minutes stalled at
    -- ~1261 files, with workers wedged on the highest-switch-count procedures.
    -- These tests pin the memo's presence so the same wiring change (or any
    -- future 'foldCat' caller) can't silently reintroduce it. Assertions are
    -- bytes-allocated, mirroring the toLowCat memo group; the fixed algorithm
    -- finishes in milliseconds and the timeout is a hang-safety-net only.
    [ testCase "18 sequential if/else groups: foldSchFootprint stays linear, not 2^18 re-folds" $ do
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
            term = compileProcedureToCatOp emptyEnv Set.empty body
            ctx  = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (Set.size (foldSchFootprint ctx term))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 5MB (Plan 167 Phase 1 force-time \
             \memo: measured ~0.4MB; the old <150MB bound was an exponential baseline that passed \
             \only because the force-time bug was present. Pre-Phase-1: ~80MB re-forcing shared \
             \CatTagged subtrees at every embedding)")
            (bytes P.< 5 P.* 1000 P.* 1000)

    , testCase "7 sequential choose/case blocks, 8 clauses each (fn_dateolografos shape): foldSchFootprint stays linear" $ do
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            chooseGroup g =
              Located (g P.* 100) (BsChoose (ChooseStmt
                (ExLvalue (Lvalue [LvSegment ("s" <> T.pack (show g)) Nothing]))
                [ CaseClause (Just [tok (T.pack (show i))])
                    [Located (g P.* 100 P.+ i) (BsCall (call ("c" <> T.pack (show g) <> "_" <> T.pack (show i))))]
                | i <- [1 .. 8 :: Int] ]))
            body = [ chooseGroup g | g <- [1 .. 7 :: Int] ]
            term = compileProcedureToCatOp emptyEnv Set.empty body
            ctx  = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (Set.size (foldSchFootprint ctx term))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (Plan 167 Phase 1 force-time \
             \memo on 8-way fan-in; the old <600MB bound was an exponential baseline that passed \
             \only because the force-time bug was present. Pre-Phase-1: ~350MB combinatorial across \
             \the 7 chained 8-clause blocks)")
            (bytes P.< 20 P.* 1000 P.* 1000)

    , testCase "foldCat memo preserves semantics: a shared tagged block's footprint is folded correctly" $
        -- Memo correctness, not just performance: the memo returns the same
        -- result the unmemoized fold would. SchFootprint's only non-empty
        -- Effectful method is 'callProc' (SetItem recognition), which produces
        -- nothing here (no control bindings), so the footprint is empty — but
        -- the assertion exercises the full fold path including CatTagged hits.
        -- The memo must never corrupt the result (e.g. return a stale or
        -- type-mismatched cached value); if it did, the result set would differ.
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   ]
            term = compileProcedureToCatOp emptyEnv Set.empty body
            ctx  = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
        in foldSchFootprint ctx term @?= Set.empty
    ]

  , testGroup "collectWiring (Plan 149 Phase 1)"
    -- Plan 149 Phase 0's survey found that a naive fold over 'LowCat' (e.g.
    -- a JSON serializer that just recurses into every constructor) re-walks
    -- a shared 'LTagged' block once per predecessor, reproducing Plan 150's
    -- exact multiplicative-blowup bug one layer up — the first survey
    -- attempt hung for 15+ minutes on a real corpus procedure before this
    -- was diagnosed. 'collectWiring' must extract each distinct blockId's
    -- content exactly once, regardless of how many times its tag is
    -- referenced in the term (mirroring 'bsBlockPcMemo'\'s contract).
    [ testCase "shared tail (if/else, both arms) is collected exactly once, referenced twice" $
        -- Same fixture as "compileBlock memoization ... both arms" above:
        -- the trailing callC/callD block is reached from both the then-arm
        -- and the else-arm, so it is tagged and its tag is referenced twice.
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   , Located 5 (BsCall (call "callD"))
                   ]
            low = compileProcedureToLowCat emptyEnv Set.empty body
            (term, shared) = collectWiring low
            taggedIds = collectTagIds term
        in do
          assertEqual "exactly one distinct shared blockId" 1 (L.length taggedIds)
          assertEqual "sharedBlocks has exactly one entry" 1 (Map.size shared)
          assertBool "the shared blockId is referenced at least twice in the raw term (real sharing)"
            (case taggedIds of { [bid] -> countTagOccurrences bid term P.>= 2; _ -> False })
          assertBool "the shared blockId's content actually holds real assigns/calls, not an empty placeholder"
            (case taggedIds of { [bid] -> Map.member bid shared; _ -> False })

    , testCase "no merge points: term unchanged, sharedBlocks empty" $
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsCall (call "callA")) ]
            low = compileProcedureToLowCat emptyEnv Set.empty body
            (term, shared) = collectWiring low
        in do
          term @?= low
          assertBool "sharedBlocks empty" (Map.null shared)

    , testCase "hand-built repeat-tag shape: dedup keeps a single entry, terminates" $
        -- A minimal, hand-built two-occurrence tag (not derived from a real
        -- compile) — the defensive-only unit-level counterpart to the
        -- corpus-derived test above; guards against a regression to
        -- re-walking (and, for a self-referential shape, never terminating).
        let inner1 = LAssignWithRhs "x" (ExInt "1")
            shape  = LCompose (LTagged "m1" inner1) (LTagged "m1" inner1)
            (_, shared) = collectWiring shape
        in shared @?= Map.fromList [("m1", inner1)]
    ]

  , testGroup "Phase 1D: Interp vs GraphBuilder trace equivalence (Plan 146)"
    -- Same CatOp term, run through both of CatOp's execution backends:
    -- Interp (direct Haskell execution) and GraphBuilder (flat InstrGraph, the
    -- shape the TS runtime consumes). A divergence here is a real backend
    -- bug, independent of anything upstream in the AST/SSA/CatOp compilation
    -- stages. Reuses the exact terms hand-built in the "Interp / runCat"
    -- group above (narrow, fixture-driven pass per Plan 146 Phase 1 Step 1D
    -- — a generator is deferred until this passes).
    [ testCase "CatId: no trace, no env change" $ do
        let term = CatId :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
        itrace @?= []
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatAssignWithRhs: same assign trace, same env" $ do
        let term = CatAssignWithRhs "x_1" (ExInt "42") :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
        itrace @?= [TeAssign "x_1" (VInt 42)]
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatCompose: two assigns execute in the same order" $ do
        let term = CatAssignWithRhs "y_1" (ExInt "2") . CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branch True: then-arm taken on both backends" $ do
        let term = branch (ExBool True)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "branch False: else-arm taken on both backends" $ do
        let term = branch (ExBool False)
                     (CatAssignWithRhs "then_taken" (ExInt "1"))
                     (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatSuspend: same effect name and evaluated args" $ do
        let term = CatSuspend "retrieve:dw_foo" [ExInt "1", ExStr "bar"] :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
        itrace @?= gtrace
        ienv @?= genv

    , testCase "CatCall: same callee and evaluated args" $ do
        let term = CatCall "my_func" [ExInt "5"] :: CatOp () ()
        (ienv, itrace) <- runInterpTrace term Map.empty
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) Map.empty
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
        let (genv, gtrace, _) = runInstrGraphTrace 10000 Map.empty (buildInstrGraphNamed term) initEnv
        itrace @?= gtrace
        ienv @?= genv
        Map.lookup "i" ienv @?= Just (VInt 3)
    ]

  , testGroup "PureCall callee name preserves source case (Plan 146 Phase 2d)"
    -- compileCallExpr's `otherwise` branch (PB.Analysis.CatOp) and
    -- compileAssign's ExMethodCall PureCall case both wrap the callee name in
    -- T.toLower before building CatCall, but PB.Analysis.InstrGraph's mirror
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
            -- Frozen expected trace (Plan 144 Phase 5 Step 7): captured from the old
            -- compiler before its deletion, when this test last passed bit-for-bit.
            expectedTrace = (Map.empty, [TeCall "GlobalMemoryStatus" []], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace

    , testCase "ExMethodCall with mixed-case receiver/method: TeCall preserves case" $
        let recv = ExLvalue (Lvalue [LvSegment "parentwindow" Nothing])
            body = [Located 1 (BsCall (ExMethodCall recv "TriggerEvent" [[]]))]
            expectedTrace = (Map.empty, [TeCall "parentwindow.TriggerEvent" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace

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
            expectedTrace = (Map.empty, [TeCall "?.TriggerEvent" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace
    ]

  , testGroup "fn_retrievechild suspend args match old compiler (Plan 146 Phase 2i)"
    -- Real corpus idiom (openpay's wiz_misth_final_details_step1::of_stepadded
    -- and 3 sibling wizard-step handlers): `fn_retrievechild(adw, "col", var)`.
    -- 'PB.Analysis.InstrGraph' special-cases this exact callee (before its
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
            expectedTrace = (Map.empty, [TeSuspend "retrieve:child_kodkat:dw_misth_final" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace
    ]

  , testGroup "local DataStore/Transaction variable suspend-classification (Plan 146 Phase 2e)"
    -- ScopedTypeEnv.steLocal's own doc comment says "body locals added in
    -- P2b" but compileProcedureViaCatOp/compileSsa never actually do this —
    -- env flows in unchanged from the caller, so a *locally-declared*
    -- datastore/transaction variable's type can never be resolved by
    -- classifyExpr's lookupScopedVar, and a suspend method call on it falls
    -- through to the conservative PureCall default. PB.Analysis.InstrGraph's
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
            expectedTrace = (Map.empty, [TeSuspend "retrieve:lds_x" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace

    , testCase "local transaction var .commit() classifies as SuspendCall" $
        let body = [ Located 1 (BsLocalVar [] (PtPrimitive "transaction") "ltrans_x" Nothing)
                   , Located 2 (BsCall (ExMethodCall (ExLvalue (Lvalue [LvSegment "ltrans_x" Nothing])) "commit" [[]]))
                   ]
            expectedTrace = (Map.empty, [TeSuspend "executeSql" [VNull]], NaturalHalt)
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
        in newTrace @?= expectedTrace
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
    [ let oiV = SsaVarRef (SsaVar "oi")
          iiV = SsaVarRef (SsaVar "ii")
          yV  = SsaVarRef (SsaVar "y")
          nestedLoopsSsa = SsaProc
            { spName   = "test"
            , spEntry  = "entry"
            , spVars   = []
            , spBlocks = Map.fromList
                [ ("entry", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "oi") (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "y") (SsaConst (ExInt "0")) ]
                    , sbTerm = SsaGoto "outer_header" })
                , ("outer_header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt oiV (SsaConst (ExInt "2"))) "outer_if" "outer_exit" })
                , ("outer_if", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaConst (ExBool True)) "outer_enter_inner" "outer_merge" })
                , ("outer_enter_inner", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "ii") (SsaConst (ExInt "0"))]
                    , sbTerm = SsaGoto "inner_header" })
                , ("inner_header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt iiV (SsaConst (ExInt "3"))) "inner_body" "inner_exit" })
                , ("inner_body", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "ii") (SsaBinOp BopAdd iiV (SsaConst (ExInt "1")))
                                  , SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) ]
                    , sbTerm = SsaGoto "inner_header" })
                , ("inner_exit", SsaBlock { sbAssigns = [], sbTerm = SsaGoto "outer_merge" })
                , ("outer_merge", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "oi") (SsaBinOp BopAdd oiV (SsaConst (ExInt "1")))]
                    , sbTerm = SsaGoto "outer_header" })
                , ("outer_exit", SsaBlock { sbAssigns = [], sbTerm = SsaReturn Nothing })
                ]
            }
          initEnv = Map.fromList [("oi", VInt 0), ("y", VInt 0), ("ii", VInt 0)]
          -- Bounded via 'runInstrGraphTrace' (never raw, unbounded 'runInterpTrace')
          -- because the pre-fix bug reproduces a genuine runtime infinite loop for
          -- this shape (confirmed empirically before writing this assertion), not
          -- just a wrong-but-terminating result.
          maxSteps = 500 :: Int
          (finalEnv, trc, _) = runInstrGraphTrace maxSteps Map.empty
                              (buildInstrGraphNamed (compileSsaDefault nestedLoopsSsa)) initEnv
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
    [ let xV  = SsaVarRef (SsaVar "x")
          yV  = SsaVarRef (SsaVar "y")
          scV = SsaVarRef (SsaVar "skip_count")
          continueSsa = SsaProc
            { spName   = "test"
            , spEntry  = "entry"
            , spVars   = []
            , spBlocks = Map.fromList
                [ ("entry", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "x") (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "y") (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "skip_count") (SsaConst (ExInt "0"))
                                  , SsaAssign (SsaVar "done") (SsaConst (ExInt "0")) ]
                    , sbTerm = SsaGoto "header" })
                , ("header", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopLt xV (SsaConst (ExInt "3"))) "body_entry" "z_exit" })
                , ("body_entry", SsaBlock
                    { sbAssigns = []
                    , sbTerm = SsaBranch (SsaBinOp BopEq xV (SsaConst (ExInt "1"))) "c_continue" "normal_body" })
                , ("c_continue", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "x") (SsaBinOp BopAdd xV (SsaConst (ExInt "1")))
                                  , SsaAssign (SsaVar "skip_count") (SsaBinOp BopAdd scV (SsaConst (ExInt "1"))) ]
                    , sbTerm = SsaContinue })
                , ("normal_body", SsaBlock
                    { sbAssigns = [ SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1")))
                                  , SsaAssign (SsaVar "x") (SsaBinOp BopAdd xV (SsaConst (ExInt "1"))) ]
                    , sbTerm = SsaGoto "header" })
                , ("z_exit", SsaBlock
                    { sbAssigns = [SsaAssign (SsaVar "done") (SsaConst (ExInt "1"))]
                    , sbTerm = SsaReturn Nothing })
                ]
            }
          initEnv = Map.fromList [("x", VInt 0), ("y", VInt 0), ("skip_count", VInt 0), ("done", VInt 0)]
          (finalEnv, _trc, _) = runInstrGraphTrace 100 Map.empty
                                (buildInstrGraphNamed (compileSsaDefault continueSsa)) initEnv
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
          expectedTrace = (Map.fromList [("done", VInt 1)], [TeBranch False, TeBranch False, TeBranch False, TeAssign "done" (VInt 1)], NaturalHalt)
          newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
      in testCase "no elseif clause matches (x unset) -> falls through to the trailing assign, matching the old compiler" $
           newTrace @?= expectedTrace
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
                   { sbAssigns = [SsaAssign (SsaVar "y") (SsaConst (ExInt "999"))]
                   , sbTerm = SsaReturn Nothing })
               , ("normal_body", SsaBlock
                   { sbAssigns = [ SsaAssign (SsaVar "x") (SsaBinOp BopAdd xV (SsaConst (ExInt "1")))
                                 , SsaAssign (SsaVar "y") (SsaBinOp BopAdd yV (SsaConst (ExInt "1"))) ]
                   , sbTerm = SsaGoto "header" })
               , ("z_exit", SsaBlock
                   { sbAssigns = [SsaAssign (SsaVar "done") (SsaConst (ExInt "1"))]
                   , sbTerm = SsaReturn Nothing })
               ]
           }
         compiled = compileSsaDefault returnSsa
         runIt trigger = runInstrGraphTrace 100 Map.empty
                           (buildInstrGraphNamed compiled)
                           (Map.fromList [("x", VInt 0), ("y", VInt 0), ("done", VInt 0), ("trigger", VInt trigger)])
     in
     [ testCase "compiles to a CatReturn (not CatInr) for the return block" $
         assertBool "expected a CatReturn node in the compiled tree" (hasCatReturn compiled)

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
          expectedTrace = (Map.empty, [TeBranch False, TeCall "trailing" []], NaturalHalt)
          newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
      in testCase "do-while with if/elseif-return, followed by trailing code, matches old compiler" $
           newTrace @?= expectedTrace
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
    -- infinite loop (confirmed via direct 'InstrGraph' inspection of the real
    -- procedure: a 'InstrBranch' whose own false edge pointed back at itself).
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
         expectedTrace = ( Map.fromList [("i", VInt 4), ("w", VReal 3.0)]
                          , [ TeBranch False
                            , TeAssign "i" (VInt 1), TeBranch True, TeAssign "w" (VReal 1.0)
                            , TeAssign "i" (VInt 2), TeBranch True, TeAssign "w" (VReal 2.0)
                            , TeAssign "i" (VInt 3), TeBranch True, TeAssign "w" (VReal 3.0)
                            , TeAssign "i" (VInt 4), TeBranch False
                            ]
                          , NaturalHalt )
         newTrace = runInstrGraphTrace maxSteps Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
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
    -- sequentially. This end-to-end fixture is deliberately compared against
    -- the old compiler (unlike GoldenFixtureTest.hs's independently
    -- hand-derived fixtures) because that's exactly what's being repaired:
    -- new should now match old, not diverge from it.
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
            newTrace = runInstrGraphTrace 100 Map.empty (compileProcedureViaCatOp emptyEnv Set.empty body) Map.empty
            (newEnv, _, _) = newTrace
        in do
             newTrace @?= expectedTrace
             Map.lookup "x" newEnv @?= Just (VInt 1)
             Map.lookup "y" newEnv @?= Nothing
             Map.lookup "z" newEnv @?= Just (VInt 2)
    ]

  , testGroup "compileProcedureToCatOp (Plan 163 Phase 3)"
    -- PB.Analysis.SchFootprint.foldSchFootprint needs the raw compiled CatOp
    -- term (via foldCat), which neither compileProcedureViaCatOp (flattens
    -- to InstrGraph) nor compileProcedureToLowCat (flattens to LowCat)
    -- exposes. compileProcedureToCatOp mirrors the same SSA -> CatOp
    -- pipeline, stopping one step earlier.
    [ testCase "toLowCat . compileProcedureToCatOp matches compileProcedureToLowCat directly" $
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   ]
        in toLowCatOp (compileProcedureToCatOp emptyEnv Set.empty body)
             @?= compileProcedureToLowCat emptyEnv Set.empty body

    , testCase "empty body: still matches compileProcedureToLowCat (totalizes, no crash)" $
        toLowCatOp (compileProcedureToCatOp emptyEnv Set.empty [])
          @?= compileProcedureToLowCat emptyEnv Set.empty []
    ]

  , testGroup "parseArgList / collectBodyLocals (retained helpers, Plan 144 Phase 5 Step 7)"
    -- Ported from the now-deleted InstrGraphTest.hs's "Gap 3" and "body locals"
    -- groups: these exercised the two PB.Analysis.InstrGraph helpers that
    -- survive the old compiler's deletion (both are still imported directly by
    -- PB.Analysis.CatOp) indirectly, through compileProcedure. Direct unit
    -- tests on the pure functions themselves, rather than losing the coverage.
    [ testGroup "parseArgList"
      [ testCase "single-token ident becomes ExLvalue" $
          parseArgList [tok "w_test"] @?= ExLvalue (Lvalue [LvSegment "w_test" Nothing])

      , testCase "multi-token binary a + 1 -> ExBinOp BopAdd" $
          case parseArgList [tok "a", tok "+", tok "1"] of
            ExBinOp { op = BopAdd } -> pure ()
            e -> assertBool ("expected ExBinOp BopAdd, got: " <> show e) False

      , testCase "quoted string -> ExStr" $
          parseArgList [tok "\"hello\""] @?= ExStr "hello"

      , testCase "bool literal true -> ExBool True" $
          parseArgList [tok "true"] @?= ExBool True

      , testCase "null -> ExNull" $
          parseArgList [tok "null"] @?= ExNull

      , testCase "multi-token sub b - 2 -> ExBinOp BopSub" $
          case parseArgList [tok "b", tok "-", tok "2"] of
            ExBinOp { op = BopSub } -> pure ()
            e -> assertBool ("expected ExBinOp BopSub, got: " <> show e) False
      ]

    , testGroup "collectBodyLocals"
      [ testCase "collects BsLocalVar declarations, lower-casing the variable name" $
          let body = [ Located 1 (BsLocalVar [] (PtPrimitive "datawindow") "dw" Nothing)
                     , Located 2 (BsLocalVar [] (PtPrimitive "integer") "Li_Count" Nothing)
                     ]
          in collectBodyLocals body @?= Map.fromList
               [ ("dw", PtPrimitive "datawindow"), ("li_count", PtPrimitive "integer") ]
    ]
  ]

  , testGroup "Plan 167 Phase 3: CatLetRef table + inlineTable rehydration"
    -- The Phase 3 correctness contract: for any term compileSsa produces,
    --   inlineTable (extractTable op)  is observationally identical to op.
    -- "Observationally identical" = the existing folds (foldCat via
    -- foldSchFootprint, toLowCat) produce the same output on both. We test
    -- via foldSchFootprint because it is the strongest exact-output oracle
    -- readily at hand in this module's helpers, and via feq for structural
    -- equality.
    [ testCase "inlineTable . extractTable == id on a shared-merge-block term (foldSchFootprint)" $ do
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 5 :: Int] ]  -- 6 if/else groups
            op   = compileProcedureToCatOp emptyEnv Set.empty body
            term = extractTable op
            ctx  = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
        -- foldSchFootprint over the rehydrated term equals foldSchFootprint
        -- over the original (both go through the same CatTagged shape).
        foldSchFootprint ctx (inlineTable term) @?= foldSchFootprint ctx op

    , testCase "extractTable rewrites CatTagged to CatLetRef in the spine" $ do
        let op   = CatTagged "blk" CatId :: CatOp () ()
            term = extractTable op
            CatTerm _spine table = term
        -- The table holds the body once.
        Map.lookup "blk" table @?= Just (CatId :: CatOp () ())

    , testCase "inlineTable rehydrates CatLetRef back to CatTagged (feq)" $ do
        let op   = CatTagged "blk" CatId :: CatOp () ()
            term = extractTable op
        -- Structural equality between original and rehydrated.
        feq op (inlineTable term) @?= True
    ]

  , testGroup "Plan 167 Phase 7 Step 2: EffTerm table + inlineEffTable rehydration"
    -- Mirrors the 'CatTerm' group above in SHAPE, not extraction mechanism:
    -- 'ELetRef' carries no body (unlike 'CatTagged'), so 'extractEffTable'
    -- cannot discover a non-trivial table from a bare term — see its own
    -- headnote in CatOp.hs. It is still the correct answer (not an
    -- approximation) on any sharing-free term, which is every term these
    -- tests construct by hand. 'Eff' has no 'Eq' instance (unlike 'CatOp'
    -- via 'feq'), so equivalence here is checked observationally, via
    -- trace comparison — the same style every other 'Eff' test in this
    -- module already uses.
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

    , testGroup "Phase 5a: Freyd split (Pure/Eff/J) — foldFreyd faithfulness"
      [ testCase "J PId folds to id" $ do
          let eff = J PId :: Eff () ()
              cat = CatId :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "J (PEval e) folds to eval e" $ do
          let e = ExInt "42"
              eff = J (PEval e) :: Eff () Value
              cat = CatEval e :: CatOp () Value
          effTrace <- runEffTraceGen () eff Map.empty
          catTrace <- runInterpTraceGen () cat Map.empty
          effTrace @?= catTrace

      , testCase "EAssignWithRhs folds equivalently to CatAssignWithRhs" $ do
          let e = ExInt "99"
              eff = EAssignWithRhs "x" e :: Eff () ()
              cat = CatAssignWithRhs "x" e :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "ECall folds to callProc" $ do
          let eff = ECall "myproc" [ExInt "1"] :: Eff () ()
              cat = CatCall "myproc" [ExInt "1"] :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "ESuspend folds to suspend" $ do
          let eff = ESuspend "myeff" [ExInt "2"] :: Eff () ()
              cat = CatSuspend "myeff" [ExInt "2"] :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "EReturn folds to ret" $ do
          let eff = EReturn :: Eff () ()
              cat = CatReturn :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "J (PFork PId PId) folds to fork id id" $ do
          let eff = J (PFork PId PId) :: Eff () ((), ())
              cat = CatFork CatId CatId :: CatOp () ((), ())
          effTrace <- runEffTraceGen () eff Map.empty
          catTrace <- runInterpTraceGen () cat Map.empty
          effTrace @?= catTrace

      , testCase "J PExl folds to exl" $ do
          let eff = J PExl :: Eff ((), ()) ()
              cat = CatExl :: CatOp ((), ()) ()
          effTrace <- runEffTraceGen ((), ()) eff Map.empty
          catTrace <- runInterpTraceGen ((), ()) cat Map.empty
          effTrace @?= catTrace

      , testCase "J PExr folds to exr" $ do
          let eff = J PExr :: Eff ((), ()) ()
              cat = CatExr :: CatOp ((), ()) ()
          effTrace <- runEffTraceGen ((), ()) eff Map.empty
          catTrace <- runInterpTraceGen ((), ()) cat Map.empty
          effTrace @?= catTrace

      , testCase "EComp folds equivalently to CatCompose" $ do
          let eff = EComp (ECall "f" []) (EAssignWithRhs "x" (ExInt "0")) :: Eff () ()
              cat = CatCompose (CatCall "f" []) (CatAssignWithRhs "x" (ExInt "0")) :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "ELoop folds equivalently to CatLoop" $ do
          let body = J PInr :: Eff () (Either () ())
              eff = ELoop body :: Eff () ()
              body' = CatInr :: CatOp () (Either () ())
              cat = CatLoop body' :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "ELetRef resolves via the table, fold-caches on first encounter" $ do
          -- The real merge-point shape: 'ELetRef "shared"' appears at BOTH
          -- arms of an 'EFanIn' (mutually exclusive branches reconverging
          -- on one block — the only shape a real 'ELetRef' ever appears
          -- in, per CatLowerEff's merge-point emission). foldFreyd folds
          -- the table's body once (first 'ELetRef' encounter), caches the
          -- k () () result under "shared", and the second 'ELetRef'
          -- occurrence reuses the CACHED FOLD — not a re-traversal of the
          -- body term. Because '(|||)' is CHOICE (Interp dispatches
          -- exactly one arm at runtime), the shared body executes exactly
          -- once regardless of which arm is taken — unlike the old
          -- 'ELet'/'EVar' shape this replaces, which composed the cached
          -- morphism into a sequential '.', re-executing it per use site.
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

      , testCase "J (PFanIn PInl PInr) folds to fanin" $ do
          let eff = J (PFanIn PInl PInr) :: Eff (Either () ()) (Either () ())
              cat = CatFanIn CatInl CatInr :: CatOp (Either () ()) (Either () ())
          effTrace <- runEffTraceGen (Left ()) eff Map.empty
          catTrace <- runInterpTraceGen (Left ()) cat Map.empty
          effTrace @?= catTrace

      , testCase "branchEff folds equivalently to branch (then-arm, true cond)" $ do
          -- The load-bearing Phase 5b design check: branchEff (an Eff-level
          -- branch with effectful arms, joined by EFanIn) folds to the SAME
          -- Interp trace as the CatOp-level branch. This is what compileSsa
          -- will emit at every SsaBranch/SsaSwitch site. Verifies that the
          -- pure fork (J (PId &&& PEval cond)) + ESplitValue + EFanIn of two
          -- effectful arms reproduces branch cond t f exactly.
          let cond = ExBool True
              eff = branchEff cond
                      (EAssignWithRhs "then_taken" (ExInt "1"))
                      (EAssignWithRhs "else_taken" (ExInt "2")) :: Eff () ()
              cat = branch cond
                      (CatAssignWithRhs "then_taken" (ExInt "1"))
                      (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "branchEff folds equivalently to branch (else-arm, false cond)" $ do
          let cond = ExBool False
              eff = branchEff cond
                      (EAssignWithRhs "then_taken" (ExInt "1"))
                      (EAssignWithRhs "else_taken" (ExInt "2")) :: Eff () ()
              cat = branch cond
                      (CatAssignWithRhs "then_taken" (ExInt "1"))
                      (CatAssignWithRhs "else_taken" (ExInt "2")) :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace

      , testCase "branchEff with effectful-call arms folds equivalently to branch" $ do
          -- Arms carry ECall effects (not just assigns) — the realistic
          -- compileSsa case where a branch target is a block that suspends
          -- a side-effect. Confirms EFanIn of effectful arms is faithful.
          let cond = ExBool True
              eff = branchEff cond
                      (ECall "then_proc" [ExInt "1"])
                      (ECall "else_proc" [ExInt "2"]) :: Eff () ()
              cat = branch cond
                      (CatCall "then_proc" [ExInt "1"])
                      (CatCall "else_proc" [ExInt "2"]) :: CatOp () ()
          effTrace <- runEffTrace eff () Map.empty
          catTrace <- runInterpTrace cat Map.empty
          effTrace @?= catTrace
      ]

    , testGroup "Phase 5b Step 1: compileSsaToEff cross-check"
      [ testCase "empty body — both paths produce no-op trace" $ do
          let body = [] :: [Located BodyStmt]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "single assign — EAssignWithRhs cross-check" $ do
          let body = [Located 1 (BsAssign (Lvalue [LvSegment "x" Nothing]) (ExInt "42"))]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "if/else with calls — branchEff cross-check" $ do
          let thenCall = Located 2 (BsPbCall (PbCall "obj" "then_event"))
              elseCall = Located 3 (BsPbCall (PbCall "obj" "else_event"))
              body = [Located 1 (BsIf (IfStmt (ExBool True) [thenCall] [] (Just [elseCall])))]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "for-loop with body call — ELoop cross-check" $ do
          let body = [Located 1 (BsFor (ForStmt (Lvalue [LvSegment "li_count" Nothing])
                        (ExInt "1") (ExInt "10") Nothing
                        [Located 2 (BsPbCall (PbCall "obj" "loop_event"))]))]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "if/else with shared tail — ELetRef merge-point cross-check" $ do
          let thenCall = Located 2 (BsPbCall (PbCall "obj" "then_event"))
              elseCall = Located 3 (BsPbCall (PbCall "obj" "else_event"))
              tailCall = Located 4 (BsPbCall (PbCall "obj" "tail_event"))
              body = [ Located 1 (BsIf (IfStmt (ExBool True) [thenCall] [] (Just [elseCall])))
                     , tailCall ]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace
      ]

    , testGroup "Phase 5b Step 2: widened cross-check"
      [ testCase "nested if/else (if inside an if-then arm)" $ do
          let innerThen = Located 2 (BsPbCall (PbCall "obj" "inner_then_event"))
              innerElse = Located 3 (BsPbCall (PbCall "obj" "inner_else_event"))
              outerElse = Located 4 (BsPbCall (PbCall "obj" "outer_else_event"))
              tailCall  = Located 5 (BsPbCall (PbCall "obj" "tail_event"))
              body = [ Located 1 (BsIf (IfStmt (ExBool True)
                            [ Located 2 (BsIf (IfStmt (ExBool False) [innerThen] [] (Just [innerElse]))) ]
                            [] (Just [outerElse])))
                     , tailCall ]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "choose with 3 cases + default (SsaSwitch cross-check)" $ do
          let clauses = [ CaseClause (Just [tok "1"]) [Located 2 (BsPbCall (PbCall "obj" "case1_event"))]
                        , CaseClause (Just [tok "2"]) [Located 3 (BsPbCall (PbCall "obj" "case2_event"))]
                        , CaseClause (Just [tok "3"]) [Located 4 (BsPbCall (PbCall "obj" "case3_event"))]
                        , CaseClause Nothing          [Located 5 (BsPbCall (PbCall "obj" "default_event"))]
                        ]
              body = [Located 1 (BsChoose (ChooseStmt (ExLvalue (Lvalue [LvSegment "sel" Nothing])) clauses))]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "nested for-loops (loop body is another loop)" $ do
          let body = [ Located 1 (BsFor (ForStmt (Lvalue [LvSegment "i" Nothing])
                        (ExInt "1") (ExInt "3") Nothing
                        [ Located 2 (BsFor (ForStmt (Lvalue [LvSegment "j" Nothing])
                            (ExInt "1") (ExInt "3") Nothing
                            [Located 3 (BsPbCall (PbCall "obj" "inner_event"))]))]))]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "loop body with if/else and shared tail (merge inside a loop)" $ do
          let iter = Lvalue [LvSegment "iter" Nothing]
              body = [ Located 1 (BsAssign iter (ExInt "0"))
                     , Located 2 (BsDo (DoStmt
                        (Just (DoWhile (ExBinOp (ExLvalue iter) BopLt (ExInt "2"))))
                        [ Located 3 (BsAssign iter (ExBinOp (ExLvalue iter) BopAdd (ExInt "1")))
                        , Located 4 (BsIf (IfStmt (ExBinOp (ExLvalue iter) BopEq (ExInt "1"))
                                             [Located 5 (BsPbCall (PbCall "obj" "then_event"))] []
                                             (Just [Located 6 (BsPbCall (PbCall "obj" "else_event"))])))
                        , Located 7 (BsPbCall (PbCall "obj" "tail_event"))
                        ]
                        Nothing))
                     ]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace

      , testCase "if/elseif/else chain (elseif flattening)" $ do
          let body = [ Located 1 (BsIf (IfStmt (ExBool True)
                        [Located 2 (BsPbCall (PbCall "obj" "first_event"))]
                        [ ElseIf (ExBool False) [Located 3 (BsPbCall (PbCall "obj" "second_event"))]
                        , ElseIf (ExBool False) [Located 4 (BsPbCall (PbCall "obj" "third_event"))]
                        ]
                        (Just [Located 5 (BsPbCall (PbCall "obj" "default_event"))])))]
              catOpTerm = compileProcedureToCatOp emptyEnv Set.empty body
              effTerm   = compileProcedureToEff emptyEnv Set.empty body
          catTrace <- runInterpTrace catOpTerm Map.empty
          effTrace <- runEffTermTrace effTerm () Map.empty
          effTrace @?= catTrace
      ]

  , testGroup "Phase 6 (Approach C): named-graph structural sharing — merge/branch/loop canonical shapes"
    -- 'compileProcedureViaCatOp' flattens via a named graph
    -- ('InstrNode''/'InstrGraph'') + 'linearize' — dedup on merge-block
    -- 'Map.Map' key uniqueness ('nbsBlockMemo', keyed on blockId alone),
    -- not a 2D-keyed pc memo. These literal shapes were the cross-check
    -- fixtures Plan 167 Phase 6 used to prove the named path matched the
    -- (now-retired) PC-threaded lowering on every merge/branch/loop pattern
    -- the rest of this test suite covers, before the production switch;
    -- kept as direct regression assertions on the production entry point.
    [ testCase "if/else with shared tail: canonical shape" $
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            body = [ Located 1 (BsIf (IfStmt (ExBool True)
                       [Located 2 (BsCall (call "callA"))] []
                       (Just [Located 3 (BsCall (call "callB"))])))
                   , Located 4 (BsCall (call "callC"))
                   , Located 5 (BsCall (call "callD"))
                   ]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SCall 3, SCall 3, SCall 4, SCall 5, SRet]

    , testCase "nested if inside if/else with shared trailing calls: canonical shape" $
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
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SBrnch 3 4, SRet, SCall 5, SCall 5, SCall 6, SCall 2]

    , testCase "choose with 3 cases + default: canonical shape" $
        let clauses = [ CaseClause (Just [tok "1"]) [Located 2 (BsPbCall (PbCall "obj" "case1_event"))]
                      , CaseClause (Just [tok "2"]) [Located 3 (BsPbCall (PbCall "obj" "case2_event"))]
                      , CaseClause (Just [tok "3"]) [Located 4 (BsPbCall (PbCall "obj" "case3_event"))]
                      , CaseClause Nothing          [Located 5 (BsPbCall (PbCall "obj" "default_event"))]
                      ]
            body = [Located 1 (BsChoose (ChooseStmt (ExLvalue (Lvalue [LvSegment "sel" Nothing])) clauses))]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SCall 3, SBrnch 4 5, SRet, SCall 3, SBrnch 6 7, SCall 3, SCall 3]

    , testCase "nested for-loops: canonical shape" $
        let body = [ Located 1 (BsFor (ForStmt (Lvalue [LvSegment "i" Nothing])
                      (ExInt "1") (ExInt "3") Nothing
                      [ Located 2 (BsFor (ForStmt (Lvalue [LvSegment "j" Nothing])
                          (ExInt "1") (ExInt "3") Nothing
                          [Located 3 (BsPbCall (PbCall "obj" "inner_event"))]))]))]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in shape @?= [SAsgn 1, SBrnch 2 3, SAsgn 4, SRet, SBrnch 5 6, SCall 7, SAsgn 1, SAsgn 4]

    , testCase "loop body with if/else and shared tail (merge inside a loop): canonical shape" $
        let iter = Lvalue [LvSegment "iter" Nothing]
            body = [ Located 1 (BsAssign iter (ExInt "0"))
                   , Located 2 (BsDo (DoStmt
                      (Just (DoWhile (ExBinOp (ExLvalue iter) BopLt (ExInt "2"))))
                      [ Located 3 (BsAssign iter (ExBinOp (ExLvalue iter) BopAdd (ExInt "1")))
                      , Located 4 (BsIf (IfStmt (ExBinOp (ExLvalue iter) BopEq (ExInt "1"))
                                           [Located 5 (BsPbCall (PbCall "obj" "then_event"))] []
                                           (Just [Located 6 (BsPbCall (PbCall "obj" "else_event"))])))
                      , Located 7 (BsPbCall (PbCall "obj" "tail_event"))
                      ]
                      Nothing))
                   ]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in shape @?= [SAsgn 1, SBrnch 2 3, SAsgn 4, SRet, SBrnch 5 6, SCall 7, SCall 7, SCall 1]

    , testCase "if/elseif/else chain: canonical shape" $
        let body = [ Located 1 (BsIf (IfStmt (ExBool True)
                      [Located 2 (BsPbCall (PbCall "obj" "first_event"))]
                      [ ElseIf (ExBool False) [Located 3 (BsPbCall (PbCall "obj" "second_event"))]
                      , ElseIf (ExBool False) [Located 4 (BsPbCall (PbCall "obj" "third_event"))]
                      ]
                      (Just [Located 5 (BsPbCall (PbCall "obj" "default_event"))])))]
            shape = normalizeCallTag <$> canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in shape @?= [SBrnch 1 2, SCall 3, SBrnch 4 5, SRet, SCall 3, SBrnch 6 7, SCall 3, SCall 3]

    , testCase "4 sequential if/else groups: per-path call counts stay uniform (no compounding across merges)" $
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
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
            shape = canonicalize (compileProcedureViaCatOp emptyEnv Set.empty body)
        in pathCallCounts shape @?= expectedCounts

    , testCase "18 sequential if/else groups: allocates < 20MB, not 2^18 blowup" $ do
        let call n = ExCall (Lvalue [LvSegment n Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (length (igNodes (compileProcedureViaCatOp emptyEnv Set.empty body)))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (structural sharing via \
             \Map.Map key uniqueness should stay linear with no memo at all)")
            (bytes P.< 20 P.* 1000 P.* 1000)
    ]

  , testGroup "branchK (Plan 167 Phase 7 Step 1): primitive Effectful method matches its prior derivation"
    -- 'branchK' is promoted from a derived combinator ('branch'/'branchEff')
    -- to a primitive, no-default 'Effectful' method (doc/plan/167-phase7-
    -- step1-branchk-charter.md). Every instance's 'branchK' body is asserted
    -- byte-identical to the derivation it replaces; these tests are the
    -- behavioral proof, not just a compile-success check.
    [ testCase "branchK matches branch's trace for CatOp (via Interp)" $ do
        let t = CatAssignWithRhs "then_taken" (ExInt "1") :: CatOp () ()
            f = CatAssignWithRhs "else_taken" (ExInt "2") :: CatOp () ()
            cond = ExBool True
            viaBranch  = branch cond t f
            viaBranchK = branchK cond t f :: CatOp () ()
            golden = [TeBranch True, TeAssign "then_taken" (VInt 1)]
        (_, st1) <- runStateT (runInterp (runCat viaBranch) ()) (InterpState Map.empty [] Map.empty)
        (_, st2) <- runStateT (runInterp (runCat viaBranchK) ()) (InterpState Map.empty [] Map.empty)
        P.reverse (isTrace st1) @?= golden
        P.reverse (isTrace st2) @?= golden

    , testCase "branchK matches branchEff's trace for Eff (via foldFreyd/Interp)" $ do
        let te = EAssignWithRhs "then_taken" (ExInt "1") :: Eff () ()
            fe = EAssignWithRhs "else_taken" (ExInt "2") :: Eff () ()
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
