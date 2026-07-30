module PassesTest (tests) where

import PB.Prelude
import PB.AST.Ident (mkIdent)
import PB.Pipeline.Passes (ResolveInputs (..), fetchResolveInputs)
import PB.Pipeline.DuckDb.PhaseA (ObjectRow (..), StructureRow (..))

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- Helpers

mkObjRow :: Text -> Maybe Text -> Text -> ObjectRow
mkObjRow obj anc cat = ObjectRow "f.srw" "powerscript" obj anc Nothing Nothing "confirmed" cat

tests :: TestTree
tests = testGroup "Passes"
  [ testGroup "fetchResolveInputs: objSet/usrTypes"
    [ testCase "a real window ends up in objSet, not usrTypes" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_foo" (Just "window") "window"] [] [] Map.empty
        riObjSet ri @?= Set.fromList ["w_foo"]
        riUsrTypes ri @?= Set.empty

    , testCase "a standalone .srs structure ends up in usrTypes, not objSet" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "os_data" (Just "structure") "structure"]
                [StructureRow "os_data.srs" "os_data" Nothing]
                [] Map.empty
        riUsrTypes ri @?= Set.fromList ["os_data"]
        riObjSet ri @?= Set.empty

    , testCase "an inline structure (no objects row of its own) still reaches usrTypes" $ do
        -- Real corpus shape: the owning window's file gets one objects row
        -- (category=window); the inline structure only has a 'structures'
        -- row, never its own 'objects' row.
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_foo" (Just "window") "window"]
                [StructureRow "w_foo.srw" "os_data" (Just "w_foo")]
                [] Map.empty
        riObjSet ri @?= Set.fromList ["w_foo"]
        riUsrTypes ri @?= Set.fromList ["os_data"]

    , testCase "a stdlib structure (category=system override) is excluded from objSet despite its category" $ do
        -- Real corpus shape: runtime/datawindowchild.sru is a genuine
        -- `type datawindowchild from structure` file, but every __stdlib__/
        -- row gets category='system' regardless (objectCategoryForFile's
        -- blanket override) -- so objSet can't filter by category alone,
        -- it must exclude by usrTypes membership instead.
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "datawindowchild" (Just "structure") "system"]
                [StructureRow "__stdlib__/datawindowchild.sru" "datawindowchild" Nothing]
                [] Map.empty
        riUsrTypes ri @?= Set.fromList ["datawindowchild"]
        riObjSet ri @?= Set.empty
    ]
  , testGroup "fetchResolveInputs: nested control ancestors (Plan 214 scope-item-3 follow-on)"
    [ testCase "a nested control's ancestor is visible in riInherits even though it has no objects row of its own" $ do
        -- Real corpus shape: 'type mdi_1 from mdiclient within w_main' never
        -- gets its own 'objects' row (that table is one row per *file*), so
        -- riInherits must learn "mdi_1"'s ancestor from the nested-ancestor
        -- map instead.
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_main" (Just "window") "window"] [] []
                (Map.fromList [(mkIdent "mdi_1", mkIdent "mdiclient")])
        Map.lookup (mkIdent "mdi_1") (riInherits ri) @?= Just (mkIdent "mdiclient")

    , testCase "a primary object's own ancestor still wins on a key collision with the nested map" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_app" (Just "w_main") "window"] [] []
                (Map.fromList [(mkIdent "w_app", mkIdent "some_other_ancestor")])
        Map.lookup (mkIdent "w_app") (riInherits ri) @?= Just (mkIdent "w_main")
    ]
  ]
