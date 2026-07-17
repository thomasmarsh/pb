module TypeFamilyTest (tests) where

import PB.Prelude
import qualified Data.Map.Strict as Map

import PB.AST.Ident       (Ident, identSetEmpty, identSetSingleton, mkIdent)
import PB.AST.Type        (PbType (..))
import PB.Analysis.TypeResolve (ResolvedType (..))
import PB.Analysis.TypeFamily

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

mkRT :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> ResolvedType
mkRT obj proc varN rawTy kind target = ResolvedType
  { rtFile      = "f.srw"
  , rtObject    = obj
  , rtProcName  = proc
  , rtVarName   = varN
  , rtRawType   = rawTy
  , rtKind      = kind
  , rtTarget    = target
  , rtIsParam   = False
  , rtScopeLine = 1
  }

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "TypeFamily"
  [ testGroup "classifyFamily" $
      [ testCase (name <> " -> " <> show expected) $
          classifyFamily (PtPrimitive raw) identSetEmpty identSetEmpty @?= expected
      | (name, raw, expected) <-
          [ ("integer", "integer", FamNumeric)
          , ("long", "long", FamNumeric)
          , ("double", "double", FamNumeric)
          , ("decimal", "decimal", FamNumeric)
          , ("byte", "byte", FamNumeric)
          , ("string", "string", FamString)
          , ("char", "char", FamString)
          , ("boolean", "boolean", FamBoolean)
          , ("date", "date", FamDateTime)
          , ("datetime", "datetime", FamDateTime)
          , ("time", "time", FamDateTime)
          , ("blob", "blob", FamBlob)
          ]
      ] <>
      [ testCase "PtAny -> any" $
          classifyFamily PtAny identSetEmpty identSetEmpty @?= FamAny
      , testCase "PtDecimalPrec -> numeric" $
          classifyFamily (PtDecimalPrec 10) identSetEmpty identSetEmpty @?= FamNumeric
      , testCase "PtPrimitive datawindow (builtin class) -> object" $
          classifyFamily (PtPrimitive "datawindow") identSetEmpty identSetEmpty @?= FamObject "datawindow"
      , testCase "PtUserDefined in object set -> object with target" $
          classifyFamily (PtUserDefined "w_main") (identSetSingleton (mkIdent "w_main")) identSetEmpty @?= FamObject "w_main"
      , testCase "PtUserDefined in user type set -> user_type with target" $
          classifyFamily (PtUserDefined "st_info") identSetEmpty (identSetSingleton (mkIdent "st_info")) @?= FamUserType "st_info"
      , testCase "PtUserDefined unresolved -> any (never guess)" $
          classifyFamily (PtUserDefined "xyz_unknown") identSetEmpty identSetEmpty @?= FamAny
      , testCase "PtUserDefined case-insensitive match recovers declared casing" $
          classifyFamily (PtUserDefined "W_Main") (identSetSingleton (mkIdent "w_main")) identSetEmpty @?= FamObject "w_main"
      ]

  , testGroup "familyOfResolvedType"
      [ testCase "primitive rtKind classifies numeric rawType" $
          familyOfResolvedType (mkRT "w" "p" "li_x" "integer" "primitive" Nothing) @?= FamNumeric
      , testCase "primitive rtKind classifies string rawType" $
          familyOfResolvedType (mkRT "w" "p" "ls_x" "string" "primitive" Nothing) @?= FamString
      , testCase "object rtKind carries resolved target" $
          familyOfResolvedType (mkRT "w" "p" "lw_x" "w_child" "object" (Just "w_child")) @?= FamObject "w_child"
      , testCase "user_type rtKind carries resolved target" $
          familyOfResolvedType (mkRT "w" "p" "lst_x" "st_info" "user_type" (Just "st_info")) @?= FamUserType "st_info"
      , testCase "unresolved rtKind maps to any (never guess)" $
          familyOfResolvedType (mkRT "w" "p" "lx_x" "xyz" "unresolved" Nothing) @?= FamAny
      , testCase "control-name-fallback-resolved var defers to rtKind/rtTarget, not rtRawType" $
          -- resolveTypes' classifyControlType fallback stores the *inferred*
          -- kind/target ("object"/"datawindow") even though rtRawType is
          -- still the original unresolved text -- confirms this function
          -- never re-derives from rtRawType when rtKind isn't "primitive".
          familyOfResolvedType (mkRT "w" "p" "dw_1" "SomeUnresolvedType" "object" (Just "datawindow"))
            @?= FamObject "datawindow"
      ]

  , testGroup "compatible"
      [ testCase "same family always compatible" $
          compatible Map.empty FamNumeric FamNumeric @?= True
      , testCase "FamAny on LHS is always compatible" $
          compatible Map.empty FamAny FamString @?= True
      , testCase "FamAny on RHS is always compatible" $
          compatible Map.empty FamNumeric FamAny @?= True
      , testCase "numeric LHS vs string RHS is incompatible" $
          compatible Map.empty FamNumeric FamString @?= False
      , testCase "string LHS vs boolean RHS is incompatible" $
          compatible Map.empty FamString FamBoolean @?= False
      , testCase "object LHS accepts exact-match object RHS" $
          compatible Map.empty (FamObject "w_main") (FamObject "w_main") @?= True
      , testCase "object LHS accepts subtype object RHS via ancestor chain" $
          compatible (Map.fromList [("w_child", "w_base")]) (FamObject "w_base") (FamObject "w_child") @?= True
      , testCase "object LHS rejects unrelated object RHS" $
          compatible Map.empty (FamObject "w_main") (FamObject "w_other") @?= False
      , testCase "object LHS accepts supertype-direction (downcast) RHS via ancestor chain" $
          compatible (Map.fromList [("w_child", "w_base")]) (FamObject "w_child") (FamObject "w_base") @?= True
      , testCase "user_type LHS accepts exact-match user_type RHS" $
          compatible Map.empty (FamUserType "st_a") (FamUserType "st_a") @?= True
      , testCase "user_type LHS rejects mismatched user_type RHS" $
          compatible Map.empty (FamUserType "st_a") (FamUserType "st_b") @?= False
      , testCase "builtin datawindow LHS accepts dragobject RHS (downcast)" $
          compatible builtinInherits (FamObject "datawindow") (FamObject "dragobject") @?= True
      , testCase "builtin dragobject LHS accepts datawindow RHS (upcast)" $
          compatible builtinInherits (FamObject "dragobject") (FamObject "datawindow") @?= True
      , testCase "builtin datawindow LHS accepts windowobject RHS (multi-hop ancestor)" $
          compatible builtinInherits (FamObject "datawindow") (FamObject "windowobject") @?= True
      , testCase "builtin datawindow LHS rejects datastore RHS (no shared ancestor)" $
          compatible builtinInherits (FamObject "datawindow") (FamObject "datastore") @?= False
      ]
  ]

-- | Slice of the real runtime/*.sru builtin class hierarchy (see
-- PB.Runtime.StdLib) relevant to the DataWindow-family ancestor tests
-- above -- kept in sync by hand rather than parsed, since this module has
-- no IO; PB.Runtime.StdLibTest.testInheritance exercises the real parsed
-- stdlib map end-to-end.
builtinInherits :: Map.Map Ident Ident
builtinInherits = Map.fromList
  [ ("windowobject",  "powerobject")
  , ("graphicobject", "windowobject")
  , ("dragobject",    "graphicobject")
  , ("datawindow",    "dragobject")
  , ("nonvisualobject", "powerobject")
  , ("datastore",     "nonvisualobject")
  ]
