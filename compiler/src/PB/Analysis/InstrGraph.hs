{-# LANGUAGE StrictData #-}
-- | Shared instruction-graph types: 'InstrNode'\/'InstrGraph' plus the
-- canonical-shape helpers ('ShapeNode', 'canonicalize', 'normalizeCallTag')
-- used by hand-trace\/golden-fixture tests.
--
-- The original monadic forward-chaining compiler
-- ('compileProcedure' :: 'PB.Analysis.TypeEnv.ScopedTypeEnv' -> ... ->
-- 'InstrGraph') that built these graphs directly from a 'BodyStmt' list was
-- deleted in Plan 144 Phase 5 Step 7, once 'PB.Analysis.CatOp.compileProcedureViaCatOp'
-- (the @[Located BodyStmt] -> SsaProc -> CatOp () () -> InstrGraph@ pipeline)
-- was swapped into production (Step 6) and verified equivalent (0 corpus
-- errors, 0/7547 @--dual-trace@ diffs, hand-compiled golden fixtures).
--
-- The resulting graph has no nested control flow; all branching is via
-- explicit node indices. The TypeScript step() driver executes the graph.
-- Python stores the result as instr_graph_json on the procedures table.
module PB.Analysis.InstrGraph
  ( InstrNode (..)
  , InstrGraph (..)
  , ShapeNode (..)
  , canonicalize
  , normalizeCallTag
  ) where

import PB.Prelude
import PB.AST.Expr
import GHC.Generics         (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- ---------------------------------------------------------------------------
-- Output types

-- | A single flat instruction.  Field names are chosen so that
-- genericToJSON + stripCamelCasePrefix produces JSON keys matching the
-- TypeScript InstrNode discriminated union (with `tag` instead of `kind`).
-- The TypeScript loadInstrGraph() function maps tag → kind and renames
-- brThenPc → then_ and brElsePc → else_ to avoid TS keyword collisions.
data InstrNode
  = InstrAssign  { anVar :: Text, anRhs :: Expr, anNext :: Int }
  | InstrBranch  { brCond :: Expr, brThenPc :: Int, brElsePc :: Int }
  | InstrGoto    { goTarget :: Int }
  | InstrCall    { clCallee :: Text, clArgs :: [Expr], clResult :: Maybe Text, clNext :: Int }
  | InstrSuspend { suEffect :: Text, suArgs :: [Expr], suVar :: Maybe Text, suContinuation :: Int }
  | InstrReturn  { reValue :: Maybe Expr }
  | InstrNop     { npNext :: Int }
  | InstrCallProc { cpCallee :: Text, cpArgs :: [Expr], cpNext :: Int }
  deriving (Eq, Show, Generic)

-- This is more appropriately a basic block / program counter (PC) driven structure rather
-- than a traditional functional CPS graph (which uses nested closures). The nodes reference
-- the next instructions by integer indices (Int), effectively serving as awwarray-backed
-- control-flow graph (CFG).
data InstrGraph = InstrGraph
  { igNodes            :: [InstrNode]
  , igEntry            :: Int
  , igSuspensionPoints :: [Int]
  , igSourceMap        :: [(Int, Int)]   -- list of [pc, line] pairs
  } deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Canonical graph shape (for hand-trace tests)

-- | Structural shape of a InstrNode with all variable names and expression
-- values erased.  PC targets are replaced by canonical indices (BFS order
-- from entry).  Effect names on InstrSuspend are retained — they are the
-- correctness-critical signal.
data ShapeNode
  = SAsgn  Int        -- InstrAssign:   canonical anNext
  | SBrnch Int Int    -- InstrBranch:   canonical then, canonical else
  | SGoto  Int        -- InstrGoto:     canonical target
  | SCall  Int        -- InstrCall:     canonical clNext
  | SSusp  Text Int   -- InstrSuspend:  effect name, canonical continuation
  | SRet              -- InstrReturn
  | SNop   Int        -- InstrNop:      canonical npNext (-1 preserved)
  | SCProc Int        -- InstrCallProc: canonical cpNext
  deriving (Eq, Show)

-- | BFS traversal from entry, returning PCs in visitation order.
bfsOrder :: Int -> Map.Map Int InstrNode -> [Int]
bfsOrder entry nodeMap = go [entry] Set.empty []
  where
    succs node = case node of
      InstrAssign  { anNext }              -> [anNext             | anNext >= 0]
      InstrBranch  { brThenPc, brElsePc } -> [brThenPc, brElsePc]
      InstrGoto    { goTarget }            -> [goTarget            | goTarget >= 0]
      InstrCall    { clNext }              -> [clNext              | clNext >= 0]
      InstrSuspend { suContinuation }      -> [suContinuation      | suContinuation >= 0]
      InstrReturn  {}                      -> []
      InstrNop     { npNext }              -> [npNext              | npNext >= 0]
      InstrCallProc { cpNext }             -> [cpNext              | cpNext >= 0]
    go []        _       acc = reverse acc
    go (pc:rest) visited acc
      | Set.member pc visited = go rest visited acc
      | otherwise = case Map.lookup pc nodeMap of
          Nothing   -> go rest (Set.insert pc visited) acc
          Just node -> go (rest ++ succs node) (Set.insert pc visited) (pc : acc)

-- | Convert a InstrGraph to a canonical shape list.
canonicalize :: InstrGraph -> [ShapeNode]
canonicalize graph =
  let nodeMap = Map.fromList (zip [0 ..] (igNodes graph))
      order   = bfsOrder (igEntry graph) nodeMap
      canon   = Map.fromList (zip order [0 ..])
      look n  = Map.findWithDefault (-1) n canon
  in [ shapeOf look node | pc <- order, Just node <- [Map.lookup pc nodeMap] ]

shapeOf :: (Int -> Int) -> InstrNode -> ShapeNode
shapeOf look node = case node of
  InstrAssign  { anNext }                   -> SAsgn  (look anNext)
  InstrBranch  { brThenPc, brElsePc }       -> SBrnch (look brThenPc) (look brElsePc)
  InstrGoto    { goTarget }                 -> SGoto  (look goTarget)
  InstrCall    { clNext }                   -> SCall  (look clNext)
  InstrSuspend { suEffect, suContinuation } -> SSusp  suEffect (look suContinuation)
  InstrReturn  {}                           -> SRet
  InstrNop     { npNext }                   -> SNop   (if npNext < 0 then -1 else look npNext)
  InstrCallProc { cpNext }                  -> SCProc (look cpNext)

-- | Collapse the SCall\/SCProc tag-naming divergence: the SSA\/CatOp
-- pipeline always lowers calls to 'InstrCallProc' ('SCProc'), while the
-- deleted old compiler emitted plain 'InstrCall' ('SCall') for non-user-function
-- callees and 'InstrCallProc' only for user-defined functions\/subroutines.
-- This is a pure node-tag difference with no effect on control flow or shape
-- (Plan 145 Phase 1B) — comparisons that care about genuine
-- structural\/semantic parity should normalize it first so this accepted,
-- harmless divergence doesn't mask real diffs.
normalizeCallTag :: ShapeNode -> ShapeNode
normalizeCallTag (SCProc n) = SCall n
normalizeCallTag other      = other
