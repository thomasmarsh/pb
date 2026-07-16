{-# LANGUAGE StrictData #-}
-- | Intra-procedural dataflow analysis — def-use chains and reaching definitions.
--
-- Pure module — no I/O.  Public API:
--
--   analyzeProcedure :: Text -> Text -> Cfg -> ProcFlow
--   dataflowDefRows  :: ProcFlow -> [Value]    -- 111d-1: Python row-dict shape
--   dataflowUseRows  :: ProcFlow -> [Value]
--   dataflowFacet    :: ProcFlow -> Value      -- {"defs":[...], "uses":[...]}
--
-- Builds on the CFG from PB.Analysis.Cfg and extracts def-use sites
-- from the typed AST, eliminating JSON re-parsing.
module PB.Analysis.Dataflow
  ( DefSite (..)
  , UseSite (..)
  , BlockFlow (..)
  , ProcFlow (..)
  , extractDefsUses
  , reachingDefinitions
  , liveVariables
  , analyzeProcedure
  , dataflowDefRows
  , dataflowUseRows
  , dataflowFacet
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located  (Located (..))
import PB.Lexing.Token (Token (..))
import PB.Analysis.Cfg (Cfg (..), CfgBlock (..), CfgEdge (..))
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
  , dsPartial :: Bool
  -- ^ True when this def writes only one member of dsVar (e.g. the
  -- @item.label = x@ in @item.label = x; item.pictureindex = y@) rather
  -- than the whole variable — 'lvRoot' collapses a member chain to its
  -- root, so two field writes to the same struct look identical to two
  -- full redefinitions of the same scalar to any consumer keyed on dsVar
  -- alone.
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
  , pfLiveIn     :: Map.Map Text (Set.Set Text)
  , pfLiveOut    :: Map.Map Text (Set.Set Text)
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
      -- here would over-count row/i/ll_row uses vs the baseline.
      maybe Set.empty Set.singleton (lvRoot lv)
    go (ExCall lv args) =
      let root = maybe Set.empty Set.singleton (lvRoot lv)
          argIdents = Set.fromList [tkText t | argToks <- args, t <- argToks, isIdent (tkText t)]
      in root <> argIdents
    go (ExMethodCall recv _ args) =
      go recv <> Set.fromList [tkText t | argToks <- args, t <- argToks, isIdent (tkText t)]
    go (ExBinOp l _ r) = go l <> go r
    go (ExNot e) = go e
    go (ExNeg e) = go e
    go (ExArray es) = Set.unions (map go es)
    go (ExCreateUsing e) = go e
    go (ExDispatch de) =
      let objIdents = maybe Set.empty go (fmap ExLvalue (object de))
          argIdents = Set.fromList [tkText t | argToks <- args de, t <- argToks, isIdent (tkText t)]
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
extractDefVar (BsAugAssign toks _ _) = listToMaybe [tkText t | t <- toks, isIdent (tkText t)]
extractDefVar (BsInc toks)       = listToMaybe [tkText t | t <- toks, isIdent (tkText t)]
extractDefVar (BsDec toks)       = listToMaybe [tkText t | t <- toks, isIdent (tkText t)]
extractDefVar _                  = Nothing

-- | True when a def only writes one member of a multi-segment lvalue
-- (@item.label = x@), not the whole variable. Only BsAssign carries a
-- parsed Lvalue with real segment structure; the token-list-based defs
-- (BsAugAssign/BsInc/BsDec) can't reliably distinguish a member chain from
-- a subscript here, so they're left False.
isPartialDef :: BodyStmt -> Bool
isPartialDef (BsAssign lv _) = length (segments lv) > 1
isPartialDef _                = False

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
extractUseVars (BsAugAssign _ _ toks) = Set.fromList [tkText t | t <- toks, isIdent (tkText t)]
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
        Just v  -> [DefSite v bid idx (Just (locLine s)) (defKind (locNode s)) (isPartialDef (locNode s))]

    localUses = concatMap extractUse (zip [0..] stmts)
    extractUse (idx, s) =
      let vs = extractUseVars (locNode s)
          uk = useKind (locNode s)
      in [UseSite v bid idx (Just (locLine s)) uk | v <- Set.toAscList vs]

-- ---------------------------------------------------------------------------
-- Reaching definitions

-- | Precompute a block's predecessor ids once per edge list, so the
-- fixpoint loop below does a Map lookup per block per iteration instead of
-- rescanning the full edge list.
buildPredMap :: [CfgEdge] -> Map.Map Text [Text]
buildPredMap = foldl' (\m e -> Map.insertWith (++) (ceDst e) [ceSrc e] m) Map.empty

-- | Iterative forward dataflow for reaching definitions.
-- Returns (reaching_in, reaching_out) mapping block_id → set of variable names.
reachingDefinitions :: Cfg -> Map.Map Text BlockFlow -> (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
reachingDefinitions cfg blockFlows = fix initial
  where
    blockIds = map cbId (cfgBlocks cfg)
    predMap  = buildPredMap (cfgEdges cfg)

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
          let preds = Map.findWithDefault [] bid predMap
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
-- Live variables

-- | Precompute a block's successor ids once per edge list — the backward
-- counterpart of 'buildPredMap'.
buildSuccMap :: [CfgEdge] -> Map.Map Text [Text]
buildSuccMap = foldl' (\m e -> Map.insertWith (++) (ceSrc e) [ceDst e] m) Map.empty

-- | A block's upward-exposed uses: variables read before any def of that
-- same variable earlier in the block. A block-level use set that included
-- every use regardless of position would count a var as "needed from
-- outside the block" even when the block redefines it before reading it
-- (e.g. @li_x = 2; li_y = li_x@ reads the block's own redefinition, not
-- whatever reached the block on entry) — the standard liveness equations
-- require this upward-exposed refinement; a raw union of 'bfUses' does not
-- satisfy it.
upwardExposedUses :: BlockFlow -> Set.Set Text
upwardExposedUses bf = snd (foldl' step (Set.empty, Set.empty) idxsAsc)
  where
    idxsAsc   = Set.toAscList (Set.fromList (map dsStmtIdx (bfDefs bf) <> map usStmtIdx (bfUses bf)))
    defByIdx  = Map.fromList [(dsStmtIdx d, dsVar d) | d <- bfDefs bf]
    usesByIdx = Map.fromListWith Set.union [(usStmtIdx u, Set.singleton (usVar u)) | u <- bfUses bf]
    step (definedSoFar, exposed) idx =
      let useSet = Map.findWithDefault Set.empty idx usesByIdx
          exposed' = exposed <> Set.filter (`Set.notMember` definedSoFar) useSet
          definedSoFar' = maybe definedSoFar (`Set.insert` definedSoFar) (Map.lookup idx defByIdx)
      in (definedSoFar', exposed')

-- | Iterative backward dataflow for live variables.
-- Returns (live_in, live_out) mapping block_id → set of variable names.
-- live_in[B]  = use[B] ∪ (live_out[B] − kill[B])
-- live_out[B] = ∪ live_in[S] for successors S of B
liveVariables :: Cfg -> Map.Map Text BlockFlow -> (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
liveVariables cfg blockFlows = fix initial
  where
    blockIds = map cbId (cfgBlocks cfg)
    succMap  = buildSuccMap (cfgEdges cfg)

    initial :: (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
    initial =
      ( Map.fromList [(bid, Set.empty) | bid <- blockIds]
      , Map.fromList [(bid, Set.empty) | bid <- blockIds]
      )

    fix :: (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
        -> (Map.Map Text (Set.Set Text), Map.Map Text (Set.Set Text))
    fix (lIn, lOut) =
      let (lIn', lOut', changed) = foldl' step (lIn, lOut, False) blockIds
      in if changed then fix (lIn', lOut') else (lIn', lOut')

    step (lIn, lOut, changed) bid =
      let succs = Map.findWithDefault [] bid succMap
          newOut = Set.unions [Map.findWithDefault Set.empty s lIn | s <- succs]
          bf = Map.lookup bid blockFlows
          useSet = maybe Set.empty upwardExposedUses bf
          newIn = case bf of
            Nothing -> useSet `Set.union` newOut
            Just b  -> useSet `Set.union` (newOut `Set.difference` bfKill b)
          oldIn  = Map.findWithDefault Set.empty bid lIn
          oldOut = Map.findWithDefault Set.empty bid lOut
          changed' = changed || newIn /= oldIn || newOut /= oldOut
      in ( Map.insert bid newIn lIn
         , Map.insert bid newOut lOut
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
      (lIn, lOut) = liveVariables cfg blockFlows
      allDefs = Map.fromListWith (++) [(dsVar d, [d]) | bf <- Map.elems blockFlows, d <- bfDefs bf]
      allUses = Map.fromListWith (++) [(usVar u, [u]) | bf <- Map.elems blockFlows, u <- bfUses bf]
  in ProcFlow
      { pfObject      = obj
      , pfProc        = proc
      , pfBlocks      = blockFlows
      , pfReachingIn  = rIn
      , pfReachingOut = rOut
      , pfLiveIn      = lIn
      , pfLiveOut     = lOut
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
