module SimplifyTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, IdentSet, identMapEmpty, identSetEmpty, identSetFromList, mkIdentSynthetic)
import PB.AST.SourceFile  (Param (..), SubSig (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (ResolvedCallSiteMap, computeSignatures)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), buildPseudocode)
import PB.Explain.Simplify (collapseBooleanBranch, dropDeadStores, inlineForwardingRegions, simplifyPseudocode)
import PB.Lexing.Token (SourceSpan (..))

import Data.List (partition)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Hedgehog (Gen, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

var :: Text -> Expr
var name = ExLvalue (Lvalue [LvSegment (ident name) Nothing])

ident :: Text -> Ident
ident = mkIdentSynthetic "SimplifyTest fixture"

safeVars :: [Text] -> IdentSet
safeVars ts = identSetFromList (map ident ts)

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

emptySigMap :: IdentMap (Map.Map Ident (Either a SubSig))
emptySigMap = identMapEmpty

noSig :: Map.Map r a
noSig = Map.empty

noCallSites :: ResolvedCallSiteMap
noCallSites = Map.empty

tests :: TestTree
tests = testGroup "PB.Explain.Simplify"
  [ testGroup "dropDeadStores"
    [ testCase "a dead store immediately overwritten before any read is dropped" $
        let stmts = [ PAssign "x" Nothing Nothing (ExInt "1") 1, PAssign "x" Nothing Nothing (ExInt "2") 2, PReturn (var "x") 3 ]
        in dropDeadStores (safeVars ["x"]) stmts @?= [ PAssign "x" Nothing Nothing (ExInt "2") 2, PReturn (var "x") 3 ]

    , testCase "a store read before being overwritten is kept" $
        let stmts = [ PAssign "x" Nothing Nothing (ExInt "1") 1, PReturn (var "x") 2
                    , PAssign "x" Nothing Nothing (ExInt "2") 3, PReturn (var "x") 4
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "a store read inside the overwriting statement's own RHS is kept (self-referential update, e.g. x = x + 1)" $
        let stmts = [ PAssign "x" Nothing Nothing (ExInt "1") 1
                    , PAssign "x" Nothing Nothing (ExBinOp (var "x") BopAdd (ExInt "1")) 2
                    , PReturn (var "x") 3
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "a store read inside an intervening PCall's arguments is kept" $
        let stmts = [ PAssign "x" Nothing Nothing (ExInt "1") 1
                    , PCall "foo" Nothing [var "x"] 2
                    , PAssign "x" Nothing Nothing (ExInt "2") 3
                    , PReturn (var "x") 4
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "dropDeadStores itself trusts whatever safe set it's given (ref-exclusion is simplifyPseudocode's job)" $
        let stmts = [ PAssign "adw" Nothing Nothing (ExInt "1") 1 ]
        in dropDeadStores identSetEmpty stmts @?= stmts

    , testCase "a store to a name outside the locals/params set is never dropped" $
        let stmts = [ PAssign "ib_flag" Nothing Nothing (ExInt "1") 1, PAssign "ib_flag" Nothing Nothing (ExInt "2") 2 ]
        in dropDeadStores (safeVars ["other_var"]) stmts @?= stmts

    , testCase "a dead store inside a branch arm is dropped when redefined within the same arm" $
        let stmts = [ PBranch (var "cond")
                        [ PAssign "x" Nothing Nothing (ExInt "1") 1, PAssign "x" Nothing Nothing (ExInt "2") 2 ]
                        []
                        1
                    , PReturn (var "x") 3
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?=
             [ PBranch (var "cond") [ PAssign "x" Nothing Nothing (ExInt "2") 2 ] [] 1, PReturn (var "x") 3 ]

    , testCase "a store inside a branch arm with no redefinition inside the arm is kept when read after the branch closes" $
        let stmts = [ PBranch (var "cond") [ PAssign "x" Nothing Nothing (ExInt "1") 1 ] [] 1, PReturn (var "x") 2 ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "a store inside a branch arm is dropped when nothing anywhere in the given list reads it" $
        let stmts = [ PBranch (var "cond") [ PAssign "x" Nothing Nothing (ExInt "1") 1 ] [] 1 ]
        in dropDeadStores (safeVars ["x"]) stmts @?= [ PBranch (var "cond") [] [] 1 ]
    ]

  , testGroup "collapseBooleanBranch"
    [ testCase "if/return with true/false arms collapses to a direct boolean return" $
        let stmts = [ PBranch (var "cond") [PReturn (ExBool True) 2] [PReturn (ExBool False) 3] 1 ]
        in collapseBooleanBranch stmts @?= [ PReturn (var "cond") 1 ]

    , testCase "if/return with false/true arms collapses to a negated boolean return" $
        let stmts = [ PBranch (var "cond") [PReturn (ExBool False) 2] [PReturn (ExBool True) 3] 1 ]
        in collapseBooleanBranch stmts @?= [ PReturn (ExNot (var "cond")) 1 ]

    , testCase "a branch whose arms aren't exactly {return true, return false} (or the negation) is left untouched" $
        let stmts = [ PBranch (var "cond") [PReturn (var "x") 2] [PReturn (ExBool False) 3] 1 ]
        in collapseBooleanBranch stmts @?= stmts
    ]

  , testCase "a store that is the region's own live-out output (per InferredSignature) is kept even with no local read" $
      let letBody = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "x") 2 Nothing . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing sigs effTerm
          simplified = simplifyPseudocode (safeVars ["x"]) pc
          nonRootRegions = Map.delete (pcRootRegion pc) (pcRegions simplified)
      in case Map.elems nonRootRegions of
           [stmts] -> stmts @?= [ PAssign "x" (Just (var "x")) Nothing (ExInt "1") 1 ]
           other   -> assertFailure ("expected exactly one non-root region, got " <> show other)

  , testCase "simplifyPseudocode never drops a store to a declared ref-mode parameter, even if the caller's locals includes it" $
      let refParam = SubSig
            { ssMods = [], ssName = ident "helper"
            , ssParams = [Param ["ref"] "long" (SourceSpan 0 0 0 0) (ident "al_x")]
            , ssThrows = Nothing, ssLibrary = Nothing, ssAliasFor = Nothing
            }
          term = EAssignWithRhs "al_x" (var "al_x") (ExInt "1") 1 Nothing :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites (Just (Right refParam)) sigs effTerm
          -- deliberately careless caller: includes the ref param's own
          -- name in locals, relying on simplifyPseudocode to still
          -- exclude it via pcDeclaredSig.
          simplified = simplifyPseudocode (safeVars ["al_x"]) pc
      in Map.lookup (pcRootRegion pc) (pcRegions simplified) @?= Just [ PAssign "al_x" (Just (var "al_x")) Nothing (ExInt "1") 1 ]

  , testProperty "simplifyPseudocode is idempotent" $ property $ do
      stmts <- forAll genStmts
      let locals = safeVars ["a", "b", "c"]
          rid = pcRootRegion trivialPc
          pc = trivialPc { pcRegions = Map.singleton rid stmts }
          once  = simplifyPseudocode locals pc
          twice = simplifyPseudocode locals once
      once === twice

  , testGroup "inlineForwardingRegions"
    [ testCase "a region whose body is a single PRegionRef is dropped, and every other reference to it retargets to its own target" $
        let pc = singleForwarderPc
            rootRid = pcRootRegion pc
            nonRoot = Map.toList (Map.delete rootRid (pcRegions pc))
            (forwarders, reals) = partition (\(_, stmts) -> isForwarderStmt stmts) nonRoot
        in case (forwarders, reals) of
             ([(fwdRid, [fwdRef])], [(targetRid, _)]) ->
               let result = inlineForwardingRegions pc
               in case Map.lookup rootRid (pcRegions result) of
                    Just (refStmt : _) -> do
                      Map.member fwdRid (pcRegions result) @?= False
                      Map.member targetRid (pcRegions result) @?= True
                      refStmt @?= fwdRef
                    other -> assertFailure ("expected root region to retain at least its trailing statement, got " <> show other)
             other -> assertFailure ("expected exactly one forwarder region and one real target region, got " <> show other)

    , testCase "a chain of two forwarding regions collapses to a direct reference to the real final target" $
        let pc = chainForwarderPc
            rootRid = pcRootRegion pc
            nonRoot = Map.toList (Map.delete rootRid (pcRegions pc))
            (forwarders, reals) = partition (\(_, stmts) -> isForwarderStmt stmts) nonRoot
        in case reals of
             [(targetRid, _)] ->
               -- the forwarder that references the real target directly already
               -- carries the target's own real (lines, sig) -- exactly what every
               -- reference to the chain should collapse to, however many hops away.
               case [ ref | (_, [ref@(PRegionRef t _ _)]) <- forwarders, t == targetRid ] of
                 [finalRef] ->
                   let result = inlineForwardingRegions pc
                   in do
                        length forwarders @?= 2
                        mapM_ (\(fwdRid, _) -> Map.member fwdRid (pcRegions result) @?= False) forwarders
                        Map.member targetRid (pcRegions result) @?= True
                        case Map.lookup rootRid (pcRegions result) of
                          Just (refStmt : _) -> refStmt @?= finalRef
                          other -> assertFailure ("expected root region to retain at least its trailing statement, got " <> show other)
                 other -> assertFailure ("expected exactly one forwarder pointing directly at the real target, got " <> show other)
             other -> assertFailure ("expected exactly one real (non-forwarder) target region, got " <> show other)

    , testCase "a region with a PRegionRef plus any other statement is left untouched (not a pure forwarder)" $
        let pc = refPlusStmtPc
            rootRid = pcRootRegion pc
            nonRoot = Map.toList (Map.delete rootRid (pcRegions pc))
            hasRefPlusStmt (_, stmts) = length stmts > 1 && any isRegionRefStmt stmts
        in case filter hasRefPlusStmt nonRoot of
             [(mixedRid, mixedStmts)] ->
               let result = inlineForwardingRegions pc
               in Map.lookup mixedRid (pcRegions result) @?= Just mixedStmts
             other -> assertFailure ("expected exactly one ref-plus-other-statement region, got " <> show other)

    , testCase "the root region is never inlined away, even if its own body is a single forwarding reference" $
        let pc = refPlusStmtPc
            rootRid = pcRootRegion pc
            result = inlineForwardingRegions pc
        in do
             Map.member rootRid (pcRegions result) @?= True
             Map.lookup rootRid (pcRegions result) @?= Map.lookup rootRid (pcRegions pc)

    , testProperty "inlineForwardingRegions is idempotent" $ property $ do
        let pc = chainForwarderPc
            rootRid = pcRootRegion pc
            nonRoot = Map.toList (Map.delete rootRid (pcRegions pc))
        -- Randomly turn some of the chain's real forwarders into non-forwarders
        -- by appending a decoy trailing statement, covering every combination of
        -- which links in the chain still forward -- without fabricating any
        -- 'RegionId' (the constructor isn't exported; see 'trivialPc').
        toggles <- forAll (Gen.list (Range.singleton (length nonRoot)) Gen.bool)
        let mutate keep (rid, stmts) = (rid, if keep then stmts else stmts <> [PReturn (var "decoy") 999])
            mutatedRegions = Map.fromList (zipWith mutate toggles nonRoot)
            pc' = pc { pcRegions = Map.insert rootRid (Map.findWithDefault [] rootRid (pcRegions pc)) mutatedRegions }
            once  = inlineForwardingRegions pc'
            twice = inlineForwardingRegions once
        once === twice
    ]
  ]

-- | A region whose body is exactly one 'PRegionRef' and nothing else -- the
-- pure-forwarder shape 'inlineForwardingRegions' inlines away.
isForwarderStmt :: [PStmt] -> Bool
isForwarderStmt [PRegionRef {}] = True
isForwarderStmt _               = False

isRegionRefStmt :: PStmt -> Bool
isRegionRefStmt PRegionRef {} = True
isRegionRefStmt _             = False

-- | root -> (ref "fwd", then a trailing return); "fwd" -> ELetRef "target"
-- (a pure forwarder); "target" -> a real leaf. Three distinct real
-- 'RegionId's, obtained the only way this module can (a genuine
-- 'buildPseudocode' call) -- see 'trivialPc'\'s own header note.
singleForwarderPc :: Pseudocode
singleForwarderPc =
  let table = Map.fromList
        [ ("fwd", ELetRef "target")
        , ("target", EReturn (ExBool True) 10)
        ]
      spine = EComp (EReturn (var "done") 20) (ELetRef "fwd") :: Eff () ()
      effTerm = EffTerm spine table
  in buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm

-- | Same shape as 'singleForwarderPc' but with two forwarding hops
-- ("fwd1" -> "fwd2" -> "target") before the real leaf.
chainForwarderPc :: Pseudocode
chainForwarderPc =
  let table = Map.fromList
        [ ("fwd1", ELetRef "fwd2")
        , ("fwd2", ELetRef "target")
        , ("target", EReturn (ExBool True) 10)
        ]
      spine = EComp (EReturn (var "done") 20) (ELetRef "fwd1") :: Eff () ()
      effTerm = EffTerm spine table
  in buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm

-- | root's own body is itself a single forwarding reference (to "mixed"),
-- and "mixed"'s own body is a 'PRegionRef' to "target" plus a trailing
-- statement -- not a pure forwarder itself.
refPlusStmtPc :: Pseudocode
refPlusStmtPc =
  let table = Map.fromList
        [ ("mixed", EComp (EReturn (var "done") 30) (ELetRef "target"))
        , ("target", EReturn (ExBool True) 10)
        ]
      spine = ELetRef "mixed" :: Eff () ()
      effTerm = EffTerm spine table
  in buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm

-- | A real, opaque 'PB.Explain.Regions.RegionId' to build synthetic
-- fixtures around -- there is no other way to obtain one (the constructor
-- is not exported), so every property-test fixture reuses the same one via
-- a trivial 'buildPseudocode' call.
trivialPc :: Pseudocode
trivialPc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig
  (extractEffTable (EAssignWithRhs "a" (var "a") (ExInt "1") 1 Nothing :: Eff () ()))

genStmts :: Gen [PStmt]
genStmts = Gen.list (Range.linear 0 4) (genStmt 2)

genStmt :: Int -> Gen PStmt
genStmt depth
  | depth <= 0 = genLeaf
  | otherwise = Gen.frequency
      [ (3, genLeaf)
      , (1, PBranch <$> genExpr <*> genStmts' <*> genStmts' <*> genLine)
      , (1, PLoop <$> genStmts' <*> genLine)
      ]
  where
    genStmts' = Gen.list (Range.linear 0 3) (genStmt (depth - 1))

genLeaf :: Gen PStmt
genLeaf = Gen.choice
  [ PAssign <$> genVar <*> pure Nothing <*> pure Nothing <*> genExpr <*> genLine
  , PReturn <$> genExpr <*> genLine
  , PCall <$> pure "someproc" <*> pure Nothing <*> Gen.list (Range.linear 0 2) genExpr <*> genLine
  ]

genVar :: Gen Text
genVar = Gen.element ["a", "b", "c"]

genExpr :: Gen Expr
genExpr = Gen.choice
  [ var <$> genVar
  , (\n -> ExInt (T.pack (show n))) <$> Gen.int (Range.linear 0 9)
  , ExBool <$> Gen.bool
  ]

genLine :: Gen Int
genLine = Gen.int (Range.linear 1 100)
