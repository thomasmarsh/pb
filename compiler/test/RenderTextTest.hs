module RenderTextTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, identMapEmpty, mkIdentSynthetic)
import PB.AST.SourceFile  (SubSig)
import PB.AST.Type        (PbType (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), buildPseudocode)
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Render.Text (renderStmtLine)
import PB.Explain.Signatures (ResolvedCallSiteMap)
import PB.Lexing.Token (SourceSpan (..), Token (..), TokenKind (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (testCase, (@?=))

-- | A bare local-variable reference, matching the shape 'PB.Compile.FromSSA'
-- always emits for a plain (non-subscripted) lvalue.
var :: Text -> Expr
var name = ExLvalue (Lvalue [LvSegment (ident name) Nothing])

ident :: Text -> Ident
ident = mkIdentSynthetic "RenderTextTest fixture"

mkTok :: TokenKind -> Text -> Token
mkTok k t = Token k t (SourceSpan 1 1 1 1)

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

emptySigMap :: IdentMap (Map.Map Ident (Either a SubSig))
emptySigMap = identMapEmpty

noSig :: Map.Map r a
noSig = Map.empty

noCallSites :: ResolvedCallSiteMap
noCallSites = Map.empty

tests :: TestTree
tests = testGroup "PB.Explain.Render.Text"
  [ testGroup "renderStmtLine"
    [ testCase "renders a PAssign with its declared type, no indent or backlink" $
        renderStmtLine (PAssign "x" Nothing (Just (PtPrimitive "integer")) (ExInt "1") 5) @?= "x: integer = 1"

    , testCase "renders a PAssign's full LHS Expr (a DataWindow property write), not just the root var name" $
        let lhs = ExLvalue (Lvalue
              [ LvSegment (ident "adw") Nothing
              , LvSegment (ident "object") Nothing
              , LvSegment (ident "kodypal") (Just [mkTok TkIdent "row"])
              ])
        in renderStmtLine (PAssign "adw" (Just lhs) Nothing (var "gsc_misth_ypal") 8) @?= "adw.object.kodypal[row] = gsc_misth_ypal"

    , testCase "falls back to the plain var name when no LHS Expr is present (e.g. LAssign, no rhs)" $
        renderStmtLine (PAssign "x" Nothing Nothing (ExRaw []) 5) @?= "x = "

    , testCase "renders a PCall with no indent or backlink" $
        renderStmtLine (PCall "foo" Nothing [var "a", ExInt "2"] 3) @?= "foo(a, 2)"

    , testCase "renders a PBranch as just its brace-opening condition header, no arms, no close" $
        renderStmtLine (PBranch (var "cond") [PReturn (ExInt "1") 2] [PReturn (ExInt "2") 3] 1) @?= "if (cond) {"

    , testCase "renders a PLoop as just its brace-opening header, no body" $
        renderStmtLine (PLoop [PReturn (ExInt "1") 2] 7) @?= "loop {"

    , testCase "renders a PReturn" $
        renderStmtLine (PReturn (var "x") 9) @?= "return x"

    , testCase "renders a PRegionRef as a tail-call-style return" $
        let letBody = EAssignWithRhs "result" (var "result") (var "gv") 5 (Just (PtPrimitive "integer")) :: Eff () ()
            term = EAssignWithRhs "y" (var "y") (var "result") 6 Nothing . ELetRef "blk1" :: Eff () ()
            effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
            pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig effTerm
            rootStmts = Map.findWithDefault [] (pcRootRegion pc) (pcRegions pc)
        in case [s | s@(PRegionRef {}) <- rootStmts] of
             [ref] -> renderStmtLine ref @?= "return region@5"
             other -> error ("expected exactly one PRegionRef in root region, got " <> show other)
    ]
  ]
