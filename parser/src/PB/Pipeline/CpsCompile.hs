-- | Compile a procedure body into a flat CPS instruction graph.
--
-- Pure module — no I/O.  Public API:
--
--   compileProcedure :: [Located BodyStmt] -> CpsGraph
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
  , calleeName
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import Control.Monad       (foldM)
import Control.Monad.State.Strict
import Data.Char            (isAlpha)
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
  deriving (Eq, Show, Generic)

data CpsGraph = CpsGraph
  { cgNodes            :: [CpsNode]
  , cgEntry            :: Int
  , cgSuspensionPoints :: [Int]
  , cgSourceMap        :: [(Int, Int)]   -- list of [pc, line] pairs
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Side-effect classification

data CallKind = Pure | Suspend deriving (Eq, Show)

classifyExpr :: Expr -> CallKind
classifyExpr (ExCall lv _) =
  let segs  = segments lv
      lnames = map (T.toLower . segName) segs
  in case lnames of
       [_, "retrieve"]      -> Suspend
       ["fn_retrievechild"] -> Suspend
       ["open"]             -> Suspend
       ["opensheet"]        -> Suspend
       _                    -> Pure
classifyExpr (ExMethodCall _ m _) =
  if T.toLower m == "retrieve" then Suspend else Pure
classifyExpr _ = Pure

calleeName :: Expr -> Text
calleeName (ExCall lv _)          = T.intercalate "." (map segName (segments lv))
calleeName (ExMethodCall recv m _) =
  let recvName = case recv of
        ExLvalue lv -> T.intercalate "." (map segName (segments lv))
        _            -> "?"
  in recvName <> "." <> m
calleeName _ = "?"

effectName :: Expr -> Text
effectName expr =
  let cn = calleeName expr
  in if ".retrieve" `T.isSuffixOf` T.toLower cn then "executeSql" else T.toLower cn

segName :: LvSegment -> Text
segName (LvSegment n _) = n

lvHead :: Lvalue -> Text
lvHead lv = case segments lv of { (s:_) -> segName s; [] -> "_" }

-- ---------------------------------------------------------------------------
-- Argument conversion: raw token lists → simple Expr nodes

parseArg :: Text -> Expr
parseArg t
  | T.length t >= 2, "\"" `T.isPrefixOf` t, "\"" `T.isSuffixOf` t =
      ExStr (T.drop 1 (T.dropEnd 1 t))
  | not (T.null t), isAlpha (T.head t) =
      ExLvalue (Lvalue [LvSegment t Nothing])
  | otherwise = ExStr t

exprArgs :: Expr -> [Expr]
exprArgs (ExCall _ rawArgLists)      = map parseArg (concat rawArgLists)
exprArgs (ExMethodCall _ _ rawArgLists) = map parseArg (concat rawArgLists)
exprArgs _                           = []

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
compileStmts :: [Located BodyStmt] -> Int -> C Int
compileStmts []     ft = pure ft
compileStmts (s:ss) ft = do
  ssFt <- compileStmts ss ft
  compileSingleStmt s ssFt

compileSingleStmt :: Located BodyStmt -> Int -> C Int
compileSingleStmt (Located line stmt) fallthrough = case stmt of

  BsLocalVar _ _ varName (Just initExpr) ->
    emit (CpsAssign { anVar = varName, anRhs = initExpr, anNext = fallthrough }) (Just line)

  BsLocalVar {} -> pure fallthrough   -- declaration without initializer

  BsAssign lv rhs ->
    emit (CpsAssign { anVar = lvHead lv, anRhs = rhs, anNext = fallthrough }) (Just line)

  BsCall expr -> case classifyExpr expr of
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

  BsIf (IfStmt cond thenStmts elseIfs elseStmts) -> do
    -- Build the false-chain from the else outward through elseifs (reverse order).
    elseFt <- case elseStmts of
                Nothing -> pure fallthrough
                Just es -> compileStmts es fallthrough
    chainFt <- foldM compileElseIf elseFt (reverse elseIfs)
    thenEntry <- compileStmts thenStmts fallthrough
    emit (CpsBranch { brCond = cond, brThenPc = thenEntry, brElsePc = chainFt }) (Just line)
    where
      compileElseIf nextFt ei = do
        eiEntry <- compileStmts (eifBody ei) fallthrough
        emit (CpsBranch { brCond = eifCond ei, brThenPc = eiEntry, brElsePc = nextFt }) Nothing

  BsFor (ForStmt var from to mStep bodyStmts) -> do
    let varName  = lvHead var
        stepExpr = fromMaybe (ExInt "1") mStep
        varExpr  = ExLvalue var
    -- Reserve PCs for branch and incr (forward references from body/init).
    branchPc <- emit (CpsNop { npNext = 0 }) Nothing
    incrPc   <- emit (CpsNop { npNext = 0 }) Nothing
    -- Compile body with fallthrough = incrPc (now known).
    bodyEntry <- compileStmts bodyStmts incrPc
    -- Patch incr: i = i + step, then re-check condition.
    patchNode incrPc (CpsAssign
      { anVar = varName
      , anRhs = ExBinOp { lhs = varExpr, op = BopAdd, rhs = stepExpr }
      , anNext = branchPc
      })
    -- Patch branch: i <= to ? body : post.
    patchNode branchPc (CpsBranch
      { brCond   = ExBinOp { lhs = varExpr, op = BopLe, rhs = to }
      , brThenPc = bodyEntry
      , brElsePc = fallthrough
      })
    -- Emit init: i = from, then check condition.
    emit (CpsAssign { anVar = varName, anRhs = from, anNext = branchPc }) (Just line)

  BsDo (DoStmt mCond bodyStmts mLoop) -> case mCond of
    Just cond -> do
      -- DO WHILE/UNTIL cond: condition at top.
      branchPc  <- emit (CpsNop { npNext = 0 }) Nothing
      bodyEntry <- compileStmts bodyStmts branchPc
      patchNode branchPc (CpsBranch
        { brCond   = condExpr cond
        , brThenPc = bodyEntry
        , brElsePc = fallthrough
        })
      pure branchPc
    Nothing -> case mLoop of
      Just cond -> do
        -- DO ... LOOP WHILE/UNTIL: condition at bottom.
        branchPc  <- emit (CpsNop { npNext = 0 }) Nothing
        bodyEntry <- compileStmts bodyStmts branchPc
        patchNode branchPc (CpsBranch
          { brCond   = condExpr cond
          , brThenPc = bodyEntry
          , brElsePc = fallthrough
          })
        pure bodyEntry
      Nothing -> do
        -- DO ... LOOP (infinite): body loops back via nop header.
        nopPc     <- emit (CpsNop { npNext = 0 }) Nothing
        bodyEntry <- compileStmts bodyStmts nopPc
        patchNode nopPc (CpsNop { npNext = bodyEntry })
        pure bodyEntry

  BsChoose (ChooseStmt expr clauses) -> do
    let (elseCs, normalCs) = partition (\c -> isNothing (ccExpr c)) clauses
    elseFt <- case elseCs of
                (c:_) -> compileStmts (ccBody c) fallthrough
                []    -> pure fallthrough
    foldM (compileClause expr) elseFt (reverse normalCs)
    where
      compileClause caseExpr nextFt clause = case ccExpr clause of
        Nothing -> compileStmts (ccBody clause) fallthrough
        Just toks -> do
          bodyEntry <- compileStmts (ccBody clause) fallthrough
          let clauseVal = case toks of { [t] -> parseArg t; ts -> ExStr (T.unwords ts) }
          let cond = ExBinOp { lhs = caseExpr, op = BopEq, rhs = clauseVal }
          emit (CpsBranch { brCond = cond, brThenPc = bodyEntry, brElsePc = nextFt }) Nothing

  -- Statements with no CPS representation yet: fall through.
  BsExit     -> pure fallthrough
  BsContinue -> pure fallthrough
  BsRaw _    -> pure fallthrough
  BsPbCall _ -> pure fallthrough
  BsDestroy _ -> pure fallthrough
  BsAugAssign _ _ _ -> pure fallthrough
  BsInc _ -> pure fallthrough
  BsDec _ -> pure fallthrough
  BsAssignExpr _ _ -> pure fallthrough

-- | For DoWhile: condition is true → keep looping.
-- For DoUntil: condition is false → keep looping (negate).
condExpr :: DoCondition -> Expr
condExpr (DoWhile e) = e
condExpr (DoUntil e) = ExNot e

-- ---------------------------------------------------------------------------
-- Public entry point

compileProcedure :: [Located BodyStmt] -> CpsGraph
compileProcedure body =
  let initSt = CompileSt { csCount = 0, csNodes = Map.empty, csSPs = [], csSM = [] }
      (graph, _) = runState go initSt
  in graph
  where
    go = do
      returnPc <- emit (CpsReturn { reValue = Nothing }) Nothing
      entryPc  <- compileStmts body returnPc
      finalizeCps entryPc
