{-# LANGUAGE StrictData #-}
-- | Static Single Assignment (SSA) intermediate representation.
--
-- Pure module — no I/O.  The SSA pass converts PB's imperative AST
-- ('BodyStmt') into SSA form where every variable is assigned exactly once.
--
-- This eliminates mutation, making variables map directly to named products
-- in the subsequent categorical compilation step.
--
-- Pipeline: 'PB.AST.BodyStmt' → SSA → 'PB.Analysis.CatOp'
module PB.Analysis.SSA
  ( -- * SSA Variables
    SsaVar (..)
  , renderSsaVar
    -- * SSA Values
  , SsaVal (..)
    -- * SSA Instructions
  , SsaAssign (..)
    -- * Basic Blocks
  , SsaBlock (..)
  , SsaTerm (..)
    -- * Phi Nodes
  , SsaPhi (..)
    -- * SSA Procedure
  , SsaProc (..)
    -- * Construction
  , buildSsa
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import PB.Analysis.Cfg (Cfg (..), CfgBlock (..), CfgEdge (..), buildCfg)
import PB.Analysis.TypeEnv (ScopedTypeEnv)
import PB.Analysis.CallClassify (lvHead)
import PB.Grammar.Body     (parseExpr)
import PB.Lexing.Token     (Token (..))
import Control.Monad.State.Strict
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ============================================================================
-- SSA Variables
-- ============================================================================

data SsaVar = SsaVar
  { svName    :: Text
  , svVersion :: Int
  } deriving (Eq, Ord, Show, Generic)

renderSsaVar :: SsaVar -> Text
renderSsaVar (SsaVar n v) = n <> "_" <> T.pack (show v)

-- ============================================================================
-- SSA Values
-- ============================================================================

data SsaVal
  = SsaConst Expr
  | SsaVarRef SsaVar
  | SsaBinOp BinOp SsaVal SsaVal
  | SsaNot SsaVal
  | SsaNull
  deriving (Eq, Show, Generic)

-- ============================================================================
-- SSA Assignments
-- ============================================================================

data SsaAssign = SsaAssign
  { saVar  :: SsaVar
  , saRhs  :: SsaVal
  } deriving (Eq, Show, Generic)

-- ============================================================================
-- Basic Blocks
-- ============================================================================

data SsaBlock = SsaBlock
  { sbAssigns :: [SsaAssign]
  , sbTerm    :: SsaTerm
  } deriving (Eq, Show, Generic)

data SsaTerm
  = SsaGoto Text
  | SsaBranch SsaVal Text Text
  | SsaSwitch SsaVal [(SsaVal, Text)] Text  -- ^ scrutinee, ordered (clauseValue, target) pairs, default target
  | SsaReturn (Maybe SsaVal)
  | SsaBreak
  | SsaContinue
  deriving (Eq, Show, Generic)

-- ============================================================================
-- Phi Nodes
-- ============================================================================

data SsaPhi = SsaPhi
  { spResult  :: SsaVar
  , spSources :: [(Text, SsaVar)]
  } deriving (Eq, Show, Generic)

-- ============================================================================
-- SSA Procedure
-- ============================================================================

data SsaProc = SsaProc
  { spName  :: Text
  , spBlocks :: Map.Map Text SsaBlock
  , spPhis   :: Map.Map Text [SsaPhi]
  , spEntry  :: Text
  , spVars   :: [SsaVar]
  } deriving (Eq, Show, Generic)

-- ============================================================================
-- Construction
-- ============================================================================

buildSsa :: ScopedTypeEnv -> Text -> [Located BodyStmt] -> SsaProc
buildSsa _env procName stmts =
  let cfg       = buildCfg stmts
      entry     = cfgEntry cfg
      blockIds  = map cbId (cfgBlocks cfg)
      blockMap  = Map.fromList [ (cbId b, b) | b <- cfgBlocks cfg ]
      predMap   = buildPredMap (cfgEdges cfg)
      edgeMap   = buildEdgeMap (cfgEdges cfg)
      headerStmts   = findLoopHeaderStmts edgeMap blockMap
      backEdgeStmts = findLoopBackEdgeStmts (cfgEdges cfg) headerStmts
      idom      = computeIdom entry blockIds predMap
      dfMap     = computeDF blockIds predMap idom
      varDefs   = findVarDefs blockMap
      phis0     = placePhis dfMap varDefs
      rawBlocks = Map.mapWithKey (cfgBlockToSsa edgeMap headerStmts backEdgeStmts) blockMap
      domTree   = buildDomTree idom entry
      succMap   = buildSuccMap (cfgEdges cfg)
      initRename = RenameState
        { rVersion = Map.empty
        , rCurrent = Map.empty
        , rBlocks  = rawBlocks
        , rPhis    = phis0
        , rAllVars = []
        }
      finalRename = execState (renameWalk entry domTree succMap) initRename
  in SsaProc
    { spName   = procName
    , spBlocks = rBlocks finalRename
    , spPhis   = rPhis finalRename
    , spEntry  = entry
    , spVars   = reverse (rAllVars finalRename)
    }

-- ============================================================================
-- Helpers
-- ============================================================================



assignTarget :: Expr -> Text
assignTarget (ExLvalue lv) = lvHead lv
assignTarget _             = "_"

lhsToExpr :: [Token] -> Expr
lhsToExpr [t] = ExLvalue (Lvalue [LvSegment (tkText t) Nothing])
lhsToExpr ts  = ExRaw (map tkText ts)

-- | Wrap a raw token list as an unparsed 'ExRaw' expression. Not a real
-- parse (unlike 'PB.Analysis.CallClassify.parseArgList', which calls
-- 'PB.Grammar.Body.parseExpr') — used only where SSA lowering doesn't need
-- a typed result, e.g. 'BsAugAssign' RHS.
rawArgsToExpr :: [Token] -> Expr
rawArgsToExpr [] = ExRaw []
rawArgsToExpr ts = ExRaw (map tkText ts)

headDef :: a -> [a] -> a
headDef d []    = d
headDef _ (x:_) = x

-- ============================================================================
-- Step 1: Edge maps
-- ============================================================================

buildEdgeMap :: [CfgEdge] -> Map.Map Text [CfgEdge]
buildEdgeMap = foldl' (\m e -> Map.insertWith (++) (ceSrc e) [e] m) Map.empty

buildPredMap :: [CfgEdge] -> Map.Map Text (Set.Set Text)
buildPredMap = foldl' (\m e -> Map.insertWith Set.union (ceDst e) (Set.singleton (ceSrc e)) m) Map.empty

buildSuccMap :: [CfgEdge] -> Map.Map Text (Set.Set Text)
buildSuccMap = foldl' (\m e -> Map.insertWith Set.union (ceSrc e) (Set.singleton (ceDst e)) m) Map.empty

-- ============================================================================
-- Step 2: Dominator tree (iterative dataflow)
-- ============================================================================

computeIdom :: Text -> [Text] -> Map.Map Text (Set.Set Text) -> Map.Map Text Text
computeIdom entry blockIds predMap = go initIdom
  where
    nonEntry = filter (/= entry) blockIds
    initIdom = Map.fromList [ (b, entry) | b <- nonEntry ]

    go curIdom =
      let nextIdom = Map.fromList [ (b, stepOne b curIdom) | b <- nonEntry ]
      in if nextIdom == curIdom then curIdom else go nextIdom

    stepOne b curIdom = case Map.lookup b predMap of
      Nothing    -> b
      Just preds ->
        let resolved = [ getPredIdom p curIdom | p <- Set.toList preds ]
        in case resolved of
             []     -> b
             (p:ps) -> foldl' (intersect curIdom) p ps

    getPredIdom p curIdom
      | p == entry = entry
      | otherwise  = Map.findWithDefault p p curIdom

    intersect curIdom a b
      | a == b    = a
      | otherwise =
          let aChain = chainUp curIdom a
              bSet   = Set.fromList (chainUp curIdom b)
          in headDef a (filter (`Set.member` bSet) aChain)

    chainUp curIdom = goChain Set.empty
      where
        goChain seen y
          | y `Set.member` seen = [y]
          | y == entry          = [y]
          | otherwise =
              let seen' = Set.insert y seen
              in case Map.lookup y curIdom of
                   Nothing    -> [y]
                   Just p | p == y -> [y]
                          | otherwise -> y : goChain seen' p

-- ============================================================================
-- Step 3: Dominance frontiers
-- ============================================================================

computeDF :: [Text] -> Map.Map Text (Set.Set Text) -> Map.Map Text Text -> Map.Map Text (Set.Set Text)
computeDF blockIds predMap idom = fixedPoint initDF
  where
    initDF = Map.fromList [ (b, Set.empty) | b <- blockIds ]

    fixedPoint df =
      let nextDF = foldl' (\m b -> Map.insert b (computeDFb b df) m) df blockIds
      in if nextDF == df then df else fixedPoint nextDF

    computeDFb b df =
      let preds = Map.findWithDefault Set.empty b predMap
          s1 = Set.filter (\p -> Map.lookup p idom /= Just b) preds
          s2 = Set.unions
            [ Map.findWithDefault Set.empty succNode df
            | p <- Set.toList preds
            , let succNode = Map.findWithDefault p p idom
            , succNode /= b
            ]
      in s1 `Set.union` s2

-- ============================================================================
-- Step 4: Find variable definitions per block
-- ============================================================================

stmtVarName :: BodyStmt -> Maybe Text
stmtVarName (BsAssign lv _)             = Just (lvHead lv)
stmtVarName (BsLocalVar _ _ vn _)       = Just vn
stmtVarName (BsAugAssign (t:_) _ _)     = Just (tkText t)
stmtVarName (BsInc (t:_))               = Just (tkText t)
stmtVarName (BsDec (t:_))               = Just (tkText t)
stmtVarName (BsAssignExpr (ExLvalue lv) _) = Just (lvHead lv)
stmtVarName (BsDestroy lv)              = Just (lvHead lv)
stmtVarName _                           = Nothing

findVarDefs :: Map.Map Text CfgBlock -> Map.Map Text (Set.Set Text)
findVarDefs blockMap = foldl' addBlock Map.empty (Map.elems blockMap)
  where
    addBlock acc blk =
      let defs = mapMaybe (stmtVarName . locNode) (cbStmts blk)
      in foldl' (\m v -> Map.insertWith Set.union v (Set.singleton (cbId blk)) m) acc defs

-- ============================================================================
-- Step 5: Phi insertion
-- ============================================================================

placePhis :: Map.Map Text (Set.Set Text) -> Map.Map Text (Set.Set Text) -> Map.Map Text [SsaPhi]
placePhis dfMap varDefs =
  foldl' (\acc (varName, defBlks) -> insertPhisFor varName defBlks acc) Map.empty (Map.toList varDefs)
  where
    insertPhisFor varName defBlks acc = go acc Set.empty (Set.toList defBlks)
      where
        go a _visited [] = a
        go a visited (b:bs) =
          let dfs = Map.findWithDefault Set.empty b dfMap
              newFs = Set.filter (`Set.notMember` visited) dfs
              (a', visited') = Set.foldl' (\(acc', vis') f ->
                let phi = SsaPhi (SsaVar varName 0) []
                    existing = Map.findWithDefault [] f acc'
                in (Map.insert f (existing ++ [phi]) acc', Set.insert f vis')
                ) (a, visited) newFs
          in go a' visited' (bs ++ Set.toList newFs)

-- ============================================================================
-- Step 6: Convert CFG blocks to SSA blocks (pre-rename)
-- ============================================================================

cfgBlockToSsa :: Map.Map Text [CfgEdge] -> Map.Map Text BodyStmt -> Map.Map Text BodyStmt
              -> Text -> CfgBlock -> SsaBlock
cfgBlockToSsa edgeMap headerStmts backEdgeStmts label blk =
  let ownAssigns  = concatMap (stmtToAssigns . locNode) (cbStmts blk)
      incrAssigns = case Map.lookup label backEdgeStmts of
        Just (BsFor (ForStmt var _ _ mStep _)) ->
          [ SsaAssign (SsaVar (lvHead var) 0)
              (SsaBinOp BopAdd (SsaVarRef (SsaVar (lvHead var) 0))
                                (exprToSsaVal (fromMaybe (ExInt "1") mStep))) ]
        _ -> []
      assigns  = ownAssigns ++ incrAssigns
      outEdges = Map.findWithDefault [] label edgeMap
      term     = cfgTermToSsa (Map.lookup label headerStmts) outEdges (cbStmts blk)
  in SsaBlock assigns term

-- | The counterpart to 'findLoopHeaderStmts': @lowerFor@ never synthesizes an
-- increment statement anywhere in the CFG (the old compiler builds it
-- procedurally, by hand, in 'PB.Analysis.InstrGraph'). This maps each loop
-- body's back-edge-source block id to the originating @BsFor@ node, so
-- 'cfgBlockToSsa' can append the missing @i = i + step@ assign to that
-- block — the same synthesis the old compiler performs explicitly.
-- @BsDo@ has no implicit increment, so it never matches in 'cfgBlockToSsa'.
findLoopBackEdgeStmts :: [CfgEdge] -> Map.Map Text BodyStmt -> Map.Map Text BodyStmt
findLoopBackEdgeStmts edges headerStmts = Map.fromList
  [ (ceSrc e, stmt)
  | e <- edges
  , ceLabel e == "loop"
  , Just stmt <- [Map.lookup (ceDst e) headerStmts]
  ]

-- | 'PB.Analysis.Cfg.lowerFor'/'lowerDo' (top-condition variant) flush the
-- raw @BsFor@/@BsDo@ AST node onto the block /preceding/ the loop, then
-- allocate a fresh, empty header block that carries the real T/F branch
-- edges. A block's own statements are therefore not enough to tell
-- 'cfgTermToSsa' that a given block is a loop header — this precomputes,
-- for each such header block id, the originating loop statement so the
-- condition can be reconstructed for it specifically (see the header-only
-- fallback in 'cfgTermToSsa').
findLoopHeaderStmts :: Map.Map Text [CfgEdge] -> Map.Map Text CfgBlock -> Map.Map Text BodyStmt
findLoopHeaderStmts edgeMap blockMap = Map.fromList
  [ (headerId, loopStmt)
  | blk <- Map.elems blockMap
  , Just loopStmt <- [trailingLoopStmt (cbStmts blk)]
  , [e] <- [Map.findWithDefault [] (cbId blk) edgeMap]
  , let headerId = ceDst e
  ]
  where
    trailingLoopStmt stmts = case map locNode (reverse stmts) of
      (s@(BsFor {}) : _)                            -> Just s
      (s@(BsDo (DoStmt (Just _) _ _)) : _)          -> Just s
      (s@(BsDo (DoStmt Nothing _ (Just _))) : _)    -> Just s
      _                                              -> Nothing

stmtToAssigns :: BodyStmt -> [SsaAssign]
stmtToAssigns (BsAssign lv expr) =
  [SsaAssign (SsaVar (lvHead lv) 0) (exprToSsaVal expr)]
-- The old compiler synthesizes the loop variable's init assign by hand
-- (InstrGraph.hs's BsFor case); the new pipeline needs the same thing here,
-- since this is the one block that legitimately owns the raw BsFor node in
-- its own cbStmts (CfgBuild.lowerFor flushes it onto the pre-loop block).
stmtToAssigns (BsFor (ForStmt var from _ _ _)) =
  [SsaAssign (SsaVar (lvHead var) 0) (exprToSsaVal from)]
stmtToAssigns (BsLocalVar _ _ varName (Just expr)) =
  [SsaAssign (SsaVar varName 0) (exprToSsaVal expr)]
stmtToAssigns (BsLocalVar {}) = []
stmtToAssigns (BsAugAssign toks op rhsToks) =
  let varName = case toks of { (t:_) -> tkText t; [] -> "_" }
      augOpToBinOp AugAdd = BopAdd
      augOpToBinOp AugSub = BopSub
      augOpToBinOp AugMul = BopMul
      augOpToBinOp AugDiv = BopDiv
  in [SsaAssign (SsaVar varName 0) (SsaBinOp (augOpToBinOp op) (SsaConst (lhsToExpr toks)) (exprToSsaVal (rawArgsToExpr rhsToks)))]
stmtToAssigns (BsInc toks) =
  let varName = case toks of { (t:_) -> tkText t; [] -> "_" }
  in [SsaAssign (SsaVar varName 0) (SsaBinOp BopAdd (SsaConst (lhsToExpr toks)) (SsaConst (ExInt "1")))]
stmtToAssigns (BsDec toks) =
  let varName = case toks of { (t:_) -> tkText t; [] -> "_" }
  in [SsaAssign (SsaVar varName 0) (SsaBinOp BopSub (SsaConst (lhsToExpr toks)) (SsaConst (ExInt "1")))]
stmtToAssigns (BsAssignExpr lhsExpr rhsExpr) =
  [SsaAssign (SsaVar (assignTarget lhsExpr) 0) (exprToSsaVal rhsExpr)]
stmtToAssigns (BsDestroy lv) =
  [SsaAssign (SsaVar (lvHead lv) 0) SsaNull]
stmtToAssigns (BsCall expr) =
  [SsaAssign (SsaVar "_" 0) (SsaConst expr)]
-- BsPbCall: CALL ancestor::event super-dispatch (Plan 145 Phase 3). Encoded as a
-- single-segment synthetic ExCall so it flows through the existing
-- classifyExpr/compileCallExpr machinery in PB.Analysis.CatOp and lowers to a
-- InstrCallProc, matching PB.Analysis.InstrGraph's explicit BsPbCall case. The
-- "ancestor::event" text can never collide with isTriggerEvent, a user-fn name
-- (PB identifiers can't contain "::"), or isBuiltinSuspendFn's fixed list, so
-- it always classifies PureCall.
stmtToAssigns (BsPbCall (PbCall ancestor event)) =
  [SsaAssign (SsaVar "_" 0)
             (SsaConst (ExCall (Lvalue [LvSegment (ancestor <> "::" <> event) Nothing]) []))]
-- Control-flow statements produce no SSA assign of their own. CfgBuild.lower
-- keeps the trailing control stmt as the last element of a block's cbStmts
-- (so cfgTermToSsa's findControlStmt can find it), but its "value" is the
-- block terminator, not an assignment — cfgTermToSsa handles all of these
-- (Plan 146 Phase 4 audit: was reached via the old catch-all, now explicit).
stmtToAssigns (BsIf {})     = []
stmtToAssigns (BsDo {})     = []
stmtToAssigns (BsChoose {}) = []
stmtToAssigns (BsReturn _)  = []
stmtToAssigns BsExit        = []
stmtToAssigns BsContinue    = []
-- BsTry/BsThrow: try/catch is not yet lowered into the CFG (CfgBuild treats
-- it as one opaque leaf statement — see BACKLOG's try/catch CFG-modeling
-- note), so any assigns nested inside tryBody/catchBody are invisible here
-- by design, not a gap in this function specifically. BsThrow has no
-- assignable value of its own.
stmtToAssigns (BsTry {})   = []
stmtToAssigns (BsThrow _)  = []
-- BsRaw: unparsed source text (embedded SQL, unclassified statements) — no
-- structured assignment to extract.
stmtToAssigns (BsRaw _)    = []

exprToSsaVal :: Expr -> SsaVal
exprToSsaVal ExNull            = SsaNull
exprToSsaVal (ExBinOp l op r)  = SsaBinOp op (exprToSsaVal l) (exprToSsaVal r)
exprToSsaVal (ExNot e)         = SsaNot (exprToSsaVal e)
exprToSsaVal (ExLvalue lv@(Lvalue [LvSegment _ Nothing])) = SsaVarRef (SsaVar (lvHead lv) 0)
exprToSsaVal e                 = SsaConst e

cfgTermToSsa :: Maybe BodyStmt -> [CfgEdge] -> [Located BodyStmt] -> SsaTerm
cfgTermToSsa mHeaderStmt edges stmts = case findControlStmt stmts of
    Just (BsIf (IfStmt cond _ _ _)) ->
      SsaBranch (exprToSsaVal cond) (findEdgeLabel "T" edges) (findEdgeLabel "F" edges)
    Just (BsFor _) ->
      SsaGoto (headDef "" (map ceDst edges))
    Just (BsDo _) ->
      let loopLbl = findEdgeLabel "loop" edges
      in if T.null loopLbl then SsaGoto (headDef "" (map ceDst edges)) else SsaGoto loopLbl
    Just (BsChoose (ChooseStmt scrutinee clauses)) -> case clauses of
      [] -> SsaGoto (headDef "" (map ceDst edges))
      _  ->
        let indexed  = zip [(0::Int)..] clauses
            edgeFor i = findEdgeLabel ("case:" <> T.pack (show i)) edges
            normalPairs = [ (exprToSsaVal (parseExpr toks), edgeFor i)
                          | (i, c) <- indexed, Just toks <- [ccExpr c] ]
            defaultTarget = case [ edgeFor i | (i, c) <- indexed, isNothing (ccExpr c) ] of
              (t:_) -> t
              []    -> findEdgeLabel "default" edges
        in SsaSwitch (exprToSsaVal scrutinee) normalPairs defaultTarget
    Just (BsReturn mExpr) ->
      SsaReturn (fmap exprToSsaVal mExpr)
    Just BsExit     -> SsaBreak
    Just BsContinue -> SsaContinue
    -- This block has no control statement of its own, but it may still be a
    -- loop *header* whose condition-check lives one block back (see
    -- 'findLoopHeaderStmts') — reconstruct the branch from there rather than
    -- falling through to the generic (and here, wrong) `SsaReturn Nothing`.
    --
    -- Plan 146 Phase 4 audit: this outer `_` is typed as `Maybe BodyStmt`, so
    -- GHC sees it as covering `Nothing` *and* `Just` of any of the 12
    -- non-control BodyStmt constructors — but `isCtrl` (above) guarantees
    -- `findControlStmt` only ever returns `Just` for the 7 constructors
    -- already matched, so the `Just`-of-a-non-control-stmt half of this
    -- wildcard is unreachable by construction, not an audit gap. Left as a
    -- wildcard rather than enumerated with dead `error "impossible"` arms,
    -- which would add real risk (a typo there is worse than the status quo)
    -- for no practical safety gain.
    _ -> case mHeaderStmt of
      Just (BsFor (ForStmt var _ to _ _)) ->
        SsaBranch (exprToSsaVal (ExBinOp (ExLvalue var) BopLe to))
                  (findEdgeLabel "T" edges) (findEdgeLabel "F" edges)
      Just (BsDo (DoStmt (Just cond) _ _)) ->
        SsaBranch (exprToSsaVal (doCondExpr cond))
                  (findEdgeLabel "T" edges) (findEdgeLabel "F" edges)
      Just (BsDo (DoStmt Nothing _ (Just cond))) ->
        SsaBranch (exprToSsaVal (doCondExpr cond))
                  (findEdgeLabel "T" edges) (findEdgeLabel "F" edges)
      -- Plan 146 Phase 4 audit: covers `Nothing` (block is not a recognized
      -- loop header — the common case) plus, type-wise, `Just` of any
      -- BodyStmt/DoCondition combination other than the three shapes
      -- `findLoopHeaderStmts`'s `trailingLoopStmt` ever produces (e.g. a
      -- `DoStmt` with both a leading and trailing condition, which the
      -- parser never builds) — type-possible but unreachable by
      -- construction, not an audit gap.
      _ -> case edges of
        [e] -> SsaGoto (ceDst e)
        _   -> SsaReturn Nothing

-- | @DoWhile@'s condition is used as-is (loop while true); @DoUntil@'s is
-- negated (loop while /not/ true) so both compile through the same "T = keep
-- looping" branch shape.
doCondExpr :: DoCondition -> Expr
doCondExpr (DoWhile e) = e
doCondExpr (DoUntil e) = ExNot e

findControlStmt :: [Located BodyStmt] -> Maybe BodyStmt
findControlStmt [] = Nothing
findControlStmt (Located _ s : rest)
  | isCtrl s   = Just s
  | otherwise  = findControlStmt rest
  where
    isCtrl BsIf {}     = True
    isCtrl BsFor {}    = True
    isCtrl BsDo {}     = True
    isCtrl BsChoose {} = True
    isCtrl (BsReturn _) = True
    isCtrl BsExit      = True
    isCtrl BsContinue  = True
    -- Plan 146 Phase 4 audit: the remaining 12 constructors were previously
    -- caught by a single `isCtrl _ = False` wildcard; enumerated explicitly
    -- so a future BodyStmt constructor trips -Wincomplete-patterns here.
    isCtrl (BsLocalVar {})   = False
    isCtrl (BsAssign {})     = False
    isCtrl (BsAugAssign {})  = False
    isCtrl (BsInc {})        = False
    isCtrl (BsDec {})        = False
    isCtrl (BsCall {})       = False
    isCtrl (BsPbCall {})     = False
    isCtrl (BsDestroy {})    = False
    isCtrl (BsAssignExpr {}) = False
    isCtrl (BsTry {})        = False
    isCtrl (BsThrow {})      = False
    isCtrl (BsRaw {})        = False

findEdgeLabel :: Text -> [CfgEdge] -> Text
findEdgeLabel lbl edges = case [ ceDst e | e <- edges, ceLabel e == lbl ] of
  (d:_) -> d
  []    -> case edges of { (e:_) -> ceDst e; [] -> "" }

-- ============================================================================
-- Step 7: Build dominator tree (parent → children)
-- ============================================================================

buildDomTree :: Map.Map Text Text -> Text -> Map.Map Text [Text]
buildDomTree idom entry = foldl' add Map.empty (Map.toList idom)
  where
    add m (b, parent)
      | b == entry = m
      | otherwise  = Map.insertWith (++) parent [b] m

-- ============================================================================
-- Step 8: Variable renaming via dominator tree DFS
-- ============================================================================

data RenameState = RenameState
  { rVersion :: !(Map.Map Text Int)
  , rCurrent :: !(Map.Map Text SsaVar)
  , rBlocks  :: !(Map.Map Text SsaBlock)
  , rPhis    :: !(Map.Map Text [SsaPhi])
  , rAllVars :: ![SsaVar]
  }

type RenameM = State RenameState

-- | Create a new version of a variable and record it.
newVersion :: Text -> RenameM SsaVar
newVersion varName = do
  st <- get
  let cur   = Map.findWithDefault 0 varName (rVersion st)
      next  = cur + 1
      sv    = SsaVar varName next
  put st
    { rVersion = Map.insert varName next (rVersion st)
    , rCurrent = Map.insert varName sv (rCurrent st)
    , rAllVars = sv : rAllVars st
    }
  pure sv

-- | Rename variables in the dominator tree via DFS.
-- For each block:
--   1. Rename phi results
--   2. Rename assignments (LHS gets new version, RHS refs get current version)
--   3. For each successor with phi nodes from this block, fill the phi source
--   4. Recurse into dominator children
renameWalk :: Text -> Map.Map Text [Text] -> Map.Map Text (Set.Set Text) -> RenameM ()
renameWalk lbl domTree succMap = do
  -- 1. Rename phi results
  phiList <- gets (Map.findWithDefault [] lbl . rPhis)
  phiList' <- mapM renamePhiResult phiList
  modify' $ \st -> st { rPhis = Map.insert lbl phiList' (rPhis st) }

  -- 2. Rename block assigns
  blk <- gets (Map.findWithDefault (SsaBlock [] (SsaReturn Nothing)) lbl . rBlocks)
  assigns' <- mapM renameAssign (sbAssigns blk)
  modify' $ \st -> st { rBlocks = Map.insert lbl (SsaBlock assigns' (sbTerm blk)) (rBlocks st) }

  -- 3. Fill phi sources in successor blocks
  let successors = Map.findWithDefault Set.empty lbl succMap
  mapM_ (fillPhiSources lbl) (Set.toList successors)

  -- 4. Recurse into dominator children
  let children = Map.findWithDefault [] lbl domTree
  mapM_ (\c -> renameWalk c domTree succMap) children

renamePhiResult :: SsaPhi -> RenameM SsaPhi
renamePhiResult phi = do
  sv <- newVersion (svName (spResult phi))
  pure phi { spResult = sv }

renameAssign :: SsaAssign -> RenameM SsaAssign
renameAssign (SsaAssign sv rhs) = do
  sv' <- newVersion (svName sv)
  rhs' <- renameVal rhs
  pure (SsaAssign sv' rhs')

renameVal :: SsaVal -> RenameM SsaVal
renameVal SsaNull            = pure SsaNull
renameVal (SsaConst e)       = pure (SsaConst e)
renameVal (SsaVarRef sv)     = SsaVarRef <$> currentVar (svName sv)
renameVal (SsaBinOp op l r)  = SsaBinOp op <$> renameVal l <*> renameVal r
renameVal (SsaNot e)         = SsaNot <$> renameVal e

currentVar :: Text -> RenameM SsaVar
currentVar varName = do
  cur <- gets (Map.lookup varName . rCurrent)
  case cur of
    Just sv -> pure sv
    Nothing -> newVersion varName

-- | When control flows from srcLbl to dstLbl, fill phi source references.
-- For each phi at dstLbl that has a source from srcLbl, set the source
-- variable to the current version at srcLbl.
fillPhiSources :: Text -> Text -> RenameM ()
fillPhiSources srcLbl dstLbl = do
  phisAtDst <- gets (Map.findWithDefault [] dstLbl . rPhis)
  currentMap <- gets rCurrent
  let updated = map (fillOne currentMap) phisAtDst
  modify' $ \st -> st { rPhis = Map.insert dstLbl updated (rPhis st) }
  where
    fillOne curMap phi =
      let updatedSources = map (\(src, sv) ->
            if src == srcLbl
            then case Map.lookup (svName sv) curMap of
                   Just currentSv -> (src, currentSv)
                   Nothing        -> (src, sv)  -- variable never assigned, keep placeholder
            else (src, sv)
            ) (spSources phi)
      in phi { spSources = updatedSources }
