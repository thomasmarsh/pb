module EffectAnnotationsTest (tests) where

import PB.Prelude
import PB.AST.Ident            (identOrig)
import PB.AST.SourceFile       (SrFile (..), FnSig (..), FunctionBlock (..))
import PB.Pipeline.Emit        (ParsedFile (..))
import PB.Runtime.EffectAnnotations (parseEffectAnnotations, realEffectAnnotations)
import PB.Runtime.StdLib       (parseStdlibFiles)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import System.FilePath (takeBaseName)

import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertFailure, testCase, (@?=))

-- | Small inline fixture -- not real runtime/*.sru content -- covering a
-- single-tag method, a multi-tag method, a (pure) method, an unannotated
-- method, and two annotated methods sharing one file.
fixture :: Text
fixture = T.unlines
  [ "HA$PBExportHeader$foo.sru"
  , ""
  , "global type foo from nonvisualobject"
  , "end type"
  , ""
  , "// @effects Suspends"
  , "public function long retrieve ()"
  , "end function"
  , ""
  , "// @effects Suspends, ReadsDb"
  , "public function long update ()"
  , "end function"
  , ""
  , "// @effects (pure)"
  , "public function long getrow ()"
  , "end function"
  , ""
  , "public function long rowcount ()"
  , "end function"
  ]

tests :: TestTree
tests = testGroup "PB.Runtime.EffectAnnotations"
  [ testCase "a method with a single-tag @effects comment parses its tag" $
      Map.lookup ("foo", "retrieve") (parseEffectAnnotations [("foo.sru", fixture)])
        @?= Just (Set.singleton "Suspends")

  , testCase "a method with a multi-tag @effects comment parses all tags" $
      Map.lookup ("foo", "update") (parseEffectAnnotations [("foo.sru", fixture)])
        @?= Just (Set.fromList ["Suspends", "ReadsDb"])

  , testCase "a method with (pure) parses to an explicit empty set, not absent" $
      Map.lookup ("foo", "getrow") (parseEffectAnnotations [("foo.sru", fixture)])
        @?= Just Set.empty

  , testCase "a method with no preceding @effects comment is absent from the map" $
      Map.lookup ("foo", "rowcount") (parseEffectAnnotations [("foo.sru", fixture)])
        @?= Nothing

  , testCase "two annotated methods in the same file each get their own tags, no leakage" $ do
      let m = parseEffectAnnotations [("foo.sru", fixture)]
      Map.lookup ("foo", "retrieve") m @?= Just (Set.singleton "Suspends")
      Map.lookup ("foo", "update")   m @?= Just (Set.fromList ["Suspends", "ReadsDb"])

  , testCase "every public method parsed from datawindow.sru/datastore.sru/datawindowchild.sru/transaction.sru has an explicit annotation" $ do
      pfs <- parseStdlibFiles
      let targetClasses = Set.fromList ["datawindow", "datastore", "datawindowchild", "transaction"]
          missing =
            [ (cls, identOrig (fnsName (fbSig fb)))
            | pf <- pfs
            , let cls = T.toLower (T.pack (takeBaseName (pfPath pf)))
            , cls `Set.member` targetClasses
            , fb <- srFunctions (pfSrFile pf)
            , let meth = T.toLower (identOrig (fnsName (fbSig fb)))
            , Map.notMember (cls, meth) realEffectAnnotations
            ]
      case missing of
        [] -> pure ()
        _  -> assertFailure ("methods missing an @effects annotation: " <> show missing)
  ]
