-- | Plainest possible text printer over 'PB.Explain.Pseudocode.Pseudocode'
-- (Plan 218 Layer 4): no access to 'PB.Compile.IR.Eff'\/'PB.Analysis.TypeEnv.ScopedTypeEnv'
-- internals -- every fact shown here (types, signatures, line numbers)
-- already arrived denormalized on 'Pseudocode' itself. Reuses
-- 'PB.Grammar.Unparse.unparseExpr' for every 'PB.AST.Expr.Expr' shown and
-- 'PB.AST.Type.renderPbType' for every type shown, same as the plan's own
-- Layer 4 note -- surface-syntax rendering isn't reinvented here.
--
-- Each 'PB.Explain.Regions.RegionId' this walk encounters (root or cut) is
-- rendered as its own block, in encounter order and de-duplicated by id
-- (a region referenced twice, e.g. a shared 'PB.Compile.IR.ELetRef', prints
-- once): the root block first, then every other referenced region reachable
-- by walking 'PB.Explain.Pseudocode.PStmt' lists recursively (including
-- nested 'PBranch'\/'PLoop' bodies). A region's own label/line-range/
-- signature always comes from the denormalized fields already carried on
-- the 'PB.Explain.Pseudocode.PRegionRef' that first refers to it, never by
-- inspecting 'PB.Explain.Regions.RegionId' itself (opaque, no accessor
-- exists to do so).
module PB.Explain.Render.Text
  ( renderText
  , renderStmtLine
  ) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import PB.AST.Expr (Expr)
import PB.AST.Ident (identOrig)
import PB.AST.SourceFile (FnSig (..), SubSig (..), renderParams)
import PB.AST.Type (renderPbType)
import PB.Analysis.CallClassify (EffectTag)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..))
import PB.Explain.Regions (RegionId, regionIdLabel)
import PB.Explain.Signatures (InferredSignature (..), VarBinding (..))
import PB.Grammar.Unparse (unparseExpr)

renderText :: Pseudocode -> Text
renderText pc = T.intercalate "\n\n" (rootBlock : renderRefs pc (Set.singleton (pcRootRegion pc)) (collectRefs rootStmts))
  where
    rootStmts = Map.findWithDefault [] (pcRootRegion pc) (pcRegions pc)
    rootBlock = T.intercalate "\n" (rootHeader pc <> concatMap (renderStmt 1) rootStmts)

-- | Both facts are shown whenever both exist -- they describe different
-- things (the procedure's own declared syntax vs. its region's inferred
-- data-flow signature, which may disclose a hidden imperative-shell
-- dependency the declaration doesn't) so there is no meaningful "same
-- value, only show once" case to collapse them into.
rootHeader :: Pseudocode -> [Text]
rootHeader pc = catMaybes
  [ ("declared " <>) . renderDeclaredSig <$> pcDeclaredSig pc
  , ("inferred " <>) . renderInferredSig rootLabel <$> pcRootSig pc
  ]
  where
    rootLabel = maybe "root" declaredName (pcDeclaredSig pc)
    declaredName (Left fnsig)  = identOrig (fnsName fnsig)
    declaredName (Right subsig) = identOrig (ssName subsig)

renderRefs :: Pseudocode -> Set.Set RegionId -> [(RegionId, Maybe (Int, Int), Maybe InferredSignature)] -> [Text]
renderRefs _pc _seen [] = []
renderRefs pc seen ((rid, lns, msig) : rest)
  | rid `Set.member` seen = renderRefs pc seen rest
  | otherwise =
      let stmts = Map.findWithDefault [] rid (pcRegions pc)
          header = regionHeader rid lns msig
          block  = T.intercalate "\n" (header : concatMap (renderStmt 1) stmts)
      in block : renderRefs pc (Set.insert rid seen) (rest <> collectRefs stmts)

-- | Every 'PRegionRef' reachable from a statement list, recursing into
-- 'PBranch'\/'PLoop' bodies (a cut can happen inside either arm\/body, its
-- own independent straight-line run). Does not recurse into a referenced
-- region's own body -- 'renderRefs' does that once, from 'pcRegions',
-- after checking the dedup set.
collectRefs :: [PStmt] -> [(RegionId, Maybe (Int, Int), Maybe InferredSignature)]
collectRefs = concatMap go
  where
    go (PRegionRef rid lns msig) = [(rid, lns, msig)]
    go (PBranch _ t f _)         = collectRefs t <> collectRefs f
    go (PLoop body _)            = collectRefs body
    go _                         = []

-- | A real line range prints as @region\@\<line\>@; a genuinely leaf-free
-- region (no line info at all) falls back to 'regionIdLabel' so two such
-- regions in the same output are still visually distinguishable, not both
-- printed as an identical, ambiguous label.
regionLabel :: RegionId -> Maybe (Int, Int) -> Text
regionLabel _   (Just (startLine, _)) = "region@" <> T.pack (show startLine)
regionLabel rid Nothing               = regionIdLabel rid

regionHeader :: RegionId -> Maybe (Int, Int) -> Maybe InferredSignature -> Text
regionHeader rid lns Nothing    = regionLabel rid lns
regionHeader rid lns (Just sig) = renderInferredSig (regionLabel rid lns) sig

renderInferredSig :: Text -> InferredSignature -> Text
renderInferredSig name sig =
  name <> "(" <> renderBindings (sigInputs sig) <> ") -> (" <> renderBindings (sigOutputs sig)
       <> ") [" <> renderEffects (sigEffects sig) <> "]"
  where
    renderBindings = T.intercalate ", " . map renderBinding

-- | @[pure]@ for a genuinely effect-free region -- the first place this
-- whole feature delivers "functional core" as a computed label rather than
-- something left to the reader to infer (Plan 218's own stated goal).
renderEffects :: Set.Set EffectTag -> Text
renderEffects tags
  | Set.null tags = "pure"
  | otherwise     = T.intercalate ", " (map (T.pack . show) (Set.toAscList tags))

renderBinding :: VarBinding -> Text
renderBinding vb = case vbType vb of
  Just ty -> identOrig (vbName vb) <> ": " <> renderPbType ty
  Nothing -> identOrig (vbName vb)

renderDeclaredSig :: Either FnSig SubSig -> Text
renderDeclaredSig (Left fnsig) =
  identOrig (fnsName fnsig) <> "(" <> renderParams (fnsParams fnsig) <> "): " <> fnsReturnType fnsig
renderDeclaredSig (Right subsig) =
  identOrig (ssName subsig) <> "(" <> renderParams (ssParams subsig) <> ")"

indent :: Int -> Text -> Text
indent n t = T.replicate (n * 2) " " <> t

backlink :: Int -> Text
backlink ln = "  -- line " <> T.pack (show ln)

renderArgs :: [Expr] -> Text
renderArgs = T.intercalate ", " . map unparseExpr

-- | The single-node header text for one 'PStmt' -- no indent, no recursion
-- into a 'PBranch'\/'PLoop' body, and no line-number backlink (the line is
-- already a structured field on the node, not text to re-parse). 'renderStmt'
-- composes this with indent\/backlink\/recursion for the CLI text view;
-- 'PB.Pipeline.Serialise'\'s 'PStmt' JSON encoding calls it directly so every
-- materialized node carries its own pre-rendered display text, and a UI
-- consumer never re-derives 'Expr' -> 'Text' a third way.
renderStmtLine :: PStmt -> Text
renderStmtLine (PAssign var mlhs mty rhs _) =
  maybe var unparseExpr mlhs <> maybe "" ((": " <>) . renderPbType) mty <> " = " <> unparseExpr rhs
renderStmtLine (PCall name _msig args _) =
  name <> "(" <> renderArgs args <> ")"
renderStmtLine (PBranch cond _ _ _) =
  "if " <> unparseExpr cond <> " then"
renderStmtLine (PLoop _ _) = "loop"
renderStmtLine (PReturn e _) = "return " <> unparseExpr e
renderStmtLine (PRegionRef rid lns _msig) = "-> " <> regionLabel rid lns

renderStmt :: Int -> PStmt -> [Text]
renderStmt ind stmt@(PAssign _ _ _ _ ln) = [indent ind (renderStmtLine stmt <> backlink ln)]
renderStmt ind stmt@(PCall _ _ _ ln) = [indent ind (renderStmtLine stmt <> backlink ln)]
renderStmt ind stmt@(PBranch _ t f ln) =
  [indent ind (renderStmtLine stmt <> backlink ln)]
    <> concatMap (renderStmt (ind + 1)) t
    <> (if null f then [] else indent ind "else" : concatMap (renderStmt (ind + 1)) f)
    <> [indent ind "end if"]
renderStmt ind stmt@(PLoop body ln) =
  [indent ind (renderStmtLine stmt <> backlink ln)]
    <> concatMap (renderStmt (ind + 1)) body
    <> [indent ind "end loop"]
renderStmt ind stmt@(PReturn _ ln) = [indent ind (renderStmtLine stmt <> backlink ln)]
renderStmt ind stmt@(PRegionRef {}) = [indent ind (renderStmtLine stmt <> " (see below)")]
