module CfgTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Located      (Located (..))
import PB.Analysis.Cfg
import PB.Lexing.Token     (Token (..), TokenKind (..), SourceSpan (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- | Block ids reachable from 'cfgEntry' by following 'cfgEdges' — used to
-- confirm a block genuinely participates in the compiled control flow (vs.
-- existing only as an allocated-but-orphaned 'CfgBlock', the shape a catch
-- body deliberately produces).
reachableFrom :: Cfg -> Set.Set Text
reachableFrom g = go (Set.singleton (cfgEntry g)) [cfgEntry g]
  where
    adj = Map.fromListWith (++) [(ceSrc e, [ceDst e]) | e <- cfgEdges g]
    go seen []     = seen
    go seen (b:bs) =
      let next = filter (`Set.notMember` seen) (Map.findWithDefault [] b adj)
      in go (Set.union seen (Set.fromList next)) (next ++ bs)

-- Helper to build a Located with a dummy line number.
at :: Int -> a -> Located a
at n x = Located n x

-- A minimal lvalue with one segment.
lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment n Nothing]

-- A minimal int-literal token for case-clause values.
tok :: Text -> Token
tok t = Token TkIntLiteral t (SourceSpan 1 1 1)

tests :: TestTree
tests = testGroup "CfgBuild"
  [ testCase "empty body → single entry block, no exits, no edges" $ do
      let g = buildCfg []
      length (cfgBlocks g) @?= 1
      cfgExits g         @?= []
      cfgEdges g         @?= []

  , testCase "single BsAssign → placed in entry block, no exits" $ do
      let stmt = at 1 (BsAssign (lv1 "x") (ExInt "1"))
          g    = buildCfg [stmt]
      length (cfgBlocks g) @?= 1
      case cfgBlocks g of
        (b0:_) -> length (cbStmts b0) @?= 1
        []     -> assertBool "expected at least one block" False
      cfgExits g          @?= []
      cfgEdges g          @?= []

  , testCase "BsIf → T/F edges plus merge block" $ do
      let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
          stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [] Nothing))
          g     = buildCfg [stmt]
      -- entry, then-entry, merge, plus T edge from entry → then, F edge entry → merge
      let edgeLabels = map ceLabel (cfgEdges g)
      elem "T" edgeLabels @?= True
      elem "F" edgeLabels @?= True
      length (cfgBlocks g) @?= 3

  , testCase "BsFor → cond block, body block, post block, loop back edge" $ do
      let bodyS = [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
          stmt  = at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing bodyS))
          g     = buildCfg [stmt]
      let edgeLabels = map ceLabel (cfgEdges g)
      elem "T" edgeLabels   @?= True
      elem "F" edgeLabels   @?= True
      elem "loop" edgeLabels @?= True

  , testGroup "BsDo bottom-tested (Plan 146 Phase 2e: missing back-edge)"
    -- lowerDo's bottom-condition branch used to emit a single unconditional
    -- edge straight from the body's exit to the merge block (mislabeled
    -- "loop"), with no condition-test block and no back-edge at all — the
    -- loop body ran exactly once, no matter what the condition evaluated to.
    [ testCase "DO ... LOOP UNTIL → real T/F branch edges (not just an unconditional exit)" $ do
        let bodyS = [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
            stmt  = at 1 (BsDo (DoStmt Nothing bodyS (Just (DoUntil (ExBool True)))))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        assertBool ("expected a \"T\" edge (back to the loop body), got labels: " <> show edgeLabels)
          (elem "T" edgeLabels)
        assertBool ("expected an \"F\" edge (exit to merge), got labels: " <> show edgeLabels)
          (elem "F" edgeLabels)

    , testCase "DO ... LOOP WHILE → same T/F branch shape as UNTIL" $ do
        let bodyS = [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
            stmt  = at 1 (BsDo (DoStmt Nothing bodyS (Just (DoWhile (ExBool True)))))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        elem "T" edgeLabels @?= True
        elem "F" edgeLabels @?= True
    ]

  , testCase "BsReturn → block added to cfgExits" $ do
      let stmt = at 1 (BsReturn Nothing)
          g    = buildCfg [stmt]
      length (cfgExits g) @?= 1

  , testGroup "BsIf elseif chain (Plan 146: each elseif must test its own condition)"
    -- 'lowerIf' never referenced 'eifCond' at all — every elseif body was
    -- wired as unconditionally reachable once the prior test failed (an
    -- unconditional "F" edge straight into the elseif's body block, with no
    -- test of the elseif's own condition anywhere). Confirmed via hand-trace
    -- of a real corpus --dual-trace diff (w_dwtostr::of_create_structure_export).
    [ testCase "single elseif -> two independent T/F pairs (outer if + elseif), not one" $ do
        let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
            eiS   = [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
            stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS [ElseIf (ExBool False) eiS] Nothing))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        length (filter (== "T") edgeLabels) @?= 2
        length (filter (== "F") edgeLabels) @?= 2

    , testCase "elseif's own condition survives into the CFG as a real test block" $ do
        let thenS  = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
            eiCond = ExLvalue (lv1 "flag")
            eiS    = [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
            stmt   = at 1 (BsIf (IfStmt (ExBool True) thenS [ElseIf eiCond eiS] Nothing))
            g      = buildCfg [stmt]
            isMarker blk = case cbStmts blk of
              [Located _ (BsIf (IfStmt c [] [] Nothing))] -> c == eiCond
              _ -> False
        assertBool "expected exactly one block carrying the elseif's own condition as a marker"
          (length (filter isMarker (cfgBlocks g)) == 1)

    , testCase "two chained elseifs -> three independent T/F pairs (outer if + 2 elseifs)" $ do
        let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
            ei1S  = [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
            ei2S  = [at 4 (BsAssign (lv1 "z") (ExInt "3"))]
            stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS
                          [ ElseIf (ExBool False) ei1S, ElseIf (ExBool False) ei2S ] Nothing))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        length (filter (== "T") edgeLabels) @?= 3
        length (filter (== "F") edgeLabels) @?= 3

    , testCase "elseif chain with no final else -> exactly one test block per elseif" $ do
        let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
            ei1S  = [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
            ei2S  = [at 4 (BsAssign (lv1 "z") (ExInt "3"))]
            stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS
                          [ ElseIf (ExBool False) ei1S, ElseIf (ExBool False) ei2S ] Nothing))
            g     = buildCfg [stmt]
            isMarker blk = case cbStmts blk of
              [Located _ (BsIf (IfStmt _ [] [] Nothing))] -> True
              _ -> False
        length (filter isMarker (cfgBlocks g)) @?= 2

    , testCase "each elseif body block has exactly one outgoing edge (to merge), not a second chain edge" $ do
        -- Before the fix, an elseif's own body block doubled as the chain
        -- link to the *next* elseif, giving it two outgoing edges — which
        -- makes cfgTermToSsa's single-edge fallback default to
        -- 'SsaReturn Nothing', silently truncating the procedure the moment
        -- a non-final elseif clause matches.
        let thenS = [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
            ei1S  = [at 3 (BsAssign (lv1 "y") (ExInt "2"))]
            ei2S  = [at 4 (BsAssign (lv1 "z") (ExInt "3"))]
            stmt  = at 1 (BsIf (IfStmt (ExBool True) thenS
                          [ ElseIf (ExBool False) ei1S, ElseIf (ExBool False) ei2S ] Nothing))
            g     = buildCfg [stmt]
            isEi1Body blk = case cbStmts blk of
              [Located 3 (BsAssign _ (ExInt "2"))] -> True
              _ -> False
            outgoing bid = [ e | e <- cfgEdges g, ceSrc e == bid ]
        case filter isEi1Body (cfgBlocks g) of
          [blk] -> length (outgoing (cbId blk)) @?= 1
          _     -> assertBool "expected exactly one block holding the first elseif's body" False
    ]

  , testGroup "BsChoose (Plan 146 Bug B: default-edge gap)"
    [ testCase "no case-else clause → explicit \"default\" edge from header to merge block" $ do
        let clauses = [ CaseClause (Just [tok "1"]) [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
                      , CaseClause (Just [tok "2"]) [at 3 (BsAssign (lv1 "x") (ExInt "2"))]
                      ]
            stmt = at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))
            g    = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        assertBool ("expected a \"default\" edge, got labels: " <> show edgeLabels)
          (elem "default" edgeLabels)

    , testCase "case-else clause present → no synthetic \"default\" edge" $ do
        let clauses = [ CaseClause (Just [tok "1"]) [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
                      , CaseClause Nothing          [at 3 (BsAssign (lv1 "x") (ExInt "2"))]
                      ]
            stmt = at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))
            g    = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        assertBool ("expected no \"default\" edge, got labels: " <> show edgeLabels)
          (notElem "default" edgeLabels)
    ]

  , testGroup "BsTry (Plan 146 Phase 3 follow-on: try-body statements reach the CFG)"
    -- The generic statement dispatcher used to treat a whole
    -- `try...catch...end try` block as one opaque pending statement (the
    -- same fallback every non-control BodyStmt hits) — the try-body's own
    -- assigns/calls never became real CfgBlock content, so
    -- 'PB.Analysis.SSA.stmtToAssigns's `BsTry {} -> []` silently dropped
    -- them from SSA entirely. The old compiler (PB.Analysis.CpsGraph)
    -- compiles the try-body sequentially and each catch body as
    -- independently-reachable dead code (no static exception edge) — this
    -- fix gives CfgBuild the same shape: the try-body continues the current
    -- block chain like ordinary statements, and each catch body lowers into
    -- its own fresh, disconnected block never reached from cfgEntry.
    [ testCase "try-body assign is real CFG content, reachable from cfgEntry" $ do
        let stmt = at 1 (BsTry (TryStmt [at 2 (BsAssign (lv1 "x") (ExInt "1"))] []))
            g    = buildCfg [stmt]
            reachable = reachableFrom g
            isTryAssign blk = cbId blk `Set.member` reachable
                            && any (\l -> locNode l == BsAssign (lv1 "x") (ExInt "1")) (cbStmts blk)
        assertBool "expected the try-body's own assign in a block reachable from cfgEntry"
          (any isTryAssign (cfgBlocks g))

    , testCase "catch-body assign exists in the CFG but is unreachable from cfgEntry" $ do
        let catches = [CatchClause "Exception" "e" [at 3 (BsAssign (lv1 "y") (ExInt "2"))]]
            stmt    = at 1 (BsTry (TryStmt [at 2 (BsAssign (lv1 "x") (ExInt "1"))] catches))
            g       = buildCfg [stmt]
            reachable = reachableFrom g
            hasCatchAssign blk = any (\l -> locNode l == BsAssign (lv1 "y") (ExInt "2")) (cbStmts blk)
        case filter hasCatchAssign (cfgBlocks g) of
          [blk] -> assertBool "expected the catch-body's block to be unreachable from cfgEntry"
                     (cbId blk `Set.notMember` reachable)
          found -> assertBool ("expected exactly one block holding the catch body's assign, found "
                                 <> show (length found)) False

    , testCase "nested if inside a try-body still lowers with real branch edges" $ do
        let thenS = [at 3 (BsAssign (lv1 "x") (ExInt "1"))]
            stmt  = at 1 (BsTry (TryStmt [at 2 (BsIf (IfStmt (ExBool True) thenS [] Nothing))] []))
            g     = buildCfg [stmt]
            edgeLabels = map ceLabel (cfgEdges g)
        elem "T" edgeLabels @?= True
        elem "F" edgeLabels @?= True
    ]
  ]
