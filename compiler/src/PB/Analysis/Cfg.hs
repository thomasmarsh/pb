{-# LANGUAGE StrictData #-}
-- | Build a Control Flow Graph from a procedure body.
--
-- Pure module — no I/O.  Public API:
--
--   buildCfg :: [Located BodyStmt] -> Cfg
--
-- The CFG mirrors cfg_builder.py output but is computed directly from the
-- typed AST, eliminating JSON re-parsing.  Python reads the stored cfg_json
-- field and deserialises it back to Python CFG objects for rendering/analysis.
module PB.Analysis.Cfg
  ( CfgBlock (..)
  , CfgEdge (..)
  , Cfg (..)
  , buildCfg
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Located  (Located (..))
import Control.Monad        (foldM)
import Control.Monad.State.Strict
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Output types

data CfgBlock = CfgBlock
  { cbId        :: Text
  , cbStmts     :: [Located BodyStmt]
  , cbFirstLine :: Maybe Int
  , cbLastLine  :: Maybe Int
  } deriving (Eq, Show, Generic)

data CfgEdge = CfgEdge
  { ceSrc   :: Text
  , ceDst   :: Text
  , ceLabel :: Text
  } deriving (Eq, Show, Generic)

data Cfg = Cfg
  { cfgEntry  :: Text
  , cfgExits  :: [Text]
  , cfgBlocks :: [CfgBlock]
  , cfgEdges  :: [CfgEdge]
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Builder state

data BuildSt = BuildSt
  { bsCount    :: !Int
  , bsBlockMap :: !(Map.Map Text CfgBlock)
  , bsOrder    :: ![Text]     -- newest first (reverse on exit)
  , bsEdges    :: ![CfgEdge]  -- newest first (reverse on exit)
  , bsExits    :: ![Text]     -- newest first (reverse on exit)
  }

type B = State BuildSt

newBlock :: B Text
newBlock = do
  st <- get
  let n   = bsCount st
      bid = "b" <> T.pack (show n)
  put st
    { bsCount    = n + 1
    , bsBlockMap = Map.insert bid (CfgBlock bid [] Nothing Nothing) (bsBlockMap st)
    , bsOrder    = bid : bsOrder st
    }
  pure bid

addStmts :: Text -> [Located BodyStmt] -> B ()
addStmts _   []    = pure ()
addStmts bid stmts = modify' $ \st ->
  let old      = Map.findWithDefault (CfgBlock bid [] Nothing Nothing) bid (bsBlockMap st)
      combined = cbStmts old ++ stmts
      fl       = cbFirstLine old <|> (locLine <$> listToMaybe stmts)
      ll       = (locLine <$> listToMaybe (reverse stmts)) <|> cbLastLine old
  in st { bsBlockMap = Map.insert bid old { cbStmts = combined, cbFirstLine = fl, cbLastLine = ll } (bsBlockMap st) }

addEdge :: Text -> Text -> Text -> B ()
addEdge src dst lbl = modify' $ \st -> st { bsEdges = CfgEdge src dst lbl : bsEdges st }

addExit :: Text -> B ()
addExit bid = modify' $ \st -> st { bsExits = bid : bsExits st }

-- ---------------------------------------------------------------------------
-- Lowering — mirrors cfg_builder.py's _lower / _lower_if / etc.

-- | Lower a list of statements starting from currentId, returning the final
-- block id.  loopHead is the header of the nearest enclosing loop.
lower :: [Located BodyStmt] -> Text -> Maybe Text -> B Text
lower stmts currentId loopHead = go stmts currentId []
  where
    flush bid pending = addStmts bid pending

    go []       bid pending = flush bid pending >> pure bid
    go (s:rest) bid pending = case locNode s of

      BsIf {} -> do
        flush bid (pending ++ [s])
        bid' <- lowerIf (locNode s) bid loopHead
        go rest bid' []

      BsFor {} -> do
        flush bid (pending ++ [s])
        bid' <- lowerFor (locNode s) bid loopHead
        go rest bid' []

      BsDo {} -> do
        flush bid (pending ++ [s])
        bid' <- lowerDo (locNode s) bid loopHead
        go rest bid' []

      BsChoose {} -> do
        flush bid (pending ++ [s])
        bid' <- lowerChoose (locNode s) bid loopHead
        go rest bid' []

      BsTry {} -> do
        flush bid (pending ++ [s])
        bid' <- lowerTry (locNode s) bid loopHead
        go rest bid' []

      BsReturn _ -> do
        flush bid (pending ++ [s])
        addExit bid
        bid' <- newBlock
        go rest bid' []

      BsExit -> do
        flush bid (pending ++ [s])
        addExit bid
        bid' <- newBlock
        go rest bid' []

      BsContinue -> do
        flush bid (pending ++ [s])
        case loopHead of { Just lh -> addEdge bid lh "loop"; Nothing -> pure () }
        bid' <- newBlock
        go rest bid' []

      _ -> go rest bid (pending ++ [s])


lowerIf :: BodyStmt -> Text -> Maybe Text -> B Text
lowerIf (BsIf (IfStmt _ thenStmts elseIfs elseStmts)) currentId loopHead = do
  mergeId     <- newBlock
  thenEntryId <- newBlock
  addEdge currentId thenEntryId "T"
  thenExitId  <- lower thenStmts thenEntryId loopHead
  addEdge thenExitId mergeId ""
  -- Else branch (or straight to merge if there is none) is the base case the
  -- elseif chain folds onto below.
  elseFt <- case elseStmts of
    Nothing -> pure mergeId
    Just es -> do
      elseEntryId <- newBlock
      elseExitId  <- lower es elseEntryId loopHead
      addEdge elseExitId mergeId ""
      pure elseEntryId
  -- Elseif chain, folded in reverse (mirrors InstrGraph.compileElseIf's
  -- (reversed elseIfs, nextFt) shape exactly): each elseif gets its own
  -- dedicated test block whose "T" edge enters a fresh body-entry block and
  -- whose "F" edge chains to the next test (or to elseFt for the last one).
  -- Plan 146: the previous version never referenced 'eifCond' at all — every
  -- elseif body was wired as unconditionally reachable via one plain "F"
  -- edge once the prior test failed, and that body block doubled as the
  -- chain link to the next elseif, giving it two outgoing edges (its own
  -- exit to merge, plus the bogus chain edge) — which makes
  -- cfgTermToSsa's single-edge fallback default to 'SsaReturn Nothing',
  -- silently truncating the procedure the moment a non-final elseif clause
  -- matched.
  chainFt <- foldM (\nextFt ei -> do
      testId    <- newBlock
      eiEntryId <- newBlock
      -- A minimal synthetic BsIf marker (empty then/elseifs/else) carries
      -- eifCond into the CFG so cfgTermToSsa's existing BsIf case
      -- reconstructs a real SsaBranch for this block — no new SSA.hs
      -- plumbing needed (stmtToAssigns (BsIf {}) = [] already guarantees
      -- this marker contributes no spurious assign).
      addStmts testId [Located 0 (BsIf (IfStmt (eifCond ei) [] [] Nothing))]
      addEdge testId eiEntryId "T"
      eiExitId  <- lower (eifBody ei) eiEntryId loopHead
      addEdge eiExitId mergeId ""
      addEdge testId nextFt "F"
      pure testId
    ) elseFt (reverse elseIfs)
  addEdge currentId chainFt "F"
  pure mergeId
lowerIf _ currentId _ = pure currentId


lowerFor :: BodyStmt -> Text -> Maybe Text -> B Text
lowerFor (BsFor (ForStmt _ _ _ _ bodyStmts)) currentId _loopHead = do
  condId      <- newBlock
  addEdge currentId condId ""
  bodyEntryId <- newBlock
  addEdge condId bodyEntryId "T"
  bodyExitId  <- lower bodyStmts bodyEntryId (Just condId)
  addEdge bodyExitId condId "loop"
  postId      <- newBlock
  addEdge condId postId "F"
  pure postId
lowerFor _ currentId _ = pure currentId


lowerDo :: BodyStmt -> Text -> Maybe Text -> B Text
lowerDo stmt@(BsDo (DoStmt mCond bodyStmts mLoop)) currentId _loopHead = do
  mergeId <- newBlock
  case mCond of
    Just _ -> do
      -- DO WHILE/UNTIL condition at top
      condId      <- newBlock
      addEdge currentId condId ""
      bodyEntryId <- newBlock
      addEdge condId bodyEntryId "T"
      bodyExitId  <- lower bodyStmts bodyEntryId (Just condId)
      addEdge bodyExitId condId "loop"
      addEdge condId mergeId "F"
    Nothing -> case mLoop of
      Just _ -> do
        -- DO ... LOOP WHILE/UNTIL condition at bottom: the condition is
        -- tested *after* the body, so — mirroring the top-tested case above
        -- but with condId placed after the body instead of before — condId
        -- gets its own real "T"/"F" branch (back to bodyEntryId / out to
        -- mergeId), and the raw BsDo node is re-attached onto bodyExitId
        -- (in addition to currentId, which already carries it from 'lower'\'s
        -- initial flush) so 'findLoopHeaderStmts' can find condId as the
        -- header needing condition-reconstruction, the same mechanism the
        -- top-tested case relies on for its own empty condId block. CONTINUE
        -- inside the body re-tests the condition (loopHead = condId), not a
        -- bare jump back to the top (Plan 146 Phase 2e: the previous version
        -- of this branch had no condId at all — one unconditional edge
        -- straight from bodyExitId to mergeId, so the loop body always ran
        -- exactly once regardless of the actual condition).
        condId      <- newBlock
        bodyEntryId <- newBlock
        addEdge currentId bodyEntryId ""
        bodyExitId  <- lower bodyStmts bodyEntryId (Just condId)
        addStmts bodyExitId [Located 0 stmt]
        addEdge bodyExitId condId ""
        addEdge condId bodyEntryId "T"
        addEdge condId mergeId "F"
      Nothing -> do
        -- DO ... LOOP (infinite)
        bodyEntryId <- newBlock
        addEdge currentId bodyEntryId ""
        bodyExitId  <- lower bodyStmts bodyEntryId (Just bodyEntryId)
        addEdge bodyExitId mergeId ""
  pure mergeId
lowerDo _ currentId _ = pure currentId


-- | try/catch: the try body has no branching semantics of its own, so it
-- lowers as ordinary sequential code continuing the current block chain
-- (matching 'PB.Analysis.InstrGraph.compileStmts's 'BsTry' case: "compile
-- try body sequentially"). Each catch body is lowered starting from a fresh,
-- disconnected block — no edge is ever added from the main flow into it —
-- so it exists in the CFG (its own statements are real 'CfgBlock' content,
-- reachable by 'buildSsa' if anything ever points to it) but is genuinely
-- unreachable from 'cfgEntry', mirroring the old compiler's own "compile
-- each catch body, discard its entry pc" behavior exactly: exception
-- dispatch is runtime-only, with no static edge in either compiler.
lowerTry :: BodyStmt -> Text -> Maybe Text -> B Text
lowerTry (BsTry (TryStmt body catches)) currentId loopHead = do
  mapM_ (\c -> newBlock >>= \catchId -> lower (catchBody c) catchId loopHead) catches
  lower body currentId loopHead
lowerTry _ currentId _ = pure currentId

lowerChoose :: BodyStmt -> Text -> Maybe Text -> B Text
lowerChoose (BsChoose (ChooseStmt _ clauses)) currentId loopHead = do
  mergeId <- newBlock
  if null clauses
    then addEdge currentId mergeId ""
    else do
      mapM_ (oneClause mergeId) (zip [(0::Int)..] clauses)
      when (not (any (isNothing . ccExpr) clauses)) (addEdge currentId mergeId "default")
  pure mergeId
  where
    oneClause mergeId (i, clause) = do
      clauseEntryId <- newBlock
      addEdge currentId clauseEntryId ("case:" <> T.pack (show i))
      clauseExitId  <- lower (ccBody clause) clauseEntryId loopHead
      addEdge clauseExitId mergeId ""
lowerChoose _ currentId _ = pure currentId

-- ---------------------------------------------------------------------------
-- Public entry point

buildCfg :: [Located BodyStmt] -> Cfg
buildCfg body =
  let initSt = BuildSt 0 Map.empty [] [] []
      (entryId, finalSt) = runState go initSt
      blocks = [ b | bid <- reverse (bsOrder finalSt)
                   , Just b <- [Map.lookup bid (bsBlockMap finalSt)] ]
  in Cfg
    { cfgEntry  = entryId
    , cfgExits  = reverse (bsExits finalSt)
    , cfgBlocks = blocks
    , cfgEdges  = reverse (bsEdges finalSt)
    }
  where
    go = do
      entryId <- newBlock
      _       <- lower body entryId Nothing
      pure entryId
