module PseudocodeTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, identMapEmpty, identMapInsertWith, mkIdentSynthetic)
import PB.AST.SourceFile  (SubSig (..))
import PB.AST.Type        (PbType (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (computeSignatures)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), buildPseudocode)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertBool, assertFailure, testCase, (@?=))

-- | A bare local-variable reference, matching the shape 'PB.Compile.FromSSA'
-- always emits for a plain (non-subscripted) lvalue.
var :: Text -> Expr
var name = ExLvalue (Lvalue [LvSegment (ident name) Nothing])

ident :: Text -> Ident
ident = mkIdentSynthetic "PseudocodeTest fixture"

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

emptySigMap :: IdentMap (Map.Map Ident (Either a SubSig))
emptySigMap = identMapEmpty

noSig :: Map.Map r a
noSig = Map.empty

-- | Build a 'Pseudocode' with no callee-resolution or declared-sig
-- machinery in play -- the shape most tests below only need.
build :: Int -> Eff () () -> Pseudocode
build threshold term =
  buildPseudocode threshold emptyEnv emptySigMap Nothing noSig (extractEffTable term)

rootStmts :: Pseudocode -> [PStmt]
rootStmts pc = case Map.lookup (pcRootRegion pc) (pcRegions pc) of
  Just stmts -> stmts
  Nothing    -> error "impossible: buildPseudocode always inserts pcRootRegion's own entry into pcRegions (closeState closes every region, including the root)"

helperSig :: SubSig
helperSig = SubSig { ssMods = [], ssName = ident "helper", ssParams = [], ssThrows = Nothing, ssLibrary = Nothing, ssAliasFor = Nothing }

tests :: TestTree
tests = testGroup "PB.Explain.Pseudocode"
  [ testCase "EAssign lowers to PAssign carrying its source line and declared type" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 5 (Just (PtPrimitive "integer")) :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?= [PAssign "x" (Just (PtPrimitive "integer")) (ExInt "1") 5]

  , testCase "EBranch lowers to PBranch with both arms present" $
      let term = branchEff (var "cond")
                   (EAssignWithRhs "a" (var "a") (ExInt "1") 2 Nothing)
                   (EAssignWithRhs "b" (var "b") (ExInt "2") 3 Nothing) 1 :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?=
           [ PBranch (var "cond")
               [PAssign "a" Nothing (ExInt "1") 2]
               [PAssign "b" Nothing (ExInt "2") 3]
               1
           ]

  , testCase "ELoop lowers to PLoop" $
      let loopBody = J PInr . EAssignWithRhs "i" (var "i") (ExBinOp (var "i") BopAdd (ExInt "1")) 2 Nothing
                       :: Eff () (Either () ())
          term = ELoop loopBody 1 :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?=
           [ PLoop [PAssign "i" Nothing (ExBinOp (var "i") BopAdd (ExInt "1")) 2] 1 ]

  , testCase "a cut RegionId lowers to PRegionRef carrying its InferredSignature" $
      let arm = EAssignWithRhs "a" (var "a") (ExInt "1") 2 Nothing :: Eff () ()
          term = branchEff (var "cond") arm arm 1 :: Eff () ()
          sigs = computeSignatures 1 emptyEnv (extractEffTable term)
          pc = buildPseudocode 1 emptyEnv emptySigMap Nothing sigs (extractEffTable term)
      in case rootStmts pc of
           [PRegionRef rid lns msig] -> do
             msig @?= Map.lookup rid sigs
             assertBool "expected a Just signature for the cut region" (isJust msig)
             Map.lookup rid (pcRegions pc)
               @?= Just [PBranch (var "cond") [PAssign "a" Nothing (ExInt "1") 2] [PAssign "a" Nothing (ExInt "1") 2] 1]
             lns @?= (1, 2)
           other -> assertFailure ("expected exactly 1 PRegionRef at root, got " <> show other)

  , testCase "two occurrences of the same ELetRef resolve to the same PRegionRef, not duplicated bodies" $
      let letBody = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          term = EComp (ELetRef "blk1") (ELetRef "blk1") :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing sigs effTerm
      in case rootStmts pc of
           [PRegionRef rid1 _ _, PRegionRef rid2 _ _] -> do
             rid1 @?= rid2
             Map.lookup rid1 (pcRegions pc) @?= Just [PAssign "x" Nothing (ExInt "1") 1]
             length (Map.toList (pcRegions pc)) @?= 2  -- root + the one shared block, not 3
           other -> assertFailure ("expected exactly 2 PRegionRef entries at root, got " <> show other)

  , testCase "a resolved call's PCall carries its callee FnSig/SubSig from buildCallableSigMap" $
      let env = emptyEnv { steObject = ident "myobj" }
          sigMap = identMapInsertWith Map.union (ident "myobj") (Map.singleton (ident "helper") (Right helperSig)) identMapEmpty
          term = ECall "helper" [] 1 :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold env sigMap Nothing noSig (extractEffTable term)
      in rootStmts pc @?= [PCall "helper" (Just (Right helperSig)) [] 1]

  , testCase "an unresolved call's PCall carries Nothing, not an error" $
      let env = emptyEnv { steObject = ident "myobj" }
          term = ECall "unknownproc" [] 1 :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold env emptySigMap Nothing noSig (extractEffTable term)
      in rootStmts pc @?= [PCall "unknownproc" Nothing [] 1]

  , testCase "the root Pseudocode's pcDeclaredSig is Just the procedure's own FnSig/SubSig" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap (Just (Right helperSig)) noSig (extractEffTable term)
      in pcDeclaredSig pc @?= Just (Right helperSig)
  ]
