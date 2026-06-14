module SerialiseTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt  (BodyStmt (..), DoCondition (..))
import PB.AST.DataWindow (DwArgument (..), DwRetrieve (..), DwRetrieveOrRaw (..),
                          DwWhereClause (..))
import PB.AST.Expr      (Expr (..), Literal (..), LvSegment (..))
import PB.AST.SourceFile (SrFile (..))
import PB.Grammar.File        (SrSpans (..))
import PB.Pipeline.Runner     (wrapSrFile)
import PB.Pipeline.Serialise  ()

import Data.Aeson          (Value (..), toJSON)
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM

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
      let v = wrapSrFile "test.srf" emptySrFile emptySrSpans
      field "file" v @?= String "test.srf"
      field "kind" v @?= String "powerscript"

  , testCase "DoCondition uses tag not kind" $ do
      let vw = toJSON (DoWhile (ExLit LitNull))
          vu = toJSON (DoUntil (ExLit LitNull))
      field "tag" vw @?= String "while"
      field "tag" vu @?= String "until"
      assertBool "DoWhile must not have 'kind' field" (not (hasField "kind" vw))
      assertBool "DoUntil must not have 'kind' field" (not (hasField "kind" vu))

  , testCase "BodyStmt BsReturn without value omits value field" $ do
      let v = toJSON (BsReturn Nothing)
      field "tag" v @?= String "return"
      assertBool "value field must be absent" (not (hasField "value" v))

  , testCase "BodyStmt BsReturn with value includes value field" $ do
      let v = toJSON (BsReturn (Just (ExLit LitNull)))
      field "tag" v @?= String "return"
      assertBool "value field must be present" (hasField "value" v)

  , testCase "Expr ExRaw encodes tokens as text list" $ do
      let v = toJSON (ExRaw [])
      field "tag"    v @?= String "raw"
      field "tokens" v @?= toJSON ([] :: [Text])

  , testCase "LvSegment with no subscript encodes subscript as null" $ do
      let v = toJSON (LvSegment { lvsName = "x", lvsSubscript = Nothing })
      field "name"      v @?= String "x"
      field "subscript" v @?= Null

  , testGroup "DwRetrieveOrRaw"
      [ testCase "DwRetrieveOk emits tag=ok with inline retrieve fields" $ do
          let dr = DwRetrieve { drVersion = 400, drTables = ["emp"], drColumns = ["emp.id"]
                              , drArguments = [], drWhere = [] }
              v  = toJSON (DwRetrieveOk dr)
          field "tag"     v @?= String "ok"
          field "version" v @?= toJSON (400 :: Int)
          field "tables"  v @?= toJSON (["emp"] :: [Text])
          field "columns" v @?= toJSON (["emp.id"] :: [Text])

      , testCase "DwRetrieveRaw emits tag=raw with text field" $ do
          let v = toJSON (DwRetrieveRaw "SELECT 1 FROM dual")
          field "tag"  v @?= String "raw"
          field "text" v @?= String "SELECT 1 FROM dual"

      , testCase "DwRetrieveOk has no text field" $ do
          let dr = DwRetrieve { drVersion = 1, drTables = [], drColumns = []
                              , drArguments = [], drWhere = [] }
              v  = toJSON (DwRetrieveOk dr)
          assertBool "DwRetrieveOk must not have 'text' field" (not (hasField "text" v))

      , testCase "DwRetrieveRaw has no tables field" $ do
          let v = toJSON (DwRetrieveRaw "raw sql")
          assertBool "DwRetrieveRaw must not have 'tables' field" (not (hasField "tables" v))

      , testCase "DwRetrieveOk with where clause serialises clause fields" $ do
          let wc = DwWhereClause { dwcExp1 = "t.id", dwcOp = "=", dwcExp2 = ":arg"
                                 , dwcLogic = Nothing }
              dr = DwRetrieve { drVersion = 400, drTables = ["t"], drColumns = []
                              , drArguments = [], drWhere = [wc] }
              v  = toJSON (DwRetrieveOk dr)
          field "tag" v @?= String "ok"
          assertBool "DwRetrieveOk must not have 'text' field" (not (hasField "text" v))

      , testCase "DwRetrieveOk with argument serialises argument fields" $ do
          let arg = DwArgument { daName = "p_id", daType = "long" }
              dr  = DwRetrieve { drVersion = 400, drTables = ["t"], drColumns = []
                               , drArguments = [arg], drWhere = [] }
              v   = toJSON (DwRetrieveOk dr)
          field "tag"       v @?= String "ok"
          field "arguments" v @?= toJSON [arg]
      ]
  ]
