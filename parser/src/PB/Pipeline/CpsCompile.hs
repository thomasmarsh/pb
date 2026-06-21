-- | Compile a procedure body into a flat CPS instruction graph.
--
-- Pure module — no I/O.  Public API:
--
--   compileProcedure :: TypeEnv -> InheritGraph -> [Located BodyStmt] -> CpsGraph
--
-- The resulting graph has no nested control flow; all branching is via
-- explicit node indices.  The TypeScript step() driver executes the graph.
-- Python stores the result as cps_graph_json on the procedures table.
module PB.Pipeline.CpsCompile
  ( CpsNode (..)
  , CpsGraph (..)
  , CallKind (..)
  , compileProcedure
  , classifyExpr
  , effectName
  , calleeName
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import PB.Grammar.Body        (parseExpr)
import PB.Lexing.Token        (Token (..))
import PB.Pipeline.TypeEnv (TypeEnv, lookupBaseType)
import Control.Monad       (foldM)
import Control.Monad.State.Strict
import Data.List            (partition)
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Output types

-- | A single flat instruction.  Field names are chosen so that
-- genericToJSON + stripCamelCasePrefix produces JSON keys matching the
-- TypeScript CpsNode discriminated union (with `tag` instead of `kind`).
-- The TypeScript loadCpsGraph() function maps tag → kind and renames
-- brThenPc → then_ and brElsePc → else_ to avoid TS keyword collisions.
data CpsNode
  = CpsAssign  { anVar :: Text, anRhs :: Expr, anNext :: Int }
  | CpsBranch  { brCond :: Expr, brThenPc :: Int, brElsePc :: Int }
  | CpsGoto    { goTarget :: Int }
  | CpsCall    { clCallee :: Text, clArgs :: [Expr], clResult :: Maybe Text, clNext :: Int }
  | CpsSuspend { suEffect :: Text, suArgs :: [Expr], suVar :: Maybe Text, suContinuation :: Int }
  | CpsReturn  { reValue :: Maybe Expr }
  | CpsNop     { npNext :: Int }
  | CpsCallProc { cpCallee :: Text, cpArgs :: [Expr], cpNext :: Int }
  deriving (Eq, Show, Generic)

data CpsGraph = CpsGraph
  { cgNodes            :: [CpsNode]
  , cgEntry            :: Int
  , cgSuspensionPoints :: [Int]
  , cgSourceMap        :: [(Int, Int)]   -- list of [pc, line] pairs
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Internal types

-- | Loop context threaded through compileStmts so that BsExit/BsContinue can
-- emit CpsGoto to the correct target PC.  Nothing = not inside a loop.
-- Just (headerPc, exitPc): headerPc is where CONTINUE jumps (increment step
-- for FOR, condition check for DO); exitPc is where EXIT jumps (past the loop).
type LoopCtx = Maybe (Int, Int)

-- ---------------------------------------------------------------------------
-- Side-effect classification

data CallKind = Pure | Suspend deriving (Eq, Show)

-- | Classify an expression as Pure or Suspend using type information when
-- available.  Without type info the fallback is conservative: Pure.
-- Free functions in 'builtinSuspendFns' are always Suspend regardless of type.
classifyExpr :: TypeEnv -> Expr -> CallKind
classifyExpr env (ExCall lv _) =
  let lnames = map (T.toLower . segName) (segments lv)
  in case lnames of
       [name]
         | isBuiltinSuspendFn name -> Suspend
       [headN, meth]
         | Just ty <- lookupBaseType headN env
         , isTypedSuspend ty meth  -> Suspend
       _ -> Pure
classifyExpr env (ExMethodCall recv meth _) =
  case resolveReceiverType env recv of
    Just ty | isTypedSuspend ty (T.toLower meth) -> Suspend
    _       -> Pure
classifyExpr _ _ = Pure

-- | Free functions that are always suspending regardless of receiver type.
isBuiltinSuspendFn :: Text -> Bool
isBuiltinSuspendFn n = n `elem`
  ["open", "opensheet", "close", "execute", "run", "fn_retrievechild"]

-- | Return True when a method on a resolved type is a side-effecting call.
isTypedSuspend :: Text -> Text -> Bool
isTypedSuspend ty meth
  | isDwType   ty = meth `elem`
      [ "retrieve", "update", "delete", "reset"
      , "rowscopy", "rowsmove", "sharedata"
      , "print", "modify"
      ]
  | isTransType ty = meth `elem`
      [ "commit", "rollback", "connect", "disconnect", "autocommit" ]
  | otherwise      = False

isDwType :: Text -> Bool
isDwType t = t `elem` ["datawindow", "datastore", "datawindowchild"]

isTransType :: Text -> Bool
isTransType t = t == "transaction"

resolveReceiverType :: TypeEnv -> Expr -> Maybe Text
resolveReceiverType env (ExLvalue lv) =
  case segments lv of
    (s:_) -> lookupBaseType (segName s) env
    []    -> Nothing
resolveReceiverType env (ExCall lv _) =
  case segments lv of
    [single] -> lookupBaseType (segName single) env
    _        -> Nothing
resolveReceiverType _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Effect naming

-- | Return the effect tag for a Suspend expression.  Only called for
-- expressions that classifyExpr already deemed Suspend.
effectName :: Expr -> Text
effectName expr =
  let cn   = T.toLower (calleeName expr)
      head_ = T.takeWhile (/= '.') cn
  in if cn `elem` ["open", "opensheet"] then "open"
     else if "close" `T.isSuffixOf` cn        then "close"
     else if ".retrieve" `T.isSuffixOf` cn    then "retrieve:" <> head_
     else "executeSql"

calleeName :: Expr -> Text
calleeName (ExCall lv _)          = T.intercalate "." (map segName (segments lv))
calleeName (ExMethodCall recv m _) =
  let recvName = case recv of
        ExLvalue lv -> T.intercalate "." (map segName (segments lv))
        _            -> "?"
  in recvName <> "." <> m
calleeName _ = "?"

segName :: LvSegment -> Text
segName (LvSegment n _) = n

lvHead :: Lvalue -> Text
lvHead lv = case segments lv of { (s:_) -> segName s; [] -> "_" }

-- | Detect `TriggerEvent(...)` or `this.TriggerEvent(...)` call sites that
-- should be lowered to a `CpsCallProc "triggerevent"` dispatch node rather
-- than a normal CpsCall/CpsSuspend (Plan 115 item 2).
isTriggerEvent :: Lvalue -> Bool
isTriggerEvent lv = case map (T.toLower . segName) (segments lv) of
  [s]   -> s == "triggerevent"
  [t,s] -> t == "this" && s == "triggerevent"
  _     -> False

-- ---------------------------------------------------------------------------
-- Argument conversion: token lists → typed Expr nodes
--
-- The AST stores call arguments as `[[Token]]`. `parseExpr` from
-- PB.Grammar.Body recovers typed Expr nodes (ExBinOp, ExStr, ExBool, ...).

-- | Convert one arg's token list to a typed Expr.
parseArgList :: [Token] -> Expr
parseArgList [] = ExRaw []
parseArgList ts = parseExpr ts

-- | Single-token → ExLvalue; multiple tokens → ExRaw (for BsAugAssign/BsInc/BsDec LHS).
lhsToExpr :: [Token] -> Expr
lhsToExpr [t] = ExLvalue (Lvalue [LvSegment (tkText t) Nothing])
lhsToExpr ts  = ExRaw (map tkText ts)

-- | Extract a CpsAssign variable name from a complex LHS expression.
assignTarget :: Expr -> Text
assignTarget (ExLvalue lv)              = lvHead lv
assignTarget (ExMethodCall recv meth _) = case recv of
    ExLvalue lv -> lvHead lv <> "." <> meth
    _            -> "?." <> meth
assignTarget _ = "?"

-- | Map BsAugAssign operators to binary operators.
augOpToBinOp :: AugOp -> BinOp
augOpToBinOp AugAdd = BopAdd
augOpToBinOp AugSub = BopSub
augOpToBinOp AugMul = BopMul
augOpToBinOp AugDiv = BopDiv

exprArgs :: Expr -> [Expr]
exprArgs (ExCall _ rawArgLists)         = map parseArgList rawArgLists
exprArgs (ExMethodCall _ _ rawArgLists) = map parseArgList rawArgLists
exprArgs _                              = []

-- ---------------------------------------------------------------------------
-- Builder state
--
-- We use a Map Int CpsNode so that we can emit a placeholder at a known PC
-- and patch it later (needed for forward references in for/do loops).

data CompileSt = CompileSt
  { csCount :: !Int
  , csNodes :: !(Map.Map Int CpsNode)
  , csSPs   :: ![Int]         -- suspension point PCs, in emission order
  , csSM    :: ![(Int, Int)]  -- (pc, line) source map, in emission order
  }

type C = State CompileSt

emit :: CpsNode -> Maybe Int -> C Int
emit node mLine = do
  st <- get
  let pc  = csCount st
      sps = if isSuspend node then csSPs st ++ [pc] else csSPs st
      sm  = case mLine of { Just l -> csSM st ++ [(pc, l)]; Nothing -> csSM st }
  put st { csCount = pc + 1
         , csNodes = Map.insert pc node (csNodes st)
         , csSPs   = sps
         , csSM    = sm
         }
  pure pc
  where
    isSuspend CpsSuspend {} = True
    isSuspend _             = False

patchNode :: Int -> CpsNode -> C ()
patchNode pc node = modify' $ \st -> st { csNodes = Map.insert pc node (csNodes st) }

finalizeCps :: Int -> C CpsGraph
finalizeCps entry = do
  st <- get
  pure CpsGraph
    { cgNodes            = Map.elems (csNodes st)   -- sorted by PC
    , cgEntry            = entry
    , cgSuspensionPoints = csSPs st
    , cgSourceMap        = csSM st
    }

-- ---------------------------------------------------------------------------
-- Compilation

-- | Compile a sequence of statements in reverse order (last first), so that
-- each statement can reference the next statement's PC as its fallthrough.
compileStmts :: TypeEnv -> LoopCtx -> [Located BodyStmt] -> Int -> C Int
compileStmts _   _    []     ft = pure ft
compileStmts env lctx (s:ss) ft = do
  ssFt <- compileStmts env lctx ss ft
  compileSingleStmt env lctx s ssFt

compileSingleStmt :: TypeEnv -> LoopCtx -> Located BodyStmt -> Int -> C Int
compileSingleStmt env lctx (Located line stmt) fallthrough = case stmt of

  BsLocalVar _ _ varName (Just initExpr) ->
    emit (CpsAssign { anVar = varName, anRhs = initExpr, anNext = fallthrough }) (Just line)

  BsLocalVar {} -> pure fallthrough   -- declaration without initializer

  BsAssign lv rhs ->
    emit (CpsAssign { anVar = lvHead lv, anRhs = rhs, anNext = fallthrough }) (Just line)

  BsAugAssign lhsToks augOp rhsToks ->
    let varName = case lhsToks of { (t:_) -> tkText t; [] -> "_" }
    in emit (CpsAssign
         { anVar = varName
         , anRhs = ExBinOp { lhs = lhsToExpr lhsToks, op = augOpToBinOp augOp, rhs = parseArgList rhsToks }
         , anNext = fallthrough
         }) (Just line)

  BsInc lhsToks ->
    let varName = case lhsToks of { (t:_) -> tkText t; [] -> "_" }
    in emit (CpsAssign
         { anVar = varName
         , anRhs = ExBinOp { lhs = lhsToExpr lhsToks, op = BopAdd, rhs = ExInt "1" }
         , anNext = fallthrough
         }) (Just line)

  BsDec lhsToks ->
    let varName = case lhsToks of { (t:_) -> tkText t; [] -> "_" }
    in emit (CpsAssign
         { anVar = varName
         , anRhs = ExBinOp { lhs = lhsToExpr lhsToks, op = BopSub, rhs = ExInt "1" }
         , anNext = fallthrough
         }) (Just line)

  BsAssignExpr lhsExpr rhsExpr ->
    emit (CpsAssign { anVar = assignTarget lhsExpr, anRhs = rhsExpr, anNext = fallthrough }) (Just line)

  BsCall expr
    | ExCall lv rawArgs <- expr
    , isTriggerEvent lv ->
        let evArg = case rawArgs of
              (a:_) -> parseArgList a
              []    -> ExRaw []
        in emit (CpsCallProc
             { cpCallee = "triggerevent"
             , cpArgs   = [evArg]
             , cpNext   = fallthrough
             }) (Just line)
    | otherwise -> case classifyExpr env expr of
      Suspend ->
        emit (CpsSuspend
          { suEffect       = effectName expr
          , suArgs         = exprArgs expr
          , suVar          = Nothing
          , suContinuation = fallthrough
          }) (Just line)
      Pure ->
        emit (CpsCall
          { clCallee = calleeName expr
          , clArgs   = exprArgs expr
          , clResult = Nothing
          , clNext   = fallthrough
          }) (Just line)

  BsReturn mExpr ->
    emit (CpsReturn { reValue = mExpr }) (Just line)

  BsExit -> case lctx of
    Just (_, exitPc) -> emit (CpsGoto { goTarget = exitPc }) (Just line)
    Nothing          -> pure fallthrough

  BsContinue -> case lctx of
    Just (headerPc, _) -> emit (CpsGoto { goTarget = headerPc }) (Just line)
    Nothing            -> pure fallthrough

  BsDestroy lv ->
    emit (CpsAssign { anVar = lvHead lv, anRhs = ExNull, anNext = fallthrough }) (Just line)

  BsIf (IfStmt cond thenStmts elseIfs elseStmts) -> do
    elseFt <- case elseStmts of
                Nothing -> pure fallthrough
                Just es -> compileStmts env lctx es fallthrough
    chainFt <- foldM (compileElseIf env lctx fallthrough) elseFt (reverse elseIfs)
    thenEntry <- compileStmts env lctx thenStmts fallthrough
    emit (CpsBranch { brCond = cond, brThenPc = thenEntry, brElsePc = chainFt }) (Just line)

  BsFor (ForStmt var from to mStep bodyStmts) -> do
    let varName  = lvHead var
        stepExpr = fromMaybe (ExInt "1") mStep
        varExpr  = ExLvalue var
    branchPc <- emit (CpsNop { npNext = 0 }) Nothing
    incrPc   <- emit (CpsNop { npNext = 0 }) Nothing
    bodyEntry <- compileStmts env (Just (incrPc, fallthrough)) bodyStmts incrPc
    patchNode incrPc (CpsAssign
      { anVar = varName
      , anRhs = ExBinOp { lhs = varExpr, op = BopAdd, rhs = stepExpr }
      , anNext = branchPc
      })
    patchNode branchPc (CpsBranch
      { brCond   = ExBinOp { lhs = varExpr, op = BopLe, rhs = to }
      , brThenPc = bodyEntry
      , brElsePc = fallthrough
      })
    emit (CpsAssign { anVar = varName, anRhs = from, anNext = branchPc }) (Just line)

  BsDo (DoStmt mCond bodyStmts mLoop) -> case mCond of
    Just cond -> do
      branchPc  <- emit (CpsNop { npNext = 0 }) Nothing
      bodyEntry <- compileStmts env (Just (branchPc, fallthrough)) bodyStmts branchPc
      patchNode branchPc (CpsBranch
        { brCond   = condExpr cond
        , brThenPc = bodyEntry
        , brElsePc = fallthrough
        })
      pure branchPc
    Nothing -> case mLoop of
      Just cond -> do
        branchPc  <- emit (CpsNop { npNext = 0 }) Nothing
        bodyEntry <- compileStmts env (Just (branchPc, fallthrough)) bodyStmts branchPc
        patchNode branchPc (CpsBranch
          { brCond   = condExpr cond
          , brThenPc = bodyEntry
          , brElsePc = fallthrough
          })
        pure bodyEntry
      Nothing -> do
        nopPc     <- emit (CpsNop { npNext = 0 }) Nothing
        bodyEntry <- compileStmts env (Just (nopPc, fallthrough)) bodyStmts nopPc
        patchNode nopPc (CpsNop { npNext = bodyEntry })
        pure bodyEntry

  BsChoose (ChooseStmt expr clauses) -> do
    let (elseCs, normalCs) = partition (\c -> isNothing (ccExpr c)) clauses
    elseFt <- case elseCs of
                (c:_) -> compileStmts env lctx (ccBody c) fallthrough
                []    -> pure fallthrough
    foldM (compileClause env expr lctx fallthrough) elseFt (reverse normalCs)

  -- BsPbCall: CALL ancestor::event  → dispatch node (Plan 115 item 2)
  BsPbCall (PbCall ancestor event) ->
    emit (CpsCallProc
      { cpCallee = ancestor <> "::" <> event
      , cpArgs   = []
      , cpNext   = fallthrough
      }) (Just line)

  -- Statements with no CPS representation: fall through.
  BsRaw _ -> pure fallthrough

compileElseIf :: TypeEnv -> LoopCtx -> Int -> Int -> ElseIf -> C Int
compileElseIf env lctx fallthrough nextFt ei = do
  eiEntry <- compileStmts env lctx (eifBody ei) fallthrough
  emit (CpsBranch { brCond = eifCond ei, brThenPc = eiEntry, brElsePc = nextFt }) Nothing

compileClause :: TypeEnv -> Expr -> LoopCtx -> Int -> Int -> CaseClause -> C Int
compileClause env caseExpr lctx fallthrough nextFt clause = case ccExpr clause of
  Nothing   -> compileStmts env lctx (ccBody clause) fallthrough
  Just toks -> do
    bodyEntry <- compileStmts env lctx (ccBody clause) fallthrough
    let clauseVal = parseExpr toks
    let cond = ExBinOp { lhs = caseExpr, op = BopEq, rhs = clauseVal }
    emit (CpsBranch { brCond = cond, brThenPc = bodyEntry, brElsePc = nextFt }) Nothing

-- | For DoWhile: condition is true → keep looping.
-- For DoUntil: condition is false → keep looping (negate).
condExpr :: DoCondition -> Expr
condExpr (DoWhile e) = e
condExpr (DoUntil e) = ExNot e

-- ---------------------------------------------------------------------------
-- Public entry point

compileProcedure :: TypeEnv -> [Located BodyStmt] -> CpsGraph
compileProcedure env body =
  let initSt = CompileSt { csCount = 0, csNodes = Map.empty, csSPs = [], csSM = [] }
      (graph, _) = runState go initSt
  in graph
  where
    go = do
      returnPc <- emit (CpsReturn { reValue = Nothing }) Nothing
      entryPc  <- compileStmts env Nothing body returnPc
      finalizeCps entryPc
