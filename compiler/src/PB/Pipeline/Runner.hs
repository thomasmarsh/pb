{-# LANGUAGE StrictData #-}
module PB.Pipeline.Runner
  ( -- re-exports from Emit
    runFile
  , collectStatements
  , wrapSrFile
  , extractWindowLayout
  , reconstructRetrieveSql
    -- own
  , runModeDb
  , compileOne
  , appendToDb
  , CompiledFile (..)
  , CompiledPs (..)
  , CompiledDw (..)
  ) where

import PB.Prelude
import PB.AST.BodyStmt   (BodyStmt (..))
import PB.AST.DataWindow
import PB.AST.Located    (Located (..))
import PB.AST.SourceFile
import PB.Grammar.File       (SrSpans (..))
import PB.Analysis.Cfg    (buildCfg)
import PB.Analysis.GraphBuilder (compileProcedureViaCatOp)
import PB.Analysis.DeadCode    qualified as DeadCode
import PB.Analysis.TypeEnv     (WorkspaceEnv (..), buildWorkspaceEnv, procEnv)
import PB.Analysis.Dataflow    qualified as Dataflow
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.TypeResolve
  ( LocalVar, CallSite, GlobalVar (..)
  , extractCallSites, extractDwCallSites, extractGlobalVars, extractLocalVars
  , parseParams
  )
import PB.Pipeline.Emit
  ( runFile, ParsedFile (..), ParseOutcome (..)
  , parseOutcome
  , extractWindowLayout, reconstructRetrieveSql, collectStatements
  , wrapSrFile
  )
import PB.Runtime.StdLib (parseStdlibFiles)
import PB.Pipeline.Passes    (runPhaseB)
import PB.Pipeline.Serialise ()
import PB.Pipeline.SqlParse
  ( SqlResult (..), SqlBridgePool
  , startSqlBridgePool, shutdownSqlBridgePool
  , parseSql, extractBsRawNodes
  )
import PB.Pipeline.FileWalk    (walkAllSrFiles)
import PB.Pipeline.DuckDb
  ( DuckConn, withWriteConn, initSchema
  , ObjectRow (..), ProcRow (..), DwObjectRow (..), DwControlRow (..)
  , DwRetrieveTableRow (..), SqlStmtRow (..)
  , SourceFileRow (..)
  , appendObjects, appendProcedures
  , appendDwObjects, appendDwControls, appendDwRetrieveTables
  , appendLocalVars, appendCallSites, appendGlobalVars
  , appendProcDefs, appendProcUses, appendSqlStmts
  , appendParseErrors, appendSourceFiles
  )

import Data.Aeson          (ToJSON (..), Value (..), encode, object, toJSON, (.=))
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL
import Control.Concurrent.Async (mapConcurrently, mapConcurrently_)
import Control.Concurrent.MVar  (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  ( TQueue, atomically
  , newTQueueIO
  , writeTQueue, isEmptyTQueue, readTQueue
  )
import GHC.Conc   (getNumCapabilities)
import Control.Exception   (finally, evaluate)
import System.Environment  (lookupEnv)
import System.IO           (hFlush, stderr)
import Data.IORef          (IORef, newIORef, readIORef, atomicModifyIORef')
import qualified Data.Set           as Set
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.FilePath     (takeBaseName)
import qualified Data.Map.Strict as Map

-- | Emit a single JSON progress event to stderr for the Python reporter.
emitProgress :: Value -> IO ()
emitProgress v = do
  BS.hPut stderr (BSL.toStrict (encode v) <> "\n")
  hFlush stderr

-- ---------------------------------------------------------------------------
-- DuckDB streaming mode
--
-- runModeDb srcDir dbPath:
--   Phase A0 — parse all files concurrently → build workspace TypeEnv
--   Phase A  — compile each file with TypeEnv → append rows to DuckDB
--   Phase B  — link analysis (passes 5–8) entirely within DuckDB

data CompiledPs = CompiledPs
  { cpsObjectRow     :: ObjectRow
  , cpsProcRows      :: [ProcRow]
  , cpsLocalVars     :: [LocalVar]
  , cpsCallSites     :: [CallSite]
  , cpsGlobalVars    :: [GlobalVar]
  , cpsProcFlows     :: [(Text, Text, Text, Dataflow.ProcFlow)]
  , cpsSqlStmts      :: [SqlStmtRow]
  , cpsSourceContent :: Maybe SourceFileRow
  }

data CompiledDw = CompiledDw
  { cdDwObjectRow      :: DwObjectRow
  , cdDwControls       :: [DwControlRow]
  , cdDwRetrieveTables :: [DwRetrieveTableRow]
  , cdCallSites        :: [CallSite]
  , cdSourceContent    :: Maybe SourceFileRow
  }

data CompiledFile
  = CFPs    CompiledPs
  | CFDw    CompiledDw
  | CFError FilePath Text
  | CFSkip

compileOne :: WorkspaceEnv -> Maybe (SqlBridgePool, Int) -> Text -> ParseOutcome -> IO CompiledFile
compileOne wsEnv mBridge confidence outcome = case outcome of

  PsParsed pf -> do
    let sf   = pfSrFile pf
        sp   = pfSpans  pf
        fp   = T.pack (pfPath pf)
        (obj, anc) = srPrimaryObject sf
        userFns = Set.fromList
          $  map (T.toLower . fnsName . fbSig) (srFunctions  sf)
          <> map (T.toLower . ssName  . sbSig) (srSubroutines sf)
        mkProcEnv params = procEnv wsEnv obj (parseParams params)
        lvs  = extractLocalVars  fp obj sf
        css  = extractCallSites  fp obj sf
        gvs  = extractGlobalVars fp obj sf
        procs =
          [ let cfg      = buildCfg body
                cfgJs    = jsonText (toJSON cfg)
                instrJs    = jsonText (toJSON (compileProcedureViaCatOp (mkProcEnv instrParams) userFns body))
                flow     = (fp, obj, pName, Dataflow.analyzeProcedure obj pName cfg)
                cyclo    = DeadCode.cyclomaticComplexity cfg
            in ( ProcRow fp obj pName pType sLine eLine cfgJs instrJs
                   taintParams retType (Just cyclo) confidence
               , flow )
          | ((sLine, eLine), (pName, pType, instrParams, taintParams, retType, body)) <-
              zip (spFunctions   sp) [ (fnsName (fbSig fb), "function",   fnsParams (fbSig fb), fnsParams    (fbSig fb), fnsReturnType (fbSig fb), fbBody fb) | fb <- srFunctions   sf ]
              <>
              zip (spSubroutines sp) [ (ssName  (sbSig sb), "subroutine", ssParams  (sbSig sb), ssParams     (sbSig sb), "",                       sbBody sb) | sb <- srSubroutines sf ]
              <>
              zip (spEvents      sp) [ (esName  (evSig ev), "event",      "",                   esRawSig     (evSig ev), "",                       evBody ev) | ev <- srEvents      sf ]
              <>
              zip (spOnBlocks    sp) [ (obEvent ob,         "on",         "",                   "",                      "",                       obBody ob) | ob <- srOnBlocks    sf ]
          ]
        procBodies =
             [ (fnsName (fbSig fb), fbBody fb) | fb <- srFunctions   sf ]
          <> [ (ssName  (sbSig sb), sbBody sb) | sb <- srSubroutines sf ]
          <> [ (esName  (evSig ev), evBody ev) | ev <- srEvents      sf ]
          <> [ (obEvent ob,         obBody ob) | ob <- srOnBlocks    sf ]
    sqlRows <- case mBridge of
      Nothing       ->
        -- No SQL bridge: extract raw SQL from BsRaw nodes (same as extractSqlStmts)
        pure $ concatMap (rawSqlRow fp obj) procBodies
      Just (pool,k) ->
        fmap concat $ mapM (extractProcSql pool k fp obj) procBodies
    pure $ CFPs $ CompiledPs
      { cpsObjectRow     = ObjectRow fp "powerscript" obj anc
                             (fmap jsonText (extractWindowLayout (srTypeBlocks sf)))
                             (Just (jsonText (toJSON (srTypeBlocks sf))))
                             confidence
      , cpsProcRows      = map fst procs
      , cpsLocalVars     = lvs
      , cpsCallSites     = css
      , cpsGlobalVars    = gvs
      , cpsProcFlows     = map snd procs
      , cpsSqlStmts      = sqlRows
      , cpsSourceContent = Just (SourceFileRow fp (pfContents pf))
      }

  PsDw fp contents dw -> do
    let obj        = T.pack (takeBaseName fp)
        fpT        = T.pack fp
        style      = Map.findWithDefault "" "style" (doaAttrs (dwObject dw))
        layoutJson = jsonText (toJSON dw)
        ctls  = [ DwControlRow fpT obj (renderBandKind (dwcBand c))
                    (dwcType c)
                    (fromMaybe "" (dwcName c))
                    (dwcX c) (dwcY c) (dwcWidth c) (dwcHeight c)
                    (dwcExpression c)
                | c <- dwControls dw ]
        css   = extractDwCallSites fpT obj dw
        retrieveSql = fmap reconstructRetrieveSql (dwTable dw >>= dtRetrieve)
        rtbls = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) -> [ DwRetrieveTableRow fpT obj t | t <- drTables r ]
          _                     -> []
    pure $ CFDw $ CompiledDw
      { cdDwObjectRow      = DwObjectRow fpT obj style layoutJson retrieveSql
      , cdDwControls       = ctls
      , cdDwRetrieveTables = rtbls
      , cdCallSites        = css
      , cdSourceContent    = Just (SourceFileRow fpT contents)
      }

  PsFailed fp err -> pure $ CFError fp err
  OtherFile _     -> pure CFSkip

renderBandKind :: Maybe DwBandKind -> Text
renderBandKind Nothing               = ""
renderBandKind (Just BkHeader)       = "header"
renderBandKind (Just BkDetail)       = "detail"
renderBandKind (Just BkFooter)       = "footer"
renderBandKind (Just BkSummary)      = "summary"
renderBandKind (Just BkBackground)   = "background"
renderBandKind (Just BkForeground)   = "foreground"
renderBandKind (Just (BkGroupHeader n)) = "group_header_" <> T.pack (show n)
renderBandKind (Just (BkGroupTrailer n)) = "group_trailer_" <> T.pack (show n)
renderBandKind (Just (BkTreeLevel n))  = "tree_level_" <> T.pack (show n)

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BSL.toStrict . encode

-- | Build SqlStmtRows from BsRaw nodes without a SQL bridge (no tables/columns).
rawSqlRow :: Text -> Text -> (Text, [Located BodyStmt]) -> [SqlStmtRow]
rawSqlRow fpT obj (pName, body) =
  [ SqlStmtRow fpT obj pName ln (Just op) "" "" rawTxt False
  | (ln, rawTxt) <- extractBsRawNodes body
  , let op = Taint.classifyOperation rawTxt
  , not (T.null op)
  , op `Set.notMember` _skipOps
  ]
  where
    _skipOps = Set.fromList
      ["DECLARE","OPEN","FETCH","CLOSE","COMMIT","ROLLBACK","CONNECT","DISCONNECT"]

extractProcSql :: SqlBridgePool -> Int -> Text -> Text -> (Text, [Located BodyStmt]) -> IO [SqlStmtRow]
extractProcSql pool k fp obj (pName, body) =
  mapM parseNode (extractBsRawNodes body)
  where
    parseNode (ln, rawTxt) = do
      res <- parseSql pool k rawTxt
      pure $ SqlStmtRow fp obj pName ln
               (srOperation res)
               (T.intercalate "," (srTables res))
               (T.intercalate "," (srColumns res))
               rawTxt
               (srParseOk res)

-- | Worker thread k: drains FilePaths from workQ, parses and compiles each without a SQL bridge.
workerLoopFilesNoBridge :: Int -> TQueue FilePath -> WorkspaceEnv -> DuckConn -> MVar () -> IORef Int -> IO ()
workerLoopFilesNoBridge k workQ wsEnv conn mutex errCount = go
  where
    go = do
      mFile <- atomically $ do
        empty <- isEmptyTQueue workQ
        if empty then pure Nothing else Just <$> readTQueue workQ
      case mFile of
        Nothing   -> pure ()
        Just file -> do
          let fp = T.pack file
          emitProgress (object ["tag" .= ("worker_start" :: Text), "worker" .= k, "file" .= fp])
          outcome  <- parseOutcome file
          compiled <- compileOne wsEnv Nothing "confirmed" outcome
          let ok = case compiled of { CFError {} -> False; _ -> True }
          when (not ok) $ atomicModifyIORef' errCount (\n -> (n + 1, ()))
          withMVar mutex $ \_ -> appendToDb conn compiled
          emitProgress (object ["tag" .= ("worker_done" :: Text), "worker" .= k, "file" .= fp, "ok" .= ok])
          go

-- | Worker thread k: drains FilePaths from workQ, parses and compiles each with bridge slot k,
--   serialises DB writes through a shared mutex (DuckDB connections are not thread-safe).
workerLoopFiles :: Int -> TQueue FilePath -> SqlBridgePool -> WorkspaceEnv -> DuckConn -> MVar () -> IORef Int -> IO ()
workerLoopFiles k workQ pool wsEnv conn mutex errCount = go
  where
    go = do
      mFile <- atomically $ do
        empty <- isEmptyTQueue workQ
        if empty then pure Nothing else Just <$> readTQueue workQ
      case mFile of
        Nothing   -> pure ()
        Just file -> do
          let fp = T.pack file
          emitProgress (object ["tag" .= ("worker_start" :: Text), "worker" .= k, "file" .= fp])
          outcome  <- parseOutcome file
          compiled <- compileOne wsEnv (Just (pool, k)) "confirmed" outcome
          let ok = case compiled of { CFError {} -> False; _ -> True }
          when (not ok) $ atomicModifyIORef' errCount (\n -> (n + 1, ()))
          withMVar mutex $ \_ -> appendToDb conn compiled
          emitProgress (object ["tag" .= ("worker_done" :: Text), "worker" .= k, "file" .= fp, "ok" .= ok])
          go

appendToDb :: DuckConn -> CompiledFile -> IO ()
appendToDb conn (CFPs r) = do
  appendObjects    conn [cpsObjectRow r]
  appendProcedures conn (cpsProcRows r)
  appendLocalVars  conn (cpsLocalVars r)
  appendCallSites  conn (cpsCallSites r)
  appendGlobalVars conn (cpsGlobalVars r)
  appendProcDefs   conn (cpsProcFlows r)
  appendProcUses   conn (cpsProcFlows r)
  appendSqlStmts   conn (cpsSqlStmts r)
  appendSourceFiles conn (catMaybes [cpsSourceContent r])
appendToDb conn (CFDw r) = do
  appendDwObjects        conn [cdDwObjectRow r]
  appendDwControls       conn (cdDwControls r)
  appendDwRetrieveTables conn (cdDwRetrieveTables r)
  appendCallSites        conn (cdCallSites r)
  appendSourceFiles      conn (catMaybes [cdSourceContent r])
appendToDb conn (CFError fp err) =
  appendParseErrors conn [(fp, err)]
appendToDb _    CFSkip = pure ()

runModeDb :: FilePath -> FilePath -> IO ()
runModeDb srcDir dbPath = do
  files <- walkAllSrFiles srcDir
  let total = length files
  emitProgress (object ["tag" .= ("total" :: Text), "n" .= total])

  -- Phase A0: parse stdlib + all user files to build workspace TypeEnv.
  stdlibParsed <- parseStdlibFiles
  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("A0" :: Text), "total" .= total])
  outcomes0 <- mapConcurrently (\file -> do
    outcome <- parseOutcome file
    emitProgress (object ["tag" .= ("file_done" :: Text), "phase" .= ("A0" :: Text)])
    pure outcome) files
  let wsEnv = buildWorkspaceEnv
                (map pfSrFile stdlibParsed ++ [pfSrFile pf | PsParsed pf <- outcomes0])
  _ <- evaluate (Map.size (weGlobals wsEnv) + Map.size (weHierarchy wsEnv))

  mBridgeBin <- lookupEnv "PB_SQL_WORKER"
  nWorkers   <- getNumCapabilities
  errCount   <- newIORef (0 :: Int)

  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("A" :: Text), "workers" .= nWorkers, "total" .= total])

  withWriteConn dbPath $ \conn -> do
    initSchema conn
    -- Load stdlib first so type lookups in user-code Phase B see the base classes.
    mapM_ (\pf -> do
      cf <- compileOne wsEnv Nothing "speculative" (PsParsed pf)
      appendToDb conn cf) stdlibParsed
    case mBridgeBin of
      Nothing -> do
        -- N worker threads drain a shared queue; serialize DB writes through mutex.
        workQ <- newTQueueIO
        atomically (mapM_ (writeTQueue workQ) files)
        mutex <- newMVar ()
        mapConcurrently_
          (\k -> workerLoopFilesNoBridge k workQ wsEnv conn mutex errCount)
          [0 .. nWorkers - 1]
      Just bin -> do
        pool  <- startSqlBridgePool nWorkers bin
        workQ <- newTQueueIO
        atomically (mapM_ (writeTQueue workQ) files)
        mutex <- newMVar ()
        mapConcurrently_
          (\k -> workerLoopFiles k workQ pool wsEnv conn mutex errCount)
          [0 .. nWorkers - 1]
          `finally` shutdownSqlBridgePool pool
    runPhaseB conn  -- Phase B: link analysis (passes 5–8)

  errors <- readIORef errCount
  emitProgress (object ["tag" .= ("done" :: Text), "parsed" .= (total - errors), "errors" .= errors])
