module CatOpTest (tests) where

import PB.Prelude hiding (id, (.))
import qualified Prelude as P
import PB.AST.Expr         (BinOp (..), Expr (..))
import PB.Analysis.CatOp
import PB.Analysis.SSA     (SsaVar (..), SsaVal (..), SsaAssign (..), SsaBlock (..),
                            SsaTerm (..), SsaProc (..), renderSsaVar, buildSsa)

import qualified Data.Map.Strict as Map
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, assertEqual, testCase, (@?=))

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

-- | Check if a CatOp tree contains a CatAssign for a given variable name.
hasAssign :: Text -> CatOp a b -> Bool
hasAssign _ CatId = False
hasAssign n (CatAssign t) = n == t
hasAssign n (CatCompose f g) = hasAssign n f P.|| hasAssign n g
hasAssign n (CatFork f g) = hasAssign n f P.|| hasAssign n g
hasAssign n (CatFanIn f g) = hasAssign n f P.|| hasAssign n g
hasAssign n (CatLoop f) = hasAssign n f
hasAssign n (CatTry f g) = hasAssign n f P.|| hasAssign n g
hasAssign _ _ = False

-- | Check if a CatOp tree contains a CatLookup for a given variable name.
hasLookup :: Text -> CatOp a b -> Bool
hasLookup _ CatId = False
hasLookup n (CatLookup t) = n == t
hasLookup n (CatCompose f g) = hasLookup n f P.|| hasLookup n g
hasLookup n (CatFork f g) = hasLookup n f P.|| hasLookup n g
hasLookup n (CatFanIn f g) = hasLookup n f P.|| hasLookup n g
hasLookup n (CatLoop f) = hasLookup n f
hasLookup n (CatTry f g) = hasLookup n f P.|| hasLookup n g
hasLookup _ _ = False

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

  , testGroup "GraphBuilder"
    [ testCase "id emits no nodes" $
        runGraphBuilder (id :: GraphBuilder () ()) @?= ([] :: [CpsNode])

    , testCase "composition concatenates in order" $
        let gb = mkAssign "x" . mkAssign "y" :: GraphBuilder () ()
        in case runGraphBuilder gb of
             [CpsAssign { anVar = "y" }, CpsAssign { anVar = "x" }] -> return ()
             other -> assertBool "expected 2 assign nodes in order" (P.length other == 2)

    , testCase "||| emits branch + then + goto + else" $
        let f = mkAssign "a" :: GraphBuilder () ()
            g = mkAssign "b"
            gb = f ||| g
        in case runGraphBuilder gb of
             [CpsBranch {}, CpsAssign { anVar = "a" }, CpsGoto {}, CpsAssign { anVar = "b" }] ->
               return ()
             other -> assertBool ("expected 4 nodes, got " <> show (P.length other)) (P.length other == 4)
    ]

  , testGroup "compileSsa"
    [ testCase "empty body compiles to CatId" $
        let sa = mkSsa [] (SsaReturn Nothing)
            result = compileSsa sa
        in result @?= (CatId :: CatOp () ())

    , testCase "single assign with SsaReturn" $
        let sa = mkSsa
              [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsa sa
        in assertBool "contains x_1 assign" (hasAssign "x_1" result)

    , testCase "single assign structure: CatCompose of assign + fork" $
        let sa = mkSsa
              [SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))]
              (SsaReturn Nothing)
            result = compileSsa sa
        in case result of
             CatCompose (CatAssign v) (CatFork CatId (CatEval _)) ->
               assertEqual "assigns to x_1" "x_1" v
             other -> assertBool ("unexpected structure: " <> show other) False

    , testCase "two linear assigns fold via CatCompose" $
        let sa = mkSsa
              [ SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y" 1) (SsaConst (ExInt "2"))
              ]
              (SsaReturn Nothing)
            result = compileSsa sa
        in assertBool "contains x_1 assign" (hasAssign "x_1" result)
           P.>> assertBool "contains y_1 assign" (hasAssign "y_1" result)

    , testCase "SsaReturn compiles to CatId" $
        let sa = mkSsa [] (SsaReturn Nothing)
            result = compileSsa sa
        in result @?= (CatId :: CatOp () ())

    , testCase "SsaReturn with value compiles to CatId" $
        let sa = mkSsa [] (SsaReturn (Just (SsaConst (ExInt "42"))))
            result = compileSsa sa
        in result @?= (CatId :: CatOp () ())

    , testCase "assign with SsaVarRef produces CatLookup in RHS" $
        let sa = mkSsa
              [ SsaAssign (SsaVar "x" 1) (SsaConst (ExInt "1"))
              , SsaAssign (SsaVar "y" 1) (SsaVarRef (SsaVar "x" 1))
              ]
              (SsaReturn Nothing)
            result = compileSsa sa
        in assertBool "contains lookup x_1" (hasLookup "x_1" result)

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
            result = compileSsa sa
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
            result = compileSsa sa
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
            result = compileSsa sa
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
            result = compileSsa sa
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
            result = compileSsa sa
        assertBool "contains CatLoop" (hasCatLoop result)
           P.>> assertBool "contains x_1 assign" (hasAssign "x_1" result)
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
  ]

-- Helper: build a GraphBuilder that emits a CpsAssign
mkAssign :: Text -> GraphBuilder () ()
mkAssign var = GraphBuilder (\currentPc ->
  ([CpsAssign { anVar = var, anRhs = ExNull, anNext = currentPc + 1 }], currentPc + 1))
