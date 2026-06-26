{-# LANGUAGE OverloadedStrings #-}
module SSATest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.AST.Type          (PbType (..))
import PB.Analysis.SSA
import PB.Analysis.TypeEnv  (ScopedTypeEnv (..))

import qualified Data.Map.Strict as Map
import Test.Tasty            (TestTree, testGroup)
import Test.Tasty.HUnit      (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n = Located n

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty

blockCount :: SsaProc -> Int
blockCount = Map.size . spBlocks

allVarNames :: SsaProc -> [Text]
allVarNames = map svName . spVars

phiVarNames :: SsaProc -> [Text]
phiVarNames sa = [ svName (spResult p) | phis <- Map.elems (spPhis sa), p <- phis ]

getBlock :: SsaProc -> Text -> SsaBlock
getBlock sa lbl = case Map.lookup lbl (spBlocks sa) of
  Just b  -> b
  Nothing -> error ("block not found: " <> show lbl)

entryBlock :: SsaProc -> SsaBlock
entryBlock sa = getBlock sa (spEntry sa)

termSuccessors :: SsaTerm -> [Text]
termSuccessors (SsaGoto dst)       = [dst]
termSuccessors (SsaBranch _ t f)   = [t, f]
termSuccessors (SsaReturn _)       = []
termSuccessors SsaBreak            = []
termSuccessors SsaContinue         = []

totalAssigns :: SsaProc -> Int
totalAssigns sa = sum [ length (sbAssigns b) | b <- Map.elems (spBlocks sa) ]

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "SSA"
  [ testGroup "linear code"
    [ testCase "empty body produces one block with return" $ do
        let sa = buildSsa emptyEnv "proc" []
        blockCount sa @?= 1
        sbTerm (entryBlock sa) @?= SsaReturn Nothing

    , testCase "single assign produces one block, one var" $ do
        let sa = buildSsa emptyEnv "proc"
                  [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
        blockCount sa @?= 1
        allVarNames sa @?= ["x"]
        length (sbAssigns (entryBlock sa)) @?= 1

    , testCase "two sequential assigns produce two vars" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsAssign (lv1 "y") (ExInt "2"))
                  ]
        allVarNames sa @?= ["x", "y"]
        length (sbAssigns (entryBlock sa)) @?= 2

    , testCase "reassignment creates new version" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsAssign (lv1 "x") (ExInt "2"))
                  ]
        allVarNames sa @?= ["x", "x"]

    , testCase "assign RHS references earlier version" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsAssign (lv1 "y") (ExBinOp (ExLvalue (lv1 "x")) BopAdd (ExInt "1")))
                  ]
        case sbAssigns (entryBlock sa) of
          [_, SsaAssign _ rhs] -> case rhs of
            SsaBinOp _ (SsaVarRef sv) _ -> svName sv @?= "x"
            _ -> assertBool "expected SsaBinOp with SsaVarRef" False
          other -> assertBool ("expected two assigns, got " <> show (length other)) (length other == 2)

    , testCase "no phi nodes in linear code" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsAssign (lv1 "y") (ExInt "2"))
                  , at 3 (BsAssign (lv1 "z") (ExInt "3"))
                  ]
        phiVarNames sa @?= []

    , testCase "local var with init becomes assign" $ do
        let sa = buildSsa emptyEnv "proc"
                  [at 1 (BsLocalVar [] (PtPrimitive "integer") "x" (Just (ExInt "42")))]
        allVarNames sa @?= ["x"]
        totalAssigns sa @?= 1

    , testCase "local var without init produces no assign" $ do
        let sa = buildSsa emptyEnv "proc"
                  [at 1 (BsLocalVar [] (PtPrimitive "integer") "x" Nothing)]
        allVarNames sa @?= []
        totalAssigns sa @?= 0
    ]

  , testGroup "if/else"
    [ testCase "simple if/else produces multiple blocks" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsIf (IfStmt (ExBool True)
                      [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
                      []
                      (Just [at 4 (BsAssign (lv1 "y") (ExInt "3"))])))
                  ]
        assertBool "has 4+ blocks" (blockCount sa >= 4)

    , testCase "if/else with y in both branches creates phi" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsIf (IfStmt (ExBool True)
                      [at 2 (BsAssign (lv1 "y") (ExInt "1"))]
                      []
                      (Just [at 3 (BsAssign (lv1 "y") (ExInt "2"))])))
                  ]
        assertBool "y has phi" (elem "y" (phiVarNames sa))

    , testCase "if without else — phi inserted at merge (standard SSA)" $ do
        -- Standard SSA inserts phis at dominance frontiers regardless of liveness.
        -- The merge block is a DF of the then-block because it has another predecessor.
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsIf (IfStmt (ExBool True)
                      [at 2 (BsAssign (lv1 "y") (ExInt "1"))]
                      []
                      Nothing))
                  ]
        -- y is defined in then-block, merge is DF(then) → phi for y
        assertBool "y has phi at merge" (elem "y" (phiVarNames sa))

    , testCase "variable defined in then and else creates single phi" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "0"))
                  , at 2 (BsIf (IfStmt (ExBool True)
                      [at 3 (BsAssign (lv1 "x") (ExInt "1"))]
                      []
                      (Just [at 4 (BsAssign (lv1 "x") (ExInt "2"))])))
                  ]
        -- x defined in entry, then, else → phi at merge
        assertBool "x has phi" (elem "x" (phiVarNames sa))
    ]

  , testGroup "loops"
    [ testCase "for loop creates multiple blocks" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))]))]
        assertBool "has multiple blocks" (blockCount sa >= 3)

    , testCase "for loop with body reassign gets phi" $ do
        -- x defined before loop and inside loop body → phi at loop header/merge
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "0"))
                  , at 2 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
                      [at 3 (BsAssign (lv1 "x") (ExBinOp (ExLvalue (lv1 "x")) BopAdd (ExInt "1")))]))
                  ]
        assertBool "x has phi" (elem "x" (phiVarNames sa))
    ]

  , testGroup "structural invariants"
    [ testCase "spEntry always points to an existing block" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsIf (IfStmt (ExBool True)
                      [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
                      []
                      (Just [at 4 (BsAssign (lv1 "y") (ExInt "3"))])))
                  ]
        assertBool "entry block exists" (Map.member (spEntry sa) (spBlocks sa))

    , testCase "every block target exists in blocks map" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsIf (IfStmt (ExBool True)
                      [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
                      []
                      (Just [at 4 (BsAssign (lv1 "y") (ExInt "3"))])))
                  ]
        let allTargets = concatMap termSuccessors
                           [ sbTerm b | b <- Map.elems (spBlocks sa) ]
        assertBool "all targets exist"
          (all (`Map.member` spBlocks sa) allTargets)

    , testCase "phi sources reference existing blocks" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsIf (IfStmt (ExBool True)
                      [at 2 (BsAssign (lv1 "y") (ExInt "1"))]
                      []
                      (Just [at 3 (BsAssign (lv1 "y") (ExInt "2"))])))
                  ]
        let allPhiSrcs = [ src | phis <- Map.elems (spPhis sa), p <- phis, (src, _) <- spSources p ]
        assertBool "all phi sources exist"
          (all (`Map.member` spBlocks sa) allPhiSrcs)

    , testCase "all SSA vars have version > 0" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsIf (IfStmt (ExBool True)
                      [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
                      []
                      (Just [at 4 (BsAssign (lv1 "y") (ExInt "3"))])))
                  ]
        assertBool "all versions > 0" (all ((> 0) . svVersion) (spVars sa))
    ]
  ]
