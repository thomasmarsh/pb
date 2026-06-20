module PB.Pipeline.PrettyPrint
  ( prettyBodyStmts
  , prettyStmt
  , prettyExpr
  , prettyLvalue
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located     (Located (..))
import PB.AST.Type         (renderPbType)
import qualified Data.Text as T

-- | Render a list of body statements to indented PowerScript text.
prettyBodyStmts :: [Located BodyStmt] -> Text
prettyBodyStmts = prettyBodyStmtsAt 0

prettyBodyStmtsAt :: Int -> [Located BodyStmt] -> Text
prettyBodyStmtsAt n =
  T.intercalate "\n" . filter (not . T.null . T.strip) . map (prettyStmtAt n . locNode)

-- | Render a single body statement at indent level 0.
prettyStmt :: BodyStmt -> Text
prettyStmt = prettyStmtAt 0

prettyStmtAt :: Int -> BodyStmt -> Text
prettyStmtAt n stmt =
  let pad = T.replicate (n * 4) " "
  in case stmt of
    BsLocalVar { varMods = mods, varType = ty, varName = name, varInit = initE } ->
      let prefix = if null mods then "" else T.unwords mods <> " "
      in pad <> prefix <> renderPbType ty <> " " <> name
         <> maybe "" (\e -> " = " <> prettyExpr e) initE
    BsAssign    lval e         -> pad <> prettyLvalue lval <> " = " <> prettyExpr e
    BsAugAssign lhs op rhs     -> pad <> T.unwords lhs <> " " <> prettyAugOp op <> " " <> T.unwords rhs
    BsInc       toks           -> pad <> T.unwords toks <> "++"
    BsDec       toks           -> pad <> T.unwords toks <> "--"
    BsCall      e              -> pad <> prettyExpr e
    BsPbCall    pc             -> pad <> "call " <> pbcAncestor pc <> " :: " <> pbcEvent pc
    BsReturn    Nothing        -> pad <> "return"
    BsReturn    (Just e)       -> pad <> "return " <> prettyExpr e
    BsExit                     -> pad <> "exit"
    BsContinue                 -> pad <> "continue"
    BsDestroy   lval           -> pad <> "destroy " <> prettyLvalue lval
    BsAssignExpr lhs rhs       -> pad <> prettyExpr lhs <> " = " <> prettyExpr rhs
    BsRaw       t              -> pad <> T.strip t
    BsIf        s              -> prettyIf n s
    BsFor       s              -> prettyFor n s
    BsDo        s              -> prettyDo n s
    BsChoose    s              -> prettyChoose n s

-- Only include body text when non-empty (avoids spurious blank lines in empty blocks).
bodyBlock :: Int -> [Located BodyStmt] -> [Text]
bodyBlock n stmts =
  let rendered = prettyBodyStmtsAt n stmts
  in [rendered | not (T.null rendered)]

prettyIf :: Int -> IfStmt -> Text
prettyIf n (IfStmt cond then_ elseIfs else_) =
  T.intercalate "\n" $ concat
    [ [pad <> "if " <> prettyExpr cond <> " then"]
    , bodyBlock (n + 1) then_
    , concatMap renderElseIf elseIfs
    , maybe [] renderElse else_
    , [pad <> "end if"]
    ]
  where
    pad = T.replicate (n * 4) " "
    renderElseIf (ElseIf eifC eifB) =
      (pad <> "elseif " <> prettyExpr eifC <> " then") : bodyBlock (n + 1) eifB
    renderElse bs =
      (pad <> "else") : bodyBlock (n + 1) bs

prettyFor :: Int -> ForStmt -> Text
prettyFor n (ForStmt { forVar = v, forFrom = fr, forTo = to, forStep = step, forBody = body }) =
  T.intercalate "\n" $ concat
    [ [pad <> "for " <> prettyLvalue v <> " = " <> prettyExpr fr
        <> " to " <> prettyExpr to
        <> maybe "" (\s -> " step " <> prettyExpr s) step]
    , bodyBlock (n + 1) body
    , [pad <> "next"]
    ]
  where pad = T.replicate (n * 4) " "

prettyDo :: Int -> DoStmt -> Text
prettyDo n (DoStmt { doCond = cond, doBody = body, doLoop = loop }) =
  T.intercalate "\n" $ concat
    [ [pad <> "do" <> maybe "" (\c -> " " <> prettyCond c) cond]
    , bodyBlock (n + 1) body
    , [pad <> "loop" <> maybe "" (\c -> " " <> prettyCond c) loop]
    ]
  where
    pad = T.replicate (n * 4) " "
    prettyCond (DoWhile e) = "while " <> prettyExpr e
    prettyCond (DoUntil e) = "until " <> prettyExpr e

prettyChoose :: Int -> ChooseStmt -> Text
prettyChoose n (ChooseStmt { chooseExpr = expr, chooseClauses = clauses }) =
  T.intercalate "\n" $
    [pad <> "choose case " <> prettyExpr expr]
    <> concatMap renderClause clauses
    <> [pad <> "end choose"]
  where
    pad = T.replicate (n * 4) " "
    renderClause (CaseClause Nothing body) =
      [pad <> "case else", prettyBodyStmtsAt (n + 1) body]
    renderClause (CaseClause (Just toks) body) =
      [pad <> "case " <> T.unwords toks, prettyBodyStmtsAt (n + 1) body]

-- | Render an expression.
prettyExpr :: Expr -> Text
prettyExpr = \case
  ExBool b    -> if b then "true" else "false"
  ExInt  t    -> t
  ExReal t    -> t
  ExStr  t    -> "\"" <> t <> "\""
  ExDate t    -> t
  ExTime t    -> t
  ExNull      -> "null"
  ExEnum t    -> t <> "!"
  ExLvalue lv -> prettyLvalue lv
  ExCall { callee = c, callArgs = as } ->
    prettyLvalue c <> "(" <> prettyArgs as <> ")"
  ExMethodCall { receiver = r, method = m, methodArgs = as } ->
    prettyExpr r <> "." <> m <> "(" <> prettyArgs as <> ")"
  ExDispatch de   -> prettyDispatch de
  ExCreate t      -> "create " <> t
  ExCreateUsing e -> "create using " <> prettyExpr e
  ExArray es      -> "{" <> T.intercalate ", " (map prettyExpr es) <> "}"
  ExBinOp { lhs = l, op = o, rhs = r } ->
    prettyExpr l <> " " <> prettyBinOp o <> " " <> prettyExpr r
  ExNot e      -> "not " <> prettyExpr e
  ExNeg e      -> "-" <> prettyExpr e
  ExHostVar lv -> ":" <> prettyLvalue lv
  ExRaw toks   -> T.unwords toks

-- | Render a dotted lvalue, e.g. @obj.arr[i].field@.
prettyLvalue :: Lvalue -> Text
prettyLvalue (Lvalue segs) = T.intercalate "." (map prettySeg segs)
  where
    prettySeg (LvSegment { name = n, subscript = Nothing })    = n
    prettySeg (LvSegment { name = n, subscript = Just sub }) = n <> "[" <> T.intercalate ", " sub <> "]"

prettyArgs :: [[Text]] -> Text
prettyArgs = T.intercalate ", " . map T.unwords

prettyDispatch :: DispatchExpr -> Text
prettyDispatch (DispatchExpr { object = mObj, mode = m, dynamic = isDyn
                             , event = isEv, name = n, args = as }) =
  T.strip $ T.concat
    [ if isDyn then "DYNAMIC " else ""
    , case m of { DmPost -> "POST "; DmTrigger -> "TRIGGER "; DmSync -> "" }
    , if isEv then "EVENT " else ""
    , maybe "" (\lv -> prettyLvalue lv <> "::") mObj
    , n
    , if null as then "" else "(" <> prettyArgs as <> ")"
    ]

prettyBinOp :: BinOp -> Text
prettyBinOp = \case
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

prettyAugOp :: AugOp -> Text
prettyAugOp = \case
  AugAdd -> "+="
  AugSub -> "-="
  AugMul -> "*="
  AugDiv -> "/="
