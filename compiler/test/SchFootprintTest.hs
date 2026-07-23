module SchFootprintTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.DataWindow      (DataWindowFile (..), DwTable (..), DwRetrieve (..), DwRetrieveOrRaw (..))
import PB.AST.Expr            (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident           (mkIdent)
import PB.AST.Located        (Located (..))
import PB.AST.SourceFile      (SrFile (..), EventBlock (..), EventSig (..), SubroutineBlock (..), SubSig (..))
import PB.Compile.IR         (Category (..), Cartesian (..), Cocartesian (..),
                                Eff (..), Pure (..), EffTerm (..), branchEff, extractEffTable)
import PB.Compile.ValueModel   (Value)
import PB.Compile.FromSSA (compileSsaToEff)
import PB.Analysis.ControlHierarchy (buildControlIndex)
import PB.Analysis.SchFootprint
import PB.Analysis.SchemaCategory (SchMorphism (..), SchObject (..), StmtId (..), LegKind (..), LegSource (..),
                                    DwRetrieveColRow (..), splitColumnRef)
import PB.Compile.SSA        (buildSsa)
import PB.Analysis.TypeEnv    (ScopedTypeEnv (..), WorkspaceEnv (..), buildWorkspaceEnv, procEnv)
import PB.Analysis.TypeResolve (extractDwControlBindings)
import PB.Grammar.DataWindow  (parseDataWindow)
import PB.Pipeline.Emit       (parsePowerScriptFile)
import PB.Pipeline.SqlParse   (TableRef (..))

import qualified Prelude        as P
import qualified Control.Exception as CE
import           GHC.Conc         (getAllocationCounter, setAllocationCounter)
import           Data.Int         (Int64)
import           System.Timeout   (timeout)
import           PB.AST.BodyStmt  (BodyStmt (..), IfStmt (..), ChooseStmt (..), CaseClause (..))
import           PB.Compile.Flatten (compileProcedureToEff)

import qualified Data.List       as L
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

import System.Directory      (doesFileExist)
import System.FilePath       ((</>))
import RepoRoot              (repoRoot)

import Hedgehog             (forAll, property, (===), Gen)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog  (testProperty)

-- ---------------------------------------------------------------------------
-- Fixtures

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

ctx0 :: FunctorCtx
ctx0 = FunctorCtx
  { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
  , fcTypeEnv         = emptyEnv
  , fcDwColumns       = Map.empty
  , fcControlBindings = Map.empty
  }

measureAllocBytes :: IO a -> IO Int64
measureAllocBytes act = do
  setAllocationCounter maxBound
  _ <- act
  remaining <- getAllocationCounter
  pure (maxBound P.- remaining)

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
lvExpr n = ExLvalue (Lvalue [LvSegment (mkIdent n) Nothing])

-- Content is arbitrary: only used to exercise Set union as a monoid.
morphismA, morphismB, morphismC, morphismD, morphismE :: SchMorphism
morphismA = SchMorphism (ColumnObj (TableRef Nothing "t1") "a") (StmtObj (SqlStmtId "f" "o" "p" 1)) LegReads SrcSqlText
morphismB = SchMorphism (StmtObj (SqlStmtId "f" "o" "p" 2)) (ColumnObj (TableRef Nothing "t2") "b") LegWrites SrcSqlText
morphismC = SchMorphism (StmtObj (DwRetrieveId "f" "dw1")) (ColumnObj (TableRef Nothing "t3") "c") LegRetrieve SrcDwRetrieve
morphismD = SchMorphism (ColumnObj (TableRef Nothing "t4") "d") (ColumnObj (TableRef Nothing "t5") "e") LegFk SrcDdlFk
morphismE = SchMorphism (ColumnObj (TableRef Nothing "t6") "f") (ColumnObj (TableRef Nothing "t7") "g") LegFk SrcDwJoin

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

  , testGroup "force-time memo (Plan 167 Phase 1): foldSchFootprintEff stays linear on a shared-merge-block DAG"
    [ testCase "18 sequential if/else groups: forces each ELetRef once, not 2^18 re-forces" $ do
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
            term = compileProcedureToEff emptyEnv Set.empty body
            ctx  = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (Set.size (foldSchFootprintEff ctx term))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 5MB (post-fix force-time \
             \memo: measured ~0.4MB; pre-fix ~80MB re-forcing shared ELetRef subtrees)")
            (bytes P.< 5 P.* 1000 P.* 1000)

    , testCase "7 sequential choose/case blocks, 8 clauses each: forces linear, not 2^N" $ do
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            chooseGroup g =
              Located (g P.* 100) (BsChoose (ChooseStmt
                (ExLvalue (Lvalue [LvSegment (mkIdent ("s" <> T.pack (show g))) Nothing]))
                [ CaseClause Nothing
                    [Located (g P.* 100 P.+ i) (BsCall (call ("c" <> T.pack (show g) <> "_" <> T.pack (show i))))]
                | i <- [1 .. 8 :: Int] ]))
            body = [ chooseGroup g | g <- [1 .. 7 :: Int] ]
            term = compileProcedureToEff emptyEnv Set.empty body
            ctx  = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
        mBytes <- timeout 30000000 (measureAllocBytes
          (CE.evaluate (Set.size (foldSchFootprintEff ctx term))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (post-fix force-time \
             \memo on 8-way fan-in; pre-fix ~350MB combinatorial across the 7 chained blocks)")
            (bytes P.< 20 P.* 1000 P.* 1000)

    , testCase "scaling ratio: 20 vs 10 if/else switches allocates <5x (near-linear), not ~600x" $ do
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            mkBody n = concatMap group [ i P.* 4 | i <- [0 .. n P.- 1] ]
              where
                group base =
                  [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                      [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                      (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
                  , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
                  ]
            ctx = FunctorCtx
              { fcStmtObj         = SqlStmtId "f.srf" "obj" "proc" 1
              , fcTypeEnv         = emptyEnv
              , fcDwColumns       = Map.empty
              , fcControlBindings = Map.empty
              }
            term10 = compileProcedureToEff emptyEnv Set.empty (mkBody 10)
            term20 = compileProcedureToEff emptyEnv Set.empty (mkBody 20)
        b10 <- measureAllocBytes (CE.evaluate (Set.size (foldSchFootprintEff ctx term10)))
        b20 <- measureAllocBytes (CE.evaluate (Set.size (foldSchFootprintEff ctx term20)))
        let ratio = fromIntegral b20 / fromIntegral b10 :: Double
        assertBool
          ("20/10 switch ratio " <> show ratio <> "x; expected < 5x (linear). bytes: "
             <> show b10 <> " -> " <> show b20)
          (ratio P.< 5.0)
    ]

  , testGroup "foldSchFootprintEff over Eff (infra slice: always empty)"
    -- Every Effectful method is a constant empty footprint except ECall's
    -- SetItem case (below) -- these are the completeness check that every
    -- one of 'Eff'\'s constructors folds without falling over, not a check
    -- of any real morphism detection.
    [ testCase "J PId / EComp / EAssignWithRhs" $
        foldSchFootprintEff ctx0 (extractEffTable (EAssignWithRhs "x" (ExInt "0") (ExInt "1") `EComp` J PId :: Eff () ())) @?= Set.empty

    , testCase "branch: EBranch / ESplitValue / ECall / ESuspend" $
        foldSchFootprintEff ctx0
          (extractEffTable (branchEff (ExBool True) (ECall "f" []) (ESuspend "retrieve:dw" []) :: Eff () ()))
          @?= Set.empty

    , testCase "J PInl / J PInr" $ do
        foldSchFootprintEff ctx0 (extractEffTable (J PInl :: Eff () (Either () ()))) @?= Set.empty
        foldSchFootprintEff ctx0 (extractEffTable (J PInr :: Eff () (Either () ()))) @?= Set.empty

    , testCase "EAssign" $
        foldSchFootprintEff ctx0 (extractEffTable (EAssign "x" :: Eff ((), Value) ())) @?= Set.empty

    , testCase "EReturn" $
        foldSchFootprintEff ctx0 (extractEffTable (EReturn (ExInt "0") :: Eff () ())) @?= Set.empty

    , testCase "ELoop (immediate break)" $
        foldSchFootprintEff ctx0 (extractEffTable (ELoop (J PInr :: Eff () (Either () ())) :: Eff () ())) @?= Set.empty

    , testCase "ELetRef (shared block reference resolves via the table)" $
        foldSchFootprintEff ctx0 (EffTerm (ELetRef "blk") (Map.singleton "blk" (J PId))) @?= Set.empty
    ]

  , testGroup "foldSchFootprintEff: callProc SetItem detection"
    [ testCase "SetItem with literal column resolves to LegWrites when control/dw/column all bound" $
        foldSchFootprintEff ctx1
          (extractEffTable (ECall "dw_dest.SetItem" [lvExpr "ll_Cnt", ExStr "id", lvExpr "li_Data"] :: Eff () ()))
          @?= Set.singleton
                (SchMorphism (StmtObj (fcStmtObj ctx1))
                             (ColumnObj (TableRef Nothing "sales_order_items") "id")
                             LegWrites SrcCatFootprint)

    , testCase "unbound control yields empty footprint" $
        foldSchFootprintEff ctx1
          (extractEffTable (ECall "dw_other.SetItem" [lvExpr "ll_Cnt", ExStr "id", lvExpr "li_Data"] :: Eff () ()))
          @?= Set.empty

    , testCase "dynamic (non-literal) column argument yields empty footprint" $
        foldSchFootprintEff ctx1
          (extractEffTable (ECall "dw_dest.SetItem" [lvExpr "ll_Cnt", lvExpr "ls_col", lvExpr "li_Data"] :: Eff () ()))
          @?= Set.empty

    , testCase "unknown column name in the bound dw yields empty footprint" $
        foldSchFootprintEff ctx1
          (extractEffTable (ECall "dw_dest.SetItem" [lvExpr "ll_Cnt", ExStr "nonexistent_col", lvExpr "li_Data"] :: Eff () ()))
          @?= Set.empty

    , testCase "non-SetItem calls remain empty" $
        foldSchFootprintEff ctx1 (extractEffTable (ECall "dw_dest.Retrieve" [] :: Eff () ())) @?= Set.empty

    , testCase "18 sequential if/else groups: allocates < 20MB, not 2^18 blowup" $ do
        let call n = ExCall (Lvalue [LvSegment (mkIdent n) Nothing]) []
            group base =
              [ Located (base P.+ 1) (BsIf (IfStmt (ExBool True)
                  [Located (base P.+ 2) (BsCall (call ("a" <> T.pack (show base))))] []
                  (Just [Located (base P.+ 3) (BsCall (call ("b" <> T.pack (show base))))])))
              , Located (base P.+ 4) (BsCall (call ("tail" <> T.pack (show base))))
              ]
            body = concatMap group [ n P.* 4 | n <- [0 .. 17 :: Int] ]
            term = compileProcedureToEff emptyEnv Set.empty body
        mBytes <- timeout 30000000 (measureAllocBytes (CE.evaluate (Set.size (foldSchFootprintEff ctx0 term))))
        case mBytes of
          Nothing -> assertFailure "did not complete within the 30s hang-safety-net timeout"
          Just bytes -> assertBool
            ("allocated " <> show bytes <> " bytes; expected < 20MB (foldSchFootprintEff's ELetRef \
             \memo should keep this linear, not 2^18 re-forcing)")
            (bytes P.< 20 P.* 1000 P.* 1000)
    ]

  , testGroup "Phase 3 done-condition: real corpus example (w_dw_copy.srw / d_items.srd)"
    [ testCase "SetItem write with value flowing through a local var resolves to sales_order_items.id" $ do
        let srwPath  = "example/PowerBuilder-Example-extract/pbexamw1.pbl/w_dw_copy.srw" :: FilePath
            srdPath  = "example/PowerBuilder-Example-extract/pbexamd2.pbl/d_items.srd" :: FilePath
            srwPathT = T.pack srwPath
            srdPathT = T.pack srdPath
        root <- repoRoot
        let fullSrwPath = root </> srwPath
            fullSrdPath = root </> srdPath
        srwExists <- doesFileExist fullSrwPath
        srdExists <- doesFileExist fullSrdPath
        if not (srwExists && srdExists)
          then pure ()  -- corpus not present in this environment; vacuous pass (mirrors CorpusTest's withCorpusFile)
          else do
            srwSrc <- readFile fullSrwPath
            srdSrc <- readFile fullSrdPath
            case (parsePowerScriptFile srwSrc, parseDataWindow srdSrc) of
              (Left e, _) -> assertFailure ("failed to parse w_dw_copy.srw: " <> T.unpack e)
              (_, Left e) -> assertFailure ("failed to parse d_items.srd: " <> T.unpack e)
              (Right (sf, _spans, _toks), Right dwFile) ->
                case [ ev | ev <- srEvents sf, esName (evSig ev) == "clicked", evOwner ev == Just "cb_getitem" ] of
                  [ev] -> do
                    let ws       = buildWorkspaceEnv [sf]
                        env      = procEnv ws (buildControlIndex [sf]) "w_dw_copy" []
                        ssaProc  = buildSsa env "clicked" (evBody ev)
                        term     = compileSsaToEff env Set.empty ssaProc
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
                        footprint = foldSchFootprintEff ctx term
                        expected = SchMorphism (StmtObj (fcStmtObj ctx))
                                               (ColumnObj (TableRef Nothing "sales_order_items") "id")
                                               LegWrites SrcCatFootprint
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
        root <- repoRoot
        let fullPaths  = map (root </>) paths
            fullSrdPath = root </> srdPath
        exist    <- traverse doesFileExist fullPaths
        srdExists <- doesFileExist fullSrdPath
        if not (and exist && srdExists)
          then pure ()  -- corpus not present in this environment; vacuous pass
          else do
            parsed <- traverse (\p -> parsePowerScriptFile <$> readFile p) fullPaths
            srdSrc <- readFile fullSrdPath
            case (sequence parsed, parseDataWindow srdSrc) of
              (Left e, _)  -> assertFailure ("failed to parse fylo fixture: " <> T.unpack e)
              (_, Left e)  -> assertFailure ("failed to parse dw_misth_fylo_epidom_list.srd: " <> T.unpack e)
              (Right triples, Right dwFile) ->
                case [ sf | (sf, _, _) <- triples ] of
                  [sf, sf2, sf3, sf4] -> do
                    let sfs = [sf, sf2, sf3, sf4]
                        ws  = buildWorkspaceEnv sfs
                        idx = buildControlIndex sfs
                        findSub n = [ sb | sb <- srSubroutines sf, ssName (sbSig sb) == n ]
                    case (findSub "of_open", findSub "if_kodfylo_changed") of
                     ([ofOpen], [ifChanged]) -> do
                       let openEnv    = procEnv ws idx "w_misth_fylo_form" []
                           aliasBindings = runtimeDwAliasBindings idx (weHierarchy ws) "w_misth_fylo_form" openEnv (sbBody ofOpen)
                           changedEnv = procEnv ws idx "w_misth_fylo_form" []
                           ssaProc    = buildSsa changedEnv "if_kodfylo_changed" (sbBody ifChanged)
                           term       = compileSsaToEff changedEnv Set.empty ssaProc
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
                           footprint = foldSchFootprintEff ctx term
                           expected  = SchMorphism (StmtObj (fcStmtObj ctx))
                                                    (ColumnObj (TableRef Nothing "misth_fylo_epidom") "kodfylo")
                                                    LegWrites SrcCatFootprint
                       aliasBindings @?= Map.fromList [(("w_misth_fylo_form", "idw_epidom"), "dw_misth_fylo_epidom_list")]
                       Set.member expected footprint @?= True
                     (openMatches, changedMatches) -> assertFailure
                       ("expected exactly 1 of_open and 1 if_kodfylo_changed subroutine, got "
                         <> show (length openMatches) <> "/" <> show (length changedMatches))
                  other -> assertFailure ("expected 4 parsed fixture files, got " <> show (length other))
    ]
  ]
