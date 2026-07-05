{-# LANGUAGE StrictData #-}
-- | Compile a procedure body into a flat CPS instruction graph.
--
-- Pure module — no I/O.  Public API:
--
--   compileProcedure :: TypeEnv -> InheritGraph -> [Located BodyStmt] -> CpsGraph
--
-- The resulting graph has no nested control flow; all branching is via
-- explicit node indices.  The TypeScript step() driver executes the graph.
-- Python stores the result as cps_graph_json on the procedures table.
module PB.Analysis.CpsCompile
  ( CpsNode (..)
  , CpsGraph (..)
  , compileProcedure
  , parseArgList
  , ShapeNode (..)
  , canonicalize
  , normalizeCallTag
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import PB.AST.Type     (PbType)
import PB.Grammar.Body        (parseExpr)
import PB.Lexing.Token        (Token (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Analysis.CallClassify
  ( CallKind (..), classifyExpr, effectName, calleeName
  , segName, lvHead, isTriggerEvent
  )
import Control.Monad       (foldM)
import Control.Monad.State.Strict
import Data.List            (partition)
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
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

-- This is more appropriately a basic block / program counter (PC) driven structure rather
-- than a traditional functional CPS graph (which uses nested closures). The nodes reference
-- the next instructions by integer indices (Int), effectively serving as awwarray-backed
-- control-flow graph (CFG).
data CpsGraph = CpsGraph
  { cgNodes            :: [CpsNode]
  , cgEntry            :: Int
  , cgSuspensionPoints :: [Int]
  , cgSourceMap        :: [(Int, Int)]   -- list of [pc, line] pairs
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Canonical graph shape (for dual-CPS comparison and hand-trace tests)

-- | Structural shape of a CpsNode with all variable names and expression
-- values erased.  PC targets are replaced by canonical indices (BFS order
-- from entry).  Effect names on CpsSuspend are retained — they are the
-- correctness-critical signal.
data ShapeNode
  = SAsgn  Int        -- CpsAssign:   canonical anNext
  | SBrnch Int Int    -- CpsBranch:   canonical then, canonical else
  | SGoto  Int        -- CpsGoto:     canonical target
  | SCall  Int        -- CpsCall:     canonical clNext
  | SSusp  Text Int   -- CpsSuspend:  effect name, canonical continuation
  | SRet              -- CpsReturn
  | SNop   Int        -- CpsNop:      canonical npNext (-1 preserved)
  | SCProc Int        -- CpsCallProc: canonical cpNext
  deriving (Eq, Show)

-- | BFS traversal from entry, returning PCs in visitation order.
bfsOrder :: Int -> Map.Map Int CpsNode -> [Int]
bfsOrder entry nodeMap = go [entry] Set.empty []
  where
    succs node = case node of
      CpsAssign  { anNext }              -> [anNext             | anNext >= 0]
      CpsBranch  { brThenPc, brElsePc } -> [brThenPc, brElsePc]
      CpsGoto    { goTarget }            -> [goTarget            | goTarget >= 0]
      CpsCall    { clNext }              -> [clNext              | clNext >= 0]
      CpsSuspend { suContinuation }      -> [suContinuation      | suContinuation >= 0]
      CpsReturn  {}                      -> []
      CpsNop     { npNext }              -> [npNext              | npNext >= 0]
      CpsCallProc { cpNext }             -> [cpNext              | cpNext >= 0]
    go []        _       acc = reverse acc
    go (pc:rest) visited acc
      | Set.member pc visited = go rest visited acc
      | otherwise = case Map.lookup pc nodeMap of
          Nothing   -> go rest (Set.insert pc visited) acc
          Just node -> go (rest ++ succs node) (Set.insert pc visited) (pc : acc)

-- | Convert a CpsGraph to a canonical shape list.
canonicalize :: CpsGraph -> [ShapeNode]
canonicalize graph =
  let nodeMap = Map.fromList (zip [0 ..] (cgNodes graph))
      order   = bfsOrder (cgEntry graph) nodeMap
      canon   = Map.fromList (zip order [0 ..])
      look n  = Map.findWithDefault (-1) n canon
  in [ shapeOf look node | pc <- order, Just node <- [Map.lookup pc nodeMap] ]

shapeOf :: (Int -> Int) -> CpsNode -> ShapeNode
shapeOf look node = case node of
  CpsAssign  { anNext }                   -> SAsgn  (look anNext)
  CpsBranch  { brThenPc, brElsePc }       -> SBrnch (look brThenPc) (look brElsePc)
  CpsGoto    { goTarget }                 -> SGoto  (look goTarget)
  CpsCall    { clNext }                   -> SCall  (look clNext)
  CpsSuspend { suEffect, suContinuation } -> SSusp  suEffect (look suContinuation)
  CpsReturn  {}                           -> SRet
  CpsNop     { npNext }                   -> SNop   (if npNext < 0 then -1 else look npNext)
  CpsCallProc { cpNext }                  -> SCProc (look cpNext)

-- | Collapse the SCall\/SCProc tag-naming divergence: the new SSA\/CatOp
-- pipeline always lowers calls to 'CpsCallProc' ('SCProc'), while the old
-- compiler ('compileProcedure') emits plain 'CpsCall' ('SCall') for
-- non-user-function callees and 'CpsCallProc' only for user-defined
-- functions\/subroutines. This is a pure node-tag difference with no effect
-- on control flow or shape (Plan 145 Phase 1B) — comparisons that care about
-- genuine structural\/semantic parity (e.g. @--dual-cps@) should normalize
-- it first so this accepted, harmless divergence doesn't mask real diffs.
normalizeCallTag :: ShapeNode -> ShapeNode
normalizeCallTag (SCProc n) = SCall n
normalizeCallTag other      = other

-- ---------------------------------------------------------------------------
-- Internal types

-- | Loop context threaded through compileStmts so that BsExit/BsContinue can
-- emit CpsGoto to the correct target PC.  Nothing = not inside a loop.
-- Just (headerPc, exitPc): headerPc is where CONTINUE jumps (increment step
-- for FOR, condition check for DO); exitPc is where EXIT jumps (past the loop).
type LoopCtx = Maybe (Int, Int)



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
  { csCount   :: !Int
  , csNodes   :: !(Map.Map Int CpsNode)
  , csSPs     :: ![Int]             -- suspension point PCs, in emission order
  , csSM      :: ![(Int, Int)]      -- (pc, line) source map, in emission order
  , csUserFns :: !(Set.Set Text)    -- user-defined function names (lower-cased)
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
compileStmts :: ScopedTypeEnv -> LoopCtx -> [Located BodyStmt] -> Int -> C Int
compileStmts _   _    []     ft = pure ft
compileStmts env lctx (s:ss) ft = do
  ssFt <- compileStmts env lctx ss ft
  compileSingleStmt env lctx s ssFt

compileSingleStmt :: ScopedTypeEnv -> LoopCtx -> Located BodyStmt -> Int -> C Int
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
    -- fn_retrievechild(adw, "col", sqlParam): encode both the column name and
    -- the parent DW control in the effect so the runtime can resolve SQL
    -- without searching. Effect: "retrieve:child_<col>:<dwCtrl>".
    | ExCall lv rawArgs <- expr
    , [seg] <- segments lv
    , T.toLower (segName seg) == "fn_retrievechild" ->
        let dwArg    = case rawArgs of { (d:_)     -> parseArgList d; _ -> ExRaw [] }
            colArg   = case rawArgs of { (_:c:_)   -> parseArgList c; _ -> ExRaw [] }
            paramArg = case rawArgs of { (_:_:p:_) -> [parseArgList p]; _ -> [] }
            col      = case colArg of { ExStr c -> T.toLower c; _ -> "?" }
            dwCtrl   = case dwArg of
                         ExLvalue dv -> case segments dv of
                           (dvSeg:_) -> T.toLower (segName dvSeg)
                           []        -> "?"
                         _ -> "?"
        in emit (CpsSuspend
             { suEffect       = "retrieve:child_" <> col <> ":" <> dwCtrl
             , suArgs         = paramArg
             , suVar          = Nothing
             , suContinuation = fallthrough
             }) (Just line)
    | otherwise -> do
        fns <- gets csUserFns
        let parsedArgs = exprArgs expr
            defaultEmit = case classifyExpr env expr of
              SuspendCall ->
                emit (CpsSuspend
                  { suEffect       = effectName expr parsedArgs
                  , suArgs         = parsedArgs
                  , suVar          = Nothing
                  , suContinuation = fallthrough
                  }) (Just line)
              PureCall ->
                emit (CpsCall
                  { clCallee = calleeName expr
                  , clArgs   = exprArgs expr
                  , clResult = Nothing
                  , clNext   = fallthrough
                  }) (Just line)
        case expr of
          ExCall lv _
            | [seg] <- segments lv
            , T.toLower (segName seg) `Set.member` fns ->
                emit (CpsCallProc
                  { cpCallee = segName seg
                  , cpArgs   = exprArgs expr
                  , cpNext   = fallthrough
                  }) (Just line)
            | otherwise -> defaultEmit
          _ -> defaultEmit

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

  -- try/catch: compile try body sequentially; compile each catch body as
  -- independently-reachable code (exception dispatch is runtime-only, no
  -- static edge). throw has no CPS representation.
  BsTry (TryStmt body catches) -> do
    _ <- mapM (\c -> compileStmts env lctx (catchBody c) fallthrough) catches
    compileStmts env lctx body fallthrough

  BsThrow _ -> pure fallthrough

  -- Statements with no CPS representation: fall through.
  BsRaw _ -> pure fallthrough

compileElseIf :: ScopedTypeEnv -> LoopCtx -> Int -> Int -> ElseIf -> C Int
compileElseIf env lctx fallthrough nextFt ei = do
  eiEntry <- compileStmts env lctx (eifBody ei) fallthrough
  emit (CpsBranch { brCond = eifCond ei, brThenPc = eiEntry, brElsePc = nextFt }) Nothing

compileClause :: ScopedTypeEnv -> Expr -> LoopCtx -> Int -> Int -> CaseClause -> C Int
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

collectBodyLocals :: [Located BodyStmt] -> Map.Map Text PbType
collectBodyLocals stmts =
  Map.fromList
    [ (T.toLower varName, varType)
    | Located _ (BsLocalVar _ varType varName _) <- stmts
    ]

compileProcedure :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> CpsGraph
compileProcedure env userFns body =
  let locals = collectBodyLocals body
      env'   = env { steLocal = locals `Map.union` steLocal env }
      initSt = CompileSt { csCount = 0, csNodes = Map.empty, csSPs = [], csSM = [], csUserFns = userFns }
      go     = do
                 returnPc <- emit (CpsReturn { reValue = Nothing }) Nothing
                 entryPc  <- compileStmts env' Nothing body returnPc
                 finalizeCps entryPc
      (graph, _) = runState go initSt
  in graph
