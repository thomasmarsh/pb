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
import PB.Analysis.CfgBuild (Cfg (..), CfgBlock (..), CfgEdge (..), buildCfg)
import PB.Analysis.TypeEnv (ScopedTypeEnv)
import PB.Analysis.CallClassify (lvHead)
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
      idom      = computeIdom entry blockIds predMap
      dfMap     = computeDF blockIds predMap idom
      varDefs   = findVarDefs blockMap
      phis0     = placePhis dfMap varDefs
      rawBlocks = Map.mapWithKey (cfgBlockToSsa edgeMap) blockMap
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

parseArgList :: [Token] -> Expr
parseArgList [] = ExRaw []
parseArgList ts = ExRaw (map tkText ts)

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
stmtVarName (BsLocalVar _ _ vn _)       = Just (T.toLower vn)
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

cfgBlockToSsa :: Map.Map Text [CfgEdge] -> Text -> CfgBlock -> SsaBlock
cfgBlockToSsa edgeMap label blk =
  let assigns = concatMap (stmtToAssigns . locNode) (cbStmts blk)
      outEdges = Map.findWithDefault [] label edgeMap
      term = cfgTermToSsa outEdges (cbStmts blk)
  in SsaBlock assigns term

stmtToAssigns :: BodyStmt -> [SsaAssign]
stmtToAssigns (BsAssign lv expr) =
  [SsaAssign (SsaVar (lvHead lv) 0) (exprToSsaVal expr)]
stmtToAssigns (BsLocalVar _ _ varName (Just expr)) =
  [SsaAssign (SsaVar (T.toLower varName) 0) (exprToSsaVal expr)]
stmtToAssigns (BsLocalVar {}) = []
stmtToAssigns (BsAugAssign toks op rhsToks) =
  let varName = case toks of { (t:_) -> tkText t; [] -> "_" }
      augOpToBinOp AugAdd = BopAdd
      augOpToBinOp AugSub = BopSub
      augOpToBinOp AugMul = BopMul
      augOpToBinOp AugDiv = BopDiv
  in [SsaAssign (SsaVar varName 0) (SsaBinOp (augOpToBinOp op) (SsaConst (lhsToExpr toks)) (exprToSsaVal (parseArgList rhsToks)))]
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
stmtToAssigns _ = []

exprToSsaVal :: Expr -> SsaVal
exprToSsaVal ExNull            = SsaNull
exprToSsaVal (ExBinOp l op r)  = SsaBinOp op (exprToSsaVal l) (exprToSsaVal r)
exprToSsaVal (ExNot e)         = SsaNot (exprToSsaVal e)
exprToSsaVal (ExLvalue lv)     = SsaVarRef (SsaVar (lvHead lv) 0)
exprToSsaVal e                 = SsaConst e

cfgTermToSsa :: [CfgEdge] -> [Located BodyStmt] -> SsaTerm
cfgTermToSsa edges stmts = case findControlStmt stmts of
    Just (BsIf (IfStmt cond _ _ _)) ->
      SsaBranch (exprToSsaVal cond) (findEdgeLabel "T" edges) (findEdgeLabel "F" edges)
    Just (BsFor _) ->
      SsaGoto (headDef "" (map ceDst edges))
    Just (BsDo _) ->
      let loopLbl = findEdgeLabel "loop" edges
      in if T.null loopLbl then SsaGoto (headDef "" (map ceDst edges)) else SsaGoto loopLbl
    Just (BsChoose _) ->
      SsaGoto (headDef "" (map ceDst edges))
    Just (BsReturn mExpr) ->
      SsaReturn (fmap exprToSsaVal mExpr)
    Just BsExit     -> SsaBreak
    Just BsContinue -> SsaContinue
    _ -> case edges of
      [e] -> SsaGoto (ceDst e)
      _   -> SsaReturn Nothing

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
    isCtrl _           = False

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
