-- | Trace-interpreter for the flat 'CpsGraph' target — the 'GraphBuilder'
-- counterpart to 'PB.Analysis.CatOp'\'s 'Interp'\/'runCat'.
--
-- Pure module — no I/O. Walks a compiled 'CpsGraph' from its entry pc,
-- threading a variable environment and accumulating the same 'TraceEvent'
-- shape 'PB.Analysis.CatOp.runCat' produces, using the one shared
-- 'PB.Analysis.CatEval.evalExpr' so both backends evaluate conditions/RHS
-- values identically (Plan 146 Phase 1D).
module PB.Analysis.CpsInterp
  ( runCpsGraphTrace
  ) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import PB.Analysis.CpsCompile (CpsNode (..), CpsGraph (..))
import PB.Analysis.CatEval (Value (..), TraceEvent (..), evalExpr)

-- | Execute a 'CpsGraph' from its entry pc against a starting environment,
-- returning the final environment and the accumulated trace in chronological
-- (oldest first) order — ready to compare directly against
-- @P.reverse . isTrace@ from an 'PB.Analysis.CatOp.Interp' run.
--
-- Mirrors 'PB.Analysis.CatOp.runCat'\'s behavior exactly, including what it
-- does *not* do: reaching 'CpsReturn' ends the walk without emitting a
-- 'TeReturn' (no 'CatOp' constructor 'runCat' interprets ever emits one
-- either — 'SsaReturn' always compiles to a structural 'CatId'\/exit-goto,
-- never a distinct return opcode), so the two traces stay comparable.
runCpsGraphTrace :: CpsGraph -> Map.Map Text Value -> (Map.Map Text Value, [TraceEvent])
runCpsGraphTrace graph initEnv =
  let (finalEnv, revTrace) = go (cgEntry graph) initEnv []
  in (finalEnv, reverse revTrace)
  where
    nodeMap :: Map.Map Int CpsNode
    nodeMap = Map.fromList (zip [0 ..] (cgNodes graph))

    nodeAt :: Int -> CpsNode
    nodeAt pc = fromMaybe (error "impossible: CpsGraph pc out of range") (Map.lookup pc nodeMap)

    go :: Int -> Map.Map Text Value -> [TraceEvent] -> (Map.Map Text Value, [TraceEvent])
    go pc env trace = case nodeAt pc of
      CpsAssign { anVar, anRhs, anNext } ->
        let v = evalExpr env anRhs
        in go anNext (Map.insert anVar v env) (TeAssign anVar v : trace)
      CpsBranch { brCond, brThenPc, brElsePc } ->
        let taken = case evalExpr env brCond of { VBool b -> b; _ -> False }
        in go (if taken then brThenPc else brElsePc) env (TeBranch taken : trace)
      CpsGoto { goTarget } -> go goTarget env trace
      CpsCall { clCallee, clArgs, clNext } ->
        let vals = map (evalExpr env) clArgs
        in go clNext env (TeCall clCallee vals : trace)
      CpsSuspend { suEffect, suArgs, suContinuation } ->
        let vals = map (evalExpr env) suArgs
        in go suContinuation env (TeSuspend suEffect vals : trace)
      CpsCallProc { cpCallee, cpArgs, cpNext } ->
        let vals = map (evalExpr env) cpArgs
        in go cpNext env (TeCall cpCallee vals : trace)
      CpsNop { npNext } -> if npNext < 0 then (env, trace) else go npNext env trace
      CpsReturn {} -> (env, trace)
