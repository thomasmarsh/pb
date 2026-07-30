module PassesTest (tests) where

import PB.Prelude
import PB.AST.Ident
  ( IdentProvenance (..), identSetLookup, identSetToList, identSpan, mkIdent
  , identMapEmpty, identMapFromListWith, identMapLookup, identSetSingleton, identSetUnion
  )
import PB.Lexing.Token (SourceSpan (..))
import PB.Pipeline.Passes (ResolveInputs (..), fetchResolveInputs)
import PB.Pipeline.DuckDb.PhaseA (ObjectRow (..), StructureRow (..))
import Data.List.NonEmpty (NonEmpty (..))

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import qualified Data.Map.Strict as Map

-- ---------------------------------------------------------------------------
-- Helpers

-- | 'identSetToList' recovers entries in ascending canonical-form order --
-- used to assert 'IdentSet' contents below, since 'IdentSet' itself has no
-- 'Eq' instance (only 'Ident' does).

mkObjRow :: Text -> Maybe Text -> Text -> ObjectRow
mkObjRow obj anc cat = ObjectRow "f.srw" "powerscript" obj anc Nothing Nothing "confirmed" cat Nothing

mkStructRow :: Text -> Text -> Maybe Text -> StructureRow
mkStructRow file obj owner = StructureRow file obj owner Nothing

tests :: TestTree
tests = testGroup "Passes"
  [ testGroup "fetchResolveInputs: objSet/usrTypes"
    [ testCase "a real window ends up in objSet, not usrTypes" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_foo" (Just "window") "window"] []
                Map.empty identMapEmpty identMapEmpty
        identSetToList (riObjSet ri) @?= [mkIdent "w_foo"]
        identSetToList (riUsrTypes ri) @?= []

    , testCase "a standalone .srs structure ends up in usrTypes, not objSet" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "os_data" (Just "structure") "structure"]
                [mkStructRow "os_data.srs" "os_data" Nothing]
                Map.empty identMapEmpty identMapEmpty
        identSetToList (riUsrTypes ri) @?= [mkIdent "os_data"]
        identSetToList (riObjSet ri) @?= []

    , testCase "an inline structure (no objects row of its own) still reaches usrTypes" $ do
        -- Real corpus shape: the owning window's file gets one objects row
        -- (category=window); the inline structure only has a 'structures'
        -- row, never its own 'objects' row.
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "w_foo" (Just "window") "window"]
                [mkStructRow "w_foo.srw" "os_data" (Just "w_foo")]
                Map.empty identMapEmpty identMapEmpty
        identSetToList (riObjSet ri) @?= [mkIdent "w_foo"]
        identSetToList (riUsrTypes ri) @?= [mkIdent "os_data"]

    , testCase "a stdlib structure (category=system override) is excluded from objSet despite its category" $ do
        -- Real corpus shape: runtime/datawindowchild.sru is a genuine
        -- `type datawindowchild from structure` file, but every __stdlib__/
        -- row gets category='system' regardless (objectCategoryForFile's
        -- blanket override) -- so objSet can't filter by category alone,
        -- it must exclude by usrTypes membership instead.
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "datawindowchild" (Just "structure") "system"]
                [mkStructRow "__stdlib__/datawindowchild.sru" "datawindowchild" Nothing]
                Map.empty identMapEmpty identMapEmpty
        identSetToList (riUsrTypes ri) @?= [mkIdent "datawindowchild"]
        identSetToList (riObjSet ri) @?= []
    ]
  , testGroup "fetchResolveInputs: objSet/usrTypes carry real provenance (Plan 196 Phase 2 follow-on)"
    [ testCase "an ObjectRow with a recorded span survives into riObjSet's Ident, not re-minted Synthetic" $ do
        let sp = SourceSpan 3 6 3 11
        ri <- fetchResolveInputs [] [] []
                [ObjectRow "w_foo.srw" "powerscript" "w_foo" (Just "window") Nothing Nothing "confirmed" "window" (Just sp)]
                [] Map.empty identMapEmpty identMapEmpty
        case identSetLookup (mkIdent "w_foo") (riObjSet ri) of
          Just i -> identSpan i @?= FromSource (sp :| [])
          Nothing -> fail "expected w_foo in riObjSet"

    , testCase "an ObjectRow with no recorded span (e.g. DataWindow-sourced) is honestly Synthetic" $ do
        ri <- fetchResolveInputs [] [] []
                [mkObjRow "d_report" Nothing "datawindow"] []
                Map.empty identMapEmpty identMapEmpty
        case identSetLookup (mkIdent "d_report") (riObjSet ri) of
          Just i -> case identSpan i of
            Synthetic _ -> pure ()
            other -> fail $ "expected Synthetic, got " <> show other
          Nothing -> fail "expected d_report in riObjSet"
    ]
  , testGroup "fetchResolveInputs: hierarchy/procMap/callableProcMap are threaded through, not re-derived"
    -- 'riInherits'/'riProcMap'/'riCallableProcMap' used to be rebuilt here
    -- from DB-round-tripped 'ObjectRow'/'ProcRow' text via 'mkIdent',
    -- discarding real declaration-site spans and re-minting 'Ident's
    -- post-parse. The caller now passes the workspace's own already-correct,
    -- parse-time-minted maps ('weHierarchy'/'weProcMap'/
    -- 'buildCallableProcMap') straight through -- these tests confirm the
    -- wiring is a plain pass-through, not a re-derivation.
    [ testCase "riInherits is exactly the hierarchy map passed in" $ do
        let hierarchy = Map.fromList [(mkIdent "mdi_1", mkIdent "mdiclient")]
        ri <- fetchResolveInputs [] [] [] [] [] hierarchy identMapEmpty identMapEmpty
        riInherits ri @?= hierarchy

    , testCase "riProcMap is exactly the procMap passed in" $ do
        let pm = identMapFromListWith identSetUnion [(mkIdent "w_test", identSetSingleton (mkIdent "f_go"))]
        ri <- fetchResolveInputs [] [] [] [] [] Map.empty pm identMapEmpty
        (identSetToList . snd <$> identMapLookup (mkIdent "w_test") (riProcMap ri)) @?= Just [mkIdent "f_go"]

    , testCase "riCallableProcMap is exactly the callableProcMap passed in" $ do
        let cpm = identMapFromListWith identSetUnion [(mkIdent "w_test", identSetSingleton (mkIdent "of_help"))]
        ri <- fetchResolveInputs [] [] [] [] [] Map.empty identMapEmpty cpm
        (identSetToList . snd <$> identMapLookup (mkIdent "w_test") (riCallableProcMap ri)) @?= Just [mkIdent "of_help"]
    ]
  ]
