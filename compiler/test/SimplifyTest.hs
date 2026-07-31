module SimplifyTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, IdentSet, identMapEmpty, identSetEmpty, identSetFromList, mkIdentSynthetic)
import PB.AST.SourceFile  (Param (..), SubSig (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (computeSignatures)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), buildPseudocode)
import PB.Explain.Simplify (collapseBooleanBranch, dropDeadStores, simplifyPseudocode)
import PB.Lexing.Token (SourceSpan (..))

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

tests :: TestTree
tests = testGroup "PB.Explain.Simplify"
  [ testGroup "dropDeadStores"
    [ testCase "a dead store immediately overwritten before any read is dropped" $
        let stmts = [ PAssign "x" Nothing (ExInt "1") 1, PAssign "x" Nothing (ExInt "2") 2, PReturn (var "x") 3 ]
        in dropDeadStores (safeVars ["x"]) stmts @?= [ PAssign "x" Nothing (ExInt "2") 2, PReturn (var "x") 3 ]

    , testCase "a store read before being overwritten is kept" $
        let stmts = [ PAssign "x" Nothing (ExInt "1") 1, PReturn (var "x") 2
                    , PAssign "x" Nothing (ExInt "2") 3, PReturn (var "x") 4
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "a store read inside the overwriting statement's own RHS is kept (self-referential update, e.g. x = x + 1)" $
        let stmts = [ PAssign "x" Nothing (ExInt "1") 1
                    , PAssign "x" Nothing (ExBinOp (var "x") BopAdd (ExInt "1")) 2
                    , PReturn (var "x") 3
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "a store read inside an intervening PCall's arguments is kept" $
        let stmts = [ PAssign "x" Nothing (ExInt "1") 1
                    , PCall "foo" Nothing [var "x"] 2
                    , PAssign "x" Nothing (ExInt "2") 3
                    , PReturn (var "x") 4
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "dropDeadStores itself trusts whatever safe set it's given (ref-exclusion is simplifyPseudocode's job)" $
        let stmts = [ PAssign "adw" Nothing (ExInt "1") 1 ]
        in dropDeadStores identSetEmpty stmts @?= stmts

    , testCase "a store to a name outside the locals/params set is never dropped" $
        let stmts = [ PAssign "ib_flag" Nothing (ExInt "1") 1, PAssign "ib_flag" Nothing (ExInt "2") 2 ]
        in dropDeadStores (safeVars ["other_var"]) stmts @?= stmts

    , testCase "a dead store inside a branch arm is dropped when redefined within the same arm" $
        let stmts = [ PBranch (var "cond")
                        [ PAssign "x" Nothing (ExInt "1") 1, PAssign "x" Nothing (ExInt "2") 2 ]
                        []
                        1
                    , PReturn (var "x") 3
                    ]
        in dropDeadStores (safeVars ["x"]) stmts @?=
             [ PBranch (var "cond") [ PAssign "x" Nothing (ExInt "2") 2 ] [] 1, PReturn (var "x") 3 ]

    , testCase "a store inside a branch arm with no redefinition inside the arm is kept when read after the branch closes" $
        let stmts = [ PBranch (var "cond") [ PAssign "x" Nothing (ExInt "1") 1 ] [] 1, PReturn (var "x") 2 ]
        in dropDeadStores (safeVars ["x"]) stmts @?= stmts

    , testCase "a store inside a branch arm is dropped when nothing anywhere in the given list reads it" $
        let stmts = [ PBranch (var "cond") [ PAssign "x" Nothing (ExInt "1") 1 ] [] 1 ]
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
          sigs = computeSignatures defaultComplexityThreshold emptyEnv emptySigMap Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing sigs effTerm
          simplified = simplifyPseudocode (safeVars ["x"]) pc
          nonRootRegions = Map.delete (pcRootRegion pc) (pcRegions simplified)
      in case Map.elems nonRootRegions of
           [stmts] -> stmts @?= [ PAssign "x" Nothing (ExInt "1") 1 ]
           other   -> assertFailure ("expected exactly one non-root region, got " <> show other)

  , testCase "simplifyPseudocode never drops a store to a declared ref-mode parameter, even if the caller's locals includes it" $
      let refParam = SubSig
            { ssMods = [], ssName = ident "helper"
            , ssParams = [Param ["ref"] "long" (SourceSpan 0 0 0 0) (ident "al_x")]
            , ssThrows = Nothing, ssLibrary = Nothing, ssAliasFor = Nothing
            }
          term = EAssignWithRhs "al_x" (var "al_x") (ExInt "1") 1 Nothing :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv emptySigMap Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap (Just (Right refParam)) sigs effTerm
          -- deliberately careless caller: includes the ref param's own
          -- name in locals, relying on simplifyPseudocode to still
          -- exclude it via pcDeclaredSig.
          simplified = simplifyPseudocode (safeVars ["al_x"]) pc
      in Map.lookup (pcRootRegion pc) (pcRegions simplified) @?= Just [ PAssign "al_x" Nothing (ExInt "1") 1 ]

  , testProperty "simplifyPseudocode is idempotent" $ property $ do
      stmts <- forAll genStmts
      let locals = safeVars ["a", "b", "c"]
          rid = pcRootRegion trivialPc
          pc = trivialPc { pcRegions = Map.singleton rid stmts }
          once  = simplifyPseudocode locals pc
          twice = simplifyPseudocode locals once
      once === twice
  ]

-- | A real, opaque 'PB.Explain.Regions.RegionId' to build synthetic
-- fixtures around -- there is no other way to obtain one (the constructor
-- is not exported), so every property-test fixture reuses the same one via
-- a trivial 'buildPseudocode' call.
trivialPc :: Pseudocode
trivialPc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap Nothing noSig
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
  [ PAssign <$> genVar <*> pure Nothing <*> genExpr <*> genLine
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
