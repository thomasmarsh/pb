-- | Trace-interpreter for the flat 'InstrGraph' target — the 'GraphBuilder'
-- counterpart to 'PB.Analysis.CatOp'\'s 'Interp'\/'runCat'.
--
-- Pure module — no I/O. Walks a compiled 'InstrGraph' from its entry pc,
-- threading a variable environment and accumulating the same 'TraceEvent'
-- shape 'PB.Analysis.CatOp.runCat' produces, using the one shared
-- 'PB.Analysis.CatEval.evalExprMocked' so both backends evaluate
-- conditions/RHS values (including mocked call responses) identically
-- (Plan 146 Phase 1D / 2a).
module PB.Analysis.InstrInterp
  ( runInstrGraphTrace
  , TraceOutcome (..)
  ) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import PB.Analysis.InstrGraph (InstrNode (..), InstrGraph (..))
import PB.Analysis.CatEval (Value (..), TraceEvent (..), MockResponses, evalExprMocked)

-- | Execute a 'InstrGraph' from its entry pc against a starting environment and
-- a table of mocked call\/suspend responses, returning the final environment
-- and the accumulated trace in chronological (oldest first) order — ready to
-- compare directly against @P.reverse . isTrace@ from an
-- 'PB.Analysis.CatOp.Interp' run given the same 'MockResponses'.
--
-- Takes an explicit @maxSteps@ fuel budget: a real PB loop's exit condition
-- often depends on a call result (row count, SQL code, …) that an empty or
-- incomplete 'MockResponses' table can never satisfy, so without a bound a
-- corpus-wide comparison can hang forever accumulating an ever-growing trace
-- for a single procedure. Running out of fuel simply stops the walk and
-- returns whatever (possibly truncated) environment/trace has accumulated so
-- far — comparing two fuel-truncated traces is still a meaningful check
-- (any divergence *before* the bound is still caught), just not a proof of
-- equivalence past it.
--
-- Mirrors 'PB.Analysis.CatOp.runCat'\'s behavior exactly, including what it
-- does *not* do: reaching 'InstrReturn' ends the walk without emitting a
-- 'TeReturn' (no 'CatOp' constructor 'runCat' interprets ever emits one
-- either — 'SsaReturn' always compiles to a structural 'CatId'\/exit-goto,
-- never a distinct return opcode), so the two traces stay comparable.
--
-- Also returns a 'TraceOutcome' disclosing *why* the walk stopped: reaching a
-- true terminal node ('NaturalHalt') versus exhausting @maxSteps@
-- ('FuelExhausted'). Two genuinely non-terminating loops (e.g. a PB
-- @do...loop until@ whose exit condition depends on an unmocked call result
-- that can never resolve) compile to different node counts per iteration in
-- the old vs new pipelines, so their fuel-truncated traces differ in length
-- even though neither compiler actually misbehaves — callers that only care
-- about genuine divergence should compare the common prefix instead of the
-- raw traces whenever both sides report 'FuelExhausted'.
data TraceOutcome = NaturalHalt | FuelExhausted
  deriving (Eq, Show)

runInstrGraphTrace :: Int -> MockResponses -> InstrGraph -> Map.Map Text Value -> (Map.Map Text Value, [TraceEvent], TraceOutcome)
runInstrGraphTrace maxSteps mocks graph initEnv =
  let (finalEnv, revTrace, outcome) = go maxSteps (igEntry graph) initEnv []
  in (finalEnv, reverse revTrace, outcome)
  where
    nodeMap :: Map.Map Int InstrNode
    nodeMap = Map.fromList (zip [0 ..] (igNodes graph))

    nodeAt :: Int -> InstrNode
    nodeAt pc = fromMaybe (error "impossible: InstrGraph pc out of range") (Map.lookup pc nodeMap)

    go :: Int -> Int -> Map.Map Text Value -> [TraceEvent] -> (Map.Map Text Value, [TraceEvent], TraceOutcome)
    go stepsLeft pc env trace
      | stepsLeft <= 0 = (env, trace, FuelExhausted)
      | otherwise = case nodeAt pc of
          InstrAssign { anVar, anRhs, anNext } ->
            let v = evalExprMocked mocks env anRhs
            in go (stepsLeft - 1) anNext (Map.insert anVar v env) (TeAssign anVar v : trace)
          InstrBranch { brCond, brThenPc, brElsePc } ->
            let taken = case evalExprMocked mocks env brCond of { VBool b -> b; _ -> False }
            in go (stepsLeft - 1) (if taken then brThenPc else brElsePc) env (TeBranch taken : trace)
          InstrGoto { goTarget } -> go (stepsLeft - 1) goTarget env trace
          InstrCall { clCallee, clArgs, clNext } ->
            let vals = map (evalExprMocked mocks env) clArgs
            in go (stepsLeft - 1) clNext env (TeCall clCallee vals : trace)
          InstrSuspend { suEffect, suArgs, suContinuation } ->
            let vals = map (evalExprMocked mocks env) suArgs
            in go (stepsLeft - 1) suContinuation env (TeSuspend suEffect vals : trace)
          InstrCallProc { cpCallee, cpArgs, cpNext } ->
            let vals = map (evalExprMocked mocks env) cpArgs
            in go (stepsLeft - 1) cpNext env (TeCall cpCallee vals : trace)
          InstrNop { npNext } -> if npNext < 0 then (env, trace, NaturalHalt) else go (stepsLeft - 1) npNext env trace
          InstrReturn {} -> (env, trace, NaturalHalt)
