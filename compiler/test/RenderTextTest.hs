module RenderTextTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, identMapEmpty, mkIdentSynthetic)
import PB.AST.SourceFile  (Param (..), SubSig (..))
import PB.AST.Type        (PbType (..))
import PB.Analysis.CallClassify (EffectTag (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (computeSignatures)
import PB.Explain.Pseudocode (Pseudocode (..), buildPseudocode)
import PB.Explain.Render.Text (renderText)
import PB.Lexing.Token (SourceSpan (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (testCase, (@?=))

-- | A bare local-variable reference, matching the shape 'PB.Compile.FromSSA'
-- always emits for a plain (non-subscripted) lvalue.
var :: Text -> Expr
var name = ExLvalue (Lvalue [LvSegment (ident name) Nothing])

ident :: Text -> Ident
ident = mkIdentSynthetic "RenderTextTest fixture"

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

emptySigMap :: IdentMap (Map.Map Ident (Either a SubSig))
emptySigMap = identMapEmpty

noSig :: Map.Map r a
noSig = Map.empty

-- | Build via a bare 'Eff', no callee-resolution/declared-sig machinery,
-- no signature computation (root's own inferred signature is 'Nothing').
build :: Eff () () -> Pseudocode
build term = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing noSig (extractEffTable term)

tests :: TestTree
tests = testGroup "PB.Explain.Render.Text"
  [ testCase "PAssign prints its declared type and a trailing backlink comment" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 5 (Just (PtPrimitive "integer")) :: Eff () ()
      in renderText (build term) @?= "  x: integer = 1  -- line 5"

  , testCase "PBranch prints an indented if/else block" $
      let term = branchEff (var "cond")
                   (EAssignWithRhs "a" (var "a") (ExInt "1") 2 Nothing)
                   (EAssignWithRhs "b" (var "b") (ExInt "2") 3 Nothing) 1 :: Eff () ()
          expected = T.intercalate "\n"
            [ "  if cond then  -- line 1"
            , "    a = 1  -- line 2"
            , "  else"
            , "    b = 2  -- line 3"
            , "  end if"
            ]
      in renderText (build term) @?= expected

  , testCase "PRegionRef prints a signature line: name(input: type, ...) -> (output: type, ...)" $
      let letBody = EAssignWithRhs "result" (var "result") (var "gv") 5 (Just (PtPrimitive "integer")) :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "result") 6 Nothing . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          env = emptyEnv
            { steGlobal = Map.singleton (ident "gv") (PtPrimitive "integer")
            , steLocal  = Map.singleton (ident "result") (PtPrimitive "integer")
            }
          sigs = computeSignatures defaultComplexityThreshold env Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold env emptySigMap Nothing sigs effTerm
          expected = T.intercalate "\n"
            [ "  -> region@5 (see below)"
            , "  y = result  -- line 6"
            , ""
            , "region@5(gv: integer) -> (result: integer) [pure]"
            , "  result: integer = gv  -- line 5"
            ]
      in renderText (pc { pcRootSig = Nothing }) @?= expected

  , testCase "an untyped (Nothing) binding prints without crashing, e.g. as a bare name" $
      let letBody = EAssignWithRhs "result" (var "result") (var "gv") 5 Nothing :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "result") 6 Nothing . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing sigs effTerm
          expected = T.intercalate "\n"
            [ "  -> region@5 (see below)"
            , "  y = result  -- line 6"
            , ""
            , "region@5(gv) -> (result) [pure]"
            , "  result = gv  -- line 5"
            ]
      in renderText (pc { pcRootSig = Nothing }) @?= expected

  , testCase "every PRegionRef in a render has a matching region block elsewhere in the same output" $
      let grandchild = EAssignWithRhs "z" (var "z") (ExInt "9") 20 Nothing :: Eff () ()
          trueArm = EAssignWithRhs "y" (var "y") (var "z") 11 Nothing . ELetRef "gc" :: Eff () ()
          falseArm = EAssignWithRhs "y" (var "y") (ExInt "0") 12 Nothing :: Eff () ()
          term = branchEff (var "cond") trueArm falseArm 10 :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("gc", grandchild)])
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing noSig effTerm
          rendered = renderText pc
      in T.count "region@20" rendered @?= 2

  , testCase "the root's declared and inferred signatures are both shown when they differ" $
      let declaredSig = Right SubSig
            { ssMods = [], ssName = ident "helper"
            , ssParams = [Param [] "integer" (SourceSpan 0 0 0 0) (ident "li_count")]
            , ssThrows = Nothing, ssLibrary = Nothing, ssAliasFor = Nothing
            }
          env = emptyEnv { steGlobal = Map.singleton (ident "gv") (PtPrimitive "boolean") }
          term = EAssignWithRhs "result" (var "result") (var "gv") 1 (Just (PtPrimitive "integer")) :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold env Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold env emptySigMap (Just declaredSig) sigs effTerm
          expected = T.intercalate "\n"
            [ "declared helper(integer li_count)"
            , "inferred helper(gv: boolean) -> () [pure]"
            , "  result: integer = gv  -- line 1"
            ]
      in renderText pc @?= expected

  , testCase "a genuinely effect-free region renders [pure]" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing sigs effTerm
          expected = T.intercalate "\n"
            [ "inferred root() -> () [pure]"
            , "  x = 1  -- line 1"
            ]
      in renderText pc @?= expected

  , testCase "an unresolved call degrades to showing no additional tags rather than erroring" $
      let term = ECall "unknown" [] 1 Set.empty :: Eff () ()
          resolveEffects = Map.singleton "known_other" (Set.fromList [WritesDb])
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv resolveEffects effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing sigs effTerm
          expected = T.intercalate "\n"
            [ "inferred root() -> () [pure]"
            , "  unknown()  -- line 1"
            ]
      in renderText pc @?= expected
  ]
