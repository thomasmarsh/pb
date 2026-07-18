module TaintAlgebraTest (tests, defRow, useRow, edge, src, snk, intraEdgesFromDefUse) where

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
  , taintReachesPairs
  , taintConfirmed
  , taintWitnesses
  )
import PB.Analysis.TaintEdges (TaintIntraEdgeRow (..), foldTaintEdgesEff)
import PB.Algebra.Semiring (Boolean (..), PathValue (..))
import PB.Algebra.Closure
  ( star
  , reachableSet
  , fromEdges
  , reconstructPath
  )
import PB.AST.BodyStmt  (BodyStmt (..))
import PB.AST.Expr      (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident      (mkIdent)
import PB.AST.Located   (Located (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.Flatten (compileProcedureToEff)

import qualified Data.Map.Strict as Map
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

-- | Test-only reimplementation of the same-line def/use join
-- 'PB.Analysis.TaintAlgebra.buildTaintIndex' used before Plan 182 Move 2
-- (2026-07-18). Production now sources intra-proc edges from
-- 'PB.Analysis.TaintEdges.foldTaintEdgesEff' (a direct fold of the
-- compiled EffTerm -- see 'TaintEdgesTest' for that path's own coverage);
-- this helper exists only so the fixtures below (hand-typed 'DefRow'\/
-- 'UseRow' lists, not compiled 'EffTerm's) can still exercise
-- 'taintReachable'\/'taintReachesPairs'\/'taintConfirmed'\/'taintWitnesses''s
-- reachability\/dedup\/cycle logic without being rewritten as EffTerm
-- fixtures -- those functions are what's under test here, not edge
-- extraction.
emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty "" Map.empty

lvExpr :: Text -> Expr
lvExpr n = ExLvalue (Lvalue [LvSegment (mkIdent n) Nothing])

intraEdgesFromDefUse :: [DefRow] -> [UseRow] -> [TaintIntraEdgeRow]
intraEdgesFromDefUse defs uses =
  [ TaintIntraEdgeRow (urObject u) (urProcName u) (urVarName u) (drVarName d)
  | u <- uses
  , Just line <- [urLine u]
  , d <- defs
  , drObject d == urObject u
  , drProcName d == urProcName u
  , drLine d == Just line
  , drVarName d /= urVarName u
  ]

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
              algSet      = taintReachable sources (intraEdgesFromDefUse defs uses) defs uses edges
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
              algSet      = taintReachable sources (intraEdgesFromDefUse defs uses) defs uses edges
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
              confirmed = taintConfirmed sources sinks (intraEdgesFromDefUse defs uses) defs uses edges
              key (s, k) =
                ( (tsObject s, tsProcName s, tsVarName s)
                , (tskObject k, tskProcName k, tskVarName k)
                )
              expected =
                [ (src "w" "oa" "pA" "ls_a" (Just 5), snk "w" "oa" "pB" "ls_c" (Just 3))
                , (src "w" "oa" "pW" "g_x" (Just 1), snk "w" "oa" "pR" "g_x" (Just 1))
                ]
          in Set.fromList (map key confirmed) @?= Set.fromList (map key expected)
      , testCase "duplicate-key source/sink records collapse to one confirmed pair" $
          -- Real-corpus finding (Plan 182 cutover, 2026-07-18): the same
          -- (object, proc, var) is classified as a taint source/sink more
          -- than once (e.g. a :host_var used in two different SELECT INTO
          -- occurrences in the same proc) -- 15 duplicate-key groups in
          -- taint_sources, 19 in taint_sinks, on the real openpay corpus.
          -- Souffle's taint_confirmed is a SET keyed on the STRING
          -- object::proc::var key, so duplicate records collapse to one
          -- row; taintConfirmed must match that (26 vs an inflated 41 rows
          -- was the observed real-corpus divergence).
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5)
                       , src "w" "oa" "pA" "ls_a" (Just 9)
                       ]
              sinks   = [ snk "w" "oa" "pB" "ls_c" (Just 3)
                       , snk "w" "oa" "pB" "ls_c" (Just 7)
                       ]
              defs = [ defRow "w" "oa" "pA" "ls_b" 5 0
                     , defRow "w" "oa" "pB" "ls_c" 3 2
                     ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var"
                     , useRow "w" "oa" "pB" "ls_c" 3 "return"
                     ]
              edges = [ edge "oa" "pA" (Just 5) "oa" "pB" "arg"    "ls_b" "ls_b" "ls_c" ]
              confirmed = taintConfirmed sources sinks (intraEdgesFromDefUse defs uses) defs uses edges
          in length confirmed @?= 1
      ]
  , testGroup "taintReachesPairs"
      [ testCase "linear chain: source pinned to x, y ranges over both hops" $
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5) ]
              defs = [ defRow "w" "oa" "pA" "ls_b" 5 0 ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var" ]
              edges = [] :: [InterprocEdge]
              srcT = ("oa", "pA", "ls_a")
              bT   = ("oa", "pA", "ls_b")
          in Set.fromList (taintReachesPairs sources (intraEdgesFromDefUse defs uses) defs uses edges)
               @?= Set.fromList [ (srcT, bT) ]
      , testCase "isolated source (zero outgoing edges) produces zero pairs" $
          let sources = [ src "w" "oa" "pA" "ls_orphan" (Just 9) ]
          in taintReachesPairs sources [] [] [] [] @?= []
      , testCase "cycle through the seed: source reachable back to itself" $
          -- ls_a -> ls_b (def-use same line) and ls_b -> ls_a (return edge
          -- back into the same var) forms a genuine 2-node cycle rooted at
          -- the source. Souffle's taint_reaches(x, y) rule has no 0-hop
          -- base case, but a REAL cycle back to x is a legitimate 2-hop
          -- derivation -- taintReachesPairs must reproduce (srcT, srcT)
          -- here, not just skip self-pairs unconditionally.
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5) ]
              defs = [ defRow "w" "oa" "pA" "ls_b" 5 0 ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var"
                     , useRow "w" "oa" "pA" "ls_b" 3 "return"
                     ]
              edges = [ edge "oa" "pA" (Just 3) "oa" "pA" "return" "ls_a" "ls_a" "ls_a" ]
              srcT = ("oa", "pA", "ls_a")
              bT   = ("oa", "pA", "ls_b")
          in Set.fromList (taintReachesPairs sources (intraEdgesFromDefUse defs uses) defs uses edges)
               @?= Set.fromList [ (srcT, bT), (srcT, srcT) ]
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
          in null (taintWitnesses sources (intraEdgesFromDefUse defs uses) defs uses edges) @?= False
      ]

  , testGroup "Move 2 parity: EffTerm fold vs same-line join (Plan 182, 2026-07-18)"
    [ testCase "y = x + 1 (single stmt): foldTaintEdgesEff matches intraEdgesFromDefUse" $
        let defs = [ defRow "w" "oa" "pA" "y" 5 0 ]
            uses = [ useRow "w" "oa" "pA" "x" 5 "var" ]
            body = [ Located 5 (BsAssign (Lvalue [LvSegment (mkIdent "y") Nothing])
                       (ExBinOp (lvExpr "x") BopAdd (ExInt "1"))) ]
            term = compileProcedureToEff emptyEnv Set.empty body
            fromRows = Set.fromList (intraEdgesFromDefUse defs uses)
            fromFold = Set.fromList
              [ TaintIntraEdgeRow "oa" "pA" u d | (u, d) <- Set.toList (foldTaintEdgesEff term) ]
        in fromFold @?= fromRows
    ]
  ]

