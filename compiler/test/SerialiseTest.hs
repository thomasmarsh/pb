module SerialiseTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt  (BodyStmt (..), DoCondition (..))
import PB.AST.DataWindow (DwArgument (..), DwRetrieve (..), DwRetrieveOrRaw (..),
                          DwWhereClause (..))
import PB.AST.Expr      (Expr (..), LvSegment (..))
import PB.AST.SourceFile (SrFile (..))
import PB.Grammar.File        (SrSpans (..))
import PB.Pipeline.Runner     (wrapSrFile)
import PB.Analysis.TypeEnv    (buildWorkspaceEnv)
import PB.Analysis.GraphBuilder (LowCat (..), WiringPayload (..))
import PB.Pipeline.Serialise  ()

import Data.Aeson          (Value (..), toJSON)
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict   as Map

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

field :: Text -> Value -> Value
field k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
field _ _          = Null

hasField :: Text -> Value -> Bool
hasField k (Object m) = KM.member (Key.fromText k) m
hasField _ _          = False

emptySrFile :: SrFile
emptySrFile = SrFile
  { srHeaders = [], srForward = Nothing, srPrototypes = Nothing
  , srVariables = Nothing, srGlobalInstances = [], srTypeBlocks = []
  , srOnBlocks = [], srEvents = [], srFunctions = [], srSubroutines = []
  }

emptySrSpans :: SrSpans
emptySrSpans = SrSpans [] [] [] []

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Serialise"
  [ testCase "SrFile round-trip: file/kind fields present in wrapSrFile output" $ do
      let v = wrapSrFile False "test.srf" emptySrFile emptySrSpans (buildWorkspaceEnv [])
      field "file" v @?= String "test.srf"
      field "kind" v @?= String "powerscript"

  , testCase "DoCondition tag uses constructor name" $ do
      let vw = toJSON (DoWhile ExNull)
          vu = toJSON (DoUntil ExNull)
      field "tag" vw @?= String "DoWhile"
      field "tag" vu @?= String "DoUntil"
      assertBool "DoWhile must not have 'kind' field" (not (hasField "kind" vw))
      assertBool "DoUntil must not have 'kind' field" (not (hasField "kind" vu))

  , testCase "BodyStmt BsReturn without value has null contents" $ do
      let v = toJSON (BsReturn Nothing)
      field "tag"      v @?= String "BsReturn"
      field "contents" v @?= Null

  , testCase "BodyStmt BsReturn with value has non-null contents" $ do
      let v = toJSON (BsReturn (Just ExNull))
      field "tag" v @?= String "BsReturn"
      assertBool "contents field must be present" (hasField "contents" v)

  , testCase "Expr ExRaw encodes tokens list under 'contents'" $ do
      let v = toJSON (ExRaw [])
      field "tag"      v @?= String "ExRaw"
      field "contents" v @?= toJSON ([] :: [Text])

  , testCase "LvSegment with no subscript encodes subscript as null" $ do
      let v = toJSON (LvSegment { name = "x", subscript = Nothing } :: LvSegment)
      field "name"      v @?= String "x"
      field "subscript" v @?= Null

  , testGroup "DwRetrieveOrRaw"
      [ testCase "DwRetrieveOk emits tag=DwRetrieveOk with retrieve nested in contents" $ do
          let dr = DwRetrieve { drVersion = 400, drTables = ["emp"], drColumns = ["emp.id"]
                              , drArguments = [], drWhere = [] }
              v  = toJSON (DwRetrieveOk dr)
          field "tag"                        v @?= String "DwRetrieveOk"
          field "version" (field "contents" v) @?= toJSON (400 :: Int)
          field "tables"  (field "contents" v) @?= toJSON (["emp"] :: [Text])
          field "columns" (field "contents" v) @?= toJSON (["emp.id"] :: [Text])

      , testCase "DwRetrieveRaw emits tag=DwRetrieveRaw with text in contents" $ do
          let v = toJSON (DwRetrieveRaw "SELECT 1 FROM dual")
          field "tag"      v @?= String "DwRetrieveRaw"
          field "contents" v @?= String "SELECT 1 FROM dual"

      , testCase "DwRetrieveOk has no text field" $ do
          let dr = DwRetrieve { drVersion = 1, drTables = [], drColumns = []
                              , drArguments = [], drWhere = [] }
              v  = toJSON (DwRetrieveOk dr)
          assertBool "DwRetrieveOk must not have 'text' field" (not (hasField "text" v))
          assertBool "DwRetrieveOk contents must not have 'text' field"
            (not (hasField "text" (field "contents" v)))

      , testCase "DwRetrieveRaw has no tables field" $ do
          let v = toJSON (DwRetrieveRaw "raw sql")
          assertBool "DwRetrieveRaw must not have 'tables' field" (not (hasField "tables" v))

      , testCase "DwRetrieveOk with where clause serialises clause fields" $ do
          let wc = DwWhereClause { dwcExp1 = "t.id", dwcOp = "=", dwcExp2 = ":arg"
                                 , dwcLogic = Nothing }
              dr = DwRetrieve { drVersion = 400, drTables = ["t"], drColumns = []
                              , drArguments = [], drWhere = [wc] }
              v  = toJSON (DwRetrieveOk dr)
          field "tag" v @?= String "DwRetrieveOk"
          assertBool "DwRetrieveOk must not have top-level 'text' field" (not (hasField "text" v))

      , testCase "DwRetrieveOk with argument serialises argument fields" $ do
          let arg = DwArgument { daName = "p_id", daType = "long" }
              dr  = DwRetrieve { drVersion = 400, drTables = ["t"], drColumns = []
                               , drArguments = [arg], drWhere = [] }
              v   = toJSON (DwRetrieveOk dr)
          field "tag" v @?= String "DwRetrieveOk"
          field "arguments" (field "contents" v) @?= toJSON [arg]
      ]

  , testGroup "LowCat / WiringPayload (Plan 149 Phase 1)"
      [ testCase "LTagged serialises as a bare reference: tag + blockId, no contents" $ do
          let v = toJSON (LTagged "b3" (LAssignWithRhs "x" (ExInt "1")))
          field "tag"     v @?= String "LTagged"
          field "blockId" v @?= String "b3"
          assertBool "LTagged must not inline its payload under 'contents'"
            (not (hasField "contents" v))

      , testCase "every other LowCat constructor keeps the generic tag/contents convention" $ do
          let v = toJSON LId
          field "tag" v @?= String "LId"
          assertBool "LId (nullary) has no contents field" (not (hasField "contents" v))

      , testCase "WiringPayload has term + sharedBlocks, sharedBlocks keyed by blockId" $ do
          let inner = LAssignWithRhs "x" (ExInt "1")
              w = WiringPayload
                    { wpTerm = LTagged "b1" inner
                    , wpShared = Map.fromList [("b1", inner)]
                    }
              v = toJSON w
          field "tag"     (field "term" v) @?= String "LTagged"
          field "blockId" (field "term" v) @?= String "b1"
          field "tag" (field "b1" (field "sharedBlocks" v)) @?= String "LAssignWithRhs"
      ]

  ]
