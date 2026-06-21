-- | Intra-procedural dataflow analysis — def-use chains and reaching definitions.
--
-- Pure module — no I/O.  Public API:
--
--   analyzeProcedure :: Text -> Text -> Cfg -> ProcFlow
--
-- Builds on the CFG from PB.Pipeline.CfgBuild and extracts def-use sites
-- from the typed AST, eliminating JSON re-parsing.
module PB.Pipeline.Dataflow
  ( DefSite (..)
  , UseSite (..)
  , BlockFlow (..)
  , ProcFlow (..)
  , extractDefsUses
  , reachingDefinitions
  , analyzeProcedure
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import PB.Pipeline.CfgBuild (Cfg (..), CfgBlock (..), CfgEdge (..))
import Data.Char            (isAlpha)
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Output types

data DefSite = DefSite
  { dsVar     :: Text
  , dsBlock   :: Text
  , dsStmtIdx :: Int
  , dsLine    :: Maybe Int
  , dsKind    :: Text
  } deriving (Eq, Show, Generic)

data UseSite = UseSite
  { usVar     :: Text
  , usBlock   :: Text
  , usStmtIdx :: Int
  , usLine    :: Maybe Int
  , usKind    :: Text
  } deriving (Eq, Show, Generic)

data BlockFlow = BlockFlow
  { bfBlockId :: Text
  , bfGen     :: Set.Set Text
  , bfKill    :: Set.Set Text
  , bfDefs    :: [DefSite]
  , bfUses    :: [UseSite]
  } deriving (Eq, Show, Generic)

data ProcFlow = ProcFlow
  { pfObject     :: Text
  , pfProc       :: Text
  , pfBlocks     :: Map.Map Text BlockFlow
  , pfReachingIn  :: Map.Map Text (Set.Set Text)
  , pfReachingOut :: Map.Map Text (Set.Set Text)
  , pfAllDefs    :: Map.Map Text [DefSite]
  , pfAllUses    :: Map.Map Text [UseSite]
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Lvalue root extraction

lvRoot :: Lvalue -> Maybe Text
lvRoot lv = case segments lv of
  (s:_) -> Just (segName s)
  []    -> Nothing

segName :: LvSegment -> Text
segName (LvSegment n _) = n

-- ---------------------------------------------------------------------------
-- Expression identifier extraction

-- | Extract all identifier names from an expression tree.
walkExprIdents :: Expr -> Set.Set Text
walkExprIdents = go
  where
    go (ExLvalue lv) =
      let root = maybe Set.empty Set.singleton (lvRoot lv)
          subIdents = Set.fromList
            [ t
            | seg <- segments lv
            , Just toks <- [subscript seg]
            , t <- toks
            , isIdent t
            ]
      in root <> subIdents
    go (ExCall lv args) =
      let root = maybe Set.empty Set.singleton (lvRoot lv)
          argIdents = Set.fromList [t | argToks <- args, t <- argToks, isIdent t]
      in root <> argIdents
    go (ExMethodCall recv _ args) =
      go recv <> Set.fromList [t | argToks <- args, t <- argToks, isIdent t]
    go (ExBinOp l _ r) = go l <> go r
    go (ExNot e) = go e
    go (ExNeg e) = go e
    go (ExArray es) = Set.unions (map go es)
    go (ExCreateUsing e) = go e
    go (ExDispatch de) =
      let objIdents = maybe Set.empty go (fmap ExLvalue (object de))
          argIdents = Set.fromList [t | argToks <- args de, t <- argToks, isIdent t]
      in objIdents <> argIdents
    go (ExRaw toks) = Set.fromList [t | t <- toks, isIdent t]
    go _ = Set.empty

isIdent :: Text -> Bool
isIdent t
  | T.null t = False
  | otherwise = let c = T.head t
                in isAlpha c || c == '_'

-- ---------------------------------------------------------------------------
-- Statement def/use extraction

-- | Extract the defined variable name from a definition statement.
extractDefVar :: BodyStmt -> Maybe Text
extractDefVar (BsAssign lv _)    = lvRoot lv
extractDefVar (BsLocalVar _ _ n _) = Just n
extractDefVar (BsFor ft)       = lvRoot (forVar ft)
extractDefVar (BsAugAssign toks _ _) = listToMaybe (filter isIdent toks)
extractDefVar (BsInc toks)       = listToMaybe (filter isIdent toks)
extractDefVar (BsDec toks)       = listToMaybe (filter isIdent toks)
extractDefVar _                  = Nothing

-- | Map BodyStmt tag to def kind text.
defKind :: BodyStmt -> Text
defKind (BsAssign {})    = "assign"
defKind (BsLocalVar {})  = "local_var"
defKind (BsFor {})       = "for_var"
defKind (BsAugAssign {}) = "augassign"
defKind (BsInc {})       = "inc"
defKind (BsDec {})       = "dec"
defKind _                = "assign"

-- | Extract used variable names from a statement.
extractUseVars :: BodyStmt -> Set.Set Text
extractUseVars (BsAssign _ rhs)       = walkExprIdents rhs
extractUseVars (BsLocalVar _ _ _ mInit) = maybe Set.empty walkExprIdents mInit
extractUseVars (BsFor ft) =
  walkExprIdents (forFrom ft) <> walkExprIdents (forTo ft)
  <> maybe Set.empty walkExprIdents (forStep ft)
  <> Set.unions (map (extractUseVars . locNode) (forBody ft))
extractUseVars (BsIf ift) =
  walkExprIdents (ifCond ift)
  <> Set.unions (map (extractUseVars . locNode) (ifThen ift))
  <> Set.unions [Set.unions (map (extractUseVars . locNode) (eifBody ei)) | ei <- ifElseIfs ift]
  <> maybe Set.empty (Set.unions . map (extractUseVars . locNode)) (ifElse ift)
extractUseVars (BsDo dt) =
  maybe Set.empty condUses (doCond dt)
  <> Set.unions (map (extractUseVars . locNode) (doBody dt))
  <> maybe Set.empty condUses (doLoop dt)
  where
    condUses (DoWhile e) = walkExprIdents e
    condUses (DoUntil e) = walkExprIdents e
extractUseVars (BsChoose cs) =
  walkExprIdents (chooseExpr cs)
  <> Set.unions [Set.unions (map (extractUseVars . locNode) (ccBody c)) | c <- chooseClauses cs]
extractUseVars (BsReturn mExpr) = maybe Set.empty walkExprIdents mExpr
extractUseVars (BsCall expr)    = walkExprIdents expr
extractUseVars (BsDestroy lv)   = maybe Set.empty Set.singleton (lvRoot lv)
extractUseVars (BsAugAssign _ _ toks) = Set.fromList [t | t <- toks, isIdent t]
extractUseVars _ = Set.empty

-- | Determine use kind from statement tag.
useKind :: BodyStmt -> Text
useKind (BsIf {})     = "condition"
useKind (BsChoose {}) = "condition"
useKind (BsReturn {}) = "return"
useKind (BsCall {})   = "call_arg"
useKind (BsFor {})    = "loop_range"
useKind _             = "rhs"

-- ---------------------------------------------------------------------------
-- Block-level extraction

-- | Walk a block's statements to extract definition and use sites.
extractDefsUses :: CfgBlock -> BlockFlow
extractDefsUses blk = BlockFlow
  { bfBlockId = cbId blk
  , bfGen     = Set.fromList (map dsVar localDefs)
  , bfKill    = Set.fromList (map dsVar localDefs)
  , bfDefs    = localDefs
  , bfUses    = localUses
  }
  where
    stmts = cbStmts blk
    bid   = cbId blk

    localDefs = concatMap extractDef (zip [0..] stmts)
    extractDef (idx, s) =
      case extractDefVar (locNode s) of
        Nothing -> []
        Just v  -> [DefSite v bid idx (Just (locLine s)) (defKind (locNode s))]

    localUses = concatMap extractUse (zip [0..] stmts)
    extractUse (idx, s) =
      let vs = extractUseVars (locNode s)
          uk = useKind (locNode s)
      in [UseSite v bid idx (Just (locLine s)) uk | v <- Set.toAscList vs]

-- ---------------------------------------------------------------------------
-- Reaching definitions

-- | Compute predecessor block ids from edge list.
predecessors :: [CfgEdge] -> Text -> [Text]
predecessors edges bid = [ceSrc e | e <- edges, ceDst e == bid]

-- | Iterative forward dataflow for reaching definitions.
-- Returns (reaching_in, reaching_out) mapping block_id → set of variable names.
reachingDefinitions :: Cfg -> Map.Map Text BlockFlow -> (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
reachingDefinitions cfg blockFlows = fix initial
  where
    blockIds = map cbId (cfgBlocks cfg)
    edges    = cfgEdges cfg

    initial :: (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
    initial =
      let rIn  = Map.fromList [(bid, Set.empty) | bid <- blockIds]
          rOut = Map.fromList
            [ (bid, maybe Set.empty bfGen (Map.lookup bid blockFlows))
            | bid <- blockIds
            ]
      in (rIn, rOut)

    fix :: (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
        -> (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
    fix (rIn, rOut) =
      let (rIn', rOut', changed) = foldl' step (rIn, rOut, False) blockIds
      in if changed then fix (rIn', rOut') else (rIn', rOut')

    step (rIn, rOut, changed) bid
      | bid == cfgEntry cfg = (rIn, rOut, changed)
      | otherwise =
          let preds = predecessors edges bid
              newIn = Set.unions [Map.findWithDefault Set.empty p rOut | p <- preds]
              oldIn = Map.findWithDefault Set.empty bid rIn
              bf    = Map.lookup bid blockFlows
              newOut = case bf of
                Nothing -> newIn
                Just b  -> bfGen b `Set.union` (newIn `Set.difference` bfKill b)
              oldOut = Map.findWithDefault Set.empty bid rOut
              changed' = changed || newIn /= oldIn || newOut /= oldOut
          in ( Map.insert bid newIn rIn
             , Map.insert bid newOut rOut
             , changed'
             )

-- ---------------------------------------------------------------------------
-- Public entry point

-- | Analyze a single procedure's dataflow.
analyzeProcedure :: Text -> Text -> Cfg -> ProcFlow
analyzeProcedure obj proc cfg =
  let blockFlows = Map.fromList
        [ (cbId b, extractDefsUses b)
        | b <- cfgBlocks cfg
        ]
      (rIn, rOut) = reachingDefinitions cfg blockFlows
      allDefs = Map.fromListWith (++) [(dsVar d, [d]) | bf <- Map.elems blockFlows, d <- bfDefs bf]
      allUses = Map.fromListWith (++) [(usVar u, [u]) | bf <- Map.elems blockFlows, u <- bfUses bf]
  in ProcFlow
      { pfObject      = obj
      , pfProc        = proc
      , pfBlocks      = blockFlows
      , pfReachingIn  = rIn
      , pfReachingOut = rOut
      , pfAllDefs     = allDefs
      , pfAllUses     = allUses
      }
