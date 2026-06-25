{-# LANGUAGE StrictData #-}
module PB.Pipeline.Passes
  ( runPhaseB
  ) where

import PB.Prelude
import PB.Analysis.Builtins    (builtinFnNames, builtinMethodNames)
import PB.Analysis.DeadCode    qualified as DeadCode
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TypeResolve
import PB.Pipeline.DuckDb
  ( DuckConn
  , queryLocalVars, queryCallSites, queryGlobalVars, queryObjInfo
  , queryProcDefs, queryProcUses, queryResolvedCalls
  , queryTaintInputs, queryProcInfos, queryDwObjectSet
  , appendResolvedTypes, appendResolvedCalls
  , appendInterprocEdges, appendProcSummaries
  , appendTaintSources, appendTaintSinks, appendTaintPaths
  , appendTaintAnnotations, appendDeadCode
  )

import Data.Aeson          (Value (..), encode, object, (.=))
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import System.IO           (hFlush, stderr)
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL

-- | Emit a single JSON progress event to stderr for the Python reporter.
emitProgress :: Value -> IO ()
emitProgress v = do
  BS.hPut stderr (BSL.toStrict (encode v) <> "\n")
  hFlush stderr

-- | Last dot-separated segment of a dotted name, e.g. "dw.setfocus" → "setfocus".
lastName :: Text -> Text
lastName t = T.takeWhileEnd (/= '.') t

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Runs sequentially after Phase A is complete. Split into three functions so
-- each pass's bindings go out of scope (and are GC-eligible) before the next.
runPhaseB :: DuckConn -> IO ()
runPhaseB conn = do
  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("B" :: Text)])
  inh   <- runPass5  conn
  allRC <- runPass67 conn
  runPass8 conn inh allRC

runPass5 :: DuckConn -> IO (Map.Map Text Text)
runPass5 conn = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Resolving types" :: Text)])
  lvs                              <- queryLocalVars  conn
  css                              <- queryCallSites  conn
  (objSet, usrTypes, inh, procMap) <- queryObjInfo   conn
  let rt = resolveTypes lvs objSet usrTypes
      rc = resolveCalls css procMap inh builtinFnNames builtinMethodNames
  appendResolvedTypes conn rt
  appendResolvedCalls conn rc
  pure inh

-- | Pass 6+7: compute interproc edges and taint ONCE corpus-wide (not once per file).
runPass67 :: DuckConn -> IO [Taint.ResolvedCallRow]
runPass67 conn = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Building call graph" :: Text)])
  gvs  <- queryGlobalVars     conn
  defs <- queryProcDefs       conn
  uses <- queryProcUses       conn
  allRC <- queryResolvedCalls conn
  tfis  <- queryTaintInputs   conn
  let globalVarNames = Set.fromList (map gvName gvs)
      allProcMetas   = concatMap Taint.tfiProcMetas tfis
      allSqlStmts    = concatMap Taint.tfiSqlStmts  tfis
      edges          = Taint.buildInterprocEdges allRC defs uses globalVarNames allProcMetas
      summaries      = Taint.buildProcedureSummaries edges defs uses globalVarNames allProcMetas
      allSources     = Taint.classifySources allSqlStmts allProcMetas
      allSinks       = Taint.classifySinks   allSqlStmts
      (tainted, prov) = Taint.propagateTaint allSources defs uses edges
      allPaths       = Taint.buildTaintPaths allSources allSinks prov
      allAnnotations = Taint.buildTaintAnnotations tainted allSources allSinks defs uses
  appendInterprocEdges   conn edges
  appendProcSummaries    conn summaries
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Taint analysis" :: Text)])
  appendTaintSources     conn allSources
  appendTaintSinks       conn allSinks
  appendTaintPaths       conn allPaths
  appendTaintAnnotations conn allAnnotations
  pure allRC

runPass8 :: DuckConn -> Map.Map Text Text -> [Taint.ResolvedCallRow] -> IO ()
runPass8 conn inh allRC = do
  emitProgress (object ["tag" .= ("step" :: Text), "label" .= ("Dead code detection" :: Text)])
  procs <- queryProcInfos   conn
  dws   <- queryDwObjectSet conn
  let rawCalls      = [ (Taint.rcrObject r, Taint.rcrFromProc r, lastName (Taint.rcrToName r))
                      | r <- allRC ]
      resolvedCalls = [ (Taint.rcrObject r, Taint.rcrFromProc r, o, p)
                      | r <- allRC
                      , Just o <- [Taint.rcrTargetObject r]
                      , Just p <- [Taint.rcrTargetProc   r]
                      ]
      dead = DeadCode.computeDeadProcedures
               procs rawCalls resolvedCalls (Map.toList inh) dws
  appendDeadCode conn dead
