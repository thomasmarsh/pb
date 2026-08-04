module SignaturesTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, identOrig, mkIdentSynthetic)
import PB.AST.Type        (PbType (..))
import PB.Analysis.CallClassify (EffectTag (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (VarBinding (..), InferredSignature (..), RegionKind (..), ResolvedCallSiteMap, computeSignatures)

import Data.List.NonEmpty (NonEmpty (..))
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

noCallSites :: ResolvedCallSiteMap
noCallSites = Map.empty

tests :: TestTree
tests = testGroup "PB.Explain.Signatures"
  [ testCase "a variable read before any local def in the region is a free input" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> assertBool
             ("expected \"x\" among free inputs, got " <> show (map vbName (sigInputs sig)))
             (any (\vb -> nameOf vb == "x") (sigInputs sig))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a variable defined and only used later within the same region is neither input nor output" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 2 Nothing Set.empty
               . EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> do
             assertBool ("\"x\" must not be a free input, got " <> show (map vbName (sigInputs sig)))
               (not (any (\vb -> nameOf vb == "x") (sigInputs sig)))
             assertBool ("\"x\" must not be a live-out output, got " <> show (map vbName (sigOutputs sig)))
               (not (any (\vb -> nameOf vb == "x") (sigOutputs sig)))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a variable defined in the region and read after it (outside) is a live-out output" $
      let letBody = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "x") 2 Nothing Set.empty . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          hasXOutput sig = any (\vb -> nameOf vb == "x") (sigOutputs sig)
      in assertBool
           ("expected some region to report \"x\" as a live-out output, got " <> show (Map.elems sigs))
           (any hasXOutput (Map.elems sigs))

  , testCase "a loop-carried variable is both an input (pre-loop value) and an output (post-loop value)" $
      let loopBody = J PInr . EAssignWithRhs "i" (var "i") (ExBinOp (var "i") BopAdd (ExInt "1")) 2 Nothing Set.empty
                       :: Eff () (Either () ())
          term = ELoop loopBody 1 :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> do
             assertBool ("expected \"i\" among inputs, got " <> show (map vbName (sigInputs sig)))
               (any (\vb -> nameOf vb == "i") (sigInputs sig))
             assertBool ("expected \"i\" among outputs, got " <> show (map vbName (sigOutputs sig)))
               (any (\vb -> nameOf vb == "i") (sigOutputs sig))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "an input with a ScopedTypeEnv entry carries its real PbType" $
      let env = emptyEnv { steLocal = Map.singleton (ident "x") (PtPrimitive "integer") }
          term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> case filter (\vb -> nameOf vb == "x") (sigInputs sig) of
             [vb] -> vbType vb @?= Just (PtPrimitive "integer")
             other -> assertFailure ("expected exactly 1 binding named \"x\", got " <> show other)
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "an input with no ScopedTypeEnv entry carries Nothing, not an error" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> case filter (\vb -> nameOf vb == "x") (sigInputs sig) of
             [vb] -> vbType vb @?= Nothing
             other -> assertFailure ("expected exactly 1 binding named \"x\", got " <> show other)
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "the root region's inferred inputs can include a global/instance var absent from the declared param list" $
      let env = emptyEnv { steGlobal = Map.singleton (ident "gv") (PtPrimitive "integer")
                          , steParams = Set.empty
                          }
          term = EAssignWithRhs "y" (var "y") (var "gv") 1 Nothing Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> case filter (\vb -> nameOf vb == "gv") (sigInputs sig) of
             [vb] -> vbType vb @?= Just (PtPrimitive "integer")
             other -> assertFailure ("expected \"gv\" among inputs with a real type, got " <> show other)
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a region with a direct effect shows its own tags" $
      let term = ECall "helper" [] 1 (Set.fromList [WritesDb]) :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.fromList [WritesDb]
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a region with a direct effect from an assigned-result call (EAssignWithRhs's own tag field) shows its own tags (Bug A, Plan 227 Phase 2)" $
      -- ll_nrows = idw.rowcount()-shaped leaf: the call's classified tags
      -- live on EAssignWithRhs's own trailing field, not derived from the
      -- RHS Expr at this layer -- this only confirms sigAccLeaf reads it.
      let term = EAssignWithRhs "ll_nrows" (var "ll_nrows") (var "idw") 1 Nothing (Set.fromList [ReadsControlState]) :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.fromList [ReadsControlState]
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a region with no direct effect but a call resolved via the corpus-wide resolved-call-site map shows the callee's transitive tags from procEffects" $
      let env = emptyEnv { steObject = ident "w_self" }
          callSiteMap = Map.singleton ("w_self", "the_proc", 1, "helper") ("w_self", "helper")
          procEffects = Map.singleton ("w_self", "helper") (Set.fromList [ReadsDb, Suspends])
          term = ECall "helper" [] 1 Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "the_proc" callSiteMap procEffects (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.fromList [ReadsDb, Suspends]
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a dotted-looking call name resolves fine, since resolution keys on (object, proc, line), never on the call name's own text shape" $
      let env = emptyEnv { steObject = ident "w_self" }
          callSiteMap = Map.singleton ("w_self", "the_proc", 1, "dw_1.retrieve") ("dw_1", "retrieve")
          procEffects = Map.singleton ("dw_1", "retrieve") (Set.fromList [Suspends, WritesDb])
          term = ECall "dw_1.retrieve" [] 1 Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "the_proc" callSiteMap procEffects (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.fromList [Suspends, WritesDb]
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "an unresolved call site (absent from the resolved-call-site map) contributes no transitive tags, even if procEffects has an entry under that bare name for a different object" $
      let env = emptyEnv { steObject = ident "w_self" }
          procEffects = Map.singleton ("w_other", "helper") (Set.fromList [ReadsDb])
          term = ECall "helper" [] 1 Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "the_proc" noCallSites procEffects (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.empty
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "two distinct calls sharing one source line resolve independently, not by whichever row was built last (Bug B, Plan 227 Phase 2)" $
      -- MessageBox(trn(68), trn(161))-shaped real corpus line: MessageBox
      -- itself is unresolved (a builtin, no row in callSiteMap); trn is a
      -- real resolved corpus function with its own effects. Before the
      -- fix, sigAccLeaf's (object, proc, line) lookup for MessageBox's own
      -- LCall would collide with trn's row on the same line and
      -- misattribute trn's ReadsDb onto MessageBox.
      let env = emptyEnv { steObject = ident "w_self" }
          callSiteMap = Map.singleton ("w_self", "the_proc", 103, "trn") ("global", "trn")
          procEffects = Map.singleton ("global", "trn") (Set.fromList [ReadsDb])
          term = ECall "MessageBox" [] 103 Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "the_proc" callSiteMap procEffects (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.empty
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "two different call lines in the same procedure resolve to their own distinct targets, not a name-only merge" $
      let env = emptyEnv { steObject = ident "w_self" }
          callSiteMap = Map.fromList
            [ (("w_self", "the_proc", 1, "helper_a"), ("w_self", "helper_a"))
            , (("w_self", "the_proc", 2, "helper_b"), ("w_other", "helper_b"))
            ]
          procEffects = Map.fromList
            [ (("w_self", "helper_a"), Set.fromList [ReadsDb])
            , (("w_other", "helper_b"), Set.fromList [WritesDb])
            ]
          term = EComp (ECall "helper_b" [] 2 Set.empty) (ECall "helper_a" [] 1 Set.empty) :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold env "the_proc" callSiteMap procEffects (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigEffects sig @?= Set.fromList [ReadsDb, WritesDb]
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a variable used within its own defining region and in another region is still live-out" $
      let letBody = EAssignWithRhs "y2" (var "y2") (var "x") 2 Nothing Set.empty
                   . EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "x") 3 Nothing Set.empty . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          hasXOutput sig = any (\vb -> nameOf vb == "x") (sigOutputs sig)
      in assertBool
           ("expected the region defining \"x\" to still report it as live-out even though that "
             <> "same region also reads \"x\" itself, got " <> show (Map.elems sigs))
           (any hasXOutput (Map.elems sigs))

  , testCase "a SELECT-INTO-shaped def (ECall composed with EAssignWithRhs) is not promoted into the region's free-input signature" $
      -- Mirrors the real bug: PB.Compile.FromSSA compiles a BsRaw
      -- `SELECT ... INTO :ls_var FROM ...` as its short-named ECall effect
      -- composed with an EAssignWithRhs def for ls_var. A later read of
      -- ls_var in the same region must not look like a free external input.
      let term = EAssignWithRhs "y" (var "y") (var "ls_var") 2 Nothing Set.empty
               . EAssignWithRhs "ls_var" (var "ls_var") (ExRaw []) 1 Nothing Set.empty
               . ECall "select" [] 1 Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> assertBool
             ("\"ls_var\" must not be a free input, got " <> show (map vbName (sigInputs sig)))
             (not (any (\vb -> nameOf vb == "ls_var") (sigInputs sig)))
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a region with no effects has sigKind PureRegion (Plan 227 Phase 2 ferry type)" $
      let term = EAssignWithRhs "y" (var "y") (var "x") 1 Nothing Set.empty :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigKind sig @?= PureRegion
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))

  , testCase "a region with a direct effect has sigKind EffectfulRegion carrying exactly its sigEffects tags" $
      let term = ECall "helper" [] 1 (Set.fromList [WritesDb]) :: Eff () ()
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
      in case Map.elems sigs of
           [sig] -> sigKind sig @?= EffectfulRegion (WritesDb :| [])
           other -> assertFailure ("expected exactly 1 region, got " <> show (length other))
  ]
  where
    nameOf :: VarBinding -> Text
    nameOf vb = identOrig (vbName vb)
