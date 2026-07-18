-- | Taint-flow materialization: the algebraic Kleene-star closure
-- ('PB.Analysis.TaintAlgebra') is production's sole source for
-- @taint_reaches@\/@taint_confirmed@\/@taint_step_kind@.
module PB.Analysis.Rules.Taint
  ( DefUseFanout (..)
  , defLineFanout
  , returnUseFanout
  , materializeTaintClosure
  , materializeTaintStepKind
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb (DuckConn, recreateTextTable, appendTextRows)
import PB.Analysis.Taint qualified as Taint
import PB.Analysis.TaintEdges qualified as TaintEdges
import PB.Analysis.TaintAlgebra (taintReachesPairs, taintConfirmed, taintWitnessLegs)
import Database.DuckDB.Simple (query_)
import Database.DuckDB.Simple.FromRow (FromRow (..), field)

import qualified Data.HashMap.Strict as HM
import qualified Data.Text           as T

-- | Fan-in characterization for a grouped-join key, mirroring
-- 'PB.Analysis.Rules.Schema.LegSourceFanout' -- computed directly in
-- DuckDB SQL against the already-materialized @proc_defs@\/@proc_uses@
-- tables. A duplicate-key fan-in blowup is the established failure shape
-- in this neighborhood (see compiler/CLAUDE.md's Appender-pool section
-- and the leg_source fan-in report), so this runs unconditionally as an
-- early-warning signal before the taint closure itself.
data DefUseFanout = DefUseFanout
  { dufTotalRows    :: !Int
  , dufDistinctKeys :: !Int
  , dufMaxGroupSize :: !Int
  } deriving (Eq, Show)

newtype FanoutRow = FanoutRow DefUseFanout

instance FromRow FanoutRow where
  fromRow = (\t k m -> FanoutRow (DefUseFanout t k m)) <$> field <*> field <*> field

-- | Fan-in of @proc_defs@ rows sharing one (object, proc_name, line) key.
defLineFanout :: DuckConn -> IO DefUseFanout
defLineFanout conn = do
  rows <- query_ conn
    "WITH g AS (SELECT object, proc_name, line, COUNT(*) AS cnt FROM proc_defs \
    \WHERE line IS NOT NULL GROUP BY object, proc_name, line) \
    \SELECT (SELECT COUNT(*) FROM proc_defs WHERE line IS NOT NULL), \
    \COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow f] -> f
    _             -> DefUseFanout 0 0 0

-- | Fan-in of @proc_uses@ rows tagged @kind = 'return'@ sharing one
-- (object, proc_name) key.
returnUseFanout :: DuckConn -> IO DefUseFanout
returnUseFanout conn = do
  rows <- query_ conn
    "WITH g AS (SELECT object, proc_name, COUNT(*) AS cnt FROM proc_uses \
    \WHERE kind = 'return' GROUP BY object, proc_name) \
    \SELECT (SELECT COUNT(*) FROM proc_uses WHERE kind = 'return'), \
    \COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow f] -> f
    _             -> DefUseFanout 0 0 0

-- | The @object::proc::var@ key every taint table joins on.
taintKey :: Text -> Text -> Text -> Text
taintKey obj proc var = obj <> "::" <> proc <> "::" <> var

-- | Materialize @taint_reaches@\/@taint_confirmed@ from the algebraic
-- closure ('PB.Analysis.TaintAlgebra'). Takes the same already-computed
-- inputs 'PB.Pipeline.Passes.runPass67' builds for its interproc-edge\/
-- source\/sink classification, so no extra DB round-trip is needed.
materializeTaintClosure
  :: [Taint.TaintSource] -> [Taint.TaintSink] -> [TaintEdges.TaintIntraEdgeRow] -> [TaintEdges.TaintReturnRow]
  -> [Taint.DefRow] -> [Taint.UseRow] -> [Taint.InterprocEdge] -> DuckConn -> IO ()
materializeTaintClosure sources sinks intraEdges returnRows defs uses edges conn = do
  let reaches   = taintReachesPairs sources intraEdges returnRows defs uses edges
      confirmed = taintConfirmed sources sinks intraEdges returnRows defs uses edges
      reachRows =
        [ [taintKey ox px vx, taintKey oy py vy]
        | ((ox, px, vx), (oy, py, vy)) <- reaches
        ]
      confirmedRows =
        [ [ taintKey (Taint.tsObject s) (Taint.tsProcName s) (Taint.tsVarName s)
          , taintKey (Taint.tskObject k) (Taint.tskProcName k) (Taint.tskVarName k)
          ]
        | (s, k) <- confirmed
        ]
  recreateTextTable conn "taint_reaches" ["x", "y"]
  appendTextRows conn "taint_reaches" reachRows
  recreateTextTable conn "taint_confirmed" ["s", "t"]
  appendTextRows conn "taint_confirmed" confirmedRows

-- | Materialize @taint_step_kind@ from the algebraic witness
-- ('TaintAlgebra.taintWitnessLegs'), restricted to CONFIRMED (source,
-- sink) pairs -- 'taintWitnessLegs' is per-reachable-node, a strict
-- superset of the confirmed pairs this table reports one row per hop
-- for. Row shape and @step_kind@\/@description@ conventions: leg_ord 0 is
-- always "source", every other leg's @step_kind@\/@description@ echo its
-- real edge kind, a terminal "sink" marker lands one ordinal past the
-- last real leg, and the 0-hop (source == sink) case is a single
-- "source-sink" row with no real edge -- 'PB.Pipeline.DuckDb.materializeTaintPaths'
-- embeds these verbatim into @taint_paths.steps_json@, so the shape is
-- load-bearing, not incidental formatting.
materializeTaintStepKind
  :: [Taint.TaintSource] -> [Taint.TaintSink] -> [TaintEdges.TaintIntraEdgeRow] -> [TaintEdges.TaintReturnRow]
  -> [Taint.DefRow] -> [Taint.UseRow] -> [Taint.InterprocEdge] -> DuckConn -> IO ()
materializeTaintStepKind sources sinks intraEdges returnRows defs uses edges conn = do
  let confirmed   = taintConfirmed sources sinks intraEdges returnRows defs uses edges
      witnessLegs = taintWitnessLegs sources intraEdges returnRows defs uses edges
      legsByPair  = HM.fromList [ ((srcT, dstT), legList) | (srcT, dstT, legList) <- witnessLegs ]
      rows        = concatMap (rowsForPair legsByPair) confirmed
  recreateTextTable conn "taint_step_kind"
    ["s", "t", "leg_ord", "lf", "lt", "kind", "step_kind", "description"]
  appendTextRows conn "taint_step_kind" rows
  where
    taintKey3 (o, p, v) = taintKey o p v
    rowsForPair legsByPair (src, snk) =
      let srcT      = (Taint.tsObject src, Taint.tsProcName src, Taint.tsVarName src)
          snkT      = (Taint.tskObject snk, Taint.tskProcName snk, Taint.tskVarName snk)
          sourceKey = taintKey3 srcT
          sinkKey   = taintKey3 snkT
      in if srcT == snkT
           then [[sourceKey, sourceKey, "0", sourceKey, sourceKey, "sink", "source-sink",
                  "taint source and sink (same variable)"]]
           else case HM.lookup (srcT, snkT) legsByPair of
             Nothing -> error
               ("PB.Analysis.Rules.Taint.materializeTaintStepKind: impossible: "
                 <> show snkT <> " has no witness path despite being taint_confirmed reachable from "
                 <> show srcT)
             Just legs ->
               let legRows = [ legRow sourceKey sinkKey o fromT toT kind
                              | (o, (fromT, toT, kind, _desc)) <- zip [0 :: Int ..] legs ]
                   terminal = [sourceKey, sinkKey, T.pack (show (length legs)), sinkKey, sinkKey,
                               "sink", "sink", "taint propagation via sink"]
               in legRows ++ [terminal]
    legRow sourceKey sinkKey o fromT toT kind =
      let lf = taintKey3 fromT
          lt = taintKey3 toT
      in if o == (0 :: Int)
           then [sourceKey, sinkKey, "0", lf, lt, kind, "source", "taint source"]
           else [sourceKey, sinkKey, T.pack (show o), lf, lt, kind, kind, "taint propagation via " <> kind]
