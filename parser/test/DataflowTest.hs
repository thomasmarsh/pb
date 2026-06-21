module DataflowTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..), BinOp (..))
import PB.AST.Type         (PbType (..))
import PB.AST.Located      (Located (..))
import PB.Pipeline.CfgBuild (Cfg (..), CfgBlock (..), CfgEdge (..), buildCfg)
import PB.Pipeline.Dataflow

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

lv2 :: Text -> Text -> Lvalue
lv2 a b = Lvalue [LvSegment a Nothing, LvSegment b Nothing]

-- | Make a simple CfgBlock for testing.
mkBlock :: Text -> [Located BodyStmt] -> CfgBlock
mkBlock bid stmts = CfgBlock
  { cbId        = bid
  , cbStmts     = stmts
  , cbFirstLine = Nothing
  , cbLastLine  = Nothing
  }

-- | Extract the single element of a list whose length was just asserted to be 1.
one :: [a] -> a
one [x] = x
one _   = error "one: expected single-element list (prior length assertion failed)"

-- | Make a minimal Cfg with one block.
mkCfg :: Text -> [CfgBlock] -> [CfgEdge] -> Cfg
mkCfg entry blocks edges = Cfg
  { cfgEntry  = entry
  , cfgExits  = []
  , cfgBlocks = blocks
  , cfgEdges  = edges
  }

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Dataflow"

  [ testGroup "extractDefsUses"
    [ testCase "BsAssign creates def + use" $
        let blk = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "x"
          dsKind (one (bfDefs bf)) @?= "assign"

    , testCase "BsLocalVar with init creates def + use" $
        let blk = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "n" (Just (ExInt "0")))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "n"
          dsKind (one (bfDefs bf)) @?= "local_var"

    , testCase "BsLocalVar without init creates def only" $
        let blk = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "n" Nothing)]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          length (bfUses bf) @?= 0

    , testCase "BsAssign with variable rhs creates use" $
        let blk = mkBlock "b0" [at 1 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "y"
          length (bfUses bf) @?= 1
          usVar (one (bfUses bf)) @?= "x"
          usKind (one (bfUses bf)) @?= "rhs"

    , testCase "BsIf condition creates condition use" $
        let blk = mkBlock "b0" [at 1 (BsIf (IfStmt
                { ifCond = ExLvalue (lv1 "flag")
                , ifThen = []
                , ifElseIfs = []
                , ifElse = Nothing
                }))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 0
          length (bfUses bf) @?= 1
          usVar (one (bfUses bf)) @?= "flag"
          usKind (one (bfUses bf)) @?= "condition"

    , testCase "BsReturn creates return use" $
        let blk = mkBlock "b0" [at 1 (BsReturn (Just (ExLvalue (lv1 "result"))))]
            bf  = extractDefsUses blk
        in do
          length (bfUses bf) @?= 1
          usVar (one (bfUses bf)) @?= "result"
          usKind (one (bfUses bf)) @?= "return"

    , testCase "BsCall creates call_arg uses (callee + args)" $
        let blk = mkBlock "b0" [at 1 (BsCall (ExCall (lv1 "foo")
                [ ["x", "y"] ]))]
            bf  = extractDefsUses blk
        in do
          -- Matches Python dataflow.py: ExCall counts the callee root plus
          -- every arg ident, so foo(x, y) → {foo, x, y} = 3 uses.
          length (bfUses bf) @?= 3
          Set.fromList (map usVar (bfUses bf)) @?= Set.fromList ["foo", "x", "y"]
          all (\u -> usKind u == "call_arg") (bfUses bf) @?= True

    , testCase "gen set matches defs" $
        let blk = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
              , at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
              ]
            bf  = extractDefsUses blk
        in bfGen bf @?= Set.fromList ["x", "y"]

    , testCase "kill set matches defs" $
        let blk = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
              , at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
              ]
            bf  = extractDefsUses blk
        in bfKill bf @?= Set.fromList ["x", "y"]
    ]

  , testGroup "reachingDefinitions"
    [ testCase "single block: gen propagates to out" $
        let blk  = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b0" (pfReachingOut pf) @?=
            Set.singleton "x"

    , testCase "two blocks linear: def reaches through" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b1" (pfReachingIn pf) @?=
            Set.singleton "x"
          Map.findWithDefault Set.empty "b1" (pfReachingOut pf) @?=
            Set.fromList ["x", "y"]

    , testCase "two blocks: kill removes old def" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "x") (ExInt "2"))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b1" (pfReachingIn pf) @?=
            Set.singleton "x"
          Map.findWithDefault Set.empty "b1" (pfReachingOut pf) @?=
            Set.singleton "x"

    , testCase "diamond: defs from both branches reach merge" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "a") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "b") (ExInt "2"))]
            b2 = mkBlock "b2" [at 3 (BsAssign (lv1 "c") (ExInt "3"))]
            b3 = mkBlock "b3" [at 4 (BsAssign (lv1 "d") (ExLvalue (lv1 "a")))]
            cfg = mkCfg "b0" [b0, b1, b2, b3]
                    [ CfgEdge "b0" "b1" "T"
                    , CfgEdge "b0" "b2" "F"
                    , CfgEdge "b1" "b3" ""
                    , CfgEdge "b2" "b3" ""
                    ]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          let reaching = Map.findWithDefault Set.empty "b3" (pfReachingIn pf)
          assertBool "a should reach b3" ("a" `Set.member` reaching)
          assertBool "b should reach b3" ("b" `Set.member` reaching)
          assertBool "c should reach b3" ("c" `Set.member` reaching)
    ]

  , testGroup "analyzeProcedure"
    [ testCase "allDefs groups by variable" $
        let blk  = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
              , at 2 (BsAssign (lv1 "x") (ExInt "2"))
              ]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "myobj" "myproc" cfg
        in do
          pfObject pf @?= "myobj"
          pfProc pf @?= "myproc"
          length (Map.findWithDefault [] "x" (pfAllDefs pf)) @?= 2

    , testCase "allUses groups by variable" $
        let blk  = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
              , at 2 (BsReturn (Just (ExLvalue (lv1 "x"))))
              ]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
        in length (Map.findWithDefault [] "x" (pfAllUses pf)) @?= 2
    ]
  ]
