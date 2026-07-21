module PB.Grammar.Unparse
  ( unparseExpr
  , unparseLvalue
  , unparseBodyStmt
  , unparseBody
  ) where

import PB.Prelude
import PB.AST.BodyStmt
  ( AugOp (..), BodyStmt (..), CaseClause (..), CatchClause (..)
  , ChooseStmt (..), DoCondition (..), DoStmt (..), ElseIf (..)
  , ForStmt (..), IfStmt (..), PbCall (..), TryStmt (..)
  )
import PB.AST.Expr
  ( BinOp (..), DispatchExpr (..), DispatchMode (..)
  , Expr (..), LvSegment (..), Lvalue (..)
  )
import PB.AST.Ident (identOrig)
import PB.AST.Located (Located (..))
import PB.AST.Type (renderPbType)
import PB.Lexing.Token (Token (..))

import qualified Data.Text as T

-- | Render an Expr back to PowerBuilder source text. Not a pretty-printer --
-- whitespace, comments, and original formatting (including string quote
-- style) are not preserved. The only guarantee is that the lexer/parser can
-- recover an equal Expr from the output.
unparseExpr :: Expr -> Text
unparseExpr expr = case expr of
  ExBool True         -> "true"
  ExBool False        -> "false"
  ExInt  t            -> t
  ExReal t            -> t
  ExStr  t            -> "\"" <> t <> "\""
  ExDate t            -> t
  ExTime t            -> t
  ExNull              -> "null"
  ExEnum nm           -> nm <> "!"
  ExLvalue lv         -> unparseLvalue lv
  ExCall callee cargs -> unparseLvalue callee <> "(" <> unparseArgGroups cargs <> ")"
  ExMethodCall recv m margs ->
    unparseAtomic recv <> "." <> identOrig m <> "(" <> unparseArgGroups margs <> ")"
  ExDispatch de       -> unparseDispatch de
  ExCreate cls        -> "create " <> identOrig cls
  ExCreateUsing e     -> "create using " <> unparseAtomic e
  ExArray elems       -> "{" <> T.intercalate ", " (map unparseExpr elems) <> "}"
  ExBinOp lhs op rhs  -> unparseAtomic lhs <> " " <> binOpText op <> " " <> unparseAtomic rhs
  ExNot e             -> "not " <> unparseAtomic e
  -- A space after "-" is load-bearing: PB.Lexing.Lexer's pFloatLiteral
  -- accepts an optional leading sign directly adjacent to its digits, so
  -- "-" <> "0.0" re-lexes as a single ExReal "-0.0" token, silently
  -- dropping the ExNeg wrapper (pIntLiteral has no such sign case, so a
  -- bare int operand doesn't collapse -- only real/float operands do, but
  -- the space is added unconditionally since it's correct for every operand).
  ExNeg e             -> "- " <> unparseAtomic e
  ExHostVar lv        -> ":" <> unparseLvalue lv
  ExRaw ts            -> T.unwords ts

-- | Wraps a sub-expression in parens when its outer constructor is not
-- already syntactically atomic (ExBinOp/ExNot/ExNeg/ExCreateUsing). Needed
-- wherever the caller re-parses the result via a precedence-sensitive
-- position: an ExBinOp operand, or ExNot/ExNeg/ExCreateUsing's own operand.
-- A fully parenthesized group always reparses to exactly its contents
-- regardless of surrounding precedence (PB.Grammar.Body's parseAtom always
-- recurses fully into a `(...)` group), so this sidesteps having to
-- replicate climbPrec's precedence table here and risk it drifting out of
-- sync.
unparseAtomic :: Expr -> Text
unparseAtomic e = case e of
  ExBinOp {}      -> "(" <> unparseExpr e <> ")"
  ExNot   _       -> "(" <> unparseExpr e <> ")"
  ExNeg   _       -> "(" <> unparseExpr e <> ")"
  ExCreateUsing _ -> "(" <> unparseExpr e <> ")"
  _               -> unparseExpr e

unparseLvalue :: Lvalue -> Text
unparseLvalue (Lvalue segs) = T.intercalate "." (map unparseSeg segs)
  where
    unparseSeg (LvSegment nm sub) =
      identOrig nm <> maybe "" (\ts -> "[" <> T.unwords ts <> "]") sub

unparseArgGroups :: [Expr] -> Text
unparseArgGroups = T.intercalate ", " . map unparseExpr

binOpText :: BinOp -> Text
binOpText op = case op of
  BopAdd -> "+"
  BopSub -> "-"
  BopMul -> "*"
  BopDiv -> "/"
  BopPow -> "^"
  BopEq  -> "="
  BopNe  -> "<>"
  BopLt  -> "<"
  BopGt  -> ">"
  BopLe  -> "<="
  BopGe  -> ">="
  BopAnd -> "and"
  BopOr  -> "or"
  BopXor -> "xor"

unparseDispatch :: DispatchExpr -> Text
unparseDispatch (DispatchExpr mObj md dyn ev nm dargs) =
  maybe "" (\lv -> unparseLvalue lv <> ".") mObj
    <> (if dyn then "dynamic " else "")
    <> modeText md
    <> (if ev then "event " else "")
    <> identOrig nm
    <> "(" <> unparseArgGroups dargs <> ")"
  where
    modeText DmPost    = "post "
    modeText DmTrigger = "trigger "
    modeText DmSync    = ""

-- | Render a BodyStmt back to PowerScript source text. Same non-goals as
-- unparseExpr: no whitespace/comment/formatting fidelity, only re-parse
-- fidelity.
unparseBodyStmt :: BodyStmt -> Text
unparseBodyStmt stmt = case stmt of
  BsLocalVar mods ty nm mInit ->
    T.unwords mods <> " " <> renderPbType ty <> " " <> identOrig nm
      <> maybe "" ((" = " <>) . unparseExpr) mInit
  BsAssign lv e         -> unparseLvalue lv <> " = " <> unparseExpr e
  BsAugAssign lv op rhs -> unparseLvalue lv <> " " <> augOpText op <> " " <> T.unwords (map tkText rhs)
  -- A space before "++"/"--" is load-bearing: PB.Lexing.Lexer's isIdentCont
  -- includes '-' (for the backtick-override compound syntax), so "foo" <>
  -- "--" with no space re-lexes as a single identifier token "foo--",
  -- dropping the BsDec wrapper entirely (mirrors unparseExpr's ExNeg note
  -- above, same collision class, different character).
  BsInc lv              -> unparseLvalue lv <> " ++"
  BsDec lv              -> unparseLvalue lv <> " --"
  BsCall e              -> unparseExpr e
  BsPbCall (PbCall anc ev) -> "call " <> anc <> " :: " <> ev
  BsReturn Nothing       -> "return"
  BsReturn (Just e)      -> "return " <> unparseExpr e
  BsIf (IfStmt cond then_ elseIfs else_) ->
    "if " <> unparseExpr cond <> " then\n" <> unparseBody then_
      <> foldMap unparseElseIf elseIfs
      <> maybe "" (\b -> "else\n" <> unparseBody b) else_
      <> "end if"
  BsFor (ForStmt lv from to step body) ->
    "for " <> unparseLvalue lv <> " = " <> unparseExpr from <> " to " <> unparseExpr to
      <> maybe "" ((" step " <>) . unparseExpr) step
      <> "\n" <> unparseBody body <> "next"
  BsDo (DoStmt mCond body mLoop) ->
    maybe "do" (("do " <>) . unparseDoCondition) mCond
      <> "\n" <> unparseBody body
      <> maybe "loop" (("loop " <>) . unparseDoCondition) mLoop
  BsChoose (ChooseStmt e clauses) ->
    "choose case " <> unparseExpr e <> "\n" <> foldMap unparseCaseClause clauses <> "end choose"
  BsExit                -> "exit"
  BsContinue            -> "continue"
  BsDestroy lv          -> "destroy " <> unparseLvalue lv
  BsAssignExpr lhs rhs  -> unparseExpr lhs <> " = " <> unparseExpr rhs
  BsTry (TryStmt body catches) ->
    "try\n" <> unparseBody body <> foldMap unparseCatchClause catches <> "end try"
  BsThrow e             -> "throw " <> unparseExpr e
  BsRaw t               -> t

unparseBody :: [Located BodyStmt] -> Text
unparseBody = T.unlines . map (unparseBodyStmt . locNode)

augOpText :: AugOp -> Text
augOpText op = case op of
  AugAdd -> "+="
  AugSub -> "-="
  AugMul -> "*="
  AugDiv -> "/="

unparseElseIf :: ElseIf -> Text
unparseElseIf (ElseIf cond body) = "elseif " <> unparseExpr cond <> " then\n" <> unparseBody body

unparseDoCondition :: DoCondition -> Text
unparseDoCondition (DoWhile e) = "while " <> unparseExpr e
unparseDoCondition (DoUntil e) = "until " <> unparseExpr e

unparseCaseClause :: CaseClause -> Text
unparseCaseClause (CaseClause mToks body) =
  "case " <> maybe "else" (T.unwords . map tkText) mToks <> "\n" <> unparseBody body

unparseCatchClause :: CatchClause -> Text
unparseCatchClause (CatchClause exnTy exnVar body) =
  "catch (" <> exnTy <> " " <> exnVar <> ")\n" <> unparseBody body
