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
  , catalogToRows
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
import PB.Analysis.GraphBuilder
  ( compileProcedureViaCatOp, compileProcedureToLowCat, collectWiring, WiringPayload (..) )
import PB.Analysis.DeadCode    qualified as DeadCode
import PB.Analysis.TypeEnv     (WorkspaceEnv (..), buildWorkspaceEnv, procEnv)
import PB.Analysis.Dataflow    qualified as Dataflow
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.SchemaCategory (splitColumnRef)
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
  ( SqlResult (..), ColumnRef (..), RowFilter (..), SqlBridgePool
  , TableRef (..), CatalogTable (..), CatalogPrimaryKey (..), CatalogForeignKey (..), SchemaCatalog (..)
  , startSqlBridgePool, shutdownSqlBridgePool
  , parseSql, parseDdl, extractBsRawNodes
  )
import PB.Pipeline.FileWalk    (walkAllSrFiles)
import PB.Pipeline.DuckDb
  ( DuckConn, withWriteConn, initSchema
  , ObjectRow (..), ProcRow (..), DwObjectRow (..), DwControlRow (..)
  , DwRetrieveTableRow (..), DwRetrieveColumnRow (..), DwJoinRow (..), SqlStmtRow (..)
  , SqlStmtColumnRow (..), SqlStmtFilterRow (..)
  , CatalogColumnRow (..), CatalogPkRow (..), CatalogFkRow (..)
  , SourceFileRow (..)
  , appendObjects, appendProcedures
  , appendDwObjects, appendDwControls, appendDwRetrieveTables, appendDwRetrieveColumns, appendDwJoins
  , appendLocalVars, appendCallSites, appendGlobalVars
  , appendProcDefs, appendProcUses, appendSqlStmts
  , appendSqlStmtColumns, appendSqlStmtFilters
  , appendCatalogColumns, appendCatalogPks, appendCatalogFks
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
  , cpsSqlStmtColumns :: [SqlStmtColumnRow]
  , cpsSqlStmtFilters :: [SqlStmtFilterRow]
  , cpsSourceContent :: Maybe SourceFileRow
  }

data CompiledDw = CompiledDw
  { cdDwObjectRow      :: DwObjectRow
  , cdDwControls       :: [DwControlRow]
  , cdDwRetrieveTables :: [DwRetrieveTableRow]
  , cdDwRetrieveColumns :: [DwRetrieveColumnRow]
  , cdDwJoins          :: [DwJoinRow]
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
                (wiringTerm, wiringShared) = collectWiring (compileProcedureToLowCat (mkProcEnv instrParams) userFns body)
                wiringJs = jsonText (toJSON (WiringPayload wiringTerm wiringShared))
                flow     = (fp, obj, pName, Dataflow.analyzeProcedure obj pName cfg)
                cyclo    = DeadCode.cyclomaticComplexity cfg
            in ( ProcRow fp obj pName pType sLine eLine cfgJs instrJs wiringJs
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
    (sqlRows, sqlColRows, sqlFilterRows) <- case mBridge of
      Nothing       ->
        -- No SQL bridge: extract raw SQL from BsRaw nodes (same as extractSqlStmts)
        pure (concatMap (rawSqlRow fp obj) procBodies, [], [])
      Just (pool,k) -> do
        triples <- mapM (extractProcSql pool k fp obj) procBodies
        pure ( concatMap (\(a,_,_) -> a) triples
             , concatMap (\(_,b,_) -> b) triples
             , concatMap (\(_,_,c) -> c) triples
             )
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
      , cpsSqlStmtColumns = sqlColRows
      , cpsSqlStmtFilters = sqlFilterRows
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
        rcols = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) ->
            [ DwRetrieveColumnRow fpT obj (trNamespace tref) (trTable tref) col
            | c <- drColumns r
            , Just (tref, col) <- [splitColumnRef c]
            ]
          _                     -> []
        jrows = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) ->
            [ DwJoinRow fpT obj (djLeft j) (djOp j) (djRight j) (djOuter1 j) (djOuter2 j)
            | j <- drJoins r ]
          _                     -> []
    pure $ CFDw $ CompiledDw
      { cdDwObjectRow      = DwObjectRow fpT obj style layoutJson retrieveSql
      , cdDwControls       = ctls
      , cdDwRetrieveTables = rtbls
      , cdDwRetrieveColumns = rcols
      , cdDwJoins          = jrows
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

extractProcSql
  :: SqlBridgePool -> Int -> Text -> Text -> (Text, [Located BodyStmt])
  -> IO ([SqlStmtRow], [SqlStmtColumnRow], [SqlStmtFilterRow])
extractProcSql pool k fp obj (pName, body) = do
  triples <- mapM parseNode (extractBsRawNodes body)
  pure ( map (\(row,_,_) -> row) triples
       , concatMap (\(_,cols,_) -> cols) triples
       , concatMap (\(_,_,filts) -> filts) triples
       )
  where
    parseNode (ln, rawTxt) = do
      res <- parseSql pool k rawTxt
      let row = SqlStmtRow fp obj pName ln
                  (srOperation res)
                  (T.intercalate "," (srTables res))
                  (T.intercalate "," (srColumns res))
                  rawTxt
                  (srParseOk res)
          colRows =
            [ SqlStmtColumnRow fp obj pName ln (crNamespace c) (crTable c) (crColumn c) (crIsWrite c)
            | c <- srColumnRefs res ]
          filterRows =
            [ SqlStmtFilterRow fp obj pName ln (rfNamespace f) (rfTable f) (rfColumn f) (rfOp f)
                (jsonText (toJSON (rfValues f)))
            | f <- srRowFilters res ]
      pure (row, colRows, filterRows)

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
  appendSqlStmtColumns conn (cpsSqlStmtColumns r)
  appendSqlStmtFilters conn (cpsSqlStmtFilters r)
  appendSourceFiles conn (catMaybes [cpsSourceContent r])
appendToDb conn (CFDw r) = do
  appendDwObjects        conn [cdDwObjectRow r]
  appendDwControls       conn (cdDwControls r)
  appendDwRetrieveTables conn (cdDwRetrieveTables r)
  appendDwRetrieveColumns conn (cdDwRetrieveColumns r)
  appendDwJoins          conn (cdDwJoins r)
  appendCallSites        conn (cdCallSites r)
  appendSourceFiles      conn (catMaybes [cdSourceContent r])
appendToDb conn (CFError fp err) =
  appendParseErrors conn [(fp, err)]
appendToDb _    CFSkip = pure ()

-- | Flatten a 'SchemaCatalog' into DuckDB's row-oriented catalog tables,
-- assigning positional ordinals (0-based) within each table/PK/FK group.
-- Composite FKs pair @fromColumns[i]@ with @toColumns[i]@ by position.
catalogToRows :: SchemaCatalog -> ([CatalogColumnRow], [CatalogPkRow], [CatalogFkRow])
catalogToRows cat =
  ( concatMap toColumnRows (scTables cat)
  , concatMap toPkRows (scPrimaryKeys cat)
  , concatMap toFkRows (scForeignKeys cat)
  )
  where
    toColumnRows (CatalogTable ref cols) =
      [ CatalogColumnRow (trNamespace ref) (trTable ref) c i | (i, c) <- zip [0 ..] cols ]
    toPkRows (CatalogPrimaryKey ref cols) =
      [ CatalogPkRow (trNamespace ref) (trTable ref) c i | (i, c) <- zip [0 ..] cols ]
    toFkRows (CatalogForeignKey mName fromRef fromCols toRef toCols) =
      [ CatalogFkRow mName (trNamespace fromRef) (trTable fromRef) fc
                     (trNamespace toRef) (trTable toRef) tc i
      | (i, fc, tc) <- zip3 [0 :: Int ..] fromCols toCols
      ]

runModeDb :: FilePath -> FilePath -> Maybe FilePath -> IO ()
runModeDb srcDir dbPath mDdlPath = do
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
        for_ mDdlPath $ \_ -> emitProgress (object
          [ "tag" .= ("warning" :: Text)
          , "message" .= ("--ddl given but PB_SQL_WORKER not set; skipping DDL ingestion" :: Text)
          ])
        -- N worker threads drain a shared queue; serialize DB writes through mutex.
        workQ <- newTQueueIO
        atomically (mapM_ (writeTQueue workQ) files)
        mutex <- newMVar ()
        mapConcurrently_
          (\k -> workerLoopFilesNoBridge k workQ wsEnv conn mutex errCount)
          [0 .. nWorkers - 1]
      Just bin -> do
        pool  <- startSqlBridgePool nWorkers bin
        for_ mDdlPath $ \ddlPath -> do
          ddlText <- readFile ddlPath
          catalog <- parseDdl pool "mysql" ddlText
          let (colRows, pkRows, fkRows) = catalogToRows catalog
          appendCatalogColumns conn colRows
          appendCatalogPks     conn pkRows
          appendCatalogFks     conn fkRows
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
