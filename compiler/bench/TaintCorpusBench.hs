module Main (main) where

import PB.Prelude
import PB.AST.Ident (mkIdent)
import PB.Pipeline.Runner (runModeDb)
import PB.Pipeline.DuckDb
  ( withHandle, Config(..)
  )
import PB.Pipeline.DuckDb.PhaseB.Query
  ( queryGlobalVars
  , queryProcDefs
  , queryProcUses
  , queryResolvedCalls
  , queryTaintInputs
  , queryTaintIntraEdges
  , queryTaintReturnRows
  )
import PB.Analysis.TypeResolve (GlobalVar (..))
import PB.Analysis.Taint qualified as Taint
import PB.Analysis.TaintClosure qualified as TA
import PB.Algebra.Closure (reachFrom, reconstructPathNodes, internByVal, unintern)

import Data.Set qualified as Set
import Data.Text qualified as T
import qualified Data.HashMap.Strict as HM
import Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors, setNumCapabilities)
import Options.Applicative

-- | Corpus-scale shape\/wall-clock report for the algebraic taint closure
-- ('PB.Analysis.TaintClosure', a sparse 'PB.Algebra.Closure.reachFrom'
-- worklist -- NOT an all-pairs closure, see
-- doc/plan/182-algebraic-analysis.md Section 11), production's sole
-- source for @taint_reaches@\/@taint_confirmed@\/@taint_step_kind@ since
-- the Plan 182 cutover. Runs the existing pipeline unmodified, then
-- reconstructs the algebraic closure's raw inputs from the resulting
-- DuckDB tables the same way 'PB.Pipeline.Passes.runPass67' does, and
-- reports set sizes plus wall-clock. The Haskell BFS
-- ('PB.Analysis.Taint.propagateTaint') is the reference closure this bench
-- reports against; unit-level regression coverage for the closure's
-- correctness lives in 'TaintClosureTest.hs'.

data Options = Options
  { optInput           :: FilePath
  , optDb              :: FilePath
  , optDdl             :: [Text]
  , optSqlDialect       :: Text
  , optSqlWorkerPython :: Maybe FilePath
  }

optParser :: Parser Options
optParser = Options
  <$> strOption (long "input" <> short 'i' <> metavar "DIR" <> value "../example/openpay-0.1.1b-extract"
       <> help "Source root directory (default: ../example/openpay-0.1.1b-extract)")
  <*> strOption (long "db" <> metavar "FILE" <> value "/tmp/taint-corpus-bench.duckdb"
       <> help "Scratch DuckDB output path")
  <*> many (strOption (long "ddl" <> metavar "[SCHEMA:]FILE"
       <> help "DDL catalog file, optionally schema-tagged (repeatable)"))
  <*> strOption (long "sql-dialect" <> metavar "DIALECT" <> value "oracle"
       <> help "sqlglot dialect for DDL/embedded-SQL parsing (default: oracle)")
  <*> optional (strOption (long "sql-worker-python" <> metavar "BIN"
       <> help "Path to the python interpreter used to launch the SQL bridge worker"))

main :: IO ()
main = do
  getNumProcessors >>= setNumCapabilities
  opts <- execParser (info (optParser <**> helper) desc)

  putStrLn ("Running full pipeline: " <> T.pack (optInput opts) <> " -> " <> T.pack (optDb opts))
  t0 <- getCurrentTime
  runModeDb (optInput opts) (optDb opts) (optDdl opts) (optSqlDialect opts) (optSqlWorkerPython opts) Nothing
  t1 <- getCurrentTime
  putStrLn ("Full pipeline wall-clock: " <> showSecs (diffUTCTime t1 t0))
  putStrLn ""

  withHandle (Config (optDb opts)) $ \conn -> do
    -- Reconstruct the algebraic closure's raw inputs exactly as
    -- PB.Pipeline.Passes.runPass67 does.
    gvs   <- queryGlobalVars conn
    defs  <- queryProcDefs conn
    uses  <- queryProcUses conn
    allRC <- queryResolvedCalls conn
    tfis  <- queryTaintInputs conn
    intraEdges <- queryTaintIntraEdges conn
    returnRows <- queryTaintReturnRows conn
    let globalVarNames = Set.fromList (map (mkIdent . gvName) gvs)
        allProcMetas   = concatMap Taint.tfiProcMetas tfis
        allSqlStmts    = concatMap Taint.tfiSqlStmts  tfis
        edges          = Taint.buildInterprocEdges allRC defs uses globalVarNames allProcMetas
        allSources     = Taint.classifySources allSqlStmts allProcMetas
        allSinks       = Taint.classifySinks   allSqlStmts

    putStrLn (T.pack (show (length allSources)) <> " sources, "
           <> T.pack (show (length allSinks)) <> " sinks, "
           <> T.pack (show (length defs)) <> " defs, "
           <> T.pack (show (length uses)) <> " uses, "
           <> T.pack (show (length edges)) <> " interproc edges")
    putStrLn ""

    tReach0 <- getCurrentTime
    let tainted = TA.taintReachable allSources intraEdges returnRows edges
        reachCount = Set.size tainted
    tReach1 <- reachCount `seq` getCurrentTime
    putStrLn ("algebraic reachable: " <> T.pack (show reachCount)
           <> " triples in " <> showSecs (diffUTCTime tReach1 tReach0))

    tConf0 <- getCurrentTime
    let confirmed = TA.taintConfirmed allSources allSinks intraEdges returnRows edges
        confirmedCount = length confirmed
    tConf1 <- confirmedCount `seq` getCurrentTime
    putStrLn ("algebraic taint_confirmed: " <> T.pack (show confirmedCount)
           <> " pairs in " <> showSecs (diffUTCTime tConf1 tConf0))

    tWit0 <- getCurrentTime
    let witnessLegs = TA.taintWitnessLegs allSources intraEdges returnRows edges
        witnessPairCount = length witnessLegs
    tWit1 <- witnessPairCount `seq` getCurrentTime
    putStrLn ("algebraic taintWitnessLegs: " <> T.pack (show witnessPairCount)
           <> " (source, reachable-node) pairs in " <> showSecs (diffUTCTime tWit1 tWit0))

    -- Hot-spot-1 candidate fix (Plan 187): reconstruct witness paths for
    -- CONFIRMED (source, sink) pairs only, instead of every reachable
    -- (source, node) pair. 'taintWitnessLegs' builds legs for all reachable
    -- nodes, then 'materializeTaintStepKind' keeps only the confirmed
    -- subset -- so the overwhelming majority of reconstructed paths are
    -- discarded. This measures the confirmed-only cost directly AND
    -- decomposes it into relation-build / fixpoint / per-pair-reconstruct
    -- to locate the real bottleneck.
    tBuild0 <- getCurrentTime
    let (internerP, relP) = TA.taintPathRelation intraEdges returnRows edges allSources
    tBuild1 <- seq internerP (getCurrentTime)
    let idByValP   = internByVal internerP
        decodeP i  = unintern i internerP
        srcIdsP    = [ i | s <- allSources
                       , let t = (Taint.tsObject s, Taint.tsProcName s, Taint.tsVarName s)
                       , Just i <- [HM.lookup t idByValP] ]
    tFix0 <- getCurrentTime
    let reachRelP  = reachFrom relP srcIdsP
    tFix1 <- seq reachRelP (getCurrentTime)
    let decodeLegP (fromId, toId, (kind, _desc, _)) = do
          fromT <- decodeP fromId
          toT   <- decodeP toId
          pure (fromT, toT, kind)
        confirmedTriples =
          [ ((Taint.tsObject s, Taint.tsProcName s, Taint.tsVarName s)
            ,(Taint.tskObject k, Taint.tskProcName k, Taint.tskVarName k))
          | (s, k) <- confirmed ]
    tRec0 <- getCurrentTime
    let confirmedWitness =
          [ (srcT, snkT, legs)
          | (srcT, snkT) <- confirmedTriples
          , Just srcId  <- [HM.lookup srcT idByValP]
          , Just sinkId <- [HM.lookup snkT idByValP]
          , Just rawLegs <- [reconstructPathNodes reachRelP srcId sinkId]
          , Just legs <- [traverse decodeLegP rawLegs]
          ]
        confirmedWitnessCount = length confirmedWitness
    tRec1 <- confirmedWitnessCount `seq` getCurrentTime
    putStrLn ("algebraic taintWitnessLegs (CONFIRMED-ONLY): " <> T.pack (show confirmedWitnessCount)
           <> " pairs")
    putStrLn ("  build taintPathRelation: " <> showSecs (diffUTCTime tBuild1 tBuild0))
    putStrLn ("  reachFrom (PathValue fixpoint): " <> showSecs (diffUTCTime tFix1 tFix0))
    putStrLn ("  reconstructPathNodes (26 pairs): " <> showSecs (diffUTCTime tRec1 tRec0))

  where
    desc = fullDesc <> progDesc
      "Corpus-scale shape/wall-clock report for the algebraic taint closure."

    showSecs :: NominalDiffTime -> Text
    showSecs d = T.pack (show (realToFrac d :: Double)) <> "s"
