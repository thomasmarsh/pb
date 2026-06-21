module SerialiseTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt  (BodyStmt (..), DoCondition (..))
import PB.AST.DataWindow (DwArgument (..), DwRetrieve (..), DwRetrieveOrRaw (..),
                          DwWhereClause (..))
import PB.AST.Expr      (Expr (..), LvSegment (..))
import PB.AST.SourceFile (SrFile (..))
import PB.Grammar.File        (SrSpans (..))
import PB.Pipeline.Runner     (wrapSrFile)
import PB.Pipeline.TypeEnv    (buildWorkspaceTypeEnv)
import PB.Pipeline.Serialise  ()
import PB.Pipeline.Serialise  (emitPython, transformType, parseFieldLine,
                               extractClassName, emitTypeAlias, splitTupleParts)

import Data.Aeson          (Value (..), toJSON)
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict   as Map
import qualified Data.Text as T

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
      let v = wrapSrFile "test.srf" emptySrFile emptySrSpans (buildWorkspaceTypeEnv [])
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

  , testGroup "emitPython / transformType"
    [ testCase "primitive types" $ do
        transformType "string"  @?= "str"
        transformType "boolean" @?= "bool"
        transformType "number"  @?= "int"

    , testCase "null suffix becomes None" $ do
        transformType "Expr | null" @?= "Expr | None"
        transformType "string | null" @?= "str | None"

    , testCase "array types" $ do
        transformType "string[]" @?= "list[str]"
        transformType "Expr[]" @?= "list[Expr]"
        transformType "string[][]" @?= "list[list[str]]"

    , testCase "named types pass through" $ do
        transformType "Expr" @?= "Expr"
        transformType "Lvalue" @?= "Lvalue"
        transformType "BinOp" @?= "BinOp"

    , testCase "literal string types become Literal" $ do
        transformType "\"ExBool\"" @?= "Literal[\"ExBool\"]"
        transformType "\"BopAdd\"" @?= "Literal[\"BopAdd\"]"

    , testCase "map types" $ do
        transformType "{[k in string]?: string}" @?= "dict[str, str]"
        transformType "{[k in string]?: number}" @?= "dict[str, int]"

    , testCase "nested map types" $ do
        transformType "{[k in string]?: {[k in string]?: string}}"
          @?= "dict[str, dict[str, str]]"

    , testCase "tuple types" $ do
        transformType "[Lvalue, Expr]" @?= "tuple[Lvalue, Expr]"
        transformType "[Expr, Expr]" @?= "tuple[Expr, Expr]"

    , testCase "tuple with array elements" $ do
        transformType "[string[], AugOp, string[]]"
          @?= "tuple[list[str], AugOp, list[str]]"

    , testCase "LocatedBodyStmt in field types" $ do
        transformType "LocatedBodyStmt[]" @?= "list[LocatedBodyStmt]"
        transformType "LocatedBodyStmt[] | null"
          @?= "list[LocatedBodyStmt] | None"
    ]

  , testGroup "parseFieldLine"
    [ testCase "simple field" $ do
        parseFieldLine "  name: string;" @?= ("name", "str")

    , testCase "field with null" $ do
        parseFieldLine "  subscript: string[] | null;"
          @?= ("subscript", "list[str] | None")

    , testCase "tag field with literal" $ do
        parseFieldLine "  tag: \"ExBool\";"
          @?= ("tag", "Literal[\"ExBool\"]")

    , testCase "map field" $ do
        parseFieldLine "  attrs: {[k in string]?: string};"
          @?= ("attrs", "dict[str, str]")

    , testCase "Located field" $ do
        parseFieldLine "  body: LocatedBodyStmt[];"
          @?= ("body", "list[LocatedBodyStmt]")
    ]

  , testGroup "extractClassName"
    [ testCase "strips I prefix" $ do
        extractClassName "interface ILvSegment {" @?= "LvSegment"

    , testCase "no I prefix" $ do
        extractClassName "interface LvSegment {" @?= "LvSegment"

    , testCase "with generic params" $ do
        extractClassName "interface ILocated<T> {" @?= "Located"
    ]

  , testGroup "splitTupleParts"
    [ testCase "two elements" $ do
        splitTupleParts "Lvalue, Expr" @?= ["Lvalue", "Expr"]

    , testCase "three elements with arrays" $ do
        splitTupleParts "string[], AugOp, string[]"
          @?= ["string[]", "AugOp", "string[]"]
    ]

  , testGroup "emitTypeAlias"
    [ testCase "single interface alias is skipped" $ do
        emitTypeAlias "LvSegment" ["ILvSegment"] @?= []

    , testCase "literal union" $ do
        emitTypeAlias "BinOp" ["\"BopAdd\"", "\"BopSub\""]
          @?= ["BinOp = Literal[\"BopAdd\", \"BopSub\"]"]

    , testCase "interface union strips I prefix" $ do
        emitTypeAlias "DoCondition" ["IDoWhile", "IDoUntil"]
          @?= ["DoCondition = DoWhile | DoUntil"]
    ]

  , testGroup "emitPython output"
    [ testCase "has header" $ do
        let py = emitPython
        assertBool "has from __future__ import annotations"
          ("from __future__ import annotations" `T.isInfixOf` py)
        assertBool "has TypedDict import"
          ("from typing import Literal, TypedDict" `T.isInfixOf` py)

    , testCase "has LvSegment class" $ do
        assertBool "class LvSegment exists"
          ("class LvSegment(TypedDict):" `T.isInfixOf` emitPython)

    , testCase "has LocatedBodyStmt class" $ do
        assertBool "class LocatedBodyStmt exists"
          ("class LocatedBodyStmt(TypedDict):" `T.isInfixOf` emitPython)
        assertBool "node field references BodyStmt"
          ("    node: BodyStmt" `T.isInfixOf` emitPython)

    , testCase "IfStmt uses functional TypedDict form with string annotations" $ do
        let py = emitPython
        assertBool "IfStmt = TypedDict(\"IfStmt\""
          ("IfStmt = TypedDict(\"IfStmt\"," `T.isInfixOf` py)
        assertBool "cond field uses string annotation"
          ("\"cond\": \"Expr\"" `T.isInfixOf` py)

    , testCase "BodyStmt is a union alias" $ do
        let py = emitPython
        assertBool "BodyStmt = BsLocalVar | ..."
          ("BodyStmt = BsLocalVar" `T.isInfixOf` py)

    , testCase "BinOp is a Literal alias" $ do
        let py = emitPython
        assertBool "BinOp = Literal[...]"
          ("BinOp = Literal[\"BopAdd\"" `T.isInfixOf` py)
    ]
  ]
