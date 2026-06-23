module ChurchTest (tests) where

import Prelude
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), testCase)

import qualified Data.Text as T

import PB.AST.BodyStmt
import PB.AST.Expr     (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Located  (Located (..))
import PB.AST.Type     (PbType (..))
import PB.Pipeline.Church
import PB.Pipeline.TypeResolve (CallSite (..), LocalVar (..))

-- ---------------------------------------------------------------------------
-- Helpers

testCtx :: ProcCtx
testCtx = ("test.srf", "w_main", "uf_test")

-- | Simple single-segment lvalue.
simpleLv :: T.Text -> Lvalue
simpleLv nm = Lvalue [LvSegment nm Nothing]

-- | A bare function call expression.
simpleCall :: T.Text -> Expr
simpleCall nm = ExCall { callee = simpleLv nm, callArgs = [] }

localVarStmt :: T.Text -> PbType -> Int -> Located BodyStmt
localVarStmt nm ty line = Located line (BsLocalVar [] ty nm Nothing)

callStmt :: T.Text -> Int -> Located BodyStmt
callStmt nm line = Located line (BsCall (simpleCall nm))

-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "Church.Spike123"
  [ functorTests
  , roundTripTests
  , localVarAlgTests
  , callSiteAlgTests
  , fusedTests
  ]

-- ---------------------------------------------------------------------------
-- BodyStmtF Functor

functorTests :: TestTree
functorTests = testGroup "BodyStmtF Functor"
  [ testCase "fmap id on leaf is identity" $
      fmap id (BsRawF "hello" :: BodyStmtF ()) @?= BsRawF "hello"

  , testCase "fmap (+10) maps over [r] children of BsIfF" $
      fmap (+ 10) (BsIfF ExNull [1, 2] [] Nothing)
      @?= (BsIfF ExNull [11, 12] [] Nothing :: BodyStmtF Int)

  , testCase "fmap maps into elseif [r] list" $
      fmap (* 2) (BsIfF ExNull [] [(ExNull, [3, 4])] Nothing)
      @?= (BsIfF ExNull [] [(ExNull, [6, 8])] Nothing :: BodyStmtF Int)

  , testCase "fmap maps into BsDoF body, preserves DoCondition" $
      fmap negate (BsDoF Nothing [5, 6] Nothing)
      @?= (BsDoF Nothing [-5, -6] Nothing :: BodyStmtF Int)

  , testCase "fmap maps into BsChooseF clause bodies" $
      fmap (* 3) (BsChooseF ExNull [(Nothing, [2])])
      @?= (BsChooseF ExNull [(Nothing, [6])] :: BodyStmtF Int)

  , testCase "fmap composition law: fmap (f.g) == fmap f . fmap g" $
      let f = (+ 1) :: Int -> Int
          g = (* 2)
          node = BsIfF ExNull [3] [(ExNull, [4])] (Just [5]) :: BodyStmtF Int
      in fmap (f . g) node @?= (fmap f . fmap g) node
  ]

-- ---------------------------------------------------------------------------
-- toFix / fromFix round-trip

roundTripTests :: TestTree
roundTripTests = testGroup "toFix / fromFix round-trip"
  [ testCase "BsRaw round-trips" $
      fromFix (toFix (Located 5 (BsRaw "hello")))
      @?= Located 5 (BsRaw "hello")

  , testCase "BsLocalVar round-trips" $
      let s = localVarStmt "x" (PtPrimitive "integer") 3
      in fromFix (toFix s) @?= s

  , testCase "BsCall round-trips" $
      let s = callStmt "of_validate" 7
      in fromFix (toFix s) @?= s

  , testCase "BsIf with nested body round-trips" $
      let inner = Located 11 (BsRaw "x = 1")
          stmt  = Located 10 (BsIf (IfStmt ExNull [inner] [] Nothing))
      in fromFix (toFix stmt) @?= stmt

  , testCase "BsIf with elseif branch round-trips" $
      let thenB  = [Located 11 (BsRaw "x")]
          elseifB = [Located 13 (BsRaw "y")]
          stmt   = Located 10 (BsIf (IfStmt ExNull thenB [ElseIf ExNull elseifB] Nothing))
      in fromFix (toFix stmt) @?= stmt

  , testCase "BsFor with body round-trips" $
      let body = [Located 2 (BsRaw "x")]
          stmt = Located 1 (BsFor (ForStmt (simpleLv "i") ExNull ExNull Nothing body))
      in fromFix (toFix stmt) @?= stmt

  , testCase "BsDo while/loop round-trips" $
      let body = [Located 3 BsExit]
          stmt = Located 1 (BsDo (DoStmt (Just (DoWhile ExNull)) body Nothing))
      in fromFix (toFix stmt) @?= stmt

  , testCase "BsChoose with clauses round-trips" $
      let body = [Located 3 (BsRaw "x")]
          stmt = Located 1 (BsChoose (ChooseStmt ExNull [CaseClause Nothing body]))
      in fromFix (toFix stmt) @?= stmt
  ]

-- ---------------------------------------------------------------------------
-- extractLocalVarsAlg (via fusedExtractList)

localVarAlgTests :: TestTree
localVarAlgTests = testGroup "extractLocalVarsAlg"
  [ testCase "flat BsLocalVar produces expected LocalVar" $
      let body = [localVarStmt "ll_count" (PtPrimitive "long") 7]
          expected = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                , lvProcName = "uf_test", lvVarName = "ll_count"
                                , lvRawType = "long", lvIsParam = False
                                , lvScopeLine = 7, lvPbType = PtPrimitive "long" } ]
      in fst (fusedExtractList testCtx body) @?= expected

  , testCase "BsLocalVar inside if-then body is found" $
      let inner = localVarStmt "ls_name" (PtPrimitive "string") 12
          stmt  = Located 10 (BsIf (IfStmt ExNull [inner] [] Nothing))
          expected = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                , lvProcName = "uf_test", lvVarName = "ls_name"
                                , lvRawType = "string", lvIsParam = False
                                , lvScopeLine = 12, lvPbType = PtPrimitive "string" } ]
      in fst (fusedExtractList testCtx [stmt]) @?= expected

  , testCase "BsLocalVar inside else branch is found" $
      let inner = localVarStmt "li_n" (PtPrimitive "integer") 20
          stmt  = Located 18 (BsIf (IfStmt ExNull [] [] (Just [inner])))
          expected = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                , lvProcName = "uf_test", lvVarName = "li_n"
                                , lvRawType = "integer", lvIsParam = False
                                , lvScopeLine = 20, lvPbType = PtPrimitive "integer" } ]
      in fst (fusedExtractList testCtx [stmt]) @?= expected

  , testCase "BsLocalVar inside elseif branch is found" $
      let inner  = localVarStmt "ldt_val" (PtPrimitive "datetime") 25
          elseif = ElseIf ExNull [inner]
          stmt   = Located 22 (BsIf (IfStmt ExNull [] [elseif] Nothing))
          expected = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                , lvProcName = "uf_test", lvVarName = "ldt_val"
                                , lvRawType = "datetime", lvIsParam = False
                                , lvScopeLine = 25, lvPbType = PtPrimitive "datetime" } ]
      in fst (fusedExtractList testCtx [stmt]) @?= expected

  , testCase "BsLocalVar inside for body is found" $
      let inner = localVarStmt "ls_x" (PtPrimitive "string") 5
          stmt  = Located 1 (BsFor (ForStmt (simpleLv "i") ExNull ExNull Nothing [inner]))
          expected = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                , lvProcName = "uf_test", lvVarName = "ls_x"
                                , lvRawType = "string", lvIsParam = False
                                , lvScopeLine = 5, lvPbType = PtPrimitive "string" } ]
      in fst (fusedExtractList testCtx [stmt]) @?= expected

  , testCase "non-decl statements produce no LocalVars" $
      let body = [Located 1 (BsRaw ""), callStmt "foo" 2]
      in fst (fusedExtractList testCtx body) @?= []
  ]

-- ---------------------------------------------------------------------------
-- extractCallSitesAlg (via fusedExtractList)

callSiteAlgTests :: TestTree
callSiteAlgTests = testGroup "extractCallSitesAlg"
  [ testCase "BsCall produces expected CallSite" $
      let body = [callStmt "of_validate" 5]
          expected = [ CallSite { csFile = "test.srf", csObject = "w_main"
                                , csFromProc = "uf_test", csToName = "of_validate"
                                , csCallType = "ExCall", csLine = Just 5 } ]
      in snd (fusedExtractList testCtx body) @?= expected

  , testCase "call in if-condition is found" $
      let stmt = Located 8 (BsIf (IfStmt (simpleCall "isvalid") [] [] Nothing))
          expected = [ CallSite { csFile = "test.srf", csObject = "w_main"
                                , csFromProc = "uf_test", csToName = "isvalid"
                                , csCallType = "ExCall", csLine = Just 8 } ]
      in snd (fusedExtractList testCtx [stmt]) @?= expected

  , testCase "call in for-range is found" $
      let stmt = Located 3 (BsFor (ForStmt (simpleLv "i") (simpleCall "lowerbound") ExNull Nothing []))
          expected = [ CallSite { csFile = "test.srf", csObject = "w_main"
                                , csFromProc = "uf_test", csToName = "lowerbound"
                                , csCallType = "ExCall", csLine = Just 3 } ]
      in snd (fusedExtractList testCtx [stmt]) @?= expected

  , testCase "non-call statements produce no CallSites" $
      let body = [Located 1 (BsRaw ""), localVarStmt "x" (PtPrimitive "integer") 2]
      in snd (fusedExtractList testCtx body) @?= []
  ]

-- ---------------------------------------------------------------------------
-- fusedExtractList: both passes in one traversal

fusedTests :: TestTree
fusedTests = testGroup "fusedExtractList"
  [ testCase "simultaneous extraction matches individual expected outputs" $
      let varDecl   = localVarStmt "li_x" (PtPrimitive "integer") 1
          callExpr  = callStmt "of_init" 2
          body      = [varDecl, callExpr]
          (lvars, csites) = fusedExtractList testCtx body
          expectedLV = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                  , lvProcName = "uf_test", lvVarName = "li_x"
                                  , lvRawType = "integer", lvIsParam = False
                                  , lvScopeLine = 1, lvPbType = PtPrimitive "integer" } ]
          expectedCS = [ CallSite { csFile = "test.srf", csObject = "w_main"
                                  , csFromProc = "uf_test", csToName = "of_init"
                                  , csCallType = "ExCall", csLine = Just 2 } ]
      in do
          lvars  @?= expectedLV
          csites @?= expectedCS

  , testCase "mixed body: nested if with var and call both found" $
      let inner    = [localVarStmt "ls_row" (PtPrimitive "string") 5, callStmt "of_log" 6]
          stmt     = Located 4 (BsIf (IfStmt ExNull inner [] Nothing))
          (lvars, csites) = fusedExtractList testCtx [stmt]
          expectedLV = [ LocalVar { lvFile = "test.srf", lvObject = "w_main"
                                  , lvProcName = "uf_test", lvVarName = "ls_row"
                                  , lvRawType = "string", lvIsParam = False
                                  , lvScopeLine = 5, lvPbType = PtPrimitive "string" } ]
          expectedCS = [ CallSite { csFile = "test.srf", csObject = "w_main"
                                  , csFromProc = "uf_test", csToName = "of_log"
                                  , csCallType = "ExCall", csLine = Just 6 } ]
      in do
          lvars  @?= expectedLV
          csites @?= expectedCS
  ]
