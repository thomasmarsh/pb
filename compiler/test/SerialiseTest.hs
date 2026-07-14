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
import PB.Compile.Flatten (WiringNode (..), WiringGraph (..))
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
                              , drArguments = [], drWhere = [], drJoins = [] }
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
                              , drArguments = [], drWhere = [], drJoins = [] }
              v  = toJSON (DwRetrieveOk dr)
          assertBool "DwRetrieveOk must not have 'text' field" (not (hasField "text" v))
          assertBool "DwRetrieveOk contents must not have 'text' field"
            (not (hasField "text" (field "contents" v)))

      , testCase "DwRetrieveRaw has no tables field" $ do
          let v = toJSON (DwRetrieveRaw "raw sql")
          assertBool "DwRetrieveRaw must not have 'tables' field" (not (hasField "tables" v))

      , testCase "DwRetrieveOk with where clause serialises clause fields" $ do
          let wc = DwWhereClause { dwcExp1 = "t.id", dwcOp = "=", dwcExp2 = ":arg"
                                 , dwcLogic = Nothing
                                 , dwcParsedExp1 = Nothing, dwcParsedExp2 = Nothing }
              dr = DwRetrieve { drVersion = 400, drTables = ["t"], drColumns = []
                              , drArguments = [], drWhere = [wc], drJoins = [] }
              v  = toJSON (DwRetrieveOk dr)
          field "tag" v @?= String "DwRetrieveOk"
          assertBool "DwRetrieveOk must not have top-level 'text' field" (not (hasField "text" v))

      , testCase "DwRetrieveOk with argument serialises argument fields" $ do
          let arg = DwArgument { daName = "p_id", daType = "long" }
              dr  = DwRetrieve { drVersion = 400, drTables = ["t"], drColumns = []
                               , drArguments = [arg], drWhere = [], drJoins = [] }
              v   = toJSON (DwRetrieveOk dr)
          field "tag" v @?= String "DwRetrieveOk"
          field "arguments" (field "contents" v) @?= toJSON [arg]
      ]

  , testGroup "WiringGraph / WiringNode (Plan 167 Phase 7 Step 7)"
      [ testCase "WiringGraph has nodes + entry, nodes keyed by name" $ do
          let g = WiringGraph
                    { wgNodes = Map.fromList [("w0", WireAssign "x" (ExInt "1") "w1")]
                    , wgEntry = "w0" :: Text
                    }
              v = toJSON g
          field "entry" v @?= String "w0"
          field "tag" (field "w0" (field "nodes" v)) @?= String "WireAssign"

      , testCase "WireCond and WireBranch serialise as separate, distinct node shapes" $ do
          let condV   = toJSON (WireCond (ExBool True) ("next" :: Text))
              branchV = toJSON (WireBranch ("then" :: Text) "else")
          field "tag" condV @?= String "WireCond"
          field "tag" branchV @?= String "WireBranch"
          assertBool "WireBranch carries no condition field of its own"
            (not (hasField "expr" branchV))
      ]

  ]
