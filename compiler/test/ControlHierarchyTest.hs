module ControlHierarchyTest (tests, withFyloFixture) where

import PB.Prelude
import PB.AST.SourceFile        (SrFile (..), TypeBlock (..), mkTypeDecl)
import PB.AST.BodyStmt          (BodyStmt (..))
import PB.AST.Expr               (Expr (..))
import PB.AST.Located            (Located (..))
import PB.AST.Type               (PbType (..))
import PB.Analysis.ControlHierarchy
import PB.Analysis.TypeResolve   (buildInheritsMap)
import PB.Pipeline.Emit          (parsePowerScriptFile)

import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

import System.Directory      (doesFileExist)

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertFailure, testCase, (@?=))

emptyFile :: SrFile
emptyFile = SrFile [] Nothing Nothing Nothing [] [] [] [] [] []

-- | A dataobject= literal, the shape extractDwControlBindings/buildControlIndex scan for.
dataObjectBody :: Text -> [Located BodyStmt]
dataObjectBody dw = [Located 1 (BsLocalVar [] (PtPrimitive "string") "dataobject" (Just (ExStr dw)))]

-- | A file's own top-level declaration (tdWithin = Nothing). Every fixture
-- below prepends one of these so 'PB.AST.SourceFile.srPrimaryObject's
-- no-forward-block fallback (head of srTypeBlocks) reports the intended
-- window/class name as this file's "root" (Plan 164 Phase E) -- mirroring
-- how every real .srw/.sru file always self-declares its own outer type
-- block first.
topLevel :: Text -> TypeBlock
topLevel name = TypeBlock (mkTypeDecl name "window" Nothing) []

tests :: TestTree
tests = testGroup "ControlHierarchy"
  [ testGroup "buildControlIndex"
    [ testCase "outer type block (tdWithin = Nothing) keys on (own name, own name, \"this\")" $
        let sf = emptyFile { srTypeBlocks = [topLevel "w_main"] }
            idx = buildControlIndex [sf]
        in Map.lookup ("w_main", "w_main", "this") idx @?=
             Just (ControlDecl "w_main" "this" "window" Nothing Nothing)

    , testCase "child control keys on (file's root, parent literal name, control name)" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in Map.lookup ("w_main", "w_main", "dw_1") idx @?=
             Just (ControlDecl "w_main" "dw_1" "datawindow" Nothing Nothing)

    , testCase "backtick ancestor splits into cdAncestorType/cdOverridesName via D1" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "page1" "w_form_tab2`page1" (Just "tab1")) []
                  ] }
            idx = buildControlIndex [sf]
        in Map.lookup ("w_main", "tab1", "page1") idx @?=
             Just (ControlDecl "tab1" "page1" "w_form_tab2" (Just "page1") Nothing)

    , testCase "literal dataobject binding is captured as cdDwBinding" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) (dataObjectBody "d_items")
                  ] }
            idx = buildControlIndex [sf]
        in (cdDwBinding <$> Map.lookup ("w_main", "w_main", "dw_1") idx) @?= Just (Just "d_items")

    , testCase "control with no dataobject literal has cdDwBinding = Nothing" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in (cdDwBinding <$> Map.lookup ("w_main", "w_main", "dw_1") idx) @?= Just Nothing

    , testCase "merges entries across multiple SrFiles into one workspace index" $
        let sfA = emptyFile { srTypeBlocks = [topLevel "a"] }
            sfB = emptyFile { srTypeBlocks = [topLevel "b"] }
            idx = buildControlIndex [sfA, sfB]
        in (Map.member ("a", "a", "this") idx, Map.member ("b", "b", "this") idx) @?= (True, True)

    , testCase "keys are lowercased for case-insensitive lookup" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "W_Main"
                  , TypeBlock (mkTypeDecl "DW_1" "DataWindow" (Just "W_Main")) []
                  ] }
            idx = buildControlIndex [sf]
        in Map.lookup ("w_main", "w_main", "dw_1") idx @?=
             Just (ControlDecl "w_main" "dw_1" "datawindow" Nothing Nothing)
    ]

  , testGroup "resolveMemberChainType"
    [ testCase "single-segment chain resolves a directly-declared control's ancestor type" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainType idx Map.empty "w_main" ["dw_1"] @?= Just "datawindow"

    , testCase "unknown starting object returns Nothing" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainType idx Map.empty "w_other" ["dw_1"] @?= Nothing

    , testCase "unknown first segment returns Nothing" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainType idx Map.empty "w_main" ["dw_unknown"] @?= Nothing

    , testCase "multi-segment chain resolves via literal-name-scoped nested declarations" $
        -- Synthetic mirror of tab1.page1 in w_misth_fylo_form.srw: page1 is
        -- declared "within tab1" using tab1's own literal instance name.
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_main")) []
                  , TypeBlock (mkTypeDecl "page1" "userobject" (Just "tab1")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainType idx Map.empty "w_main" ["tab1", "page1"] @?= Just "userobject"

    , testCase "backtick override resolves through the ancestor's own declaration of the same-named control" $
        -- tab1 (in the descendant window's own file) overrides w_form_tab2's
        -- own tab1 (in ITS OWN file), whose real (non-overridden) type is
        -- "tab" -- two separate SrFiles, matching real file boundaries.
        let sfDescendant = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_descendant"
                  , TypeBlock (mkTypeDecl "tab1" "w_form_tab2`tab1" (Just "w_descendant")) []
                  ] }
            sfAncestor = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_form_tab2"
                  , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_form_tab2")) []
                  ] }
            idx = buildControlIndex [sfDescendant, sfAncestor]
        in resolveMemberChainType idx Map.empty "w_descendant" ["tab1"] @?= Just "tab"

    , testCase "chain falls back to resolved effective type when no literal-name declaration exists for the next hop" $
        -- Synthetic mirror of uo_epidom.dw: "dw" is declared within the
        -- CLASS uo_grid's own file, never within the instance name
        -- "uo_epidom" (a separate SrFile from the one declaring uo_epidom,
        -- matching real file boundaries).
        let sfMain = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "uo_epidom" "uo_grid" (Just "w_main")) []
                  ] }
            sfGrid = emptyFile
              { srTypeBlocks =
                  [ topLevel "uo_grid"
                  , TypeBlock (mkTypeDecl "dw" "datawindow" (Just "uo_grid")) []
                  ] }
            idx = buildControlIndex [sfMain, sfGrid]
        in resolveMemberChainType idx Map.empty "w_main" ["uo_epidom", "dw"] @?= Just "datawindow"

    , testCase "ancestor-chain lookup finds a control declared on an ancestor object, not locally redeclared" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_ancestor"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_ancestor")) []
                  ] }
            idx = buildControlIndex [sf]
            inh = Map.singleton "w_descendant" "w_ancestor"
        in resolveMemberChainType idx inh "w_descendant" ["dw_1"] @?= Just "datawindow"

    , testCase "cycle in inherits map terminates rather than looping" $
        let idx = buildControlIndex [emptyFile]
            inh = Map.fromList [("a", "b"), ("b", "a")]
        in resolveMemberChainType idx inh "a" ["dw_1"] @?= Nothing

    , testCase "cycle in override chain terminates rather than looping" $
        -- x (owner "a") claims to override "a`x" -- i.e. its own override
        -- target is itself. The override-unwind visited-set must catch this
        -- on the second visit and stop, returning the decl it was stuck on.
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "a"
                  , TypeBlock (mkTypeDecl "x" "a`x" (Just "a")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainType idx Map.empty "a" ["x"] @?= Just "a"

    , testCase "unresolvable hop midway through the chain returns Nothing, not a partial guess" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainType idx Map.empty "w_main" ["tab1", "nonexistent", "further"] @?= Nothing

    , testCase "real corpus fixture: tab1.page1.uo_epidom.dw resolves to base type datawindow" $
        withFyloFixture $ \idx inh ->
          resolveMemberChainType idx inh "w_misth_fylo_form" ["tab1", "page1", "uo_epidom", "dw"] @?= Just "datawindow"

    , testCase "Plan 164 Phase E: two unrelated windows redeclaring the same literal tab1.page1 pair do not collide" $
        -- Mirrors the real corpus shape: many windows independently
        -- redeclare an identically-named "tab1"/"page1" pair (a generic
        -- tab-container child name). Each window's own page1 must resolve
        -- to its OWN declaration, not whichever file happens to load last.
        let sfWinA = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_win_a"
                  , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_win_a")) []
                  , TypeBlock (mkTypeDecl "page1" "usedataA" (Just "tab1")) []
                  ] }
            sfWinB = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_win_b"
                  , TypeBlock (mkTypeDecl "tab1" "tab" (Just "w_win_b")) []
                  , TypeBlock (mkTypeDecl "page1" "usedataB" (Just "tab1")) []
                  ] }
            idx = buildControlIndex [sfWinA, sfWinB]
        in do
          resolveMemberChainType idx Map.empty "w_win_a" ["tab1", "page1"] @?= Just "usedataa"
          resolveMemberChainType idx Map.empty "w_win_b" ["tab1", "page1"] @?= Just "usedatab"
    ]

  , testGroup "resolveMemberChainDwBinding"
    [ testCase "terminal control with a literal dataobject resolves to that binding" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) (dataObjectBody "d_items")
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainDwBinding idx Map.empty "w_main" ["dw_1"] @?= Just "d_items"

    , testCase "terminal control with no dataobject binding returns Nothing" $
        let sf = emptyFile
              { srTypeBlocks =
                  [ topLevel "w_main"
                  , TypeBlock (mkTypeDecl "dw_1" "datawindow" (Just "w_main")) []
                  ] }
            idx = buildControlIndex [sf]
        in resolveMemberChainDwBinding idx Map.empty "w_main" ["dw_1"] @?= Nothing

    , testCase "unresolvable chain returns Nothing" $
        let idx = buildControlIndex [emptyFile]
        in resolveMemberChainDwBinding idx Map.empty "w_main" ["dw_1"] @?= Nothing

    , testCase "a closer override's own dataobject wins over an ancestor's binding-less declaration" $
        -- Synthetic mirror of uo_epidom.dw: uo_grid's own "dw" (u_grid`dw
        -- style) sets no dataobject, but the overriding decl on the
        -- concrete grid class does. Two separate SrFiles, matching real
        -- file boundaries (uo_concrete's own class file vs. uo_grid's own).
        let sfConcrete = emptyFile
              { srTypeBlocks =
                  [ topLevel "uo_concrete"
                  , TypeBlock (mkTypeDecl "dw" "uo_grid`dw" (Just "uo_concrete")) (dataObjectBody "d_items")
                  ] }
            sfGrid = emptyFile
              { srTypeBlocks =
                  [ topLevel "uo_grid"
                  , TypeBlock (mkTypeDecl "dw" "datawindow" (Just "uo_grid")) []
                  ] }
            idx = buildControlIndex [sfConcrete, sfGrid]
        in resolveMemberChainDwBinding idx Map.empty "uo_concrete" ["dw"] @?= Just "d_items"

    , testCase "real corpus fixture: tab1.page1.uo_epidom.dw resolves to dw_misth_fylo_epidom_list" $
        withFyloFixture $ \idx inh ->
          resolveMemberChainDwBinding idx inh "w_misth_fylo_form" ["tab1", "page1", "uo_epidom", "dw"]
            @?= Just "dw_misth_fylo_epidom_list"
    ]
  ]

-- | Loads the real corpus fixture (w_misth_fylo_form.srw, its ancestor
-- w_form_tab2.srw, and the embedded uo_misth_fylo_epidom_grid.sru ->
-- u_grid.sru chain) and builds a workspace-wide ControlIndex + inherits map
-- from it. Mirrors SchFootprintTest.hs's "Phase 3 done-condition" pattern:
-- vacuous pass if the example corpus isn't present in this environment.
withFyloFixture :: (ControlIndex -> Map.Map Text Text -> IO ()) -> IO ()
withFyloFixture check = do
  let paths =
        [ "example/openpay-0.1.1b-extract/fylo.pbl/w_misth_fylo_form.srw"
        , "example/openpay-0.1.1b-extract/afxlib.pbl/w_form_tab2.srw"
        , "example/openpay-0.1.1b-extract/fylo.pbl/uo_misth_fylo_epidom_grid.sru"
        , "example/openpay-0.1.1b-extract/afxlib.pbl/u_grid.sru"
        ]
  exist <- traverse doesFileExist paths
  if not (and exist)
    then pure ()  -- corpus not present in this environment; vacuous pass
    else do
      parsed <- traverse (\p -> parsePowerScriptFile <$> readFile p) paths
      case sequence parsed of
        Left e     -> assertFailure ("failed to parse fylo fixture: " <> T.unpack e)
        Right pairs ->
          let sfs = map fst pairs
              idx = buildControlIndex sfs
              inh = buildInheritsMap sfs
          in check idx inh
