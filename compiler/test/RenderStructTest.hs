module RenderStructTest (tests) where

import PB.Prelude hiding (id, (.))
import PB.AST.Expr        (BinOp (..), Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident       (Ident, IdentMap, identMapEmpty, mkIdentSynthetic)
import PB.AST.SourceFile  (FnSig (..), Param (..), SubSig (..))
import PB.AST.Type        (PbType (..))
import PB.Analysis.CallClassify (EffectTag (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (InferredSignature (..), ResolvedCallSiteMap, VarBinding (..), computeSignatures)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), buildPseudocode)
import PB.Explain.Render.Struct (renderAbility, renderStruct, renderStructType)
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
ident = mkIdentSynthetic "RenderStructTest fixture"

-- | @adw.object.kodypal[row]@ -- a compound, subscripted 'Lvalue', matching
-- the shape a DataWindow property write compiles to.
dwPropertyLhs :: Expr
dwPropertyLhs = ExLvalue (Lvalue
  [ LvSegment (ident "adw") Nothing
  , LvSegment (ident "object") Nothing
  , LvSegment (ident "kodypal") (Just [])
  ])

emptyEnv :: ScopedTypeEnv
emptyEnv = ScopedTypeEnv Map.empty Map.empty Map.empty Set.empty Map.empty Map.empty "" Map.empty

emptySigMap :: IdentMap (Map.Map Ident (Either a SubSig))
emptySigMap = identMapEmpty

noSig :: Map.Map r a
noSig = Map.empty

noCallSites :: ResolvedCallSiteMap
noCallSites = Map.empty

-- | Build via a bare 'Eff', no callee-resolution/declared-sig machinery, no
-- signature computation (root's own inferred signature is 'Nothing', so
-- every region header falls back to '()').
build :: Eff () () -> Pseudocode
build term = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing noSig (extractEffTable term)

-- | Overrides the root region's own statement list -- lets a test target
-- one 'PStmt' shape in isolation while still exercising 'renderStruct'
-- against a real (opaque) root 'PB.Explain.Regions.RegionId'.
withRootStmts :: [PStmt] -> Pseudocode
withRootStmts stmts =
  let pc = build (EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ())
  in pc { pcRegions = Map.singleton (pcRootRegion pc) stmts }

tests :: TestTree
tests = testGroup "PB.Explain.Render.Struct"
  [ testCase "a bare local LHS prints as a var declaration with its declared type and a trailing line comment" $
      let stmts = [PAssign "x" (Just (var "x")) (Just (PtPrimitive "integer")) (ExInt "1") 5]
          expected = T.intercalate "\n" ["function root() -> () {", "  var x: Integer = 1;  // line 5", "}"]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "no LHS Expr also falls back to a var declaration (e.g. LAssign, no rhs)" $
      let stmts = [PAssign "x" Nothing (Just (PtPrimitive "integer")) (ExInt "1") 5]
          expected = T.intercalate "\n" ["function root() -> () {", "  var x: Integer = 1;  // line 5", "}"]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "a compound/subscripted LHS (a property write) prints without the var keyword" $
      let stmts = [PAssign "adw" (Just dwPropertyLhs) Nothing (var "gsc_misth_ypal") 8]
          expected = T.intercalate "\n" ["function root() -> () {", "  adw.object.kodypal[] = gsc_misth_ypal;  // line 8", "}"]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "PCall prints as a semicolon-terminated call with a trailing line comment" $
      let stmts = [PCall "dw.AcceptText" Nothing [] 259]
          expected = T.intercalate "\n" ["function root() -> () {", "  dw.AcceptText();  // line 259", "}"]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "PReturn prints as a semicolon-terminated return with a trailing line comment" $
      let stmts = [PReturn (var "x") 9]
          expected = T.intercalate "\n" ["function root() -> () {", "  return x;  // line 9", "}"]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "PBranch prints a brace-delimited if/else block" $
      let stmts = [PBranch (var "cond") [PReturn (ExInt "1") 2] [PReturn (ExInt "2") 3] 1]
          expected = T.intercalate "\n"
            [ "function root() -> () {"
            , "  if (cond) {  // line 1"
            , "    return 1;  // line 2"
            , "  } else {"
            , "    return 2;  // line 3"
            , "  }"
            , "}"
            ]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "PBranch with an empty false branch omits the else block" $
      let stmts = [PBranch (var "cond") [PReturn (ExInt "1") 2] [] 1]
          expected = T.intercalate "\n"
            [ "function root() -> () {"
            , "  if (cond) {  // line 1"
            , "    return 1;  // line 2"
            , "  }"
            , "}"
            ]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "PLoop prints a brace-delimited loop block" $
      let stmts = [PLoop [PAssign "i" (Just (var "i")) Nothing (ExBinOp (var "i") BopAdd (ExInt "1")) 2] 1]
          expected = T.intercalate "\n"
            [ "function root() -> () {"
            , "  loop {  // line 1"
            , "    var i = i + 1;  // line 2"
            , "  }"
            , "}"
            ]
      in renderStruct (withRootStmts stmts) @?= expected

  , testCase "PRegionRef prints as a semicolon-terminated return-call using its target signature's input names as arguments" $
      let pc0 = build (EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ())
          sig = InferredSignature [VarBinding (ident "dw") Nothing, VarBinding (ident "ib_autoupdate") Nothing] [] Set.empty
          stmts = [PRegionRef (pcRootRegion pc0) (Just (3, 10)) (Just sig)]
          pc = pc0 { pcRegions = Map.singleton (pcRootRegion pc0) stmts }
          expected = T.intercalate "\n" ["function root() -> () {", "  return region@3(dw, ib_autoupdate);", "}"]
      in renderStruct pc @?= expected

  , testCase "a genuinely pure region's header has no ability annotation" $
      let term = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing sigs effTerm
          expected = T.intercalate "\n" ["function root() -> () {", "  var x = 1;  // line 1", "}"]
      in renderStruct pc @?= expected

  , testCase "an effectful region's header shows a sorted, deduplicated capability-label ability prefix" $
      let term = ECall "foo" [] 1 (Set.fromList [WritesDb, ReadsControlState]) :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites Nothing sigs effTerm
          expected = T.intercalate "\n" ["function root() -> '{Control, DB} () {", "  foo();  // line 1", "}"]
      in renderStruct pc @?= expected

  , testCase "a non-root region's output list is parenthesized even for a single output" $
      let letBody = EAssignWithRhs "result" (var "result") (var "gv") 5 (Just (PtPrimitive "integer")) :: Eff () ()
          term = EAssignWithRhs "y" (var "y") (var "result") 6 Nothing . ELetRef "blk1" :: Eff () ()
          effTerm = EffTerm term (Map.fromList [("blk1", letBody)])
          env = emptyEnv
            { steGlobal = Map.singleton (ident "gv") (PtPrimitive "integer")
            , steLocal  = Map.singleton (ident "result") (PtPrimitive "integer")
            }
          sigs = computeSignatures defaultComplexityThreshold env "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold env emptySigMap "proc" noCallSites Nothing sigs effTerm
      in T.isInfixOf "-> (result: Integer) {" (renderStruct pc) @?= True

  , testCase "the root's declared signature prints as a leading comment when one exists, using the procedure's declared name" $
      let declaredSig = Right SubSig
            { ssMods = [], ssName = ident "helper"
            , ssParams = [Param [] "integer" (SourceSpan 0 0 0 0) (ident "li_count")]
            , ssThrows = Nothing, ssLibrary = Nothing, ssAliasFor = Nothing
            }
          env = emptyEnv { steGlobal = Map.singleton (ident "gv") (PtPrimitive "boolean") }
          term = EAssignWithRhs "result" (var "result") (var "gv") 1 (Just (PtPrimitive "integer")) :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold env "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold env emptySigMap "proc" noCallSites (Just declaredSig) sigs effTerm
          expected = T.intercalate "\n"
            [ "// declared: helper(integer li_count)"
            , "function helper(gv: Boolean) -> () {"
            , "  var result: Integer = gv;  // line 1"
            , "}"
            ]
      in renderStruct pc @?= expected

  , testCase "a root with a declared Function signature shows its bare declared return type, not the inferred output tuple" $
      let declaredSig = Left FnSig
            { fnsMods = [], fnsReturnType = "string", fnsReturnTypeSpan = SourceSpan 0 0 0 0
            , fnsName = ident "of_where4print", fnsParams = []
            , fnsThrows = Nothing, fnsLibrary = Nothing, fnsAliasFor = Nothing
            }
          term = EAssignWithRhs "x" (var "x") (ExInt "1") 1 Nothing :: Eff () ()
          effTerm = extractEffTable term
          sigs = computeSignatures defaultComplexityThreshold emptyEnv "proc" noCallSites Map.empty effTerm
          pc = buildPseudocode defaultComplexityThreshold emptyEnv emptySigMap "proc" noCallSites (Just declaredSig) sigs effTerm
      in T.isInfixOf "function of_where4print() -> String {" (renderStruct pc) @?= True

  , testCase "renderStructType capitalizes a primitive type but leaves a user-defined type as renderPbType renders it" $ do
      renderStructType (PtPrimitive "long") @?= "Long"
      renderStructType (PtUserDefined (ident "DataWindow")) @?= "DataWindow"

  , testCase "renderAbility renders no annotation for an empty tag set, and a sorted brace-prefix otherwise" $ do
      renderAbility Set.empty "Boolean" @?= "Boolean"
      renderAbility (Set.fromList [WritesDb, ReadsControlState]) "()" @?= "'{Control, DB} ()"
  ]
