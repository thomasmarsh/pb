module PassesTest (tests) where

import PB.Prelude
import PB.Pipeline.Passes (ResolveInputs (..), fetchResolveInputs)
import PB.Pipeline.DuckDb.PhaseA (ObjectRow (..), StructureRow (..))

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
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
                [mkObjRow "w_foo" (Just "window") "window"] [] []
        riObjSet ri @?= Set.fromList ["w_foo"]
        riUsrTypes ri @?= Set.empty

    , testCase "a standalone .srs structure ends up in usrTypes, not objSet" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "os_data" (Just "structure") "structure"]
                [StructureRow "os_data.srs" "os_data" Nothing]
                []
        riUsrTypes ri @?= Set.fromList ["os_data"]
        riObjSet ri @?= Set.empty

    , testCase "an inline structure (no objects row of its own) still reaches usrTypes" $ do
        -- Real corpus shape: the owning window's file gets one objects row
        -- (category=window); the inline structure only has a 'structures'
        -- row, never its own 'objects' row.
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_foo" (Just "window") "window"]
                [StructureRow "w_foo.srw" "os_data" (Just "w_foo")]
                []
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
                []
        riUsrTypes ri @?= Set.fromList ["datawindowchild"]
        riObjSet ri @?= Set.empty
    ]
  ]
