module DeadVarsTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr    (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident   (mkIdent)
import PB.AST.Type    (PbType (..))
import PB.AST.Located (Located (..))
import PB.Analysis.Cfg      (Cfg (..), CfgBlock (..), CfgEdge (..))
import PB.Analysis.Dataflow (analyzeProcedure)
import PB.Analysis.DeadVars
import PB.Analysis.TypeResolve (LocalVar (..))

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment (mkIdent n) Nothing]

-- | A two-segment member-chain lvalue, e.g. @item.label@.
lv2 :: Text -> Text -> Lvalue
lv2 root field = Lvalue [LvSegment (mkIdent root) Nothing, LvSegment (mkIdent field) Nothing]

mkBlock :: Text -> [Located BodyStmt] -> CfgBlock
mkBlock bid stmts = CfgBlock
  { cbId        = bid
  , cbStmts     = stmts
  , cbFirstLine = Nothing
  , cbLastLine  = Nothing
  }

mkCfg :: Text -> [CfgBlock] -> [CfgEdge] -> Cfg
mkCfg entry blocks edges = Cfg
  { cfgEntry  = entry
  , cfgExits  = []
  , cfgBlocks = blocks
  , cfgEdges  = edges
  }

-- | A local var declaration (not a param), scoped at the given line.
localVar :: Text -> Int -> LocalVar
localVar n line = LocalVar
  { lvFile = "f.srw", lvObject = "obj", lvProcName = "proc"
  , lvVarName = n, lvRawType = "integer", lvIsParam = False
  , lvScopeLine = line, lvPbType = PtPrimitive "integer"
  }

-- | A parameter, scoped at the given line.
param :: Text -> Int -> LocalVar
param n line = (localVar n line) { lvIsParam = True }

kindsFor :: Text -> [DeadVarFinding] -> [DeadVarKind]
kindsFor v = map dvfKind . filter ((== v) . dvfVar)

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "DeadVars"

  [ testCase "declared-and-never-read local is flagged never-read" $
      let blk = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "li_x" (Just (ExInt "0")))]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 1] pf
      in kindsFor "li_x" fs @?= [NeverRead]

  , testCase "local var that is read is not flagged" $
      let blk = mkBlock "b0"
            [ at 1 (BsLocalVar [] (PtPrimitive "integer") "li_x" (Just (ExInt "0")))
            , at 2 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 1] pf
      in kindsFor "li_x" fs @?= []

  , testCase "var declared in entry block, read inside if-branch block, is not flagged (cross-block use)" $
      let entry = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "li_x" (Just (ExInt "0")))]
          thenB = mkBlock "b1" [at 2 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))]
          cfg   = mkCfg "b0" [entry, thenB] [CfgEdge "b0" "b1" "T"]
          pf    = analyzeProcedure "obj" "proc" cfg
          fs    = findDeadVars [localVar "li_x" 1] pf
      in kindsFor "li_x" fs @?= []

  , testCase "declared-then-immediately-assigned local is not flagged overwritten-before-read" $
      let blk = mkBlock "b0"
            [ at 1 (BsLocalVar [] (PtPrimitive "integer") "li_x" Nothing)
            , at 2 (BsAssign (lv1 "li_x") (ExInt "5"))
            , at 3 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 1] pf
      in kindsFor "li_x" fs @?= []

  , testCase "same-block reassignment with no intervening read is overwritten-before-read" $
      let blk = mkBlock "b0"
            [ at 1 (BsAssign (lv1 "li_x") (ExInt "1"))
            , at 2 (BsAssign (lv1 "li_x") (ExInt "2"))
            , at 3 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 0] pf
      in kindsFor "li_x" fs @?= [OverwrittenBeforeRead]

  , testCase "same-block reassignment WITH intervening read is not flagged" $
      let blk = mkBlock "b0"
            [ at 1 (BsAssign (lv1 "li_x") (ExInt "1"))
            , at 2 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))
            , at 3 (BsAssign (lv1 "li_x") (ExInt "2"))
            , at 4 (BsAssign (lv1 "li_z") (ExLvalue (lv1 "li_x")))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [] pf
      in kindsFor "li_x" fs @?= []

  , testCase "cross-block dead store: def in b0 killed by def in b1 with no use anywhere else" $
      let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "li_x") (ExInt "1"))]
          b1 = mkBlock "b1"
            [ at 2 (BsAssign (lv1 "li_x") (ExInt "2"))
            , at 3 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))
            ]
          cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 0] pf
      in kindsFor "li_x" fs @?= [OverwrittenBeforeRead]

  , testCase "end-of-procedure dead store: value assigned earlier, read, then reassigned and never read again" $
      let blk = mkBlock "b0"
            [ at 1 (BsAssign (lv1 "li_x") (ExInt "1"))
            , at 2 (BsAssign (lv1 "li_y") (ExLvalue (lv1 "li_x")))
            , at 3 (BsAssign (lv1 "li_x") (ExInt "2"))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 0] pf
      in kindsFor "li_x" fs @?= [OverwrittenBeforeRead]

  , testCase "unused parameter is flagged unused-param" $
      let blk = mkBlock "b0" [at 1 (BsReturn Nothing)]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [param "ai_unused" 0] pf
      in kindsFor "ai_unused" fs @?= [UnusedParam]

  , testCase "used parameter is not flagged" $
      let blk = mkBlock "b0" [at 1 (BsReturn (Just (ExLvalue (lv1 "ai_used"))))]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [param "ai_used" 0] pf
      in kindsFor "ai_used" fs @?= []

  , testCase "consecutive field writes to the same struct var are not flagged (treeviewitem idiom)" $
      -- item.label = "a"; item.pictureindex = 1 — two DIFFERENT fields of
      -- the same struct, not two clobbering writes of the same scalar.
      -- lvRoot collapses both to dsVar "item", so without the dsPartial
      -- guard this looks identical to a same-block dead store.
      let blk = mkBlock "b0"
            [ at 1 (BsAssign (lv2 "item" "label") (ExStr "a"))
            , at 2 (BsAssign (lv2 "item" "pictureindex") (ExInt "1"))
            , at 3 (BsAssign (lv1 "li_result") (ExLvalue (lv1 "item")))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "item" 0] pf
      in kindsFor "item" fs @?= []

  , testCase "full def followed by a partial write on the same var is not flagged (datastore-populate idiom)" $
      -- lds = create datastore; lds.DataObject = x; return lds -- real-corpus
      -- regression. The partial write implicitly reads `lds` to reach into
      -- it and doesn't clobber the rest of its value, so it must neither
      -- itself be flagged (already covered by the treeviewitem case above)
      -- NOR make the preceding full def look dead by killing `lds`'s
      -- liveness on its way through the backward walk.
      let blk = mkBlock "b0"
            [ at 1 (BsAssign (lv1 "lds") (ExCreate "datastore"))
            , at 2 (BsAssign (lv2 "lds" "dataobject") (ExLvalue (lv1 "as_dataobject")))
            , at 3 (BsReturn (Just (ExLvalue (lv1 "lds"))))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "lds" 0] pf
      in kindsFor "lds" fs @?= []

  , testCase "instance/global variable reassignment is never flagged overwritten-before-read" $
      -- Real-corpus regression: PB.Analysis.Dataflow has no notion of
      -- variable scope, so ProcFlow's def/use sites cover EVERY assigned
      -- identifier in the body -- instance vars and globals included, not
      -- just declared locals/params. `ib_flag` here is never passed in
      -- `lvs` (it isn't a declared local or param of this procedure), so
      -- it must never be flagged even though its def/use shape (read in
      -- an `if`, reassigned right after) looks identical to a genuine
      -- same-block dead store on a real local.
      let blk = mkBlock "b0"
            [ at 1 (BsIf (IfStmt
                { ifCond = ExLvalue (lv1 "ib_flag"), ifThen = []
                , ifElseIfs = [], ifElse = Nothing }))
            , at 2 (BsAssign (lv1 "ib_flag") (ExBool False))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [] pf
      in kindsFor "ib_flag" fs @?= []

  , testCase "unused for-loop counter is not flagged (loop-idiom exclusion)" $
      let blk = mkBlock "b0"
            [ at 1 (BsFor (ForStmt
                { forVar = lv1 "li_i", forFrom = ExInt "1", forTo = ExInt "10"
                , forStep = Nothing, forBody = [] }))
            , at 2 (BsFor (ForStmt
                { forVar = lv1 "li_i", forFrom = ExInt "1", forTo = ExInt "10"
                , forStep = Nothing, forBody = [] }))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [] pf
      in kindsFor "li_i" fs @?= []

  , testCase "findDeadVars stamps object/proc from ProcFlow" $
      let blk = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "li_x" (Just (ExInt "0")))]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "w_main" "wf_open" cfg
          fs  = findDeadVars [localVar "li_x" 1] pf
      in do
        map dvfObject fs @?= ["w_main"]
        map dvfProc fs @?= ["wf_open"]

  , testCase "deadVarKindText renders the roadmap's kind strings" $ do
      deadVarKindText NeverRead @?= "never-read"
      deadVarKindText OverwrittenBeforeRead @?= "overwritten-before-read"
      deadVarKindText UnusedParam @?= "unused-param"

  , testCase "dedup: fully-unused declared local is reported as never-read only, not also overwritten-before-read" $
      let blk = mkBlock "b0"
            [ at 1 (BsAssign (lv1 "li_x") (ExInt "1"))
            , at 2 (BsAssign (lv1 "li_x") (ExInt "2"))
            ]
          cfg = mkCfg "b0" [blk] []
          pf  = analyzeProcedure "obj" "proc" cfg
          fs  = findDeadVars [localVar "li_x" 1] pf
      in kindsFor "li_x" fs @?= [NeverRead]
  ]
