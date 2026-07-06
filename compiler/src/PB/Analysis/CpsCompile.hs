{-# LANGUAGE StrictData #-}
-- | Shared CPS instruction-graph types, plus a handful of pure helpers
-- ('collectBodyLocals', 'parseArgList') reused by the SSA/CatOp compiler
-- ('PB.Analysis.CatOp').
--
-- The original monadic forward-chaining compiler
-- ('compileProcedure' :: 'PB.Analysis.TypeEnv.ScopedTypeEnv' -> ... ->
-- 'CpsGraph') that built these graphs directly from a 'BodyStmt' list was
-- deleted in Plan 144 Phase 5 Step 7, once 'PB.Analysis.CatOp.compileProcedureViaCatOp'
-- (the @[Located BodyStmt] -> SsaProc -> CatOp () () -> CpsGraph@ pipeline)
-- was swapped into production (Step 6) and verified equivalent (0 corpus
-- errors, 0/7547 @--dual-trace@ diffs, hand-compiled golden fixtures).
--
-- The resulting graph has no nested control flow; all branching is via
-- explicit node indices. The TypeScript step() driver executes the graph.
-- Python stores the result as cps_graph_json on the procedures table.
module PB.Analysis.CpsCompile
  ( CpsNode (..)
  , CpsGraph (..)
  , collectBodyLocals
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
-- Canonical graph shape (for hand-trace tests)

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

-- | Collapse the SCall\/SCProc tag-naming divergence: the SSA\/CatOp
-- pipeline always lowers calls to 'CpsCallProc' ('SCProc'), while the
-- deleted old compiler emitted plain 'CpsCall' ('SCall') for non-user-function
-- callees and 'CpsCallProc' only for user-defined functions\/subroutines.
-- This is a pure node-tag difference with no effect on control flow or shape
-- (Plan 145 Phase 1B) — comparisons that care about genuine
-- structural\/semantic parity should normalize it first so this accepted,
-- harmless divergence doesn't mask real diffs.
normalizeCallTag :: ShapeNode -> ShapeNode
normalizeCallTag (SCProc n) = SCall n
normalizeCallTag other      = other

-- ---------------------------------------------------------------------------
-- Argument conversion: token lists → typed Expr nodes
--
-- The AST stores call arguments as `[[Token]]`. `parseExpr` from
-- PB.Grammar.Body recovers typed Expr nodes (ExBinOp, ExStr, ExBool, ...).

-- | Convert one arg's token list to a typed Expr.
parseArgList :: [Token] -> Expr
parseArgList [] = ExRaw []
parseArgList ts = parseExpr ts

-- ---------------------------------------------------------------------------
-- Local variable collection

-- | Seed a procedure's local-variable type map from its own body's
-- 'BsLocalVar' declarations, so a locally-declared datastore/datawindow/
-- transaction variable's type can be resolved by classification (e.g.
-- 'PB.Analysis.CallClassify.classifyExpr') before that variable's first use.
collectBodyLocals :: [Located BodyStmt] -> Map.Map Text PbType
collectBodyLocals stmts =
  Map.fromList
    [ (T.toLower varName, varType)
    | Located _ (BsLocalVar _ varType varName _) <- stmts
    ]
