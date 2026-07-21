{-# LANGUAGE OverloadedStrings #-}
module SSATest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Ident        (mkIdent)
import PB.AST.Expr         (BinOp (..), Expr (..), LvSegment (..), Lvalue (..),
                            DispatchExpr (..), DispatchMode (..))
import PB.AST.Located      (Located (..))
import PB.AST.Type          (PbType (..))
import PB.Compile.SSA
import PB.Analysis.TypeEnv  (ScopedTypeEnv (..))
import PB.Analysis.CallClassify (CallKind (..), classifyExpr)
import PB.Lexing.Token      (Token (..), TokenKind (..), SourceSpan (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Control.Exception     (evaluate)
import System.CPUTime        (getCPUTime)
import Test.Tasty            (TestTree, testGroup)
import Test.Tasty.HUnit      (assertBool, assertEqual, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n = Located n

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment (mkIdent n) Nothing]

intTok :: Text -> Token
intTok t = Token TkIntLiteral t (SourceSpan 1 1 1)

strTok :: Text -> Token
strTok t = Token TkStringDouble t (SourceSpan 1 1 1)

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty "" Map.empty

blockCount :: SsaProc -> Int
blockCount = Map.size . spBlocks

allVarNames :: SsaProc -> [Text]
allVarNames = map svName . spVars

getBlock :: SsaProc -> Text -> SsaBlock
getBlock sa lbl = case Map.lookup lbl (spBlocks sa) of
  Just b  -> b
  Nothing -> error ("block not found: " <> show lbl)

-- | N sequential guard-clause ifs (@if true then x = 1 end if@, no else),
-- all reassigning the same variable — the "ordinary but pathological" shape
-- (validation functions with many guard clauses in a row, real corpus style)
-- that stresses 'buildSsa''s dominator/dominance-frontier convergence: each
-- if adds one more merge point whose correct idom depends on the previous
-- one's already being resolved.
guardChain :: Int -> [Located BodyStmt]
guardChain n =
  [ at i (BsIf (IfStmt (ExBool True)
      [at i (BsAssign (lv1 "x") (ExInt "1"))]
      []
      Nothing))
  | i <- [1 .. n]
  ]

entryBlock :: SsaProc -> SsaBlock
entryBlock sa = getBlock sa (spEntry sa)

termSuccessors :: SsaTerm -> [Text]
termSuccessors (SsaGoto dst)          = [dst]
termSuccessors (SsaBranch _ t f)      = [t, f]
termSuccessors (SsaSwitch _ pairs d)  = d : map snd pairs
termSuccessors (SsaReturn _)          = []
termSuccessors SsaBreak               = []
termSuccessors SsaContinue            = []

isBranchTerm :: SsaTerm -> Bool
isBranchTerm (SsaBranch {}) = True
isBranchTerm _              = False

isBareReturnTerm :: SsaTerm -> Bool
isBareReturnTerm (SsaReturn Nothing) = True
isBareReturnTerm _                   = False

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
          [_, SsaAssign _ rhs _] -> case rhs of
            SsaBinOp _ (SsaVarRef sv) _ -> svName sv @?= "x"
            _ -> assertBool "expected SsaBinOp with SsaVarRef" False
          other -> assertBool ("expected two assigns, got " <> show (length other)) (length other == 2)

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

    -- Plan 146 Phase 2k: 'stmtToAssigns'/'stmtVarName' used to lowercase a
    -- BsLocalVar's declared name (e.g. "lb_First" -> "lb_first") while every
    -- other assignment-producing BodyStmt preserved case verbatim — the same
    -- class of bug as Phase 2c/2d's stray case-folding, breaking
    -- --dual-trace equivalence against the old compiler's never-lowercasing
    -- InstrGraph.
    , testCase "local var with init preserves declared case" $ do
        let sa = buildSsa emptyEnv "proc"
                  [at 1 (BsLocalVar [] (PtPrimitive "boolean") "lb_First" (Just (ExBool True)))]
        allVarNames sa @?= ["lb_First"]

    -- Plan 146 Phase 2k: 'exprToSsaVal's 'ExLvalue' case used to collapse ANY
    -- lvalue RHS (including multi-segment/subscripted member access like
    -- "adw_dw.object.level[al_row]") down to a bare 'SsaVarRef' on just its
    -- head segment — silently reading whatever the head variable's own
    -- current value happens to be instead of the real property/array
    -- element. Only a plain, single-segment, no-subscript reference is a
    -- genuine SSA-tracked variable read; anything else must stay an opaque
    -- 'SsaConst' expression, matching the old compiler (which never
    -- simplifies a RHS at all).
    , testCase "multi-segment lvalue RHS is not collapsed to its head variable" $ do
        let rhsLv = Lvalue [LvSegment "adw_dw" Nothing, LvSegment "object" Nothing, LvSegment "level" (Just ["al_row"])]
            sa = buildSsa emptyEnv "proc"
                  [at 1 (BsAssign (lv1 "li_level") (ExLvalue rhsLv))]
        case sbAssigns (entryBlock sa) of
          [SsaAssign _ (SsaConst (ExLvalue lv)) _] -> lv @?= rhsLv
          other -> assertBool ("expected one SsaConst-wrapped assign, got " <> show other) False

    , testCase "subscripted single-segment lvalue RHS is not collapsed either" $ do
        let rhsLv = Lvalue [LvSegment "la_items" (Just ["1"])]
            sa = buildSsa emptyEnv "proc"
                  [at 1 (BsAssign (lv1 "x") (ExLvalue rhsLv))]
        case sbAssigns (entryBlock sa) of
          [SsaAssign _ (SsaConst (ExLvalue lv)) _] -> lv @?= rhsLv
          other -> assertBool ("expected one SsaConst-wrapped assign, got " <> show other) False

    , testCase "plain single-segment lvalue RHS still becomes SsaVarRef" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
                  , at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
                  ]
        case sbAssigns (entryBlock sa) of
          [_, SsaAssign _ (SsaVarRef sv) _] -> svName sv @?= "x"
          other -> assertBool ("expected SsaVarRef, got " <> show other) False

    , testCase "BsAugAssign/BsInc/BsDec lower to SsaAssign using declared-casing var name" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsAugAssign (lv1 "N") AugAdd [intTok "1"])
                  , at 2 (BsInc (lv1 "N"))
                  , at 3 (BsDec (lv1 "N"))
                  ]
        allVarNames sa @?= ["N", "N", "N"]

    , testCase "BsAugAssign on member-chain lvalue lowers via ExLvalue, not ExRaw" $ do
        let memberLv = Lvalue [LvSegment "this" Nothing, LvSegment "count" Nothing]
            sa = buildSsa emptyEnv "proc"
                  [at 1 (BsAugAssign memberLv AugAdd [intTok "1"])]
        case sbAssigns (entryBlock sa) of
          [SsaAssign _ (SsaBinOp _ (SsaConst (ExLvalue lv)) _) _] -> lv @?= memberLv
          other -> assertBool ("expected SsaBinOp with SsaConst-wrapped ExLvalue, got " <> show other) False
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
    ]

  , testGroup "loops"
    [ testCase "for loop creates multiple blocks" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))]))]
        assertBool "has multiple blocks" (blockCount sa >= 3)

    , testCase "for loop header block gets SsaBranch, not a bare SsaReturn (Plan 145 block-collapse)" $ do
        -- CfgBuild.lowerFor flushes the raw BsFor node onto the *predecessor*
        -- block and gives the actual condition/header block zero statements
        -- of its own. cfgTermToSsa used to look for a control statement only
        -- in the header block's own stmts, find none, and fall back to
        -- `SsaReturn Nothing` (since the header has two edges, not one) —
        -- silently terminating the whole procedure at the first loop.
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExInt "10") Nothing
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))]))]
            terms = map sbTerm (Map.elems (spBlocks sa))
        assertBool "some block has a branch (the loop condition check)"
          (any isBranchTerm terms)
        -- Exactly one block may legitimately be a bare `return nothing` — the
        -- true end-of-procedure exit after the loop. The bug produced a
        -- *second* one at the loop header, silently truncating everything
        -- downstream of it.
        assertEqual "only the true end-of-procedure exit is a bare return"
          1 (length (filter isBareReturnTerm terms))

    , testCase "do-while loop header block gets SsaBranch, not a bare SsaReturn (Plan 145 block-collapse)" $ do
        -- Same root cause as the BsFor case above: lowerDo's top-condition
        -- variant creates an empty header block with two edges.
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsDo (DoStmt (Just (DoWhile (ExBool True)))
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))] Nothing))]
            terms = map sbTerm (Map.elems (spBlocks sa))
        assertBool "some block has a branch (the loop condition check)"
          (any isBranchTerm terms)
        assertEqual "only the true end-of-procedure exit is a bare return"
          1 (length (filter isBareReturnTerm terms))

    , testCase "do-loop-until (bottom-tested) header block gets SsaBranch, not just an unconditional goto (Plan 146 Phase 2e)" $ do
        -- CfgBuild.lowerDo's bottom-condition variant used to emit a single
        -- unconditional edge straight from the body's exit to the merge
        -- block (mislabeled "loop"), with no condition-test block at all —
        -- the loop body always ran exactly once regardless of the actual
        -- condition. The fix mirrors the top-tested case: a real condId
        -- block (reached after the body) with its own SsaBranch, back to
        -- the body on "keep looping" and out to the merge block otherwise.
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsDo (DoStmt Nothing
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))]
                      (Just (DoUntil (ExBool True)))))]
            terms = map sbTerm (Map.elems (spBlocks sa))
        assertBool "some block has a branch (the loop condition check)"
          (any isBranchTerm terms)
        assertEqual "only the true end-of-procedure exit is a bare return"
          1 (length (filter isBareReturnTerm terms))

    , testCase "for loop's init assign carries to/step as saLhs, not just from as saRhs" $ do
        -- saRhs is the loop var's real assigned value (from alone); to/step
        -- are loop-bound reads that matter for taint but aren't part of
        -- that value, so they must still surface somewhere for
        -- PB.Analysis.TaintEdges to see -- see SsaAssign's own doc comment.
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExLvalue (lv1 "n")) (Just (ExLvalue (lv1 "step_var")))
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))]))]
        case sbAssigns (entryBlock sa) of
          [SsaAssign _ _ lhs] -> lhs @?= ExArray [ExLvalue (lv1 "n"), ExLvalue (lv1 "step_var")]
          other -> assertBool ("expected one SsaAssign with an ExArray saLhs, got " <> show other) False

    , testCase "for loop's init assign with no step: saLhs carries just to" $ do
        let sa = buildSsa emptyEnv "proc"
                  [ at 1 (BsFor (ForStmt (lv1 "i") (ExInt "1") (ExLvalue (lv1 "n")) Nothing
                      [at 2 (BsAssign (lv1 "x") (ExInt "0"))]))]
        case sbAssigns (entryBlock sa) of
          [SsaAssign _ _ lhs] -> lhs @?= ExArray [ExLvalue (lv1 "n")]
          other -> assertBool ("expected one SsaAssign with an ExArray saLhs, got " <> show other) False
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

    ]

  , testGroup "scaling (Plan 150 follow-up)"
    [ testCase "wide sequential guard-clause chain builds fast, not O(blocks^2-3)" $ do
        -- Regression for the buildSsa residual-cost finding logged after Plan
        -- 150: computeIdom/computeDF's fixed-point loops processed blocks in
        -- arbitrary (CFG-declaration) order instead of reverse postorder, so
        -- convergence needed up to O(blocks) passes instead of the ~2-3 the
        -- Cooper/Harvey/Kennedy algorithm guarantees under RPO+Gauss-Seidel
        -- ordering, and computeDF used an unnecessary fixed point at all
        -- (it now computes directly from idom, Cytron et al.'s algorithm).
        -- A real corpus procedure with ~150-200 blocks (fn_dateolografos,
        -- 6 sequential choose-case blocks) took ~9s pre-fix; this synthetic
        -- 300-guard-clause chain is wider still and must stay well under
        -- that (hand-traced post-fix: real fn_dateolografos now ~0.01s).
        let n = 300 :: Int
            sa = buildSsa emptyEnv "wide_guard_chain" (guardChain n)
        start <- getCPUTime
        _ <- evaluate (length (show sa))
        end <- getCPUTime
        let elapsedSecs = fromIntegral (end - start) / (1e12 :: Double)
        assertBool
          ("buildSsa on a " <> show n <> "-guard-clause chain took "
             <> show elapsedSecs <> "s; must stay well under 5s")
          (elapsedSecs < 5)
    ]

  , testGroup "buildSsa per-variant (Plan 145 Phase 3)"
    -- Fills in the Step 3A table rows not already covered above (BsAssign,
    -- BsIf both variants, BsFor are covered by "linear code"/"if/else"/"loops").
    -- BsTry is deliberately absent: PB.Analysis.Cfg has no lowerTry (unlike
    -- lowerIf/lowerFor/lowerDo/lowerChoose), so a BsTry statement's tryBody is
    -- never split into blocks and stmtToAssigns's catch-all silently drops the
    -- whole try/catch — a CfgBuild-level gap, not an SSA-layer one. Logged to
    -- BACKLOG.md and doc/plan/145-dual-cps-debug.md rather than fixed here.
    [ testCase "BsReturn (Just expr) → SsaReturn (Just ...) terminator" $ do
        let sa = buildSsa emptyEnv "proc" [at 1 (BsReturn (Just (ExInt "1")))]
        sbTerm (entryBlock sa) @?= SsaReturn (Just (SsaConst (ExInt "1")))

    , testCase "BsCall (ExCall) → assign with SsaConst (ExCall ...)" $ do
        let callExpr = ExCall { callee = lv1 "messagebox", callArgs = [] }
            sa       = buildSsa emptyEnv "proc" [at 1 (BsCall callExpr)]
        case sbAssigns (entryBlock sa) of
          [SsaAssign _ (SsaConst e) _] -> e @?= callExpr
          other -> assertBool ("expected one SsaConst assign, got: " <> show other) False

    , testCase "BsDo (while) creates multiple blocks (entry/header/body/exit)" $ do
        let sa = buildSsa emptyEnv "proc"
                  [at 1 (BsDo (DoStmt (Just (DoWhile (ExBool True)))
                      [at 2 (BsAssign (lv1 "x") (ExInt "1"))] Nothing))]
        assertBool "has multiple blocks" (blockCount sa >= 3)

    , testCase "BsChoose creates entry + clause blocks + exit" $ do
        let clauses = [ CaseClause (Just []) [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
                      , CaseClause Nothing    [at 3 (BsAssign (lv1 "x") (ExInt "2"))]
                      ]
            sa = buildSsa emptyEnv "proc" [at 1 (BsChoose (ChooseStmt (ExInt "1") clauses))]
        assertBool "has at least entry + 2 clause blocks + exit" (blockCount sa >= 4)

    , testCase "BsChoose 3 clauses, no else (Plan 146 Bug B) → SsaSwitch with 3 pairs, distinct default" $ do
        let clauses = [ CaseClause (Just [intTok "1"]) [at 2 (BsAssign (lv1 "x") (ExInt "10"))]
                      , CaseClause (Just [intTok "2"]) [at 3 (BsAssign (lv1 "x") (ExInt "20"))]
                      , CaseClause (Just [intTok "3"]) [at 4 (BsAssign (lv1 "x") (ExInt "30"))]
                      ]
            sa = buildSsa emptyEnv "proc" [at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))]
        case sbTerm (entryBlock sa) of
          SsaSwitch scrutinee pairs def -> do
            scrutinee @?= SsaVarRef (SsaVar "y")
            map fst pairs @?= [SsaConst (ExInt "1"), SsaConst (ExInt "2"), SsaConst (ExInt "3")]
            assertBool "default target is not one of the clause targets"
              (def `notElem` map snd pairs)
            assertBool "default target is a real block" (Map.member def (spBlocks sa))
          other -> assertBool ("expected SsaSwitch, got: " <> show other) False

    , testCase "BsChoose with case-else → SsaSwitch default targets the else clause's block" $ do
        let clauses = [ CaseClause (Just [intTok "1"]) [at 2 (BsAssign (lv1 "x") (ExInt "10"))]
                      , CaseClause Nothing              [at 3 (BsAssign (lv1 "x") (ExInt "99"))]
                      ]
            sa = buildSsa emptyEnv "proc" [at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))]
        case sbTerm (entryBlock sa) of
          SsaSwitch _ pairs def -> do
            length pairs @?= 1
            case Map.lookup def (spBlocks sa) of
              Just defBlock -> case sbAssigns defBlock of
                [SsaAssign sv (SsaConst (ExInt "99")) _] -> svName sv @?= "x"
                other -> assertBool ("expected one assign of 99 to x, got: " <> show other) False
              Nothing -> assertBool "default block must exist" False
          other -> assertBool ("expected SsaSwitch, got: " <> show other) False

    , testCase "BsChoose clause value parsed via real parseExpr, not raw ExRaw (string literal clause)" $ do
        let clauses = [ CaseClause (Just [strTok "\"a\""]) [at 2 (BsAssign (lv1 "x") (ExInt "1"))]
                      , CaseClause Nothing                  [at 3 (BsAssign (lv1 "x") (ExInt "2"))]
                      ]
            sa = buildSsa emptyEnv "proc" [at 1 (BsChoose (ChooseStmt (ExLvalue (lv1 "y")) clauses))]
        case sbTerm (entryBlock sa) of
          SsaSwitch _ [(val, _)] _ -> val @?= SsaConst (ExStr "a")
          other -> assertBool ("expected SsaSwitch with one pair, got: " <> show other) False

    , testCase "BsPbCall (call ancestor::event) → assign with synthetic ExCall (Plan 145 Phase 1C fix)" $ do
        let sa = buildSsa emptyEnv "proc" [at 1 (BsPbCall (PbCall "m_ole_frame" "destroy"))]
        case sbAssigns (entryBlock sa) of
          [SsaAssign sv (SsaConst (ExCall lv [])) _] -> do
            svName sv @?= "_"
            map (\(LvSegment n _) -> n) (segments lv) @?= ["m_ole_frame::destroy"]
          other -> assertBool ("expected one SsaConst ExCall assign, got: " <> show other) False

    -- BsCall (ExDispatch) — standalone `.Post`/`.Trigger`/`Dynamic ... Event(...)`
    -- (PB's inter-object messaging idiom). stmtToAssigns's BsCall case is
    -- expr-agnostic (SsaAssign (SsaVar "_") (SsaConst expr) regardless of
    -- expr's constructor), so this already worked before Plan 145's ExDispatch
    -- fix — the confirmed bug was one layer down, in CatOp.compileAssign. Kept
    -- here as an explicit regression guard for the SSA layer's expr-agnosticism.
    , testCase "BsCall (ExDispatch) → assign with SsaConst (ExDispatch ...)" $ do
        let dispatchExpr = ExDispatch (DispatchExpr
              { object = Just (lv1 "ParentWindow"), mode = DmPost, dynamic = True
              , event = False, name = "of_run_report", args = [] })
            sa = buildSsa emptyEnv "proc" [at 1 (BsCall dispatchExpr)]
        case sbAssigns (entryBlock sa) of
          [SsaAssign sv (SsaConst e) _] -> do
            svName sv @?= "_"
            e @?= dispatchExpr
          other -> assertBool ("expected one SsaConst ExDispatch assign, got: " <> show other) False
    ]

  , testGroup "classifyExpr effect names"
    [ testCase "dw_foo.retrieve() → SuspendCall" $
        classifyExpr
          ScopedTypeEnv { steGlobal = Map.singleton "dw_foo" (PtPrimitive "datawindow")
                        , steInstance = Map.empty, steLocal = Map.empty, steHierarchy = Map.empty
                        , steObject = "", steControlIndex = Map.empty, steParams = Set.empty }
          (ExCall { callee = Lvalue [LvSegment "dw_foo" Nothing, LvSegment "retrieve" Nothing], callArgs = [] })
          @?= SuspendCall

    , testCase "commit() with Transaction type → SuspendCall" $
        classifyExpr
          ScopedTypeEnv { steGlobal = Map.singleton "sqlca" (PtPrimitive "transaction")
                        , steInstance = Map.empty, steLocal = Map.empty, steHierarchy = Map.empty
                        , steObject = "", steControlIndex = Map.empty, steParams = Set.empty }
          (ExCall { callee = Lvalue [LvSegment "sqlca" Nothing, LvSegment "commit" Nothing], callArgs = [] })
          @?= SuspendCall

    , testCase "free function my_func() → PureCall" $
        classifyExpr emptyEnv
          (ExCall { callee = lv1 "my_func", callArgs = [] })
          @?= PureCall

    , testCase "non-call expression → PureCall" $
        classifyExpr emptyEnv (ExInt "1")
          @?= PureCall
    ]
  ]
