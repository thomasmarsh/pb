module Main (main) where

import PB.Prelude
import PB.AST.Ident (mkIdent)
import PB.Pipeline.Runner (runModeDb)
import PB.Pipeline.DuckDb
  ( withWriteConn
  , queryGlobalVars
  , queryProcDefs
  , queryProcUses
  , queryResolvedCalls
  , queryTaintInputs
  , queryTextRows
  )
import PB.Analysis.TypeResolve (GlobalVar (..))
import PB.Analysis.Taint qualified as Taint
import PB.Analysis.TaintAlgebra qualified as TA
import PB.Analysis.Rules.Taint qualified as TaintRules
import PB.Pipeline.Souffle qualified as Souffle

import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors, setNumCapabilities)
import Options.Applicative

-- | Plan 182 Phase 2 step 6: corpus-validate the algebraic taint closure
-- ('PB.Analysis.TaintAlgebra', a sparse 'PB.Algebra.Closure.reachFrom'
-- worklist -- NOT 'star's all-pairs closure, see
-- doc/plan/182-algebraic-analysis.md Section 11) against both the Haskell
-- BFS oracle ('PB.Analysis.Taint.propagateTaint') and the real Souffle
-- 'taintRules' fixpoint, on a real corpus. Runs the existing pipeline
-- unmodified, then reconstructs 'propagateTaint's raw inputs from the
-- resulting DuckDB tables the same way 'PB.Pipeline.Passes.runPass67'
-- does, and reports row-count/set parity plus wall-clock.

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
  putStrLn ("Full pipeline wall-clock (incl. Souffle taint rules): " <> showSecs (diffUTCTime t1 t0))
  putStrLn ""

  withWriteConn (optDb opts) $ \conn -> do
    -- Reconstruct propagateTaint's 4 raw inputs exactly as
    -- PB.Pipeline.Passes.runPass67 does.
    gvs   <- queryGlobalVars conn
    defs  <- queryProcDefs conn
    uses  <- queryProcUses conn
    allRC <- queryResolvedCalls conn
    tfis  <- queryTaintInputs conn
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

    -- Gate 1: BFS oracle vs. the algebraic closure, on identical
    -- real-corpus inputs -- exact Set equality, not just a row count.
    tBfs0 <- getCurrentTime
    let (taintedBFS, _prov) = Taint.propagateTaint allSources defs uses edges
        bfsCount = Set.size taintedBFS
    tBfs1 <- bfsCount `seq` getCurrentTime

    tAlg0 <- getCurrentTime
    let taintedAlg = TA.taintReachable allSources defs uses edges
        algCount = Set.size taintedAlg
    tAlg1 <- algCount `seq` getCurrentTime

    putStrLn ("BFS reachable:       " <> T.pack (show (Set.size taintedBFS))
           <> " triples in " <> showSecs (diffUTCTime tBfs1 tBfs0))
    putStrLn ("algebraic reachable: " <> T.pack (show (Set.size taintedAlg))
           <> " triples in " <> showSecs (diffUTCTime tAlg1 tAlg0))
    if taintedBFS == taintedAlg
      then putStrLn "OK: BFS and algebraic reachable sets are IDENTICAL"
      else putStrLn ("MISMATCH: " <> T.pack (show (Set.size (Set.difference taintedBFS taintedAlg)))
             <> " only in BFS, " <> T.pack (show (Set.size (Set.difference taintedAlg taintedBFS)))
             <> " only in algebraic")
    putStrLn ""

    -- Isolated Souffle-only closure timer: taintRules over the EDB tables
    -- the full pipeline already materialized (taint_source/taint_sink/
    -- taint_edge) -- re-run standalone so its cost is comparable
    -- apples-to-apples against the algebraic path above (the full
    -- pipeline wall-clock above includes EDB materialization plus every
    -- OTHER rule set, not just taint).
    tSouffle0 <- getCurrentTime
    Souffle.runRuleSet conn TaintRules.taintRules
    tSouffle1 <- getCurrentTime
    putStrLn ("Souffle taintRules (isolated closure only): " <> showSecs (diffUTCTime tSouffle1 tSouffle0))
    putStrLn ""

    -- Gate 2: algebraic taint_confirmed vs. the real Souffle oracle's
    -- materialized taint_confirmed table.
    tConf0 <- getCurrentTime
    let algConfirmed = TA.taintConfirmed allSources allSinks defs uses edges
        algConfirmedKeys = Set.fromList
          [ ( taintKey3 (Taint.tsObject s)  (Taint.tsProcName s)  (Taint.tsVarName s)
            , taintKey3 (Taint.tskObject t) (Taint.tskProcName t) (Taint.tskVarName t)
            )
          | (s, t) <- algConfirmed
          ]
        confirmedCount = Set.size algConfirmedKeys
    tConf1 <- confirmedCount `seq` getCurrentTime

    souffleConfirmedRows <- queryTextRows conn "taint_confirmed" ["s", "t"]
    let souffleConfirmedKeys = Set.fromList (pairsOf souffleConfirmedRows)

    putStrLn ("algebraic taint_confirmed: " <> T.pack (show (Set.size algConfirmedKeys))
           <> " pairs in " <> showSecs (diffUTCTime tConf1 tConf0))
    putStrLn ("Souffle taint_confirmed:   " <> T.pack (show (Set.size souffleConfirmedKeys)) <> " pairs (oracle)")
    if algConfirmedKeys == souffleConfirmedKeys
      then putStrLn "OK: algebraic taint_confirmed matches the Souffle oracle exactly"
      else putStrLn ("MISMATCH: " <> T.pack (show (Set.size (Set.difference algConfirmedKeys souffleConfirmedKeys)))
             <> " only in algebraic, " <> T.pack (show (Set.size (Set.difference souffleConfirmedKeys algConfirmedKeys)))
             <> " only in Souffle")
    putStrLn ""

    -- Measurement only (not a gate): taintWitnesses (one row per
    -- (source, reachable-node) with its final incoming edge label) has
    -- coarser granularity than taint_step_kind (one row per hop on the
    -- reconstructed witness path) -- reported for visibility, not diffed.
    let algWitnesses = TA.taintWitnesses allSources defs uses edges
    souffleStepKindRows <- queryTextRows conn "taint_step_kind" ["s", "t"]
    let souffleStepKindPairs = Set.fromList (pairsOf souffleStepKindRows)

    putStrLn ("algebraic taintWitnesses: " <> T.pack (show (length algWitnesses)) <> " (source, reachable-node) rows")
    putStrLn ("Souffle taint_step_kind:  " <> T.pack (show (length souffleStepKindRows)) <> " leg rows, "
           <> T.pack (show (Set.size souffleStepKindPairs)) <> " distinct (s,t) pairs")

  where
    desc = fullDesc <> progDesc
      "Plan 182 Phase 2 step 6: corpus-validate the algebraic taint closure \
      \against the BFS oracle and the real Souffle taintRules fixpoint."

    showSecs :: NominalDiffTime -> Text
    showSecs d = T.pack (show (realToFrac d :: Double)) <> "s"

    pairsOf :: [[Text]] -> [(Text, Text)]
    pairsOf = mapMaybe toPair
      where
        toPair [a, b] = Just (a, b)
        toPair _      = Nothing

    taintKey3 :: Text -> Text -> Text -> Text
    taintKey3 obj proc var = obj <> "::" <> proc <> "::" <> var
