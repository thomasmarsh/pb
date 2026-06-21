-- | Intra-procedural dataflow analysis — def-use chains and reaching definitions.
--
-- Pure module — no I/O.  Public API:
--
--   analyzeProcedure :: Text -> Text -> Cfg -> ProcFlow
--   dataflowDefRows  :: ProcFlow -> [Value]    -- 111d-1: Python row-dict shape
--   dataflowUseRows  :: ProcFlow -> [Value]
--   dataflowFacet    :: ProcFlow -> Value      -- {"defs":[...], "uses":[...]}
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
  , dataflowDefRows
  , dataflowUseRows
  , dataflowFacet
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import PB.Pipeline.CfgBuild (Cfg (..), CfgBlock (..), CfgEdge (..))
import qualified Data.Aeson        as Aeson
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
      -- Root ident only. Subscript tokens are intentionally NOT extracted to
      -- match core/dataflow.py's _walk_expr_idents (which checks for
      -- tag=="TkIdent" dicts that the Haskell JSON emitter never produces for
      -- subscripts, so it systematically misses them). Extracting subscripts
      -- here would over-count row/i/ll_row uses vs the baseline. Plan 111d-2
      -- can revisit whether subscript idents should be real uses.
      maybe Set.empty Set.singleton (lvRoot lv)
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

-- | A valid PB identifier: first char alpha/underscore, rest alnum/underscore.
-- Must match Python core/dataflow.py's _IDENT_RE (`^[a-zA-Z_][a-zA-Z0-9_]*$`)
-- exactly — it is applied to ExCall/ExMethodCall/ExDispatch/ExRaw token strings,
-- where enum constants like "Original!" live. A first-char-only check would
-- wrongly admit "Original!" as an identifier (the 111d-1 over-count bug).
isIdent :: Text -> Bool
isIdent t = case T.uncons t of
  Nothing     -> False
  Just (c, r) -> (isAlpha c || c == '_') && T.all isIdentRest r
  where isIdentRest ch = (ch >= 'a' && ch <= 'z')
                      || (ch >= 'A' && ch <= 'Z')
                      || (ch >= '0' && ch <= '9')
                      || ch == '_'

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
--
-- IMPORTANT: this must mirror core/dataflow.py's _extract_use_vars_from_stmt.
-- For compound statements (BsFor/BsIf/BsDo/BsChoose) it extracts ONLY the
-- condition / loop-range / choose expression — NOT the nested bodies. The CFG
-- lowers those bodies into their own basic blocks, where each statement is
-- analyzed independently by extractDefsUses. Recursing into the bodies here
-- would double-count every use inside if/for/do/choose blocks (this was the
-- 111d-1 over-count bug: proc_uses 13824 vs the 11303 baseline).
extractUseVars :: BodyStmt -> Set.Set Text
extractUseVars (BsAssign _ rhs)       = walkExprIdents rhs
extractUseVars (BsLocalVar _ _ _ mInit) = maybe Set.empty walkExprIdents mInit
extractUseVars (BsFor ft) =
  -- Loop var is a def; from/to/step are uses. Body is handled by CFG blocks.
  walkExprIdents (forFrom ft) <> walkExprIdents (forTo ft)
  <> maybe Set.empty walkExprIdents (forStep ft)
extractUseVars (BsIf ift) =
  -- Only the condition; then/elseif/else bodies are handled by CFG blocks.
  walkExprIdents (ifCond ift)
extractUseVars (BsDo dt) =
  -- Only the cond/loop expressions; body is handled by CFG blocks.
  maybe Set.empty condUses (doCond dt)
  <> maybe Set.empty condUses (doLoop dt)
  where
    condUses (DoWhile e) = walkExprIdents e
    condUses (DoUntil e) = walkExprIdents e
extractUseVars (BsChoose cs) =
  -- Only the choose expression; clause bodies are handled by CFG blocks.
  walkExprIdents (chooseExpr cs)
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

-- ---------------------------------------------------------------------------
-- 111d-1: Flat row emission (Python consumer shape)
--
-- These emit one Aeson Value per def/use site, with the exact snake_case
-- dict keys the Python consumers read from DuckDB. The per-procedure context
-- (file/object/proc_name) is added by the consumer, which already knows it —
-- only the per-block keys belong here. This keeps the streaming facet (which
-- is embedded in the per-procedure JSON and therefore already carries the
-- procedure context via its parent object) and the consolidated Pass-6 JSON
-- on the same row emitter.

-- | One def row: {var_name, block_id, stmt_index, line, kind}.
defRow :: DefSite -> Aeson.Value
defRow d = Aeson.object
  [ "var_name"   Aeson..= dsVar d
  , "block_id"   Aeson..= dsBlock d
  , "stmt_index" Aeson..= dsStmtIdx d
  , "line"       Aeson..= dsLine d
  , "kind"       Aeson..= dsKind d
  ]

-- | One use row: {var_name, block_id, stmt_index, line, kind}.
useRow :: UseSite -> Aeson.Value
useRow u = Aeson.object
  [ "var_name"   Aeson..= usVar u
  , "block_id"   Aeson..= usBlock u
  , "stmt_index" Aeson..= usStmtIdx u
  , "line"       Aeson..= usLine u
  , "kind"       Aeson..= usKind u
  ]

-- | All def rows for a procedure, in block-then-statement order.
-- Order is deterministic: blocks in CFG order, defs in their order within
-- the block, flattened across all blocks.
dataflowDefRows :: ProcFlow -> [Aeson.Value]
dataflowDefRows pf = map defRow (concatMap bfDefs (Map.elems (pfBlocks pf)))

-- | All use rows for a procedure, in block-then-statement order.
dataflowUseRows :: ProcFlow -> [Aeson.Value]
dataflowUseRows pf = map useRow (concatMap bfUses (Map.elems (pfBlocks pf)))

-- | The per-procedure facet embedded into the JSON by wrapSrFile:
--   {"defs": [row...], "uses": [row...]}.
-- This is the streaming-mode delivery channel — pb index (runModeJsonl)
-- never calls writeDataflowAnalysis, so it relies on this facet.
dataflowFacet :: ProcFlow -> Aeson.Value
dataflowFacet pf = Aeson.object
  [ "defs" Aeson..= dataflowDefRows pf
  , "uses" Aeson..= dataflowUseRows pf
  ]
