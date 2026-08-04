module PseudocodeTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.BodyStmt    (BodyStmt (..), IfStmt (..))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, identMapEmpty, identMapInsertWith, mkIdentSynthetic)
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile  (SubSig (..))
import PB.AST.Type        (PbType (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Compile.FromSSA (compileSsaToEff)
import PB.Compile.SSA     (buildSsa)
import PB.Explain.Regions (RegionId, defaultComplexityThreshold)
import PB.Explain.Signatures (ResolvedCallSiteMap, computeSignatures)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), RegionEntry (..), buildPseudocode, pseudocodeRegions)
import PB.Lexing.Token     (SourceSpan (..), Token (..), TokenKind (..))

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

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1 1)

-- | @adw.object.kodypal[row]@ -- a DataWindow property write with a member
-- chain and a subscript on the last segment, the exact shape
-- 'PB.Grammar.Body.parseLvalue' produces for corpus code like
-- @adw.object.kodypal[row] = gsc_misth_ypal.kodypal@.
dwPropertyLhs :: Expr
dwPropertyLhs = ExLvalue (Lvalue
  [ LvSegment (ident "adw") Nothing
  , LvSegment (ident "object") Nothing
  , LvSegment (ident "kodypal") (Just [mkTok TkIdent "row"])
  ])

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

emptySigMap :: IdentMap (Map.Map Ident (Either a SubSig))
emptySigMap = identMapEmpty

noSig :: Map.Map r a
noSig = Map.empty

noCallSites :: ResolvedCallSiteMap
noCallSites = Map.empty

-- | Build a 'Pseudocode' with no callee-resolution or declared-sig
-- machinery in play -- the shape most tests below only need.
build :: Int -> Eff () () -> Pseudocode
build threshold term =
  buildPseudocode threshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig (extractEffTable term)

rootStmts :: Pseudocode -> [PStmt]
rootStmts pc = case Map.lookup (pcRootRegion pc) (pcRegions pc) of
  Just stmts -> stmts
  Nothing    -> error "impossible: buildPseudocode always inserts pcRootRegion's own entry into pcRegions (closeState closes every region, including the root)"

-- | Every 'RegionId' a 'PRegionRef' reaches from a statement list, recursing
-- into 'PBranch'\/'PLoop' bodies -- used to check two arms of the same
-- branch don't reference the same region (a duplicate-tail regression),
-- independent of 'PB.Explain.Pseudocode.collectRegionRefs' (not exported).
regionRefIds :: [PStmt] -> Set.Set RegionId
regionRefIds = foldMap go
  where
    go (PRegionRef rid _ _) = Set.singleton rid
    go (PBranch _ t f _)    = regionRefIds t <> regionRefIds f
    go (PLoop body _)       = regionRefIds body
    go _                    = Set.empty

-- | Every 'PBranch' reachable from a statement list (its own cond/then/else/
-- line), including nested ones inside another 'PBranch'\/'PLoop' arm.
allBranches :: [PStmt] -> [(Expr, [PStmt], [PStmt], Int)]
allBranches = concatMap go
  where
    go (PBranch cond t f ln) = (cond, t, f, ln) : (allBranches t <> allBranches f)
    go (PLoop body _)        = allBranches body
    go _                     = []

helperSig :: SubSig
helperSig = SubSig { ssMods = [], ssName = ident "helper", ssParams = [], ssThrows = Nothing, ssLibrary = Nothing, ssAliasFor = Nothing }

tests :: TestTree
tests = testGroup "PB.Explain.Pseudocode"
  [ testCase "EAssign lowers to PAssign carrying its source line and declared type" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 5 (Just (PtPrimitive "integer")) Set.empty :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?= [PAssign "x" (Just (var "x")) (Just (PtPrimitive "integer")) (ExInt "1") 5]

  , testCase "a member/indexed LHS (adw.object.kodypal[row] = ...) carries its full LHS Expr into PAssign, not just the root var name" $
      let term = EAssignWithRhs "adw" dwPropertyLhs (var "gsc_misth_ypal") 8 Nothing Set.empty :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?= [PAssign "adw" (Just dwPropertyLhs) Nothing (var "gsc_misth_ypal") 8]

  , testCase "EBranch lowers to PBranch with both arms present" $
      let term = branchEff (var "cond")
                   (EAssignWithRhs "a" (var "a") (ExInt "1") 2 Nothing Set.empty)
                   (EAssignWithRhs "b" (var "b") (ExInt "2") 3 Nothing Set.empty) 1 :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?=
           [ PBranch (var "cond")
               [PAssign "a" (Just (var "a")) Nothing (ExInt "1") 2]
               [PAssign "b" (Just (var "b")) Nothing (ExInt "2") 3]
               1
           ]

  , testCase "ELoop lowers to PLoop" $
      let loopBody = J PInr . EAssignWithRhs "i" (var "i") (ExBinOp (var "i") BopAdd (ExInt "1")) 2 Nothing Set.empty
                       :: Eff () (Either () ())
          term = ELoop loopBody 1 :: Eff () ()
          pc = build defaultComplexityThreshold term
      in rootStmts pc @?=
           [ PLoop [PAssign "i" (Just (var "i")) Nothing (ExBinOp (var "i") BopAdd (ExInt "1")) 2] 1 ]

  , testCase "a cut RegionId lowers to PRegionRef carrying its InferredSignature" $
      let arm = EAssignWithRhs "a" (var "a") (ExInt "1") 2 Nothing Set.empty :: Eff () ()
          term = branchEff (var "cond") arm arm 1 :: Eff () ()
          sigs = computeSignatures 1 emptyEnv "proc" noCallSites Map.empty (extractEffTable term)
          pc = buildPseudocode 1 emptyEnv emptySigMap "proc" noCallSites Nothing sigs (extractEffTable term)
      in case rootStmts pc of
           [PRegionRef rid lns msig] -> do
             msig @?= Map.lookup rid sigs
             assertBool "expected a Just signature for the cut region" (isJust msig)
             Map.lookup rid (pcRegions pc)
               @?= Just [PBranch (var "cond") [PAssign "a" (Just (var "a")) Nothing (ExInt "1") 2] [PAssign "a" (Just (var "a")) Nothing (ExInt "1") 2] 1]
             lns @?= Just (1, 2)
           other -> assertFailure ("expected exactly 1 PRegionRef at root, got " <> show other)

  , testCase "if-without-else arms sharing a merge-point ELetRef -> PRegionRef appears once, at the tail of the enclosing region, not inside both branch arms" $
      -- Mirrors PB.Compile.FromSSA's real compiled shape: the true arm falls
      -- through to the shared post-merge continuation after its own
      -- assignment, the false arm (no else clause) IS the shared
      -- continuation. Both must resolve to a single PRegionRef hoisted
      -- after the PBranch, not one duplicated inside each arm's own
      -- statement list (doc/plan/226-explain-live-ui-regressions.md Layer 3).
      let mergeBody = EAssignWithRhs "y" (var "y") (var "x") 5 Nothing Set.empty :: Eff () ()
          trueArm   = EComp (ELetRef "merge") (EAssignWithRhs "x" (var "x") (ExInt "1") 2 Nothing Set.empty) :: Eff () ()
          falseArm  = ELetRef "merge" :: Eff () ()
          term      = branchEff (var "cond") trueArm falseArm 1 :: Eff () ()
          effTerm   = EffTerm term (Map.fromList [("merge", mergeBody)])
          pc        = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm
      in case rootStmts pc of
           [PBranch cond t f 1, PRegionRef rid _ _] -> do
             cond @?= var "cond"
             t @?= [PAssign "x" (Just (var "x")) Nothing (ExInt "1") 2]
             f @?= []
             Map.lookup rid (pcRegions pc) @?= Just [PAssign "y" (Just (var "y")) Nothing (var "x") 5]
           other -> assertFailure ("expected PBranch (no PRegionRef in either arm) followed by exactly one PRegionRef, got " <> show other)

  , testCase "real-pipeline regression: sequential if-without-else blocks (of_createwhere shape) never show the same RegionId in both a PBranch's then and else arms" $
      -- Real compiler pipeline (buildSsa -> compileSsaToEff -> buildPseudocode),
      -- not a hand-built Eff -- pins doc/plan/226-explain-live-ui-regressions.md's
      -- own of_createwhere finding: N sequential `if cond then x = ...; end if`
      -- blocks with no else, each one's implicit merge point shared between its
      -- own then-arm and else-arm.
      let lv = Lvalue [LvSegment (ident "ls_where") Nothing]
          ifBlock ln val = Located ln (BsIf (IfStmt (ExBool True) [Located (ln + 1) (BsAssign lv (ExInt val))] [] Nothing))
          body = [ifBlock 1 "10", ifBlock 3 "20", ifBlock 5 "30", Located 7 (BsReturn (Just (var "ls_where")))]
          ssaProc = buildSsa emptyEnv "of_createwhere" body
          effTerm = compileSsaToEff emptyEnv Set.empty ssaProc
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "of_createwhere" noCallSites Nothing noSig effTerm
          allStmts = concatMap reStmts (pseudocodeRegions pc)
          offenders = [ (ln, Set.intersection (regionRefIds t) (regionRefIds f))
                      | (_, t, f, ln) <- allBranches allStmts
                      , not (Set.null (Set.intersection (regionRefIds t) (regionRefIds f)))
                      ]
      in assertBool ("expected no PBranch with the same RegionId in both then and else arms, found offenders: " <> show offenders) (null offenders)

  , testCase "real-pipeline regression: a bare valueless return inside an if-arm renders its own PReturn leaf (Plan 228, w_gridfind.if_find shape)" $
      -- Real compiler pipeline (buildSsa -> compileSsaToEff -> buildPseudocode).
      -- Before Plan 228, a non-loop valueless 'return' compiled to 'J PId'
      -- (pure structural identity, no Eff leaf), so the true arm's own early
      -- exit vanished from the rendered pseudocode entirely -- a reader
      -- would see the arm's other statements and conclude execution falls
      -- through, the opposite of the source's actual control flow.
      let lv = Lvalue [LvSegment (ident "ls_x") Nothing]
          body =
            [ Located 1 (BsIf (IfStmt (ExBool True)
                [ Located 2 (BsAssign lv (ExInt "1"))
                , Located 3 (BsReturn Nothing)
                ] [] Nothing))
            , Located 5 (BsAssign lv (ExInt "2"))
            ]
          ssaProc = buildSsa emptyEnv "of_early_exit" body
          effTerm = compileSsaToEff emptyEnv Set.empty ssaProc
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "of_early_exit" noCallSites Nothing noSig effTerm
      in case rootStmts pc of
           [PBranch _ t f 1] -> do
             t @?= [PAssign "ls_x" (Just (var "ls_x")) Nothing (ExInt "1") 2, PReturn ExNull 3]
             case f of
               [PRegionRef rid _ _] ->
                 Map.lookup rid (pcRegions pc) @?= Just [PAssign "ls_x" (Just (var "ls_x")) Nothing (ExInt "2") 5]
               other -> assertFailure ("expected the false arm to be a single PRegionRef to the post-if code, got " <> show other)
           other -> assertFailure ("expected a single PBranch whose true arm ends with its own PReturn, got " <> show other)

  , testCase "two occurrences of the same ELetRef resolve to the same PRegionRef, not duplicated bodies" $
      let letBody = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          term = EComp (ELetRef "blk1") (ELetRef "blk1") :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing sigs effTerm
      in case rootStmts pc of
           [PRegionRef rid1 _ _, PRegionRef rid2 _ _] -> do
             rid1 @?= rid2
             Map.lookup rid1 (pcRegions pc) @?= Just [PAssign "x" (Just (var "x")) Nothing (ExInt "1") 1]
             length (Map.toList (pcRegions pc)) @?= 2  -- root + the one shared block, not 3
           other -> assertFailure ("expected exactly 2 PRegionRef entries at root, got " <> show other)

  , testCase "a resolved call's PCall carries its callee FnSig/SubSig via the resolved-call-site map" $
      let env = emptyEnv { steObject = ident "myobj" }
          sigMap = identMapInsertWith Map.union (ident "myobj") (Map.singleton (ident "helper") (Right helperSig)) identMapEmpty
          callSiteMap = Map.singleton ("myobj", "the_proc", 1, "helper") ("myobj", "helper")
          term = ECall "helper" [] 1 Set.empty :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold env sigMap "the_proc" callSiteMap Nothing noSig (extractEffTable term)
      in rootStmts pc @?= [PCall "helper" (Just (Right helperSig)) [] 1]

  , testCase "a dotted-looking call name resolves its declared signature via the same resolved-call-site map, not by parsing the call text" $
      let env = emptyEnv { steObject = ident "myobj" }
          sigMap = identMapInsertWith Map.union (ident "dw_1") (Map.singleton (ident "retrieve") (Right helperSig)) identMapEmpty
          callSiteMap = Map.singleton ("myobj", "the_proc", 1, "dw_1.retrieve") ("dw_1", "retrieve")
          term = ECall "dw_1.retrieve" [] 1 Set.empty :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold env sigMap "the_proc" callSiteMap Nothing noSig (extractEffTable term)
      in rootStmts pc @?= [PCall "dw_1.retrieve" (Just (Right helperSig)) [] 1]

  , testCase "an unresolved call sharing a line with an unrelated resolved call (a nested arg call, e.g. MessageBox(trn(x))) carries Nothing, not the sibling's target (Bug B, Plan 227 Phase 2)" $
      let env = emptyEnv { steObject = ident "myobj" }
          sigMap = identMapInsertWith Map.union (ident "global") (Map.singleton (ident "trn") (Right helperSig)) identMapEmpty
          callSiteMap = Map.singleton ("myobj", "the_proc", 103, "trn") ("global", "trn")
          term = ECall "MessageBox" [] 103 Set.empty :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold env sigMap "the_proc" callSiteMap Nothing noSig (extractEffTable term)
      in rootStmts pc @?= [PCall "MessageBox" Nothing [] 103]

  , testCase "an unresolved call's PCall carries Nothing, not an error" $
      let env = emptyEnv { steObject = ident "myobj" }
          term = ECall "unknownproc" [] 1 Set.empty :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold env emptySigMap "the_proc" noCallSites Nothing noSig (extractEffTable term)
      in rootStmts pc @?= [PCall "unknownproc" Nothing [] 1]

  , testCase "the root Pseudocode's pcDeclaredSig is Just the procedure's own FnSig/SubSig" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites (Just (Right helperSig)) noSig (extractEffTable term)
      in pcDeclaredSig pc @?= Just (Right helperSig)

  , testCase "the root Pseudocode's pcRootSig is Just its own InferredSignature from the sigs map" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing sigs effTerm
      in do
           assertBool "expected the sigs map to carry an entry for the root region" (isJust (Map.lookup (pcRootRegion pc) sigs))
           pcRootSig pc @?= Map.lookup (pcRootRegion pc) sigs
  , testGroup "pseudocodeRegions"
    [ testCase "returns the root region first regardless of encounter order" $
        let letBody = EAssignWithRhs "result" (var "result") (var "gv") 5 Nothing Set.empty :: Eff () ()
            term = EAssignWithRhs "y" (var "y") (var "result") 6 Nothing Set.empty . ELetRef "blk1" :: Eff () ()
            effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
            pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm
        in case pseudocodeRegions pc of
             (first : _) -> reId first @?= pcRootRegion pc
             []          -> assertFailure "expected at least the root entry"

    , testCase "de-duplicates a region referenced twice to a single entry" $
        let letBody = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing Set.empty :: Eff () ()
            term = EComp (ELetRef "blk1") (ELetRef "blk1") :: Eff () ()
            effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
            pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm
        in length (pseudocodeRegions pc) @?= 2  -- root + the one shared block, not 3

    , testCase "walks into nested PBranch/PLoop bodies to find every referenced region" $
        let grandchild = EAssignWithRhs "z" (var "z") (ExInt "9") 20 Nothing Set.empty :: Eff () ()
            trueArm = EAssignWithRhs "y" (var "y") (var "z") 11 Nothing Set.empty . ELetRef "gc" :: Eff () ()
            falseArm = EAssignWithRhs "y" (var "y") (ExInt "0") 12 Nothing Set.empty :: Eff () ()
            term = branchEff (var "cond") trueArm falseArm 10 :: Eff () ()
            effTerm = EffTerm term (Map.fromList [("gc", grandchild)])
            pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm
        in length (pseudocodeRegions pc) @?= 2  -- root + the nested grandchild
    ]
  ]
