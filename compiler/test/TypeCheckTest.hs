module TypeCheckTest (tests) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Ident       (identSetEmpty, identSetFromList, identSetSingleton, mkIdent)
import PB.AST.Located     (Located (..))
import PB.AST.Type        (PbType (..))
import PB.Analysis.ControlHierarchy (ControlDecl (..))
import PB.Analysis.TypeFamily
import PB.Analysis.TypeCheck
import PB.Lexing.Token    (Token (..), TokenKind (..), SourceSpan (..))

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

baseCtx :: TypeCheckCtx
baseCtx = TypeCheckCtx
  { tcScope          = Map.empty
  , tcProcMap        = Map.empty
  , tcInherits       = Map.empty
  , tcParams         = Map.empty
  , tcObjects        = identSetEmpty
  , tcUserTypes      = identSetEmpty
  , tcObject         = "w_main"
  , tcControlIdx     = Map.empty
  , tcBuiltinFns     = Set.empty
  , tcBuiltinMethods = Set.empty
  , tcOwnReturnType  = Nothing
  }

scope1 :: Map.Map Text TypeFamily
scope1 = Map.fromList [("li_x", FamNumeric), ("ls_y", FamString), ("lb_z", FamBoolean)]

varE :: Text -> Expr
varE n = ExLvalue (Lvalue [LvSegment (mkIdent n) Nothing])

callE :: Text -> Expr
callE n = ExCall { callee = Lvalue [LvSegment (mkIdent n) Nothing], callArgs = [] }

assignStmt :: Text -> Expr -> Int -> Located BodyStmt
assignStmt n rhs line = Located line (BsAssign (Lvalue [LvSegment (mkIdent n) Nothing]) rhs)

subscriptAssignStmt :: Text -> Expr -> Int -> Located BodyStmt
subscriptAssignStmt n rhs line = Located line (BsAssign (Lvalue [LvSegment (mkIdent n) (Just ["1"])]) rhs)

returnStmt :: Expr -> Int -> Located BodyStmt
returnStmt e line = Located line (BsReturn (Just e))

ifWrap :: [Located BodyStmt] -> Int -> Located BodyStmt
ifWrap thenBody line = Located line (BsIf IfStmt
  { ifCond = ExBool True, ifThen = thenBody, ifElseIfs = [], ifElse = Nothing })

-- Token-list construction for call-argument fixtures ('ExCall'\/'ExMethodCall'
-- args are raw '[Token]', not 'Expr' -- see 'PB.Analysis.TypeCheck's use of
-- 'PB.Grammar.Body.parseExpr').
mkTok :: TokenKind -> Text -> Token
mkTok k t = Token { tkKind = k, tkText = t, tkSpan = SourceSpan 0 0 0 }

intTok :: Text -> [Token]
intTok t = [mkTok TkIntLiteral t]

strTok :: Text -> [Token]
strTok t = [mkTok TkStringDouble ("\"" <> t <> "\"")]

identTok :: Text -> [Token]
identTok n = [mkTok TkIdent n]

callWithArgs :: Text -> [[Token]] -> Expr
callWithArgs n args = ExCall { callee = Lvalue [LvSegment (mkIdent n) Nothing], callArgs = args }

-- | Token list for @name(argToks)@ -- one argument, itself a call -- used to
-- build a "nested call as argument" fixture.
nestedCallArgTok :: Text -> [Token] -> [Token]
nestedCallArgTok n argToks = [mkTok TkIdent n, mkTok TkLParen "("] <> argToks <> [mkTok TkRParen ")"]

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "TypeCheck"
  [ testGroup "inferExpr: literals and local scope (ported from typeOfExpr)"
      [ testCase "bool literal -> boolean" $ inferExpr baseCtx (ExBool True) @?= Just FamBoolean
      , testCase "int literal -> numeric" $ inferExpr baseCtx (ExInt "5") @?= Just FamNumeric
      , testCase "real literal -> numeric" $ inferExpr baseCtx (ExReal "5.0") @?= Just FamNumeric
      , testCase "string literal -> string" $ inferExpr baseCtx (ExStr "hi") @?= Just FamString
      , testCase "date literal -> datetime" $ inferExpr baseCtx (ExDate "2026-01-01") @?= Just FamDateTime
      , testCase "time literal -> datetime" $ inferExpr baseCtx (ExTime "12:00:00") @?= Just FamDateTime
      , testCase "null literal -> Nothing (handled specially by callers, not a family)" $
          inferExpr baseCtx ExNull @?= Nothing
      , testCase "single-segment var resolves via scope" $
          inferExpr (baseCtx { tcScope = scope1 }) (varE "li_x") @?= Just FamNumeric
      , testCase "unresolved var name -> Nothing (no guessing)" $
          inferExpr (baseCtx { tcScope = scope1 }) (varE "unknown_var") @?= Nothing
      , testCase "numeric + numeric binop -> numeric" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExBinOp (varE "li_x") BopAdd (ExInt "1")) @?= Just FamNumeric
      , testCase "string + string binop (BopAdd concat) -> string" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExBinOp (varE "ls_y") BopAdd (ExStr "!")) @?= Just FamString
      , testCase "string + numeric binop -> Nothing (incompatible operand families)" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExBinOp (varE "ls_y") BopAdd (ExInt "1")) @?= Nothing
      , testCase "comparison binop -> boolean regardless of operand family" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExBinOp (varE "li_x") BopLt (ExInt "1")) @?= Just FamBoolean
      , testCase "logical And on two booleans -> boolean" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExBinOp (varE "lb_z") BopAnd (ExBool True)) @?= Just FamBoolean
      , testCase "logical And with a non-boolean operand -> Nothing" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExBinOp (varE "li_x") BopAnd (ExBool True)) @?= Nothing
      , testCase "Not on a boolean operand -> boolean" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExNot (varE "lb_z")) @?= Just FamBoolean
      , testCase "Not on a non-boolean operand -> Nothing" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExNot (varE "li_x")) @?= Nothing
      , testCase "Neg on a numeric operand -> numeric" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExNeg (varE "li_x")) @?= Just FamNumeric
      , testCase "Neg on a non-numeric operand -> Nothing" $
          inferExpr (baseCtx { tcScope = scope1 }) (ExNeg (varE "ls_y")) @?= Nothing
      , testCase "unresolved call expression -> Nothing" $
          inferExpr baseCtx (callE "f_get_value") @?= Nothing
      ]

  , testGroup "inferExpr: ExCall/ExMethodCall return-type lookup (new)"
      [ testCase "resolved virtual call -> declared return type" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_get"])]
                , tcParams  = Map.fromList [(("w_main", "of_get"), [ProcSignature [] (Just (PtPrimitive "integer"))])]
                }
          in inferExpr ctx (callE "of_get") @?= Just FamNumeric

      , testCase "resolved inherited call (ancestor chain) -> declared return type" $
          let ctx = baseCtx
                { tcObject   = "w_child"
                , tcInherits = Map.fromList [("w_child", "w_base")]
                , tcProcMap  = Map.fromList [("w_base", Set.fromList ["of_get"])]
                , tcParams   = Map.fromList [(("w_base", "of_get"), [ProcSignature [] (Just (PtPrimitive "string"))])]
                }
          in inferExpr ctx (callE "of_get") @?= Just FamString

      , testCase "call to a subroutine (no return type) -> Nothing" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_do"])]
                , tcParams  = Map.fromList [(("w_main", "of_do"), [ProcSignature [] Nothing])]
                }
          in inferExpr ctx (callE "of_do") @?= Nothing

      , testCase "builtin free-function call -> Nothing (no return-type map for builtins)" $
          let ctx = baseCtx { tcBuiltinFns = Set.singleton "messagebox" }
          in inferExpr ctx (callE "MessageBox") @?= Nothing

      , testCase "dotted static call to another object's function -> declared return type" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("n_util", Set.fromList ["of_helper"])]
                , tcParams  = Map.fromList [(("n_util", "of_helper"), [ProcSignature [] (Just (PtPrimitive "boolean"))])]
                }
              e = ExCall { callee = Lvalue [LvSegment "n_util" Nothing, LvSegment "of_helper" Nothing], callArgs = [] }
          in inferExpr ctx e @?= Just FamBoolean

      , testCase "method call on an object-typed local var -> resolved method's return type" $
          let ctx = baseCtx
                { tcScope   = Map.fromList [("lu_helper", FamObject "n_util")]
                , tcProcMap = Map.fromList [("n_util", Set.fromList ["of_helper"])]
                , tcParams  = Map.fromList [(("n_util", "of_helper"), [ProcSignature [] (Just (PtPrimitive "long"))])]
                }
              e = ExMethodCall { receiver = varE "lu_helper", method = "of_helper", methodArgs = [] }
          in inferExpr ctx e @?= Just FamNumeric

      , testCase "builtin method call -> Nothing" $
          let ctx = baseCtx
                { tcScope          = Map.fromList [("lds_1", FamObject "datastore")]
                , tcBuiltinMethods = Set.singleton "retrieve"
                }
              e = ExMethodCall { receiver = varE "lds_1", method = "Retrieve", methodArgs = [] }
          in inferExpr ctx e @?= Nothing

      , testCase "method call whose receiver can't be typed -> Nothing" $
          let e = ExMethodCall { receiver = varE "unknown", method = "of_helper", methodArgs = [] }
          in inferExpr baseCtx e @?= Nothing
      ]

  , testGroup "inferExpr: ExCreate/ExCreateUsing (new)"
      [ testCase "CREATE a known object class -> FamObject" $
          let ctx = baseCtx { tcObjects = identSetSingleton "n_cst_util" }
          in inferExpr ctx (ExCreate "n_cst_util") @?= Just (FamObject "n_cst_util")
      , testCase "CREATE a known object class, case-insensitive match" $
          let ctx = baseCtx { tcObjects = identSetSingleton "n_cst_util" }
          in inferExpr ctx (ExCreate "N_CST_UTIL") @?= Just (FamObject "n_cst_util")
      , testCase "CREATE an unknown class -> any (never guess)" $
          inferExpr baseCtx (ExCreate "xyz_unknown") @?= Just FamAny
      , testCase "CREATE USING a literal class name -> same as CREATE" $
          let ctx = baseCtx { tcObjects = identSetSingleton "n_cst_util" }
          in inferExpr ctx (ExCreateUsing (ExStr "n_cst_util")) @?= Just (FamObject "n_cst_util")
      , testCase "CREATE USING a non-literal expression -> Nothing" $
          inferExpr baseCtx (ExCreateUsing (varE "ls_classname")) @?= Nothing
      ]

  , testGroup "inferExpr: multi-segment ExLvalue member chain (new)"
      [ testCase "member chain resolves via ControlIndex -> FamObject" $
          let idx = Map.fromList
                [ ( ("w_main", "w_main", "tab1")
                  , ControlDecl { cdOwner = "w_main", cdName = "tab1", cdAncestorType = "tab"
                                , cdOverridesName = Nothing, cdDwBinding = Nothing }
                  )
                , ( ("w_main", "tab1", "page1")
                  , ControlDecl { cdOwner = "tab1", cdName = "page1", cdAncestorType = "uo_epidom"
                                , cdOverridesName = Nothing, cdDwBinding = Nothing }
                  )
                ]
              ctx = baseCtx { tcObjects = identSetSingleton "uo_epidom", tcControlIdx = idx }
              e = ExLvalue (Lvalue [LvSegment "tab1" Nothing, LvSegment "page1" Nothing])
          in inferExpr ctx e @?= Just (FamObject "uo_epidom")

      , testCase "member chain with no resolvable hop -> Nothing" $
          let e = ExLvalue (Lvalue [LvSegment "tab1" Nothing, LvSegment "page1" Nothing])
          in inferExpr baseCtx e @?= Nothing
      ]

  , testGroup "checkBody: assignment and return (ported from findTypeMismatches)"
      [ testCase "flags integer var assigned a string literal" $
          checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric)] }) "of_test"
                    [assignStmt "li_x" (ExStr "hello") 10]
            @?= [TypeMismatchFinding "w_main" "of_test" 10 "li_x" "numeric" "\"hello\"" AssignMismatch]

      , testCase "flags string var assigned a boolean literal" $
          checkBody (baseCtx { tcScope = Map.fromList [("ls_y", FamString)] }) "of_test"
                    [assignStmt "ls_y" (ExBool True) 5]
            @?= [TypeMismatchFinding "w_main" "of_test" 5 "ls_y" "string" "true" AssignMismatch]

      , testCase "does not flag matching-family literal assignment" $
          checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric)] }) "of_test"
                    [assignStmt "li_x" (ExInt "5") 1]
            @?= []

      , testCase "does not flag var-to-var assignment of compatible resolved kinds" $
          checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric), ("li_y", FamNumeric)] }) "of_test"
                    [assignStmt "li_x" (varE "li_y") 1]
            @?= []

      , testCase "flags var-to-var assignment of incompatible resolved kinds" $
          let fs = checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric), ("ls_y", FamString)] })
                             "of_test" [assignStmt "li_x" (varE "ls_y") 2]
          in map tmfKind fs @?= [AssignMismatch]

      , testCase "does not flag assignment to a null literal" $
          checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric)] }) "of_test"
                    [assignStmt "li_x" ExNull 1]
            @?= []

      , testCase "skips RHS shapes needing real inference (unresolved call expression)" $
          checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric)] }) "of_test"
                    [assignStmt "li_x" (callE "f_get") 1]
            @?= []

      , testCase "skips subscripted LHS lvalues" $
          checkBody (baseCtx { tcScope = Map.fromList [("la_arr", FamNumeric)] }) "of_test"
                    [subscriptAssignStmt "la_arr" (ExStr "bad") 1]
            @?= []

      , testCase "skips assignment when RHS var is itself unresolved" $
          checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric)] }) "of_test"
                    [assignStmt "li_x" (varE "lu_unknown") 1]
            @?= []

      , testCase "finds mismatches inside nested if bodies" $
          let fs = checkBody (baseCtx { tcScope = Map.fromList [("li_x", FamNumeric)] }) "of_test"
                             [ifWrap [assignStmt "li_x" (ExStr "bad") 7] 6]
          in map tmfLine fs @?= [7]

      , testCase "flags function return statement with incompatible type" $
          let ctx = baseCtx { tcOwnReturnType = Just (PtPrimitive "integer") }
          in checkBody ctx "of_get" [returnStmt (ExStr "bad") 12]
               @?= [TypeMismatchFinding "w_main" "of_get" 12 "of_get" "numeric" "\"bad\"" ReturnMismatch]

      , testCase "does not flag compatible function return statement" $
          let ctx = baseCtx { tcOwnReturnType = Just (PtPrimitive "integer") }
          in checkBody ctx "of_get" [returnStmt (ExInt "5") 12] @?= []

      , testCase "return-type lookup is unaffected by other overloads sharing this proc's name" $
          -- tcOwnReturnType is set directly by the caller (Runner.hs, from
          -- this specific declaration's own retType text), not looked up
          -- via tcParams keyed on (tcObject, procN) -- so a same-named
          -- overload with a different return type declared elsewhere in
          -- tcParams must not affect this check at all.
          let ctx = baseCtx
                { tcOwnReturnType = Just (PtPrimitive "integer")
                , tcParams = Map.fromList
                    [ (("w_main", "of_get"), [ProcSignature [("as_y", PtPrimitive "string")] (Just (PtPrimitive "string"))]) ]
                }
          in checkBody ctx "of_get" [returnStmt (ExInt "5") 12] @?= []
      ]

  , testGroup "checkBody: call-argument checking (new)"
      [ testCase "incompatible call-arg literal flags CallArgMismatch" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_take_int"])]
                , tcParams  = Map.fromList
                    [(("w_main", "of_take_int"), [ProcSignature [("ai_x", PtPrimitive "integer")] Nothing])]
                }
              fs = checkBody ctx "of_test" [Located 3 (BsCall (callWithArgs "of_take_int" [strTok "oops"]))]
          in fs @?= [TypeMismatchFinding "w_main" "of_test" 3 "ai_x" "numeric" "\"oops\"" CallArgMismatch]

      , testCase "compatible call-arg literal is not flagged" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_take_int"])]
                , tcParams  = Map.fromList
                    [(("w_main", "of_take_int"), [ProcSignature [("ai_x", PtPrimitive "integer")] Nothing])]
                }
          in checkBody ctx "of_test" [Located 3 (BsCall (callWithArgs "of_take_int" [intTok "5"]))] @?= []

      , testCase "call-arg typed through a caller-local variable is checked" $
          let ctx = baseCtx
                { tcScope   = Map.fromList [("ls_name", FamString)]
                , tcProcMap = Map.fromList [("w_main", Set.fromList ["of_take_int"])]
                , tcParams  = Map.fromList
                    [(("w_main", "of_take_int"), [ProcSignature [("ai_x", PtPrimitive "integer")] Nothing])]
                }
              fs = checkBody ctx "of_test" [Located 4 (BsCall (callWithArgs "of_take_int" [identTok "ls_name"]))]
          in map tmfKind fs @?= [CallArgMismatch]

      , testCase "object-subtype-compatible call-arg is not flagged" $
          let ctx = baseCtx
                { tcScope    = Map.fromList [("lw_child", FamObject "w_child")]
                , tcInherits = Map.fromList [("w_child", "w_base")]
                , tcProcMap  = Map.fromList [("w_main", Set.fromList ["of_take_base"])]
                , tcParams   = Map.fromList
                    [(("w_main", "of_take_base"), [ProcSignature [("aw_x", PtUserDefined "w_base")] Nothing])]
                , tcObjects  = identSetFromList ["w_base", "w_child"]
                }
          in checkBody ctx "of_test" [Located 5 (BsCall (callWithArgs "of_take_base" [identTok "lw_child"]))] @?= []

      , testCase "call to an unresolved/builtin target is skipped for arg-checking" $
          let ctx = baseCtx { tcBuiltinFns = Set.singleton "messagebox" }
          in checkBody ctx "of_test" [Located 6 (BsCall (callWithArgs "MessageBox" [intTok "5"]))] @?= []

      , testCase "fewer call-args than declared params is not flagged (arity mismatch ignored)" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_take_two"])]
                , tcParams  = Map.fromList
                    [ ( ("w_main", "of_take_two")
                      , [ProcSignature [("ai_x", PtPrimitive "integer"), ("as_y", PtPrimitive "string")] Nothing]
                      )
                    ]
                }
          in checkBody ctx "of_test" [Located 7 (BsCall (callWithArgs "of_take_two" [intTok "5"]))] @?= []

      , testCase "more call-args than declared params only checks the overlapping prefix" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_take_one"])]
                , tcParams  = Map.fromList
                    [(("w_main", "of_take_one"), [ProcSignature [("ai_x", PtPrimitive "integer")] Nothing])]
                }
          in checkBody ctx "of_test" [Located 8 (BsCall (callWithArgs "of_take_one" [intTok "5", strTok "extra"]))]
               @?= []

      , testCase "a mistyped nested call's own argument is still checked" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_outer", "of_inner"])]
                , tcParams  = Map.fromList
                    [ (("w_main", "of_outer"), [ProcSignature [("ai_x", PtPrimitive "integer")] Nothing])
                    , ( ("w_main", "of_inner")
                      , [ProcSignature [("ai_y", PtPrimitive "integer")] (Just (PtPrimitive "integer"))]
                      )
                    ]
                }
              stmt = BsCall (callWithArgs "of_outer" [nestedCallArgTok "of_inner" (strTok "bad")])
              fs   = checkBody ctx "of_test" [Located 9 stmt]
          in map tmfKind fs @?= [CallArgMismatch]
      ]

  , testGroup "buildParamsMap/selectSignature: PB function overloading (new)"
      -- Real-corpus regression (openpay's w_wizmain.getstep, overloaded on
      -- (string)/(integer) -- both arity 1): a name-only ((object, proc))
      -- lookup used to collapse both overloads to whichever parsed last,
      -- checking every call against the wrong one regardless of which
      -- overload it actually targets.
      [ testCase "call to a name with 2+ same-arity overloads is skipped (ambiguous, never guessed)" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["getstep"])]
                , tcParams  = Map.fromList
                    [ ( ("w_main", "getstep")
                      , [ ProcSignature [("as_stepname", PtPrimitive "string")]  (Just (PtUserDefined "bcv_step"))
                        , ProcSignature [("ai_pos",      PtPrimitive "integer")] (Just (PtUserDefined "bcv_step"))
                        ]
                      )
                    ]
                }
          in checkBody ctx "of_test" [Located 1 (BsCall (callWithArgs "getstep" [strTok "kratsel"]))] @?= []

      , testCase "return-type lookup for a same-arity-ambiguous overload is Nothing" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["getstep"])]
                , tcParams  = Map.fromList
                    [ ( ("w_main", "getstep")
                      , [ ProcSignature [("as_stepname", PtPrimitive "string")]  (Just (PtUserDefined "bcv_step"))
                        , ProcSignature [("ai_pos",      PtPrimitive "integer")] (Just (PtUserDefined "bcv_step"))
                        ]
                      )
                    ]
                }
          in inferExpr ctx (callWithArgs "getstep" [strTok "kratsel"]) @?= Nothing

      , testCase "overloads differing by arity correctly disambiguate via the call's actual arg count" $
          let ctx = baseCtx
                { tcProcMap = Map.fromList [("w_main", Set.fromList ["of_get"])]
                , tcParams  = Map.fromList
                    [ ( ("w_main", "of_get")
                      , [ ProcSignature [("ai_pos", PtPrimitive "integer")] (Just (PtPrimitive "long"))
                        , ProcSignature [("ai_pos", PtPrimitive "integer"), ("as_extra", PtPrimitive "string")]
                                        (Just (PtPrimitive "long"))
                        ]
                      )
                    ]
                }
              fs = checkBody ctx "of_test" [Located 2 (BsCall (callWithArgs "of_get" [strTok "kratsel"]))]
          in fs @?= [TypeMismatchFinding "w_main" "of_test" 2 "ai_pos" "numeric" "\"kratsel\"" CallArgMismatch]
      ]
  ]
