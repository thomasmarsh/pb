module SchFootprintTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.DataWindow      (DataWindowFile (..), DwTable (..), DwRetrieve (..), DwRetrieveOrRaw (..))
import PB.AST.Expr            (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.SourceFile      (SrFile (..), EventBlock (..), EventSig (..), SubroutineBlock (..), SubSig (..))
import PB.Analysis.CatOp      (Category (..), Cartesian (..), Cocartesian (..),
                                CatOp (..), branch)
import PB.Analysis.CatEval    (Value)
import PB.Analysis.CatLower   (compileSsa)
import PB.Analysis.ControlHierarchy (buildControlIndex)
import PB.Analysis.SchFootprint
import PB.Analysis.SchemaCategory (SchMorphism (..), SchObject (..), StmtId (..), LegKind (..), FkSource (..),
                                    DwRetrieveColRow (..), splitColumnRef)
import PB.Analysis.SSA        (buildSsa)
import PB.Analysis.TypeEnv    (ScopedTypeEnv (..), WorkspaceEnv (..), buildWorkspaceEnv, procEnv)
import PB.Analysis.TypeResolve (extractDwControlBindings)
import PB.Grammar.DataWindow  (parseDataWindow)
import PB.Pipeline.Emit       (parsePowerScriptFile)
import PB.Pipeline.SqlParse   (TableRef (..))

import qualified Data.List       as L
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import System.Directory      (doesFileExist)

import Hedgehog             (forAll, property, (===), Gen)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog  (testProperty)

-- ---------------------------------------------------------------------------
-- Fixtures

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Map.empty

ctx0 :: FunctorCtx
ctx0 = FunctorCtx
  { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
  , fcTypeEnv         = emptyEnv
  , fcDwColumns       = Map.empty
  , fcControlBindings = Map.empty
  }

-- | Mirrors the real w_dw_copy.srw shape (dw_dest control statically bound
-- to d_items, whose retrieve exposes sales_order_items.{id,line_id}).
ctx1 :: FunctorCtx
ctx1 = FunctorCtx
  { fcStmtObj = SqlStmtId "w_dw_copy.srw" "w_dw_copy" "clicked" 553
  , fcTypeEnv = emptyEnv
  , fcDwColumns = Map.fromList
      [ ("d_items", [ (TableRef Nothing "sales_order_items", "id")
                    , (TableRef Nothing "sales_order_items", "line_id") ]) ]
  , fcControlBindings = Map.fromList [ (("w_dw_copy", "dw_dest"), "d_items") ]
  }

lvExpr :: Text -> Expr
lvExpr n = ExLvalue (Lvalue [LvSegment n Nothing])

-- Content is arbitrary: only used to exercise Set union as a monoid.
morphismA, morphismB, morphismC, morphismD, morphismE :: SchMorphism
morphismA = SchMorphism (ColumnObj (TableRef Nothing "t1") "a") (StmtObj (SqlStmtId "f" "o" "p" 1)) LegReads
morphismB = SchMorphism (StmtObj (SqlStmtId "f" "o" "p" 2)) (ColumnObj (TableRef Nothing "t2") "b") LegWrites
morphismC = SchMorphism (StmtObj (DwRetrieveId "f" "dw1")) (ColumnObj (TableRef Nothing "t3") "c") LegRetrieve
morphismD = SchMorphism (ColumnObj (TableRef Nothing "t4") "d") (ColumnObj (TableRef Nothing "t5") "e") (LegFk FkDdl)
morphismE = SchMorphism (ColumnObj (TableRef Nothing "t6") "f") (ColumnObj (TableRef Nothing "t7") "g") (LegFk FkDwJoin)

allMorphisms :: [SchMorphism]
allMorphisms = [morphismA, morphismB, morphismC, morphismD, morphismE]

genFootprintSet :: Gen (Set.Set SchMorphism)
genFootprintSet = Set.fromList <$> Gen.list (Range.linear 0 5) (Gen.element allMorphisms)

tests :: TestTree
tests = testGroup "SchFootprint"

  [ testGroup "category laws"
    [ testCase "id is the empty footprint" $
        runSchFootprint (id :: SchFootprint () ()) ctx0 @?= Set.empty

    , testCase "composition of two constant footprints unions them" $
        let f = SchFootprint (const (Set.fromList [morphismA])) :: SchFootprint () ()
            g = SchFootprint (const (Set.fromList [morphismB])) :: SchFootprint () ()
        in runSchFootprint (f . g) ctx0 @?= Set.fromList [morphismA, morphismB]

    , testCase "(&&&) unions both sides' footprints" $
        let f = SchFootprint (const (Set.fromList [morphismA])) :: SchFootprint () ()
            g = SchFootprint (const (Set.fromList [morphismB])) :: SchFootprint () ()
        in runSchFootprint (f &&& g) ctx0 @?= Set.fromList [morphismA, morphismB]

    , testCase "(|||) unions both branches' footprints (static over-approximation)" $
        let f = SchFootprint (const (Set.fromList [morphismA])) :: SchFootprint () ()
            g = SchFootprint (const (Set.fromList [morphismB])) :: SchFootprint () ()
        in runSchFootprint (f ||| g) ctx0 @?= Set.fromList [morphismA, morphismB]

    , testProperty "composition unions footprints associatively (Hedgehog)" $ property $ do
        sA <- forAll genFootprintSet
        sB <- forAll genFootprintSet
        sC <- forAll genFootprintSet
        let f = SchFootprint (const sA) :: SchFootprint () ()
            g = SchFootprint (const sB) :: SchFootprint () ()
            h = SchFootprint (const sC) :: SchFootprint () ()
        runSchFootprint ((f . g) . h) ctx0 === runSchFootprint (f . (g . h)) ctx0
        runSchFootprint (f . g) ctx0 === Set.union sA sB
    ]

  , testGroup "foldSchFootprint over CatOp (infra slice: always empty)"
    -- Every Effectful method is a constant empty footprint this session
    -- (Plan 148 Phase 3 infra slice) -- these are the completeness check
    -- that foldCat's generic dispatch reaches every one of CatOp's 20
    -- constructors without falling over, not a check of any real morphism
    -- detection (that lands in a follow-up session).
    [ testCase "CatId / CatCompose / CatAssignWithRhs" $
        foldSchFootprint ctx0 (CatAssignWithRhs "x" (ExInt "1") . CatId :: CatOp () ()) @?= Set.empty

    , testCase "branch: CatFanIn / CatSplitValue / CatFork / CatEval / CatCall / CatSuspend" $
        foldSchFootprint ctx0
          (branch (ExBool True) (CatCall "f" []) (CatSuspend "retrieve:dw" []) :: CatOp () ())
          @?= Set.empty

    , testCase "CatExl / CatExr" $ do
        foldSchFootprint ctx0 (CatExl :: CatOp ((), ()) ()) @?= Set.empty
        foldSchFootprint ctx0 (CatExr :: CatOp ((), ()) ()) @?= Set.empty

    , testCase "CatInl / CatInr" $ do
        foldSchFootprint ctx0 (CatInl :: CatOp () (Either () ())) @?= Set.empty
        foldSchFootprint ctx0 (CatInr :: CatOp () (Either () ())) @?= Set.empty

    , testCase "CatAssign / CatLookup" $ do
        foldSchFootprint ctx0 (CatAssign "x" :: CatOp ((), Value) ()) @?= Set.empty
        foldSchFootprint ctx0 (CatLookup "x" :: CatOp () Value) @?= Set.empty

    , testCase "CatReturn" $
        foldSchFootprint ctx0 (CatReturn :: CatOp () ()) @?= Set.empty

    , testCase "CatLoop (immediate break)" $
        foldSchFootprint ctx0 (CatLoop (CatInr :: CatOp () (Either () ())) :: CatOp () ()) @?= Set.empty

    , testCase "CatTry" $
        foldSchFootprint ctx0 (CatTry CatId (CatAssign "x") :: CatOp () ()) @?= Set.empty

    , testCase "CatTagged" $
        foldSchFootprint ctx0 (CatTagged "blk" CatId :: CatOp () ()) @?= Set.empty

    , testCase "CatConst" $
        foldSchFootprint ctx0 (CatConst (ExInt "1") :: CatOp () Value) @?= Set.empty
    ]

  , testGroup "callProc SetItem detection"
    [ testCase "SetItem with literal column resolves to LegWrites when control/dw/column all bound" $
        foldSchFootprint ctx1
          (CatCall "dw_dest.SetItem" [lvExpr "ll_Cnt", ExStr "id", lvExpr "li_Data"] :: CatOp () ())
          @?= Set.singleton
                (SchMorphism (StmtObj (fcStmtObj ctx1))
                             (ColumnObj (TableRef Nothing "sales_order_items") "id")
                             LegWrites)

    , testCase "unbound control yields empty footprint" $
        foldSchFootprint ctx1
          (CatCall "dw_other.SetItem" [lvExpr "ll_Cnt", ExStr "id", lvExpr "li_Data"] :: CatOp () ())
          @?= Set.empty

    , testCase "dynamic (non-literal) column argument yields empty footprint" $
        foldSchFootprint ctx1
          (CatCall "dw_dest.SetItem" [lvExpr "ll_Cnt", lvExpr "ls_col", lvExpr "li_Data"] :: CatOp () ())
          @?= Set.empty

    , testCase "unknown column name in the bound dw yields empty footprint" $
        foldSchFootprint ctx1
          (CatCall "dw_dest.SetItem" [lvExpr "ll_Cnt", ExStr "nonexistent_col", lvExpr "li_Data"] :: CatOp () ())
          @?= Set.empty

    , testCase "non-SetItem calls remain empty" $
        foldSchFootprint ctx1 (CatCall "dw_dest.Retrieve" [] :: CatOp () ()) @?= Set.empty
    ]

  , testGroup "Phase 3 done-condition: real corpus example (w_dw_copy.srw / d_items.srd)"
    [ testCase "SetItem write with value flowing through a local var resolves to sales_order_items.id" $ do
        let srwPath  = "example/PowerBuilder-Example-extract/pbexamw1.pbl/w_dw_copy.srw" :: FilePath
            srdPath  = "example/PowerBuilder-Example-extract/pbexamd2.pbl/d_items.srd" :: FilePath
            srwPathT = T.pack srwPath
            srdPathT = T.pack srdPath
        srwExists <- doesFileExist srwPath
        srdExists <- doesFileExist srdPath
        if not (srwExists && srdExists)
          then pure ()  -- corpus not present in this environment; vacuous pass (mirrors CorpusTest's withCorpusFile)
          else do
            srwSrc <- readFile srwPath
            srdSrc <- readFile srdPath
            case (parsePowerScriptFile srwSrc, parseDataWindow srdSrc) of
              (Left e, _) -> assertFailure ("failed to parse w_dw_copy.srw: " <> T.unpack e)
              (_, Left e) -> assertFailure ("failed to parse d_items.srd: " <> T.unpack e)
              (Right (sf, _spans), Right dwFile) ->
                case [ ev | ev <- srEvents sf, esName (evSig ev) == "clicked", evOwner ev == Just "cb_getitem" ] of
                  [ev] -> do
                    let ws       = buildWorkspaceEnv [sf]
                        env      = procEnv ws "w_dw_copy" []
                        ssaProc  = buildSsa env "clicked" (evBody ev)
                        term     = compileSsa env Set.empty ssaProc
                        bindings = extractDwControlBindings srwPathT sf
                        dwCols = case dwTable dwFile >>= dtRetrieve of
                          Just (DwRetrieveOk retrieve) ->
                            [ DwRetrieveColRow srdPathT "d_items" ns tbl col
                            | ref <- drColumns retrieve
                            , Just (TableRef ns tbl, col) <- [splitColumnRef ref]
                            ]
                          _ -> []
                        ctx = FunctorCtx
                          { fcStmtObj         = SqlStmtId srwPathT "w_dw_copy" "clicked" 0
                          , fcTypeEnv         = env
                          , fcDwColumns       = dwColumnsFromRows dwCols
                          , fcControlBindings = controlBindingsMap bindings
                          }
                        footprint = foldSchFootprint ctx term
                        expected = SchMorphism (StmtObj (fcStmtObj ctx))
                                               (ColumnObj (TableRef Nothing "sales_order_items") "id")
                                               LegWrites
                    L.length dwCols @?= 5
                    Set.member expected footprint @?= True
                  other -> assertFailure ("expected exactly 1 clicked/cb_getitem event, got " <> show (length other))
    ]

  , testGroup "Plan 164 Phase C done-condition: real corpus example (fylo.pbl runtime DW alias)"
    -- The openpay "0/6 SetItem resolution" gap Plan 164 exists to close:
    -- w_misth_fylo_form.srw's of_open subroutine aliases the instance var
    -- idw_epidom to tab1.page1.uo_epidom.dw (a control two files away whose
    -- own static dataobject= is dw_misth_fylo_epidom_list); a *different*
    -- subroutine, if_kodfylo_changed, later calls
    -- idw_epidom.setitem(i, "kodfylo", ...). Neither
    -- extractDwControlBindings (no literal dataobject= on idw_epidom
    -- itself -- it's a plain instance var, not a control) nor a
    -- same-procedure-only scan (the alias assignment and the SetItem call
    -- are in different subroutines) can resolve this without
    -- runtimeDwAliasBindings aggregating across the whole file, exactly as
    -- 'PB.Pipeline.Runner.compileOne' now does.
    [ testCase "SetItem on an aliased instance var resolves to misth_fylo_epidom.kodfylo" $ do
        let srwPath = "example/openpay-0.1.1b-extract/fylo.pbl/w_misth_fylo_form.srw"
            paths =
              [ srwPath
              , "example/openpay-0.1.1b-extract/afxlib.pbl/w_form_tab2.srw"
              , "example/openpay-0.1.1b-extract/fylo.pbl/uo_misth_fylo_epidom_grid.sru"
              , "example/openpay-0.1.1b-extract/afxlib.pbl/u_grid.sru"
              ]
            srdPath  = "example/openpay-0.1.1b-extract/fylo.pbl/dw_misth_fylo_epidom_list.srd"
            srwPathT = T.pack srwPath
        exist    <- traverse doesFileExist paths
        srdExists <- doesFileExist srdPath
        if not (and exist && srdExists)
          then pure ()  -- corpus not present in this environment; vacuous pass
          else do
            parsed <- traverse (\p -> parsePowerScriptFile <$> readFile p) paths
            srdSrc <- readFile srdPath
            case (sequence parsed, parseDataWindow srdSrc) of
              (Left e, _)  -> assertFailure ("failed to parse fylo fixture: " <> T.unpack e)
              (_, Left e)  -> assertFailure ("failed to parse dw_misth_fylo_epidom_list.srd: " <> T.unpack e)
              (Right pairs, Right dwFile) ->
                case map fst pairs of
                  [sf, sf2, sf3, sf4] -> do
                    let sfs = [sf, sf2, sf3, sf4]
                        ws  = buildWorkspaceEnv sfs
                        idx = buildControlIndex sfs
                        findSub n = [ sb | sb <- srSubroutines sf, ssName (sbSig sb) == n ]
                    case (findSub "of_open", findSub "if_kodfylo_changed") of
                     ([ofOpen], [ifChanged]) -> do
                       let openEnv    = procEnv ws "w_misth_fylo_form" []
                           aliasBindings = runtimeDwAliasBindings idx (weHierarchy ws) "w_misth_fylo_form" openEnv (sbBody ofOpen)
                           changedEnv = procEnv ws "w_misth_fylo_form" []
                           ssaProc    = buildSsa changedEnv "if_kodfylo_changed" (sbBody ifChanged)
                           term       = compileSsa changedEnv Set.empty ssaProc
                           dwCols = case dwTable dwFile >>= dtRetrieve of
                             Just (DwRetrieveOk retrieve) ->
                               [ DwRetrieveColRow (T.pack srdPath) "dw_misth_fylo_epidom_list" ns tbl col
                               | ref <- drColumns retrieve
                               , Just (TableRef ns tbl, col) <- [splitColumnRef ref]
                               ]
                             _ -> []
                           ctx = FunctorCtx
                             { fcStmtObj         = SqlStmtId srwPathT "w_misth_fylo_form" "if_kodfylo_changed" 0
                             , fcTypeEnv         = changedEnv
                             , fcDwColumns       = dwColumnsFromRows dwCols
                             , fcControlBindings = aliasBindings
                             }
                           footprint = foldSchFootprint ctx term
                           expected  = SchMorphism (StmtObj (fcStmtObj ctx))
                                                    (ColumnObj (TableRef Nothing "misth_fylo_epidom") "kodfylo")
                                                    LegWrites
                       aliasBindings @?= Map.fromList [(("w_misth_fylo_form", "idw_epidom"), "dw_misth_fylo_epidom_list")]
                       Set.member expected footprint @?= True
                     (openMatches, changedMatches) -> assertFailure
                       ("expected exactly 1 of_open and 1 if_kodfylo_changed subroutine, got "
                         <> show (length openMatches) <> "/" <> show (length changedMatches))
                  other -> assertFailure ("expected 4 parsed fixture files, got " <> show (length other))
    ]
  ]
