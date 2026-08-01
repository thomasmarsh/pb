-- | C-brace surface-syntax printer over 'PB.Explain.Pseudocode.Pseudocode'
-- (Plan 225 Layer 4a), a sibling of 'PB.Explain.Render.Text' sharing the
-- same containment discipline: no access to
-- 'PB.Compile.IR.Eff'\/'PB.Explain.Regions.Region'\/'PB.Analysis.TypeEnv.ScopedTypeEnv'
-- internals, only 'PB.Explain.Pseudocode.PStmt'\/'PB.Explain.Signatures.InferredSignature'.
-- 'PB.Grammar.Unparse.unparseExpr' is reused verbatim for every 'PB.AST.Expr.Expr'
-- (PB's own @not@\/@and@\/@or@\/@=@\/@\<\>@ keywords print as-is, matching
-- this plan's own Non-Goal against forking a second expression printer);
-- 'PB.AST.Type.renderPbType' is reused for every type via 'renderStructType',
-- which only adds a capitalization convention for the primitive case.
module PB.Explain.Render.Struct
  ( renderStruct
  , renderAbility
  , renderStructType
  ) where

import PB.Prelude
import qualified Data.Char as Char
import qualified Data.Set as Set
import qualified Data.Text as T
import PB.AST.Expr (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident (identOrig)
import PB.AST.SourceFile (FnSig (..), SubSig (..))
import PB.AST.Type (PbType (..), renderPbType)
import PB.Analysis.CallClassify (EffectTag, capabilityLabel)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), RegionEntry (..), pseudocodeRegions)
import PB.Explain.Regions (regionLabel)
import PB.Explain.Render.Text (renderDeclaredSig)
import PB.Explain.Signatures (InferredSignature (..), VarBinding (..))
import PB.Grammar.Unparse (unparseExpr)

renderStruct :: Pseudocode -> Text
renderStruct pc = T.intercalate "\n\n" (map (renderEntry pc) (pseudocodeRegions pc))

renderEntry :: Pseudocode -> RegionEntry -> Text
renderEntry pc entry = declaredComment <> T.intercalate "\n" (header : body <> ["}"])
  where
    isRoot = reId entry == pcRootRegion pc
    label
      | isRoot    = maybe "root" declaredName (pcDeclaredSig pc)
      | otherwise = regionLabel (reId entry) (reLines entry)
    declaredName (Left fnsig)   = identOrig (fnsName fnsig)
    declaredName (Right subsig) = identOrig (ssName subsig)
    mDeclared = if isRoot then pcDeclaredSig pc else Nothing
    sig = fromMaybe emptySig (reSig entry)
    header = renderRegionHeader label mDeclared sig
    body = concatMap (renderStmt 1) (reStmts entry)
    declaredComment
      | isRoot, Just d <- pcDeclaredSig pc = "// declared: " <> renderDeclaredSig d <> "\n"
      | otherwise                          = ""

emptySig :: InferredSignature
emptySig = InferredSignature [] [] Set.empty

-- | A PB 'FnSig' has exactly one declared return type -- shown bare, from
-- that declared text (capitalized), not from the region's own inferred
-- live-out variable set. Every other case (a 'SubSig' with no return
-- value, no declared signature at all, or any non-root region -- none of
-- which correspond to a single nominal return value) falls back to the
-- parenthesized live-out tuple, the same shape 'InferredSignature' always
-- carries.
renderRegionHeader :: Text -> Maybe (Either FnSig SubSig) -> InferredSignature -> Text
renderRegionHeader name mDeclared sig =
  "function " <> name <> "(" <> renderInputs (sigInputs sig) <> ") -> " <> outputText <> " {"
  where
    outputText = case mDeclared of
      Just (Left fnsig) -> renderAbility (sigEffects sig) (capitalizeFirst (fnsReturnType fnsig))
      _                 -> renderAbility (sigEffects sig) (renderOutputs (sigOutputs sig))

renderInputs :: [VarBinding] -> Text
renderInputs = T.intercalate ", " . map renderBindingStruct

renderOutputs :: [VarBinding] -> Text
renderOutputs vbs = "(" <> T.intercalate ", " (map renderBindingStruct vbs) <> ")"

renderBindingStruct :: VarBinding -> Text
renderBindingStruct vb = case vbType vb of
  Just ty -> identOrig (vbName vb) <> ": " <> renderStructType ty
  Nothing -> identOrig (vbName vb)

-- | A genuinely pure region (@Set.null tags@) renders with no ability
-- annotation at all -- @-> Boolean@, not @-> '{} Boolean@ -- matching
-- Unison's own convention.
renderAbility :: Set.Set EffectTag -> Text -> Text
renderAbility tags ty
  | Set.null tags = ty
  | otherwise     = "'{" <> labels <> "} " <> ty
  where
    labels = T.intercalate ", " (Set.toAscList (Set.map capabilityLabel tags))

renderStructType :: PbType -> Text
renderStructType (PtPrimitive t) = capitalizeFirst t
renderStructType ty              = renderPbType ty

capitalizeFirst :: Text -> Text
capitalizeFirst t = case T.uncons t of
  Just (c, rest) -> T.cons (Char.toUpper c) rest
  Nothing        -> t

indent :: Int -> Text -> Text
indent n t = T.replicate (n * 2) " " <> t

lineComment :: Int -> Text
lineComment ln = "  // line " <> T.pack (show ln)

renderArgs :: [Expr] -> Text
renderArgs = T.intercalate ", " . map unparseExpr

renderRegionRefArgs :: Maybe InferredSignature -> Text
renderRegionRefArgs Nothing    = ""
renderRegionRefArgs (Just sig) = T.intercalate ", " (map (identOrig . vbName) (sigInputs sig))

-- | A 'PRegionRef' is always the tail of its containing statement list (the
-- point 'PB.Explain.Regions.computeRegionsWith' cut the walk into a fresh
-- region) -- there is no statement "after" it in the same list, so it
-- always reads as the block's own final control transfer, rendered as a
-- @return@ of a call to the target region using its own free-variable
-- inputs as arguments. No trailing line comment: the region's own line
-- range is already shown on its block header below, not re-stated here.
-- | A bare, non-subscripted single-segment 'Lvalue' (@x@, not
-- @adw.object.kodypal[row]@) is a plain scalar local -- the shape a fresh
-- @var@ declaration describes. Any compound or subscripted 'Lvalue' is a
-- write to something already declared (a property, an array element, an
-- instance/global var), never a @var@ declaration.
isBareLocal :: Expr -> Bool
isBareLocal (ExLvalue (Lvalue [LvSegment _ Nothing])) = True
isBareLocal _                                         = False

renderStmt :: Int -> PStmt -> [Text]
renderStmt ind (PAssign var' mlhs mty rhs ln) =
  [indent ind (target <> typeAnn <> " = " <> unparseExpr rhs <> ";" <> lineComment ln)]
  where
    target = case mlhs of
      Just lhs | isBareLocal lhs -> "var " <> unparseExpr lhs
      Just lhs                   -> unparseExpr lhs
      Nothing                    -> "var " <> var'
    typeAnn = maybe "" ((": " <>) . renderStructType) mty
renderStmt ind (PCall name _msig args ln) =
  [indent ind (name <> "(" <> renderArgs args <> ");" <> lineComment ln)]
renderStmt ind (PBranch cond t f ln) =
  [indent ind ("if (" <> unparseExpr cond <> ") {" <> lineComment ln)]
    <> concatMap (renderStmt (ind + 1)) t
    <> (if null f then [] else indent ind "} else {" : concatMap (renderStmt (ind + 1)) f)
    <> [indent ind "}"]
renderStmt ind (PLoop body ln) =
  [indent ind ("loop {" <> lineComment ln)]
    <> concatMap (renderStmt (ind + 1)) body
    <> [indent ind "}"]
renderStmt ind (PReturn e ln) =
  [indent ind ("return " <> unparseExpr e <> ";" <> lineComment ln)]
renderStmt ind (PRegionRef rid lns msig) =
  [indent ind ("return " <> regionLabel rid lns <> "(" <> renderRegionRefArgs msig <> ");")]
