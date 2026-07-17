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
  , extractSqlHostVars
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
import PB.AST.Ident    (Ident, mkIdent)
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
  { dsVar     :: Ident
  -- ^ 'Ident''s 'Eq'/'Ord' compare only the canonical (lowercased) form --
  -- PB variable names are case-insensitive -- while its 'ToJSON' renders
  -- only the originally-declared-at-this-occurrence casing, so gen/kill/
  -- reaching/live Set/Map operations below get case-insensitive identity
  -- for free and the JSON @var_name@ wire field is unaffected.
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
  { usVar     :: Ident
  , usBlock   :: Text
  , usStmtIdx :: Int
  , usLine    :: Maybe Int
  , usKind    :: Text
  } deriving (Eq, Show, Generic)

data BlockFlow = BlockFlow
  { bfBlockId :: Text
  , bfGen     :: Set.Set Ident
  , bfKill    :: Set.Set Ident
  , bfDefs    :: [DefSite]
  , bfUses    :: [UseSite]
  } deriving (Eq, Show, Generic)

data ProcFlow = ProcFlow
  { pfObject     :: Text
  , pfProc       :: Text
  , pfBlocks     :: Map.Map Text BlockFlow
  , pfReachingIn  :: Map.Map Text (Set.Set Ident)
  , pfReachingOut :: Map.Map Text (Set.Set Ident)
  , pfLiveIn     :: Map.Map Text (Set.Set Ident)
  , pfLiveOut    :: Map.Map Text (Set.Set Ident)
  , pfAllDefs    :: Map.Map Ident [DefSite]
  , pfAllUses    :: Map.Map Ident [UseSite]
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Lvalue root extraction

lvRoot :: Lvalue -> Maybe Ident
lvRoot lv = case segments lv of
  (LvSegment n _ : _) -> Just n
  []                  -> Nothing

-- ---------------------------------------------------------------------------
-- Expression identifier extraction

-- | Extract all identifier names from an expression tree. Every raw token/
-- text source is minted into an 'Ident' via 'mkIdent' right here (the sole
-- point where these particular occurrences become identity-comparable) --
-- nothing downstream re-derives canonicalization.
walkExprIdents :: Expr -> Set.Set Ident
walkExprIdents = go
  where
    go (ExLvalue lv) =
      -- Root ident, plus any identifiers in the lvalue's own subscript
      -- expressions (e.g. `arr[i+1]` reads `i` to compute which slot to
      -- address) -- covers a subscripted lvalue read anywhere in an
      -- expression tree (RHS, conditions, call args, returns), not just an
      -- assignment's own LHS (see 'lvalueSubscriptIdents', used directly by
      -- 'extractUseVars' for that LHS case since the LHS is never itself
      -- wrapped in an 'ExLvalue' node).
      maybe Set.empty Set.singleton (lvRoot lv) <> lvalueSubscriptIdents lv
    go (ExCall lv args) =
      let root = maybe Set.empty Set.singleton (lvRoot lv)
      in root <> argTokenIdents args
    go (ExMethodCall recv _ args) =
      go recv <> argTokenIdents args
    go (ExBinOp l _ r) = go l <> go r
    go (ExNot e) = go e
    go (ExNeg e) = go e
    go (ExArray es) = Set.unions (map go es)
    go (ExCreateUsing e) = go e
    go (ExDispatch de) =
      let objIdents = maybe Set.empty go (fmap ExLvalue (object de))
      in objIdents <> argTokenIdents (args de)
    go (ExRaw toks) = identTexts toks
    go _ = Set.empty

-- | Mint an 'Ident', in order, for every token in a flat list whose text is
-- a valid identifier -- the one mint point for token-list identifier
-- extraction ('argTokenIdents' below and 'extractDefVar''s token-list defs).
identTokenList :: [Token] -> [Ident]
identTokenList toks = [ mkIdent (tkText t) | t <- toks, isIdent (tkText t) ]

-- | Mint an 'Ident' for every token across a call's raw argument lists whose
-- text is a valid identifier -- the one mint point for 'ExCall'\/
-- 'ExMethodCall'\/'ExDispatch' argument tokens.
argTokenIdents :: [[Token]] -> Set.Set Ident
argTokenIdents args = Set.fromList (concatMap identTokenList args)

-- | Mint an 'Ident' for every valid-identifier 'Text' in a flat list -- the
-- one mint point for 'ExRaw' tokens and 'Lvalue' subscript text.
identTexts :: [Text] -> Set.Set Ident
identTexts ts = Set.fromList [ mkIdent t | t <- ts, isIdent t ]

-- | Identifiers referenced in an lvalue's own subscript expressions (e.g.
-- @arr[i+1]@ reads @i@ to compute which slot to address). Used both by
-- 'walkExprIdents'' 'ExLvalue' case (a subscripted lvalue read as a plain
-- expression -- RHS, condition, call arg, return) and directly by
-- 'extractUseVars' for an assignment's own LHS, which is always a read of
-- its subscript regardless of being the def target, and which is never
-- itself wrapped in an 'ExLvalue' node for 'walkExprIdents' to see.
lvalueSubscriptIdents :: Lvalue -> Set.Set Ident
lvalueSubscriptIdents (Lvalue segs) =
  Set.unions [ identTexts toks | LvSegment _ (Just toks) <- segs ]

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
extractDefVar :: BodyStmt -> Maybe Ident
extractDefVar (BsAssign lv _)    = lvRoot lv
extractDefVar (BsLocalVar _ _ n _) = Just (mkIdent n)
extractDefVar (BsFor ft)       = lvRoot (forVar ft)
extractDefVar (BsAugAssign toks _ _) = listToMaybe (identTokenList toks)
extractDefVar (BsInc toks)       = listToMaybe (identTokenList toks)
extractDefVar (BsDec toks)       = listToMaybe (identTokenList toks)
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
extractUseVars :: BodyStmt -> Set.Set Ident
extractUseVars stmt@(BsAssign lv rhs) =
  walkExprIdents rhs <> lvalueSubscriptIdents lv <> partialSelfUse
  where
    -- A partial def (`item.label = x`) implicitly reads `item` itself to
    -- reach into it -- without this, the preceding full def that produced
    -- `item` looks dead to any backward walk keyed on def/use sites alone
    -- (the datastore-populate idiom: `ds = create datastore; ds.field = x`).
    partialSelfUse
      | isPartialDef stmt = maybe Set.empty Set.singleton (lvRoot lv)
      | otherwise          = Set.empty
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
extractUseVars (BsAugAssign _ _ toks) = Set.fromList (identTokenList toks)
extractUseVars (BsRaw txt)      = Set.fromList (map mkIdent (extractSqlHostVars txt))
extractUseVars _ = Set.empty

-- | Extract :identifier host-variable names referenced in embedded SQL.
-- 'BsRaw' carries raw, unparsed SQL text (embedded-SQL parsing is not yet
-- part of the grammar), so a host-variable read like
-- @where kodxrisi = :gs_kodxrisi@ is otherwise invisible to every def-use
-- consumer -- 'liveVariables'/'reachingDefinitions' would treat the
-- variable as never read, and any analysis built on top (e.g. DeadVars)
-- would flag a genuinely-used variable as dead.
extractSqlHostVars :: Text -> [Text]
extractSqlHostVars = go
  where
    go t = case T.breakOn ":" t of
      ("", rest) | T.null rest -> []
                 | otherwise   -> go (T.drop 1 rest)
      (_, rest) ->
        let afterColon = T.drop 1 rest
            (var, remaining) = T.span isIdentChar afterColon
        in if T.null var then go remaining else var : go remaining
    isIdentChar c = isAlpha c || c == '_' || (c >= '0' && c <= '9')

-- | Determine use kind from statement tag.
useKind :: BodyStmt -> Text
useKind (BsIf {})     = "condition"
useKind (BsChoose {}) = "condition"
useKind (BsReturn {}) = "return"
useKind (BsCall {})   = "call_arg"
useKind (BsFor {})    = "loop_range"
useKind (BsRaw {})    = "sql_host_var"
useKind _             = "rhs"

-- ---------------------------------------------------------------------------
-- Block-level extraction

-- | Walk a block's statements to extract definition and use sites.
extractDefsUses :: CfgBlock -> BlockFlow
extractDefsUses blk = BlockFlow
  { bfBlockId = cbId blk
  , bfGen     = Set.fromList (map dsVar localDefs)
  , bfKill    = Set.fromList (map dsVar (filter (not . dsPartial) localDefs))
  -- ^ A partial def doesn't kill the variable's reaching/live value -- it
  -- overwrites one member, not the whole thing (see 'dsPartial'). 'bfGen'
  -- deliberately still includes it: a def, even partial, does reach past
  -- the block, and 'bfGen' always wins over 'bfKill' in the reaching/live
  -- equations regardless of this exclusion (bfGen ∪ (in − bfKill)), so
  -- narrowing bfKill alone can only add liveness/reaching info, never
  -- remove it.
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
reachingDefinitions :: Cfg -> Map.Map Text BlockFlow -> (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
reachingDefinitions cfg blockFlows = fix initial
  where
    blockIds = map cbId (cfgBlocks cfg)
    predMap  = buildPredMap (cfgEdges cfg)

    initial :: (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
    initial =
      let rIn  = Map.fromList [(bid, Set.empty) | bid <- blockIds]
          rOut = Map.fromList
            [ (bid, maybe Set.empty bfGen (Map.lookup bid blockFlows))
            | bid <- blockIds
            ]
      in (rIn, rOut)

    fix :: (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
        -> (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
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
upwardExposedUses :: BlockFlow -> Set.Set Ident
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
liveVariables :: Cfg -> Map.Map Text BlockFlow -> (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
liveVariables cfg blockFlows = fix initial
  where
    blockIds = map cbId (cfgBlocks cfg)
    succMap  = buildSuccMap (cfgEdges cfg)

    initial :: (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
    initial =
      ( Map.fromList [(bid, Set.empty) | bid <- blockIds]
      , Map.fromList [(bid, Set.empty) | bid <- blockIds]
      )

    fix :: (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
        -> (Map.Map Text (Set.Set Ident), Map.Map Text (Set.Set Ident))
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
