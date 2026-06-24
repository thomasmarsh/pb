{-# LANGUAGE StrictData #-}
module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  , wrapSrFile
  , runModeDb
  ) where

import PB.Prelude
import PB.AST.BodyStmt   (BodyStmt)
import PB.AST.DataWindow
import PB.AST.Located    (Located (..))
import PB.AST.SourceFile
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Grammar.File       (parseSrFileWithSpans, SrSpans (..))
import PB.Lexing.Lexer      (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Splitter   (Statement (..), splitStatements)
import PB.Pipeline.Preprocess  (LogicalLine (..), normalizeText, stripHeaders)
import PB.Pipeline.CfgBuild    (buildCfg)
import PB.Pipeline.CpsCompile  (compileProcedure)
import PB.Pipeline.DeadCode    qualified as DeadCode
import PB.Pipeline.TypeEnv     (TypeEnv (..), buildWorkspaceTypeEnv, withProcScope)
import PB.Pipeline.Dataflow    qualified as Dataflow
import PB.Pipeline.Taint       qualified as Taint
import PB.Pipeline.Serialise   ()

import Data.Aeson          (ToJSON (..), Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL
import Control.Concurrent.Async (mapConcurrently, mapConcurrently_)
import Control.Concurrent.MVar  (MVar, newMVar, withMVar)
import Control.Concurrent.QSem  (newQSem, waitQSem, signalQSem)
import Control.Concurrent.STM
  ( TQueue, atomically
  , newTQueueIO
  , writeTQueue, isEmptyTQueue, readTQueue
  )
import GHC.Conc   (getNumCapabilities)
import Control.Exception   (SomeException, try, finally, bracket_, evaluate)
import System.Environment  (lookupEnv)
import Data.Char           (intToDigit, toLower)
import Data.Either         (lefts)
import Data.Word           (Word8)
import qualified Data.Set           as Set
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.FilePath     (takeBaseName, takeExtension)
import PB.Pipeline.PbApi    (builtinFnNames, builtinMethodNames)
import PB.Pipeline.TypeResolve
  ( LocalVar, CallSite, GlobalVar (..)
  , extractCallSites, extractDwCallSites, extractGlobalVars, extractLocalVars
  , resolveTypes, resolveCalls
  , parseParams
  )
import qualified Data.Map.Strict as Map
import PB.Pipeline.SqlParse
  ( SqlResult (..), SqlBridgePool
  , startSqlBridgePool, shutdownSqlBridgePool
  , parseSql, extractBsRawNodes
  )
import PB.Pipeline.Walk    (walkAllSrFiles)
import PB.Pipeline.DuckDb
  ( DuckConn, withWriteConn, initSchema
  , ObjectRow (..), ProcRow (..), DwObjectRow (..), DwControlRow (..), SqlStmtRow (..)
  , SourceFileRow (..)
  , appendObjects, appendProcedures
  , appendDwObjects, appendDwControls
  , appendLocalVars, appendCallSites, appendGlobalVars
  , appendProcDefs, appendProcUses, appendSqlStmts
  , appendParseErrors, appendSourceFiles
  , queryLocalVars, queryCallSites, queryGlobalVars, queryObjInfo
  , queryProcDefs, queryProcUses, queryResolvedCalls
  , queryTaintInputs, queryProcInfos, queryDwObjectSet
  , appendResolvedTypes, appendResolvedCalls
  , appendInterprocEdges, appendProcSummaries
  , appendTaintSources, appendTaintSinks, appendTaintPaths
  , appendTaintAnnotations, appendDeadCode
  )

-- | Last dot-separated segment of a dotted name, e.g. "dw.setfocus" → "setfocus".
lastName :: Text -> Text
lastName t = T.takeWhileEnd (/= '.') t

-- ---------------------------------------------------------------------------
-- Entry point

runFile :: FilePath -> Text -> Either Text Value
runFile path src0 =
  let src = stripBom src0
  in case fileKind path of
    DataWindow  -> runDataWindow  path src
    Pipeline    -> runPipeline    path src
    Project     -> runProject     path src
    PowerScript -> runPowerScript path src

stripBom :: Text -> Text
stripBom t = fromMaybe t (T.stripPrefix "\xFEFF" t)

data FileKind = DataWindow | Pipeline | Project | PowerScript

fileKind :: FilePath -> FileKind
fileKind fp = case map toLower (takeExtension fp) of
  ".srd" -> DataWindow
  ".srp" -> Pipeline
  ".srj" -> Project
  _      -> PowerScript

-- ---------------------------------------------------------------------------
-- DataWindow

runDataWindow :: FilePath -> Text -> Either Text Value
runDataWindow path src = fmap (wrapDwFile path) (parseDataWindow src)

wrapDwFile :: FilePath -> DataWindowFile -> Value
wrapDwFile path dw = case toJSON dw of
  Object o -> Object (KM.fromList
    [ "file" .= path
    , "kind" .= ("datawindow" :: Text)
    , "meta" .= object
        [ "object"   .= T.pack (takeBaseName path)
        , "ancestor" .= (Nothing :: Maybe Text)
        ]
    ] <> o)
  v        -> v

runPipeline :: FilePath -> Text -> Either Text Value
runPipeline path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("pipeline" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

runProject :: FilePath -> Text -> Either Text Value
runProject path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("project" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

-- ---------------------------------------------------------------------------
-- PowerScript pipeline

runPowerScript :: FilePath -> Text -> Either Text Value
runPowerScript path src = do
  (srFile, spans) <- parsePowerScriptFile src
  let wsEnv = buildWorkspaceTypeEnv [srFile]
  Right (wrapSrFile False path srFile spans wsEnv)

-- | Parse PowerScript source text to (SrFile, SrSpans).
parsePowerScriptFile :: Text -> Either Text (SrFile, SrSpans)
parsePowerScriptFile src = do
  let logicalLines         = normalizeText src
      (headers, bodyLines) = stripHeaders logicalLines
      lexLines             = tokenize bodyLines
  stmts <- collectStatements lexLines
  parseSrFileWithSpans headers stmts

wrapSrFile :: Bool -> FilePath -> SrFile -> SrSpans -> TypeEnv -> Value
wrapSrFile withCps path sf spans wsEnv =
    let (objName, ancestor) = case srTypeBlocks sf of
          (tb:_) -> (tdName (tbDecl tb), Just (tdAncestor (tbDecl tb)))
          []     -> (T.pack path, Nothing)

        -- Per-procedure env: overlay parsed params on the workspace env.
        procEnv :: Text -> TypeEnv
        procEnv paramsText = withProcScope (parseParams paramsText) wsEnv

        -- User-defined function names (lower-cased) for CPS callproc dispatch.
        userFns :: Set.Set Text
        userFns = Set.fromList
          $  map (T.toLower . fnsName . fbSig) (srFunctions  sf)
          <> map (T.toLower . ssName  . sbSig) (srSubroutines sf)

        injectMeta :: (Int, Int) -> Value -> Value
        injectMeta (start, end) (Object o) =
            Object (KM.fromList ["meta" .= metaVal] <> o)
          where metaVal = object
                  [ "file"      .= T.pack path
                  , "object"    .= objName
                  , "ancestor"  .= ancestor
                  , "startLine" .= start
                  , "endLine"   .= end
                  ]
        injectMeta _ v = v

        injectCompiled env body (Object o) =
            let cfg = buildCfg body
                base = KM.insert "cfg" (toJSON cfg) o
            in Object $ if withCps
                then KM.insert "cpsGraph" (toJSON (compileProcedure env userFns body)) base
                else base
        injectCompiled _ _ v = v

        injectAll env body sp v =
            injectCompiled env body (injectMeta sp v)

    in object
        [ "file"            .= path
        , "kind"            .= ("powerscript" :: Text)
        , "meta"            .= object ["object" .= objName, "ancestor" .= ancestor]
        , "headers"         .= srHeaders sf
        , "forward"         .= srForward sf
        , "prototypes"      .= srPrototypes sf
        , "variables"       .= srVariables sf
        , "globalInstances" .= srGlobalInstances sf
        , "typeBlocks"      .= srTypeBlocks sf
        , "onBlocks"    .= [ injectAll wsEnv                             (obBody ob) sp (toJSON ob)
                           | (sp, ob) <- zip (spOnBlocks    spans) (srOnBlocks    sf) ]
        , "events"      .= [ injectAll wsEnv                             (evBody ev) sp (toJSON ev)
                           | (sp, ev) <- zip (spEvents      spans) (srEvents      sf) ]
        , "functions"   .= [ injectAll (procEnv (fnsParams (fbSig fn))) (fbBody fn) sp (toJSON fn)
                           | (sp, fn) <- zip (spFunctions   spans) (srFunctions   sf) ]
        , "subroutines" .= [ injectAll (procEnv (ssParams  (sbSig sb))) (sbBody sb) sp (toJSON sb)
                           | (sp, sb) <- zip (spSubroutines spans) (srSubroutines sf) ]
        ]

-- | Convert lex results to statements, failing on the first lex error.
--   Empty-token statements (blank lines) are filtered out so the grammar
--   parser's eof succeeds on trailing whitespace.
collectStatements :: [LexLine] -> Either Text [Statement]
collectStatements lexLines =
  let results = splitStatements lexLines
  in case lefts results of
    (e : _) -> Left (formatLexErr e)
    []      -> Right [s | Right s <- results, not (null (stmtTokens s))]

-- | Human-readable lex error: line span, unexpected char, content, xxd hex dump.
formatLexErr :: LexError -> Text
formatLexErr e =
  let ll    = leSource e
      off   = leOffset e
      raw   = llText ll
      bytes = BS.unpack (TE.encodeUtf8 raw)
      lineSpan
        | llStartLine ll == llEndLine ll =
            "line "  <> T.pack (show (llStartLine ll))
        | otherwise =
            "lines " <> T.pack (show (llStartLine ll))
                     <> "-" <> T.pack (show (llEndLine ll))
      badChar
        | off < T.length raw =
            let c  = T.index raw off
                cp = fromEnum c
                repr = if c >= ' ' && c <= '~' then " '" <> T.singleton c <> "'" else ""
            in "\n  unexpected char at offset " <> T.pack (show off)
               <> ": 0x" <> T.pack (map intToDigit [cp `div` 16, cp `mod` 16])
               <> repr
        | otherwise = ""
  in "lex error at " <> lineSpan <> ":"
  <> "\n  content: " <> T.take 120 raw
  <> badChar
  <> "\n" <> T.intercalate "\n" (xxdDump bytes)

xxdDump :: [Word8] -> [Text]
xxdDump = go 0
  where
    go _    [] = []
    go addr bs = fmtXxdRow addr (take 16 bs) : go (addr + 16) (drop 16 bs)

fmtXxdRow :: Int -> [Word8] -> Text
fmtXxdRow addr bs =
  "  " <> fmtHexAddr addr <> ": " <> fmtHexSection bs <> "  " <> T.pack (map asciiOf bs)

fmtHexAddr :: Int -> Text
fmtHexAddr n =
  T.pack [intToDigit ((n `div` d) `mod` 16) | d <- [268435456, 16777216, 1048576, 65536, 4096, 256, 16, 1]]

fmtHexSection :: [Word8] -> Text
fmtHexSection bs = t <> T.replicate (max 0 (40 - T.length t)) " "
  where
    pairs  = toPairs bs
    nPairs = length pairs
    t      = T.concat (zipWith mkPair [0 ..] pairs)
    mkPair i pair =
      let hex = T.concat [T.pack [intToDigit (fromIntegral b `div` 16), intToDigit (fromIntegral b `mod` 16)] | b <- pair]
          sep | i == nPairs - 1 = ""
              | i == 3          = "  "
              | otherwise       = " "
      in hex <> sep
    toPairs []       = []
    toPairs [x]      = [[x]]
    toPairs (x:y:zs) = [x, y] : toPairs zs

asciiOf :: Word8 -> Char
asciiOf b
  | b >= 0x20 && b <= 0x7e = toEnum (fromIntegral b)
  | otherwise               = '.'

-- ---------------------------------------------------------------------------
-- Per-file parse outcome

data ParsedFile = ParsedFile
  { pfPath     :: FilePath
  , pfSrFile   :: SrFile
  , pfSpans    :: SrSpans
  , pfContents :: Text
  }

data ParseOutcome
  = PsParsed ParsedFile
  | PsDw     FilePath Text DataWindowFile
  | PsFailed FilePath Text
  | OtherFile FilePath

-- | Attempt to parse one file.
parseOutcome :: FilePath -> IO ParseOutcome
parseOutcome src = case fileKind src of
  PowerScript -> do
    readResult <- try (readFile src) :: IO (Either SomeException Text)
    pure $ case readResult of
      Left  ex -> PsFailed src (T.pack (show ex))
      Right contents ->
        case parsePowerScriptFile (stripBom contents) of
          Left  err      -> PsFailed src err
          Right (sf, sp) -> PsParsed (ParsedFile src sf sp contents)
  DataWindow -> do
    readResult <- try (readFile src) :: IO (Either SomeException Text)
    pure $ case readResult of
      Left  ex       -> PsFailed src (T.pack (show ex))
      Right contents -> case parseDataWindow (stripBom contents) of
        Left  err -> PsFailed src err
        Right dw  -> PsDw src contents dw
  _ -> pure (OtherFile src)

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
  { cdDwObjectRow    :: DwObjectRow
  , cdDwControls     :: [DwControlRow]
  , cdCallSites      :: [CallSite]
  , cdSourceContent  :: Maybe SourceFileRow
  }

data CompiledFile
  = CFPs    CompiledPs
  | CFDw    CompiledDw
  | CFError FilePath Text
  | CFSkip

compileOne :: TypeEnv -> Maybe (SqlBridgePool, Int) -> ParseOutcome -> IO CompiledFile
compileOne wsEnv mBridge outcome = case outcome of

  PsParsed pf -> do
    let sf   = pfSrFile pf
        sp   = pfSpans  pf
        fp   = T.pack (pfPath pf)
        obj  = case srTypeBlocks sf of
                 (tb:_) -> tdName (tbDecl tb)
                 []     -> ""
        anc  = case srTypeBlocks sf of
                 (tb:_) -> Just (tdAncestor (tbDecl tb))
                 []     -> Nothing
        userFns = Set.fromList
          $  map (T.toLower . fnsName . fbSig) (srFunctions  sf)
          <> map (T.toLower . ssName  . sbSig) (srSubroutines sf)
        procEnv params = withProcScope (parseParams params) wsEnv
        lvs  = extractLocalVars  fp obj sf
        css  = extractCallSites  fp obj sf
        gvs  = extractGlobalVars fp obj sf
        procs =
          [ let cfg      = buildCfg body
                cfgJs    = jsonText (toJSON cfg)
                cpsJs    = jsonText (toJSON (compileProcedure (procEnv cpsParams) userFns body))
                flow     = (fp, obj, pName, Dataflow.analyzeProcedure obj pName cfg)
                cyclo    = DeadCode.cyclomaticComplexity cfg
            in ( ProcRow fp obj pName pType sLine eLine cfgJs cpsJs
                   taintParams retType (Just cyclo)
               , flow )
          | ((sLine, eLine), (pName, pType, cpsParams, taintParams, retType, body)) <-
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
    pure $ CFDw $ CompiledDw
      { cdDwObjectRow   = DwObjectRow fpT obj style layoutJson
      , cdDwControls    = ctls
      , cdCallSites     = css
      , cdSourceContent = Just (SourceFileRow fpT contents)
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

-- | Parse SQL from one procedure's BsRaw nodes via the bridge pool slot k.
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

-- | Worker thread k: drains FilePaths from workQ, parses and compiles each with bridge slot k,
--   serialises DB writes through a shared mutex (DuckDB connections are not thread-safe).
workerLoopFiles :: Int -> TQueue FilePath -> SqlBridgePool -> TypeEnv -> DuckConn -> MVar () -> IO ()
workerLoopFiles k workQ pool wsEnv conn mutex = go
  where
    go = do
      mFile <- atomically $ do
        empty <- isEmptyTQueue workQ
        if empty then pure Nothing else Just <$> readTQueue workQ
      case mFile of
        Nothing   -> pure ()
        Just file -> do
          outcome  <- parseOutcome file
          compiled <- compileOne wsEnv (Just (pool, k)) outcome
          withMVar mutex $ \_ -> appendToDb conn compiled
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
  appendDwObjects   conn [cdDwObjectRow r]
  appendDwControls conn (cdDwControls r)
  appendCallSites   conn (cdCallSites r)
  appendSourceFiles conn (catMaybes [cdSourceContent r])
appendToDb conn (CFError fp err) =
  appendParseErrors conn [(fp, err)]
appendToDb _    CFSkip = pure ()

runModeDb :: FilePath -> FilePath -> IO ()
runModeDb srcDir dbPath = do
  files <- walkAllSrFiles srcDir

  -- Phase A0: parse all files to build workspace TypeEnv, then discard SrFiles.
  outcomes0 <- mapConcurrently parseOutcome files
  let wsEnv = buildWorkspaceTypeEnv [pfSrFile pf | PsParsed pf <- outcomes0]
  _ <- evaluate (Map.size (teVars wsEnv) + Map.size (teUserTypes wsEnv))
  -- outcomes0 and all SrFiles are now GC-eligible.

  mBridgeBin <- lookupEnv "PB_SQL_WORKER"
  nWorkers   <- getNumCapabilities

  withWriteConn dbPath $ \conn -> do
    initSchema conn
    case mBridgeBin of
      Nothing -> do
        -- Re-parse each file with bounded concurrency (32 in-flight); serialize DB writes.
        sem   <- newQSem 32
        mutex <- newMVar ()
        mapConcurrently_ (\file ->
          bracket_ (waitQSem sem) (signalQSem sem) $ do
            outcome  <- parseOutcome file
            compiled <- compileOne wsEnv Nothing outcome
            withMVar mutex $ \_ -> appendToDb conn compiled
          ) files
      Just bin -> do
        pool  <- startSqlBridgePool nWorkers bin
        workQ <- newTQueueIO
        atomically (mapM_ (writeTQueue workQ) files)
        mutex <- newMVar ()
        mapConcurrently_
          (\k -> workerLoopFiles k workQ pool wsEnv conn mutex)
          [0 .. nWorkers - 1]
          `finally` shutdownSqlBridgePool pool
    runPhaseB conn  -- Phase B: link analysis (passes 5–8)

-- | Phase B: read Phase A tables from DuckDB, run link analysis, write results.
-- Runs sequentially after Phase A is complete. Split into three functions so
-- each pass's bindings go out of scope (and are GC-eligible) before the next.
runPhaseB :: DuckConn -> IO ()
runPhaseB conn = do
  inh   <- runPass5  conn
  allRC <- runPass67 conn
  runPass8 conn inh allRC

runPass5 :: DuckConn -> IO (Map.Map Text Text)
runPass5 conn = do
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
  appendTaintSources     conn allSources
  appendTaintSinks       conn allSinks
  appendTaintPaths       conn allPaths
  appendTaintAnnotations conn allAnnotations
  pure allRC

runPass8 :: DuckConn -> Map.Map Text Text -> [Taint.ResolvedCallRow] -> IO ()
runPass8 conn inh allRC = do
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
