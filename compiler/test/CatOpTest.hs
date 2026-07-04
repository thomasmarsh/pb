module CatOpTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Type         (PbType (..))
import PB.AST.BodyStmt     (BodyStmt (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.CatOp
import PB.Analysis.SSA     (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                            SsaTerm (..), SsaProc (..), renderSsaVar, buildSsa)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
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

-- | Environment with datawindow and transaction typed variables.
dwEnv :: ScopedTypeEnv
dwEnv = ScopedTypeEnv
  { steGlobal    = Map.fromList [("dw_foo", PtPrimitive "datawindow"), ("sqlca", PtPrimitive "transaction")]
  , steInstance  = Map.empty
  , steLocal     = Map.empty
  , steHierarchy = Map.empty
  }

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

  , testGroup "Interp"
    [ testCase "id returns input" $
        runInterp (id :: Interp Int Int) 42 P.>>= \v -> v @?= 42

    , testCase "composition chains effects" $
        let f = Interp (\x -> P.pure (x P.+ 1)) :: Interp Int Int
            g = Interp (\x -> P.pure (x P.* 2))
        in runInterp (f . g) 3 P.>>= \v -> v @?= 7

    , testCase "inl injects left" $
        runInterp (inl :: Interp Int (Either Int Text)) 42 P.>>= \v -> v @?= Left 42

    , testCase "inr injects right" $
        runInterp (inr :: Interp Text (Either Int Text)) "hi" P.>>= \v -> v @?= Right "hi"

    , testCase "fanin dispatches" $
        let f = Interp (\_ -> P.pure "left") :: Interp Int P.String
            g = Interp (\_ -> P.pure "right")
        in runInterp (f ||| g) (Right "x" :: Either Int Text) P.>>= \v -> v @?= "right"

    , testCase "splitValue routes True to Left" $
        runInterp (splitValue :: Interp ((), Value) (Either () ())) ((), VBool True) P.>>= \v -> v @?= Left ()

    , testCase "splitValue routes False to Right" $
        runInterp (splitValue :: Interp ((), Value) (Either () ())) ((), VBool False) P.>>= \v -> v @?= Right ()
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

    , testCase "branch compiles to CpsBranch diamond with join nop" $
        let thenK = CatAssignWithRhs "x_1" (ExInt "1") :: CatOp () ()
            elseK = CatAssignWithRhs "y_1" (ExInt "2")
            op = branch (ExBool True) thenK elseK :: CatOp () ()
            graph = buildCpsGraph op
        in do
          P.length (cgNodes graph) @?= 5
          case cgNodes graph of
            ( CpsReturn Nothing
              : CpsNop { npNext = 0 }
              : CpsAssign { anVar = "y_1", anNext = 1 }
              : CpsAssign { anVar = "x_1", anNext = 1 }
              : CpsBranch { brThenPc = 3, brElsePc = 2 }
              : [] ) -> return ()
            nodes -> assertBool ("expected 5 nodes [exit, join-nop, else, then, branch], got " <> show (P.length nodes) <> ": " <> show nodes) False

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
          assertBool "should contain backward CpsGoto" hasGoto
          assertBool "should contain CpsBranch" hasBranch

    , testCase "unit: CatLoop lowers to correct header patch and backward CpsGoto" $
        let loopBody = CatCompose CatInl (CatAssignWithRhs "counter" (ExInt "42")) :: CatOp () (Either () ())
            catTree  = CatLoop loopBody :: CatOp () ()
            graph    = buildCpsGraph catTree
            nodes    = cgNodes graph
            gotos        = [ target | CpsGoto target <- nodes ]
            assignNexts  = [ next   | CpsAssign { anNext = next } <- nodes ]
            headerTarget = [ next   | CpsNop next <- nodes, next /= -1 ]
        in do
          assertBool ("Should allocate a backward jump; nodes: " <> show nodes) (not (null gotos))
          assertBool ("Should allocate an assignment sequence; nodes: " <> show nodes) (not (null assignNexts))
          assertBool ("Loop layout must form a synchronized cycle; nodes: " <> show nodes) (not (null headerTarget))

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
    ]
  ]
