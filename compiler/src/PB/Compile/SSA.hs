{-# LANGUAGE StrictData #-}
-- | Static Single Assignment (SSA) intermediate representation.
--
-- Pure module — no I/O.  Converts PB's imperative AST ('BodyStmt') into a
-- block-structured form ('SsaProc') keyed by CFG block id, which the
-- subsequent categorical compilation step ('PB.Compile.LoopAnalysis') consumes
-- directly by (unversioned) variable name.
--
-- Pipeline: 'PB.AST.BodyStmt' → SSA → 'PB.Compile.IR.Eff'
--
-- __Design note:__ This module does not compute dominance-based SSA renaming
-- (dominator tree, dominance frontiers, phi-node placement, per-variable
-- version numbers). 'PB.Compile.LoopAnalysis' compiles every variable reference
-- back down to its bare, unversioned name ('svName') — never the version
-- number — because PB's execution model has one mutable runtime slot per
-- variable name, not per lexical scope. Renaming would only change a field
-- ('svVersion') nothing downstream reads, and phi placement would only
-- produce phi nodes with an always-empty source list (no call site feeds
-- 'predMap' into them), so phi resolution always compiles to a no-op.
module PB.Compile.SSA
  ( -- * SSA Variables
    SsaVar (..)
    -- * SSA Values
  , SsaVal (..)
    -- * SSA Instructions
  , SsaAssign (..)
    -- * Basic Blocks
  , SsaBlock (..)
  , SsaTerm (..)
    -- * SSA Procedure
  , SsaProc (..)
    -- * Construction
  , buildSsa
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Ident    (IdentProvenance (..), identOrig, identSpan, mkIdent, mkIdentDerived, mkIdentSynthetic)
import PB.AST.Located  (Located (..))
import PB.Analysis.Cfg (Cfg (..), CfgBlock (..), CfgEdge (..), buildCfg)
import PB.Analysis.TypeEnv (ScopedTypeEnv)
import PB.Analysis.CallClassify (lvHead)
import PB.Grammar.Body     (parseExpr)
import PB.Lexing.Token     (Token (..))
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

-- ============================================================================
-- SSA Variables
-- ============================================================================

-- | A PB variable, identified by its bare source name only. There is no
-- version number — see the module-level history note.
newtype SsaVar = SsaVar
  { svName :: Text
  } deriving (Eq, Ord, Show, Generic)

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
  , saLhs  :: Expr
    -- ^ A side channel of identifiers a consumer like
    -- 'PB.Analysis.TaintEdges' must be able to read as uses without their
    -- being part of 'saRhs''s real assigned value ('PB.Compile.Interp' and
    -- every other real-evaluation 'PB.Compile.IR.Effectful' instance
    -- ignore this field entirely). Two genuine cases carry real content
    -- here: the original assignment-target expression, preserved (not
    -- reduced to 'lvHead') where its own subscript is itself a read
    -- ('BsAssign'\/'BsAssignExpr' — @arr[i+1] = x@ reads @i@ to address the
    -- write); and a 'BsFor''s loop bounds ('forTo'\/'forStep'), which are
    -- reads that inform the loop var's def but aren't its assigned value
    -- (only 'forFrom' is). Every other clause below sets this to a
    -- subscript-free placeholder: either their target's subscript is
    -- already re-embedded in 'saRhs' ('BsAugAssign'\/'BsInc'\/'BsDec'
    -- compile @lv op= x@ to a 'SsaBinOp' that itself contains @lv@), or
    -- there is no real target to read ('BsDestroy', a \"_\"-def synthetic
    -- assign for 'BsCall'\/'BsPbCall').
  } deriving (Eq, Show, Generic)

-- | A subscript-free placeholder 'saLhs' for an 'SsaAssign' clause whose
-- target's subscript (if any) is not a genuine additional read — see
-- 'SsaAssign''s own doc comment.
noSubscriptLhs :: Text -> Expr
noSubscriptLhs root = ExLvalue (Lvalue [LvSegment (mkIdent root) Nothing])

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
-- SSA Procedure
-- ============================================================================

data SsaProc = SsaProc
  { spName  :: Text
  , spBlocks :: Map.Map Text SsaBlock
  , spEntry  :: Text
  , spVars   :: [SsaVar]
    -- ^ Every variable assigned anywhere in the procedure, one entry per
    -- assignment, in block-declaration order. Not consumed by
    -- 'PB.Compile.LoopAnalysis' (which walks 'spBlocks' directly) — kept for
    -- tests and debugging.
  } deriving (Eq, Show, Generic)

-- ============================================================================
-- Construction
-- ============================================================================

buildSsa :: ScopedTypeEnv -> Text -> [Located BodyStmt] -> SsaProc
buildSsa _env procName stmts =
  let cfg       = buildCfg stmts
      blockMap  = Map.fromList [ (cbId b, b) | b <- cfgBlocks cfg ]
      edgeMap   = buildEdgeMap (cfgEdges cfg)
      headerStmts   = findLoopHeaderStmts edgeMap blockMap
      backEdgeStmts = findLoopBackEdgeStmts (cfgEdges cfg) headerStmts
      rawBlocks = Map.mapWithKey (cfgBlockToSsa edgeMap headerStmts backEdgeStmts) blockMap
  in SsaProc
    { spName   = procName
    , spBlocks = rawBlocks
    , spEntry  = cfgEntry cfg
    , spVars   = concatMap (map saVar . sbAssigns) (Map.elems rawBlocks)
    }

-- ============================================================================
-- Helpers
-- ============================================================================



assignTarget :: Expr -> Text
assignTarget (ExLvalue lv) = lvHead lv
assignTarget _             = "_"

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

-- ============================================================================
-- Step 2: Convert CFG blocks to SSA blocks
-- ============================================================================

cfgBlockToSsa :: Map.Map Text [CfgEdge] -> Map.Map Text BodyStmt -> Map.Map Text BodyStmt
              -> Text -> CfgBlock -> SsaBlock
cfgBlockToSsa edgeMap headerStmts backEdgeStmts label blk =
  let ownAssigns  = concatMap (stmtToAssigns . locNode) (cbStmts blk)
      incrAssigns = case Map.lookup label backEdgeStmts of
        Just (BsFor (ForStmt var _ _ mStep _)) ->
          [ SsaAssign (SsaVar (lvHead var))
              (SsaBinOp BopAdd (SsaVarRef (SsaVar (lvHead var)))
                                (exprToSsaVal (fromMaybe (ExInt "1") mStep)))
              (noSubscriptLhs (lvHead var)) ]
        _ -> []
      assigns  = ownAssigns ++ incrAssigns
      outEdges = Map.findWithDefault [] label edgeMap
      term     = cfgTermToSsa (Map.lookup label headerStmts) outEdges (cbStmts blk)
  in SsaBlock assigns term

-- | The counterpart to 'findLoopHeaderStmts': @lowerFor@ never synthesizes an
-- increment statement anywhere in the CFG (the old compiler builds it
-- procedurally, by hand, in 'PB.Compile.InstrTypes'). This maps each loop
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
  [SsaAssign (SsaVar (lvHead lv)) (exprToSsaVal expr) (ExLvalue lv)]
-- The old compiler synthesizes the loop variable's init assign by hand
-- (InstrGraph.hs's BsFor case); the new pipeline needs the same thing here,
-- since this is the one block that legitimately owns the raw BsFor node in
-- its own cbStmts (CfgBuild.lowerFor flushes it onto the pre-loop block).
stmtToAssigns (BsFor (ForStmt var from to mStep _)) =
  -- The loop var's real assigned value is 'from' alone -- 'to'/'step' are
  -- loop-bound reads, not part of the value, so they ride in the 'saLhs'
  -- channel (same reasoning as a subscripted LHS: a read that must not
  -- corrupt 'saRhs''s real evaluation semantics) rather than 'saRhs'.
  [SsaAssign (SsaVar (lvHead var)) (exprToSsaVal from) (ExArray (to : maybe [] (: []) mStep))]
stmtToAssigns (BsLocalVar _ _ varName (Just expr)) =
  [SsaAssign (SsaVar (identOrig varName)) (exprToSsaVal expr) (noSubscriptLhs (identOrig varName))]
stmtToAssigns (BsLocalVar {}) = []
stmtToAssigns (BsAugAssign lv op rhsToks) =
  let augOpToBinOp AugAdd = BopAdd
      augOpToBinOp AugSub = BopSub
      augOpToBinOp AugMul = BopMul
      augOpToBinOp AugDiv = BopDiv
  in [SsaAssign (SsaVar (lvHead lv))
        (SsaBinOp (augOpToBinOp op) (SsaConst (ExLvalue lv)) (exprToSsaVal (rawArgsToExpr rhsToks)))
        (noSubscriptLhs (lvHead lv))]
stmtToAssigns (BsInc lv) =
  [SsaAssign (SsaVar (lvHead lv)) (SsaBinOp BopAdd (SsaConst (ExLvalue lv)) (SsaConst (ExInt "1"))) (noSubscriptLhs (lvHead lv))]
stmtToAssigns (BsDec lv) =
  [SsaAssign (SsaVar (lvHead lv)) (SsaBinOp BopSub (SsaConst (ExLvalue lv)) (SsaConst (ExInt "1"))) (noSubscriptLhs (lvHead lv))]
stmtToAssigns (BsAssignExpr lhsExpr rhsExpr) =
  [SsaAssign (SsaVar (assignTarget lhsExpr)) (exprToSsaVal rhsExpr) lhsExpr]
stmtToAssigns (BsDestroy lv) =
  [SsaAssign (SsaVar (lvHead lv)) SsaNull (noSubscriptLhs (lvHead lv))]
stmtToAssigns (BsCall expr) =
  [SsaAssign (SsaVar "_") (SsaConst expr) (noSubscriptLhs "_")]
-- BsPbCall: CALL ancestor::event super-dispatch. Encoded as a single-segment
-- synthetic ExCall so it flows through the existing classifyExpr/compileCallExpr
-- machinery in PB.Compile.FromSSA and lowers to a InstrCallProc, matching
-- PB.Compile.InstrTypes's explicit BsPbCall case. The "ancestor::event" text
-- can never collide with isTriggerEvent, a user-fn name (PB identifiers can't
-- contain "::"), or isBuiltinSuspendFn's fixed list, so it always classifies
-- PureCall.
stmtToAssigns (BsPbCall (PbCall ancestor event)) =
  [SsaAssign (SsaVar "_")
             (SsaConst (ExCall (Lvalue [LvSegment dispatchIdent Nothing]) []))
             (noSubscriptLhs "_")]
  where
    dispatchIdent = case (identSpan ancestor, identSpan event) of
      (FromSource as, FromSource es) -> mkIdentDerived (as <> es) (identOrig ancestor <> "::" <> identOrig event)
      _ -> mkIdentSynthetic "PbCall non-FromSource" (identOrig ancestor <> "::" <> identOrig event)
-- Control-flow statements produce no SSA assign of their own. CfgBuild.lower
-- keeps the trailing control stmt as the last element of a block's cbStmts
-- (so cfgTermToSsa's findControlStmt can find it), but its "value" is the
-- block terminator, not an assignment — cfgTermToSsa handles all of these.
stmtToAssigns (BsIf {})     = []
stmtToAssigns (BsDo {})     = []
stmtToAssigns (BsChoose {}) = []
stmtToAssigns (BsReturn _)  = []
stmtToAssigns BsExit        = []
stmtToAssigns (BsHalt _)    = []
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
exprToSsaVal (ExLvalue lv@(Lvalue [LvSegment _ Nothing])) = SsaVarRef (SsaVar (lvHead lv))
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
    Just (BsHalt _) -> SsaReturn Nothing  -- HALT never resumes; same terminator as a void return
    Just BsContinue -> SsaContinue
    -- This block has no control statement of its own, but it may still be a
    -- loop *header* whose condition-check lives one block back (see
    -- 'findLoopHeaderStmts') — reconstruct the branch from there rather than
    -- falling through to the generic (and here, wrong) `SsaReturn Nothing`.
    --
    -- This outer `_` is typed as `Maybe BodyStmt`, so GHC sees it as covering
    -- `Nothing` *and* `Just` of any of the 12 non-control BodyStmt constructors
    -- — but `isCtrl` (above) guarantees `findControlStmt` only ever returns
    -- `Just` for the 7 constructors already matched, so the `Just`-of-a-non-
    -- control-stmt half of this wildcard is unreachable by construction, not an
    -- audit gap. Left as a wildcard rather than enumerated with dead
    -- `error "impossible"` arms, which would add real risk (a typo there is
    -- worse than the status quo)
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
      -- Covers `Nothing` (block is not a recognized loop header — the common
      -- case) plus, type-wise, `Just` of any BodyStmt/DoCondition combination
      -- other than the three shapes `findLoopHeaderStmts`'s `trailingLoopStmt`
      -- ever produces (e.g. a `DoStmt` with both a leading and trailing
      -- condition, which the parser never builds) — type-possible but
      -- unreachable by construction.
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
    isCtrl (BsHalt _)  = True
    isCtrl BsContinue  = True
    -- Enumerated explicitly (not a wildcard) so a future BodyStmt constructor
    -- trips -Wincomplete-patterns here.
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
