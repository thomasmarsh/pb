-- | The one canonical 'PB.Explain.Pseudocode.PStmt' -> 'Text' single-line
-- renderer: no access to 'PB.Compile.IR.Eff'\/'PB.Analysis.TypeEnv.ScopedTypeEnv'
-- internals -- every fact shown here (types, line numbers) already arrived
-- denormalized on 'PB.Explain.Pseudocode.PStmt' itself. Reuses
-- 'PB.Grammar.Unparse.unparseExpr' for every 'PB.AST.Expr.Expr' shown and
-- 'PB.AST.Type.renderPbType' for every type shown.
--
-- Brace-opening convention for a control-structure header ('PBranch'\/
-- 'PLoop'): this renders only the node's own opening line, never its body
-- or closing brace -- a live UI consumer (the Explain explorer's
-- 'ExplainCore.tsx') synthesizes '} else {'\/closing '}' punctuation itself
-- from the already-structural 'then'\/'else'\/'body' fields it receives, so
-- there is exactly one renderer of that punctuation, not two.
module PB.Explain.Render.Text
  ( renderStmtLine
  ) where

import PB.Prelude
import qualified Data.Text as T
import PB.AST.Expr (Expr (ExNull))
import PB.AST.Type (renderPbType)
import PB.Explain.Pseudocode (PStmt (..))
import PB.Explain.Regions (regionLabel)
import PB.Grammar.Unparse (unparseExpr)

renderArgs :: [Expr] -> Text
renderArgs = T.intercalate ", " . map unparseExpr

-- | The single-node header text for one 'PStmt' -- no indent, no recursion
-- into a 'PBranch'\/'PLoop' body. 'PB.Pipeline.Serialise'\'s 'PStmt' JSON
-- encoding calls this directly so every materialized node carries its own
-- pre-rendered display text, and a UI consumer never re-derives 'Expr' ->
-- 'Text' a third way.
renderStmtLine :: PStmt -> Text
renderStmtLine (PAssign var mlhs mty rhs _) =
  maybe var unparseExpr mlhs <> maybe "" ((": " <>) . renderPbType) mty <> " = " <> unparseExpr rhs
renderStmtLine (PCall name _msig args _) =
  name <> "(" <> renderArgs args <> ")"
renderStmtLine (PBranch cond _ _ _) =
  "if (" <> unparseExpr cond <> ") {"
renderStmtLine (PLoop _ _) = "loop {"
renderStmtLine (PReturn ExNull _) = "return"
renderStmtLine (PReturn e _) = "return " <> unparseExpr e
renderStmtLine (PRegionRef rid lns _msig) = "return " <> regionLabel rid lns
