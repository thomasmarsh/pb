module SignaturesTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, identOrig, mkIdentSynthetic)
import PB.AST.Type        (PbType (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (VarBinding (..), InferredSignature (..), computeSignatures)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertBool, assertFailure, testCase, (@?=))

-- | A bare local-variable reference, matching the shape 'PB.Compile.FromSSA'
-- always emits for a plain (non-subscripted) lvalue.
var :: Text -> Expr
var name = ExLvalue (Lvalue [LvSegment (ident name) Nothing])

ident :: Text -> Ident
ident = mkIdentSynthetic "SignaturesTest fixture"

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

tests :: TestTree
tests = testGroup "PB.Explain.Signatures"
  [ testCase "a variable read before any local def in the region is a free input" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> assertBool
             ("expected \"x\" among free inputs, got " <> show (map vbName (sigInputs sig)))
             (any (\vb -> nameOf vb == "x") (sigInputs sig))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a variable defined and only used later within the same region is neither input nor output" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 2 Nothing
               . EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> do
             assertBool ("\"x\" must not be a free input, got " <> show (map vbName (sigInputs sig)))
               (not (any (\vb -> nameOf vb == "x") (sigInputs sig)))
             assertBool ("\"x\" must not be a live-out output, got " <> show (map vbName (sigOutputs sig)))
               (not (any (\vb -> nameOf vb == "x") (sigOutputs sig)))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a variable defined in the region and read after it (outside) is a live-out output" $
      let letBody = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "x") 2 Nothing . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv effTerm
          hasXOutput sig = any (\vb -> nameOf vb == "x") (sigOutputs sig)
      in assertBool
           ("expected some region to report \"x\" as a live-out output, got " <> show (Map.elems sigs))
           (any hasXOutput (Map.elems sigs))

  , testCase "a loop-carried variable is both an input (pre-loop value) and an output (post-loop value)" $
      let loopBody = J PInr . EAssignWithRhs "i" (var "i") (ExBinOp (var "i") BopAdd (ExInt "1")) 2 Nothing
                       :: Eff () (Either () ())
          term = ELoop loopBody 1 :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> do
             assertBool ("expected \"i\" among inputs, got " <> show (map vbName (sigInputs sig)))
               (any (\vb -> nameOf vb == "i") (sigInputs sig))
             assertBool ("expected \"i\" among outputs, got " <> show (map vbName (sigOutputs sig)))
               (any (\vb -> nameOf vb == "i") (sigOutputs sig))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "an input with a ScopedTypeEnv entry carries its real PbType" $
      let env = emptyEnv { steLocal = Map.singleton (ident "x") (PtPrimitive "integer") }
          term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> case filter (\vb -> nameOf vb == "x") (sigInputs sig) of
             [vb] -> vbType vb @?= Just (PtPrimitive "integer")
             other -> assertFailure ("expected exactly 1 binding named \"x\", got " <> show other)
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "an input with no ScopedTypeEnv entry carries Nothing, not an error" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> case filter (\vb -> nameOf vb == "x") (sigInputs sig) of
             [vb] -> vbType vb @?= Nothing
             other -> assertFailure ("expected exactly 1 binding named \"x\", got " <> show other)
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "the root region's inferred inputs can include a global/instance var absent from the declared param list" $
      let env = emptyEnv { steGlobal = Map.singleton (ident "gv") (PtPrimitive "integer")
                          , steParams = Set.empty
                          }
          term = EAssignWithRhs "y" (var "y") (var "gv") 1 Nothing :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> case filter (\vb -> nameOf vb == "gv") (sigInputs sig) of
             [vb] -> vbType vb @?= Just (PtPrimitive "integer")
             other -> assertFailure ("expected \"gv\" among inputs with a real type, got " <> show other)
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))
  ]
  where
    nameOf :: VarBinding -> Text
    nameOf vb = identOrig (vbName vb)
