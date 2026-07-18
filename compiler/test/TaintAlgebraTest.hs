module TaintAlgebraTest (tests, defRow, useRow, edge, src, snk) where

-- | A/B oracle tests for the algebraic taint closure (Plan 182).
--
-- The core claim is that 'PB.Analysis.TaintAlgebra.taintReachable'
-- (a Kleene star over a semiring-labeled relation) agrees *exactly*
-- with the hand-written BFS 'PB.Analysis.Taint.propagateTaint'
-- on the tainted set, for fixtures spanning all four edge rules
-- (intra-proc same-line def-use, arg, return, global-hub).
--
-- 'propagateTaint' is the trusted oracle here: both are pure Haskell
-- over identical inputs, so equality is a strong, fast, always-runnable
-- gate (the Souffle path in 'SouffleTaintTest' remains the
-- ultimate oracle where 'souffle' is installed).
import PB.Prelude
import PB.Analysis.Taint
  ( propagateTaint
  , DefRow (..)
  , UseRow (..)
  , InterprocEdge (..)
  , TaintSource (..)
  , TaintSink (..)
  )
import PB.Analysis.TaintAlgebra
  ( taintReachable
  , taintConfirmed
  , taintWitnesses
  )
import PB.Algebra.Semiring (Boolean (..), PathValue (..))
import PB.Algebra.Closure
  ( star
  , reachableSet
  , fromEdges
  , reconstructPath
  )

import qualified Data.Set as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- helpers (mirror compiler/test/TaintTest.hs)
defRow :: Text -> Text -> Text -> Text -> Int -> Int -> DefRow
defRow file obj proc var line stmtIdx = DefRow
  { drFile = file, drObject = obj, drProcName = proc
  , drVarName = var, drBlockId = "b0", drStmtIdx = stmtIdx
  , drLine = Just line, drKind = "assign"
  }

useRow :: Text -> Text -> Text -> Text -> Int -> Text -> UseRow
useRow file obj proc var line kind = UseRow
  { urFile = file, urObject = obj, urProcName = proc
  , urVarName = var, urBlockId = "b0", urStmtIdx = 0
  , urLine = Just line, urKind = kind
  }

edge :: Text -> Text -> Maybe Int -> Text -> Text -> Text -> Text -> Text -> Text -> InterprocEdge
edge co cp cl fo fp ek v cc fc = InterprocEdge
  { ieCallerObject = co, ieCallerProc = cp, ieCallerLine = cl
  , ieCalleeObject = fo, ieCalleeProc = fp, ieEdgeKind = ek
  , ieVarName = v, ieCallerContext = cc, ieCalleeContext = fc
  }

src :: Text -> Text -> Text -> Text -> Maybe Int -> TaintSource
src o p v t l = TaintSource o p v t "db_read" l

snk :: Text -> Text -> Text -> Text -> Maybe Int -> TaintSink
snk o p v t l = TaintSink o p v t "db_write" "high" l

tests :: TestTree
tests = testGroup "TaintAlgebra"
  [ testGroup "Semiring closure"
      [ testCase "reachability on a 3-chain" $
          let rel = fromEdges [ (0,1,Boolean True), (1,2,Boolean True) ]
              sr  = star rel
          in reachableSet sr 0 @?= Set.fromList [0,1,2]
      , testCase "cycle terminates and is idempotent" $
          let rel = fromEdges [ (0,1,Boolean True), (1,0,Boolean True) ]
              sr  = star rel
          in reachableSet sr 0 @?= Set.fromList [0,1]
      , testCase "witness path reconstructs 0->1->2" $
          let rel = fromEdges
                [ (0,1, Reachable 1 (Just 'a') 0)
                , (1,2, Reachable 1 (Just 'b') 1)
                ]
              sr  = star rel
          in reconstructPath sr 0 2 @?= Just ['a','b']
      ]

  , testGroup "taint A/B vs propagateTaint"
      [ testCase "algebraic reachability == BFS tainted set" $
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5)
                       , src "w" "oa" "pW" "g_x" (Just 1)
                       ]
              defs = [ defRow "w" "oa" "pA" "ls_a" 5 0
                     , defRow "w" "oa" "pA" "ls_b" 5 1
                     , defRow "w" "oa" "pB" "ls_c" 3 2
                     ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var"
                     , useRow "w" "oa" "pB" "ls_c" 3 "return"
                     ]
              edges = [ edge "oa" "pA" (Just 5) "oa" "pB" "arg"    "ls_b" "ls_b" "ls_c"
                     , edge "oa" "pB" (Just 3) "oa" "pA" "return" "ls_c" "ls_c" "ls_b"
                     , edge "oa" "pW" (Just 1) ""  "global::g_x" "global_write" "g_x" "g_x" "g_x"
                     , edge ""  "global::g_x" (Just 1) "oa" "pR" "global_write" "g_x" "g_x" "g_x"
                     ]
              (bfsSet, _) = propagateTaint sources defs uses edges
              algSet      = taintReachable sources defs uses edges
          in bfsSet @?= algSet
      , testCase "isolated source (zero outgoing edges) keeps its own 0-hop membership" $
          -- Plan 182 corpus finding (doc/plan/182-algebraic-analysis.md
          -- Section 11, 2026-07-18): a source var never subsequently
          -- used/passed/returned/globally-written must still count as
          -- tainted by definition -- propagateTaint's fixpoint always
          -- inserts every seed unconditionally; taintRelation's interner
          -- used to omit any seed with no outgoing arcPairs, silently
          -- dropping it (confirmed on real corpus: 152/966 triples lost).
          let sources = [ src "w" "oa" "pA" "ls_orphan" (Just 9) ]
              defs = []
              uses = []
              edges = []
              (bfsSet, _) = propagateTaint sources defs uses edges
              algSet      = taintReachable sources defs uses edges
          in bfsSet @?= algSet
      , testCase "confirmed (source, sink) pairs match" $
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5)
                       , src "w" "oa" "pW" "g_x" (Just 1)
                       ]
              sinks   = [ snk "w" "oa" "pB" "ls_c" (Just 3)
                       , snk "w" "oa" "pR" "g_x" (Just 1)
                       ]
              defs = [ defRow "w" "oa" "pA" "ls_a" 5 0
                     , defRow "w" "oa" "pA" "ls_b" 5 1
                     , defRow "w" "oa" "pB" "ls_c" 3 2
                     ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var"
                     , useRow "w" "oa" "pB" "ls_c" 3 "return"
                     ]
              edges = [ edge "oa" "pA" (Just 5) "oa" "pB" "arg"    "ls_b" "ls_b" "ls_c"
                     , edge "oa" "pB" (Just 3) "oa" "pA" "return" "ls_c" "ls_c" "ls_b"
                     , edge "oa" "pW" (Just 1) ""  "global::g_x" "global_write" "g_x" "g_x" "g_x"
                     , edge ""  "global::g_x" (Just 1) "oa" "pR" "global_write" "g_x" "g_x" "g_x"
                     ]
              confirmed = taintConfirmed sources sinks defs uses edges
              key (s, k) =
                ( (tsObject s, tsProcName s, tsVarName s)
                , (tskObject k, tskProcName k, tskVarName k)
                )
              expected =
                [ (src "w" "oa" "pA" "ls_a" (Just 5), snk "w" "oa" "pB" "ls_c" (Just 3))
                , (src "w" "oa" "pW" "g_x" (Just 1), snk "w" "oa" "pR" "g_x" (Just 1))
                ]
          in Set.fromList (map key confirmed) @?= Set.fromList (map key expected)
      ]
  , testGroup "taint witness (Path)"
      [ testCase "Path relation yields a witness for a confirmed pair" $
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5) ]
              defs = [ defRow "w" "oa" "pA" "ls_a" 5 0
                     , defRow "w" "oa" "pA" "ls_b" 5 1
                     , defRow "w" "oa" "pB" "ls_c" 3 2
                     ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var"
                     , useRow "w" "oa" "pB" "ls_c" 3 "return"
                     ]
              edges = [ edge "oa" "pA" (Just 5) "oa" "pB" "arg"    "ls_b" "ls_b" "ls_c"
                     , edge "oa" "pB" (Just 3) "oa" "pA" "return" "ls_c" "ls_c" "ls_b"
                     ]
          in null (taintWitnesses sources defs uses edges) @?= False
      ]
  ]

