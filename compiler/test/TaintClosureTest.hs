module TaintClosureTest (tests, defRow, useRow, edge, src, snk, intraEdgesFromDefUse, returnRowsFromUses) where

-- | Unit and self-consistency tests for the algebraic taint closure.
-- Covers reachability, confirmed source-sink pairs, and witness-path
-- reconstruction across fixtures spanning all four edge rules (intra-proc
-- same-line def-use, arg, return, global-hub), plus the adversarial shapes
-- (duplicate-key sources/sinks, a cycle through the seed, a diamond, a
-- 0-hop source==sink pair). The algebraic closure is production's sole
-- implementation, so expected values here are golden (independently
-- traced/verified, not re-derived from a second implementation at test
-- time).
import PB.Prelude
import PB.Analysis.Taint
  ( DefRow (..)
  , UseRow (..)
  , InterprocEdge (..)
  , TaintSource (..)
  , TaintSink (..)
  )
import PB.Analysis.TaintClosure
  ( taintReachable
  , taintReachesPairs
  , taintConfirmed
  , taintWitnesses
  , taintWitnessLegs
  )
import PB.Analysis.TaintEdges (TaintIntraEdgeRow (..), TaintReturnRow (..), foldTaintEdgesEff)
import PB.AST.BodyStmt  (BodyStmt (..))
import PB.AST.Expr      (BinOp (..), Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident      (mkIdent)
import PB.AST.Located   (Located (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.Flatten (compileProcedureToEff)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, assertBool, assertEqual, assertFailure, (@?=))

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
-- 'PB.Analysis.TaintClosure.buildTaintSuccessors' derives from the
-- already-folded 'TaintEdges' output (Plan 182 Move 2, 2026-07-19).
-- Production now sources intra-proc edges from
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

-- | Test-only reimplementation of the same @urKind == \"return\"@ row
-- filter 'PB.Analysis.TaintClosure.buildTaintSuccessors' derives from the
-- already-folded 'TaintEdges' return rows (Plan 182 Move 2, 2026-07-19).
-- Production sources return rows from
-- 'PB.Analysis.TaintEdges.TaintReturnRow' (a term fact, not a row one).
-- Lets the existing hand-typed 'UseRow' fixtures below (which already tag
-- their return-kind rows) keep driving 'taintReachable'\/'taintReachesPairs'\/
-- 'taintConfirmed'\/'taintWitnesses' unchanged.
returnRowsFromUses :: [UseRow] -> [TaintReturnRow]
returnRowsFromUses uses =
  [ TaintReturnRow (urObject u) (urProcName u) (urVarName u)
  | u <- uses, urKind u == "return"
  ]

tests :: TestTree
tests = testGroup "TaintClosure"
  [ testGroup "taintReachable"
      [ testCase "reachability spans all four edge rules (intra/arg/return/global)" $
          -- Golden expected set (independently traced + cross-verified
          -- against the deleted BFS oracle in every CI run and the real
          -- openpay corpus gate before propagateTaint was removed, Plan
          -- 182 item 7-8, 2026-07-18): ls_a -(def)-> ls_b -(arg)-> ls_c
          -- in pB; the global chain g_x written in pW reaches the
          -- synthetic hub then pR.
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
              algSet = taintReachable sources (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges
              expected = Set.fromList
                [ ("", "global::g_x", "g_x"), ("oa", "pA", "ls_a"), ("oa", "pA", "ls_b")
                , ("oa", "pB", "ls_c"), ("oa", "pR", "g_x"), ("oa", "pW", "g_x")
                ]
          in algSet @?= expected
      , testCase "isolated source (zero outgoing edges) keeps its own 0-hop membership" $
          -- Plan 182 corpus finding (doc/plan/182-algebraic-analysis.md
          -- Section 11, 2026-07-18): a source var never subsequently
          -- used/passed/returned/globally-written must still count as
          -- tainted by definition -- taintRelation's interner used to
          -- omit any seed with no outgoing arcPairs, silently dropping
          -- it (confirmed on real corpus: 152/966 triples lost).
          let sources = [ src "w" "oa" "pA" "ls_orphan" (Just 9) ]
              algSet   = taintReachable sources [] [] []
          in algSet @?= Set.fromList [ ("oa", "pA", "ls_orphan") ]

      , testCase "intermediate def+use node expands (pure intra chain x->y->z)" $
          -- Move 2 regression guard (Plan 182 §18.4): the new fold-driven
          -- seed set must include intra-edge defVars (not just useVars), so
          -- an intermediate def that is also a use elsewhere expands and its
          -- own successors are reached. Source x; y = x+1 (def y, use x);
          -- z = y+1 (def z, use y). Intra edges: x->y, y->z. Reachable must
          -- be {x, y, z} -- if y failed to seed, z would be unreachable.
          let sources = [ src "w" "oa" "pA" "x" (Just 1) ]
              defs = [ defRow "w" "oa" "pA" "y" 1 0
                     , defRow "w" "oa" "pA" "z" 2 1
                     ]
              uses = [ useRow "w" "oa" "pA" "x" 1 "var"
                     , useRow "w" "oa" "pA" "y" 2 "var"
                     ]
              intra = intraEdgesFromDefUse defs uses
              rets  = returnRowsFromUses uses
              algSet = taintReachable sources intra rets []
              expected = Set.fromList
                [ ("oa", "pA", "x"), ("oa", "pA", "y"), ("oa", "pA", "z") ]
          in algSet @?= expected
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
              confirmed = taintConfirmed sources sinks (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges
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
          -- taint_confirmed is a SET keyed on the STRING
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
              confirmed = taintConfirmed sources sinks (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges
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
          in Set.fromList (taintReachesPairs sources (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges)
               @?= Set.fromList [ (srcT, bT) ]
      , testCase "isolated source (zero outgoing edges) produces zero pairs" $
          let sources = [ src "w" "oa" "pA" "ls_orphan" (Just 9) ]
          in taintReachesPairs sources [] [] [] @?= []
      , testCase "cycle through the seed: source reachable back to itself" $
          -- ls_a -> ls_b (def-use same line) and ls_b -> ls_a (return edge
          -- back into the same var) forms a genuine 2-node cycle rooted at
          -- the source. The taint_reaches(x, y) relation has no 0-hop
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
          in Set.fromList (taintReachesPairs sources (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges)
               @?= Set.fromList [ (srcT, bT), (srcT, srcT) ]
      , testCase "shared-hub fan-in: 2 sources x 1 hub x 2 sinks confirm all 4 pairs" $
          -- Regression guard for a production incident: a widely-shared
          -- global fans every writer/reader through one synthetic hub
          -- node instead of a direct cartesian product (see
          -- PB.Analysis.Taint's globalEdges doc comment). Both sources
          -- must reach both sinks THROUGH the hub, not just the hub
          -- itself.
          let sources = [ src "f" "obj" "proc_a" "ls_s1" (Just 1), src "f" "obj" "proc_a" "ls_s2" (Just 1) ]
              sinks   = [ snk "f" "obj" "proc_a" "ls_t1" (Just 1), snk "f" "obj" "proc_a" "ls_t2" (Just 1) ]
              edges =
                [ edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_s1" "ls_s1" "ls_h"
                , edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_s2" "ls_s2" "ls_h"
                , edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_h"  "ls_h"  "ls_t1"
                , edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_h"  "ls_h"  "ls_t2"
                ]
              s1 = ("obj", "proc_a", "ls_s1"); s2 = ("obj", "proc_a", "ls_s2")
              t1 = ("obj", "proc_a", "ls_t1"); t2 = ("obj", "proc_a", "ls_t2")
              confirmedKeys = Set.fromList
                [ ((tsObject s, tsProcName s, tsVarName s), (tskObject k, tskProcName k, tskVarName k))
                | (s, k) <- taintConfirmed sources sinks [] [] edges
                ]
          in confirmedKeys @?= Set.fromList [ (s1, t1), (s1, t2), (s2, t1), (s2, t2) ]
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
          in null (taintWitnesses sources (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges) @?= False
      , testCase "decomposed witness legs equal expected BFS legs (linear chain)" $
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5) ]
              defs = [ defRow "w" "oa" "pA" "ls_b" 5 0 ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var" ]
              edges = [ edge "oa" "pA" (Just 5) "oa" "pB" "arg" "ls_b" "ls_b" "ls_c" ]
              srcT = ("oa", "pA", "ls_a")
              midT = ("oa", "pA", "ls_b")
              dstT = ("oa", "pB", "ls_c")
              proj (f, t, k, _desc) = (f, t, k)
              legsFor = [ legs
                        | (s, d, legs) <- taintWitnessLegs sources (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges
                        , s == srcT, d == dstT
                        ]
          in map (map proj) legsFor @?= [ [ (srcT, midT, "def"), (midT, dstT, "arg") ] ]
      , testCase "diamond: two equal-length paths -- legs form a valid chain with matching hop count" $
          -- Datalog Rule Placement Discipline's adversarial-fixture
          -- requirement, applied to witness reconstruction: ls_a reaches
          -- ls_sink via two distinct 2-hop routes (through ls_x or ls_y).
          -- PathValue's hop-count tie-break may pick either branch --
          -- reconciliation with taint_step_kind tolerates that (see
          -- doc/plan/182-algebraic-analysis.md Section 12 item 4), so this
          -- only asserts structural validity (a real chain of real edges,
          -- correct hop count), not which branch won.
          let sources = [ src "w" "oa" "pA" "ls_a" (Just 5) ]
              defs = [ defRow "w" "oa" "pA" "ls_x" 5 0
                     , defRow "w" "oa" "pA" "ls_y" 6 1
                     ]
              uses = [ useRow "w" "oa" "pA" "ls_a" 5 "var"
                     , useRow "w" "oa" "pA" "ls_a" 6 "var"
                     ]
              edges = [ edge "oa" "pA" (Just 5) "oa" "pB" "arg" "ls_x" "ls_x" "ls_sink"
                     , edge "oa" "pA" (Just 6) "oa" "pB" "arg" "ls_y" "ls_y" "ls_sink"
                     ]
              srcT = ("oa", "pA", "ls_a")
              dstT = ("oa", "pB", "ls_sink")
              realEdges = Set.fromList
                [ (srcT, ("oa", "pA", "ls_x"), "def" :: Text)
                , (srcT, ("oa", "pA", "ls_y"), "def")
                , (("oa", "pA", "ls_x"), dstT, "arg")
                , (("oa", "pA", "ls_y"), dstT, "arg")
                ]
              legsFor = [ legs
                        | (s, d, legs) <- taintWitnessLegs sources (intraEdgesFromDefUse defs uses) (returnRowsFromUses uses) edges
                        , s == srcT, d == dstT
                        ]
          in case legsFor of
               [legs] ->
                 let proj (f, t, k, _desc) = (f, t, k)
                     projected = map proj legs
                     chainConnects = case projected of
                       [(f1, t1, _), (f2, t2, _)] -> f1 == srcT && t1 == f2 && t2 == dstT
                       _ -> False
                 in do
                      assertEqual "diamond witness has exactly 2 legs" 2 (length legs)
                      assertBool "diamond witness legs chain src->dst" chainConnects
                      assertBool "every diamond leg is a real edge" (all (`Set.member` realEdges) projected)
               other -> assertFailure ("expected exactly one (src,dst) witness entry, got " <> show (length other))
      , testCase "0-hop: confirmed pair with source == sink has an empty witness leg list" $
          -- Mirrors materializeTaintStepKind's degenerate-pair handling:
          -- taintWitnessLegs still emits an entry for the trivial 0-hop
          -- (src, src) pair (PathValue's 'one' identity), and its leg
          -- list must be empty -- there is no real edge to report.
          let sources = [ src "f" "obj" "proc_a" "ls_same" (Just 1) ]
              sinks   = [ snk "f" "obj" "proc_a" "ls_same" (Just 1) ]
              srcT    = ("obj", "proc_a", "ls_same")
              confirmed = taintConfirmed sources sinks [] [] []
              witnessLegs = taintWitnessLegs sources [] [] []
              legsFor = [ legs | (s, d, legs) <- witnessLegs, s == srcT, d == srcT ]
          in do
               assertEqual "0-hop pair is confirmed" 1 (length confirmed)
               assertEqual "0-hop witness has exactly one (src,src) entry" [[]] legsFor
      ]

  , testGroup "Move 2 parity: EffTerm fold vs same-line join (Plan 182, 2026-07-18)"
    [ testCase "y = x + 1 (single stmt): foldTaintEdgesEff matches intraEdgesFromDefUse" $
        let defs = [ defRow "w" "oa" "pA" "y" 5 0 ]
            uses = [ useRow "w" "oa" "pA" "x" 5 "var" ]
            body = [ Located 5 (BsAssign (Lvalue [LvSegment (mkIdent "y") Nothing])
                       (ExBinOp (lvExpr "x") BopAdd (ExInt "1"))) ]
            term = compileProcedureToEff emptyEnv Set.empty body
            fromRows = Set.fromList (intraEdgesFromDefUse defs uses)
            (edgePairs, _) = foldTaintEdgesEff term
            fromFold = Set.fromList
              [ TaintIntraEdgeRow "oa" "pA" u d | (u, d) <- Set.toList edgePairs ]
        in fromFold @?= fromRows
    ]

  , testGroup "Move 2b parity: EReturn payload vs UseRow return-kind (Plan 182b, 2026-07-18)"
    [ testCase "return x: foldTaintEdgesEff's returned-var set matches the row-derived one" $
        let uses = [ useRow "w" "oa" "pA" "x" 1 "return" ]
            body = [ Located 1 (BsReturn (Just (lvExpr "x"))) ]
            term = compileProcedureToEff emptyEnv Set.empty body
            fromRows = Set.fromList (returnRowsFromUses uses)
            (_, returnVars) = foldTaintEdgesEff term
            fromFold = Set.fromList
              [ TaintReturnRow "oa" "pA" v | v <- Set.toList returnVars ]
        in fromFold @?= fromRows
    ]
  ]

