module TypeMismatchTest (tests) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import PB.AST.Type        (PbType (..))
import PB.Analysis.TypeResolve (ResolvedType (..))
import PB.Analysis.TypeMismatch

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

emptySrFile :: SrFile
emptySrFile = SrFile
  { srHeaders         = []
  , srForward         = Nothing
  , srPrototypes      = Nothing
  , srVariables       = Nothing
  , srGlobalInstances = []
  , srTypeBlocks      = []
  , srOnBlocks        = []
  , srEvents          = []
  , srFunctions       = []
  , srSubroutines     = []
  }

mkFn :: Text -> Text -> [Located BodyStmt] -> FunctionBlock
mkFn retTy nm body = FunctionBlock
  { fbSig = FnSig
      { fnsMods       = []
      , fnsReturnType = retTy
      , fnsName       = nm
      , fnsParams     = ""
      , fnsThrows     = Nothing
      }
  , fbBody = body
  }

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

varE :: Text -> Expr
varE n = ExLvalue (Lvalue [LvSegment n Nothing])

callE :: Text -> Expr
callE n = ExCall { callee = Lvalue [LvSegment n Nothing], callArgs = [] }

assignStmt :: Text -> Expr -> Int -> Located BodyStmt
assignStmt n rhs line = Located line (BsAssign (Lvalue [LvSegment n Nothing]) rhs)

subscriptAssignStmt :: Text -> Expr -> Int -> Located BodyStmt
subscriptAssignStmt n rhs line = Located line (BsAssign (Lvalue [LvSegment n (Just ["1"])]) rhs)

returnStmt :: Expr -> Int -> Located BodyStmt
returnStmt e line = Located line (BsReturn (Just e))

ifWrap :: [Located BodyStmt] -> Int -> Located BodyStmt
ifWrap thenBody line = Located line (BsIf IfStmt
  { ifCond = ExBool True, ifThen = thenBody, ifElseIfs = [], ifElse = Nothing })

scope1 :: Map.Map Text TypeFamily
scope1 = Map.fromList [("li_x", FamNumeric), ("ls_y", FamString), ("lb_z", FamBoolean)]

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "TypeMismatch"
  [ testGroup "classifyFamily" $
      [ testCase (name <> " -> " <> show expected) $
          classifyFamily (PtPrimitive raw) Set.empty Set.empty @?= expected
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
          classifyFamily PtAny Set.empty Set.empty @?= FamAny
      , testCase "PtDecimalPrec -> numeric" $
          classifyFamily (PtDecimalPrec 10) Set.empty Set.empty @?= FamNumeric
      , testCase "PtPrimitive datawindow (builtin class) -> object" $
          classifyFamily (PtPrimitive "datawindow") Set.empty Set.empty @?= FamObject "datawindow"
      , testCase "PtUserDefined in object set -> object with target" $
          classifyFamily (PtUserDefined "w_main") (Set.singleton "w_main") Set.empty @?= FamObject "w_main"
      , testCase "PtUserDefined in user type set -> user_type with target" $
          classifyFamily (PtUserDefined "st_info") Set.empty (Set.singleton "st_info") @?= FamUserType "st_info"
      , testCase "PtUserDefined unresolved -> any (never guess)" $
          classifyFamily (PtUserDefined "xyz_unknown") Set.empty Set.empty @?= FamAny
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
      , testCase "object LHS rejects supertype-direction mismatch" $
          compatible (Map.fromList [("w_child", "w_base")]) (FamObject "w_child") (FamObject "w_base") @?= False
      , testCase "user_type LHS accepts exact-match user_type RHS" $
          compatible Map.empty (FamUserType "st_a") (FamUserType "st_a") @?= True
      , testCase "user_type LHS rejects mismatched user_type RHS" $
          compatible Map.empty (FamUserType "st_a") (FamUserType "st_b") @?= False
      ]

  , testGroup "typeOfExpr"
      [ testCase "bool literal -> boolean" $ typeOfExpr Map.empty (ExBool True) @?= Just FamBoolean
      , testCase "int literal -> numeric" $ typeOfExpr Map.empty (ExInt "5") @?= Just FamNumeric
      , testCase "real literal -> numeric" $ typeOfExpr Map.empty (ExReal "5.0") @?= Just FamNumeric
      , testCase "string literal -> string" $ typeOfExpr Map.empty (ExStr "hi") @?= Just FamString
      , testCase "date literal -> datetime" $ typeOfExpr Map.empty (ExDate "2026-01-01") @?= Just FamDateTime
      , testCase "time literal -> datetime" $ typeOfExpr Map.empty (ExTime "12:00:00") @?= Just FamDateTime
      , testCase "null literal -> Nothing (handled specially by callers, not a family)" $
          typeOfExpr Map.empty ExNull @?= Nothing
      , testCase "single-segment var resolves via scope" $
          typeOfExpr scope1 (varE "li_x") @?= Just FamNumeric
      , testCase "unresolved var name -> Nothing (no guessing)" $
          typeOfExpr scope1 (varE "unknown_var") @?= Nothing
      , testCase "numeric + numeric binop -> numeric" $
          typeOfExpr scope1 (ExBinOp (varE "li_x") BopAdd (ExInt "1")) @?= Just FamNumeric
      , testCase "string + string binop (BopAdd concat) -> string" $
          typeOfExpr scope1 (ExBinOp (varE "ls_y") BopAdd (ExStr "!")) @?= Just FamString
      , testCase "string + numeric binop -> Nothing (incompatible operand families)" $
          typeOfExpr scope1 (ExBinOp (varE "ls_y") BopAdd (ExInt "1")) @?= Nothing
      , testCase "comparison binop -> boolean regardless of operand family" $
          typeOfExpr scope1 (ExBinOp (varE "li_x") BopLt (ExInt "1")) @?= Just FamBoolean
      , testCase "logical And on two booleans -> boolean" $
          typeOfExpr scope1 (ExBinOp (varE "lb_z") BopAnd (ExBool True)) @?= Just FamBoolean
      , testCase "logical And with a non-boolean operand -> Nothing" $
          typeOfExpr scope1 (ExBinOp (varE "li_x") BopAnd (ExBool True)) @?= Nothing
      , testCase "Not on a boolean operand -> boolean" $
          typeOfExpr scope1 (ExNot (varE "lb_z")) @?= Just FamBoolean
      , testCase "Not on a non-boolean operand -> Nothing" $
          typeOfExpr scope1 (ExNot (varE "li_x")) @?= Nothing
      , testCase "Neg on a numeric operand -> numeric" $
          typeOfExpr scope1 (ExNeg (varE "li_x")) @?= Just FamNumeric
      , testCase "Neg on a non-numeric operand -> Nothing" $
          typeOfExpr scope1 (ExNeg (varE "ls_y")) @?= Nothing
      , testCase "call expression -> Nothing (needs real inference)" $
          typeOfExpr scope1 (callE "f_get_value") @?= Nothing
      ]

  , testGroup "findTypeMismatches"
      [ testCase "flags integer var assigned a string literal" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" (ExStr "hello") 10]] }
              rts = [mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing]
              fs  = findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf
          in fs @?= [TypeMismatchFinding "w_main" "of_test" 10 "li_x" "numeric" "\"hello\"" AssignMismatch]

      , testCase "flags string var assigned a boolean literal" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "ls_y" (ExBool True) 5]] }
              rts = [mkRT "w_main" "of_test" "ls_y" "string" "primitive" Nothing]
              fs  = findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf
          in fs @?= [TypeMismatchFinding "w_main" "of_test" 5 "ls_y" "string" "true" AssignMismatch]

      , testCase "does not flag matching-family literal assignment" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" (ExInt "5") 1]] }
              rts = [mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing]
          in findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []

      , testCase "does not flag var-to-var assignment of compatible resolved kinds" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" (varE "li_y") 1]] }
              rts = [ mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing
                    , mkRT "w_main" "of_test" "li_y" "integer" "primitive" Nothing ]
          in findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []

      , testCase "flags var-to-var assignment of incompatible resolved kinds" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" (varE "ls_y") 2]] }
              rts = [ mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing
                    , mkRT "w_main" "of_test" "ls_y" "string"  "primitive" Nothing ]
              fs  = findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf
          in map tmfKind fs @?= [AssignMismatch]

      , testCase "does not flag assignment to a null literal" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" ExNull 1]] }
              rts = [mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing]
          in findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []

      , testCase "skips RHS shapes needing real inference (call expression)" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" (callE "f_get") 1]] }
              rts = [mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing]
          in findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []

      , testCase "skips subscripted LHS lvalues" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [subscriptAssignStmt "la_arr" (ExStr "bad") 1]] }
              rts = [mkRT "w_main" "of_test" "la_arr" "integer" "primitive" Nothing]
          in findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []

      , testCase "skips assignment when RHS var is itself unresolved" $
          let sf  = emptySrFile { srFunctions = [mkFn "integer" "of_test" [assignStmt "li_x" (varE "lu_unknown") 1]] }
              rts = [mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing]
          in findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []

      , testCase "finds mismatches inside nested if bodies" $
          let sf  = emptySrFile
                { srFunctions = [mkFn "integer" "of_test" [ifWrap [assignStmt "li_x" (ExStr "bad") 7] 6]] }
              rts = [mkRT "w_main" "of_test" "li_x" "integer" "primitive" Nothing]
              fs  = findTypeMismatches rts Set.empty Set.empty Map.empty "f.srw" "w_main" sf
          in map tmfLine fs @?= [7]

      , testCase "flags function return statement with incompatible type" $
          let sf = emptySrFile { srFunctions = [mkFn "integer" "of_get" [returnStmt (ExStr "bad") 12]] }
              fs = findTypeMismatches [] Set.empty Set.empty Map.empty "f.srw" "w_main" sf
          in fs @?= [TypeMismatchFinding "w_main" "of_get" 12 "of_get" "numeric" "\"bad\"" ReturnMismatch]

      , testCase "does not flag compatible function return statement" $
          let sf = emptySrFile { srFunctions = [mkFn "integer" "of_get" [returnStmt (ExInt "5") 12]] }
          in findTypeMismatches [] Set.empty Set.empty Map.empty "f.srw" "w_main" sf @?= []
      ]
  ]
