module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  , wrapSrFile
  , runModeFiles
  , runModeJsonl
  , writeDataflowAnalysis
  , writeTaintAnalysis
  , ManifestEntry (..)
  , manifestEntry
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
import PB.Pipeline.PrettyPrint (prettyBodyStmts)
import PB.Pipeline.CfgBuild    (buildCfg)
import PB.Pipeline.CpsCompile  (compileProcedure)
import PB.Pipeline.TypeEnv     (TypeEnv, buildWorkspaceTypeEnv, withProcScope)
import PB.Pipeline.Dataflow    qualified as Dataflow
import PB.Pipeline.Taint       qualified as Taint
import PB.Pipeline.Serialise   ()

import Data.Aeson          (FromJSON (..), ToJSON (..), Value (..), eitherDecodeFileStrict'
                           , encode, object, toJSON, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL
import Control.Exception   (SomeException, try)
import Data.Char           (intToDigit, toLower)
import Data.Either         (lefts)
import Data.Word           (Word8)
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.Directory    (createDirectoryIfMissing, doesFileExist)
import System.FilePath     (makeRelative, takeBaseName, takeDirectory
                           , takeExtension, (</>))
import PB.Pipeline.PbApi    (builtinFnNames, builtinMethodNames)
import PB.Pipeline.TypeResolve
  ( buildInheritsMap, buildObjectSet, buildProcMap, buildUserTypeSet
  , extractCallSites, extractGlobalVars, extractLocalVars
  , resolveTypes, resolveCalls
  , parseParams
  )
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import PB.Pipeline.Walk    (walkAllSrFiles)

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
  Right (wrapSrFile path srFile spans wsEnv)

-- | Parse PowerScript source text to (SrFile, SrSpans).
parsePowerScriptFile :: Text -> Either Text (SrFile, SrSpans)
parsePowerScriptFile src = do
  let logicalLines         = normalizeText src
      (headers, bodyLines) = stripHeaders logicalLines
      lexLines             = tokenize bodyLines
  stmts <- collectStatements lexLines
  parseSrFileWithSpans headers stmts

wrapSrFile :: FilePath -> SrFile -> SrSpans -> TypeEnv -> Value
wrapSrFile path sf spans wsEnv =
    let (objName, ancestor) = case srTypeBlocks sf of
          (tb:_) -> (tdName (tbDecl tb), Just (tdAncestor (tbDecl tb)))
          []     -> (T.pack path, Nothing)

        -- Per-procedure env: overlay parsed params on the workspace env.
        procEnv :: Text -> TypeEnv
        procEnv paramsText = withProcScope (parseParams paramsText) wsEnv

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

        injectRendered body (Object o) =
            Object (KM.insert "source_rendered" (toJSON (prettyBodyStmts body)) o)
        injectRendered _ v = v

        injectCompiled env body (Object o) =
            Object
              $ KM.insert "cfg"      (toJSON (buildCfg body))
              $ KM.insert "dataflow" (toJSON (dataflowProcFlow objName body))
              $ KM.insert "cpsGraph" (toJSON (compileProcedure env body))
              $ o
        injectCompiled _ _ v = v

        -- 111d-1: per-procedure dataflow facet. objName comes from the
        -- enclosing wrapSrFile scope; the proc name is omitted (the consumer
        -- adds file/object/proc_name from the parent procedures row). This
        -- facet is the streaming-mode delivery channel — pb index runs
        -- pb-runner --jsonl (runModeJsonl) which never calls writeDataflowAnalysis.
        dataflowProcFlow obj body =
            Dataflow.dataflowFacet (Dataflow.analyzeProcedure obj "" (buildCfg body))

        injectAll env body sp v =
            injectCompiled env body (injectRendered body (injectMeta sp v))

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
-- Manifest

data ManifestEntry = ManifestEntry
  { meFile     :: Text
  , meKind     :: Text
  , meObject   :: Text
  , meAncestor :: Maybe Text
  }

instance ToJSON ManifestEntry where
  toJSON e = object
    [ "file"     .= meFile     e
    , "kind"     .= meKind     e
    , "object"   .= meObject   e
    , "ancestor" .= meAncestor e
    ]

-- | Extract a String value at val[k].
topStr :: Text -> Value -> Maybe Text
topStr k (Object o) = case KM.lookup (Key.fromText k) o of
  Just (String s) -> Just s
  _               -> Nothing
topStr _ _ = Nothing

-- | Extract a String value at val[k1][k2].
nestedStr :: Text -> Text -> Value -> Maybe Text
nestedStr k1 k2 (Object o) = case KM.lookup (Key.fromText k1) o of
  Just inner -> topStr k2 inner
  _          -> Nothing
nestedStr _ _ _ = Nothing

manifestEntry :: FilePath -> Value -> ManifestEntry
manifestEntry path v = ManifestEntry
  { meFile     = T.pack path
  , meKind     = fromMaybe "unknown" (topStr "kind" v)
  , meObject   = fromMaybe (T.pack path) (nestedStr "meta" "object" v)
  , meAncestor = nestedStr "meta" "ancestor" v
  }

-- ---------------------------------------------------------------------------
-- Build and write cross-file resolution outputs

writeResolution :: FilePath -> [(FilePath, SrFile)] -> IO ()
writeResolution outDir pairs = do
  let allSfs   = map snd pairs
      objSet   = buildObjectSet   allSfs
      usrTypes = buildUserTypeSet allSfs
      inh      = buildInheritsMap allSfs
      procMap  = buildProcMap     allSfs
      toObj sf = case srTypeBlocks sf of
        (tb:_) -> tdName (tbDecl tb)
        []     -> ""
      triples  = [ (T.pack fp, toObj sf, sf) | (fp, sf) <- pairs ]
      lvs      = concatMap (\(fp, obj, sf) -> extractLocalVars  fp obj sf) triples
      css      = concatMap (\(fp, obj, sf) -> extractCallSites  fp obj sf) triples
      gvs      = concatMap (\(fp, obj, sf) -> extractGlobalVars fp obj sf) triples
      rt       = resolveTypes lvs objSet usrTypes
      rc       = resolveCalls css procMap inh builtinFnNames builtinMethodNames
  BSL.writeFile (outDir </> "resolved_types.json") (encode rt)
  BSL.writeFile (outDir </> "resolved_calls.json") (encode rc)
  BSL.writeFile (outDir </> "global_vars.json")    (encode gvs)

-- ---------------------------------------------------------------------------
-- Pass 6 (111d-1): intra-procedural dataflow → proc_defs.json / proc_uses.json
--
-- Drives PB.Pipeline.Dataflow.analyzeProcedure over every procedure body in
-- the workspace and emits consolidated JSON for batch consumers (dump,
-- check-corpus). Rows carry the full 8-key consumer shape:
--   [file, object, proc_name, var_name, block_id, stmt_index, line, kind]
-- This is the same shape the Python side inserts into DuckDB and the shape
-- core/interproc.py + core/slicing.py read by dict key.
--
-- The per-procedure JSON written by wrapSrFile already carries a "dataflow"
-- facet (the streaming-mode delivery channel); this pass consolidates those
-- per-procedure results into the two flat arrays the batch consumers expect.

-- | (obj, procName, body) triples for every procedure in a file.
procBodies :: Text -> SrFile -> [(Text, Text, [Located BodyStmt])]
procBodies obj sf =
     [ (obj, fnsName (fbSig fb), fbBody fb) | fb <- srFunctions   sf ]
  <> [ (obj, ssName  (sbSig sb), sbBody sb) | sb <- srSubroutines sf ]
  <> [ (obj, esName  (evSig ev), evBody ev) | ev <- srEvents      sf ]
  <> [ (obj, obEvent ob,         obBody ob) | ob <- srOnBlocks    sf ]

-- | Emit one full-shape def row (8 keys).
defRowFull :: Text -> Text -> Text -> Dataflow.DefSite -> Value
defRowFull file obj proc d = object
  [ "file"       .= file
  , "object"     .= obj
  , "proc_name"  .= proc
  , "var_name"   .= Dataflow.dsVar d
  , "block_id"   .= Dataflow.dsBlock d
  , "stmt_index" .= Dataflow.dsStmtIdx d
  , "line"       .= Dataflow.dsLine d
  , "kind"       .= Dataflow.dsKind d
  ]

-- | Emit one full-shape use row (8 keys).
useRowFull :: Text -> Text -> Text -> Dataflow.UseSite -> Value
useRowFull file obj proc u = object
  [ "file"       .= file
  , "object"     .= obj
  , "proc_name"  .= proc
  , "var_name"   .= Dataflow.usVar u
  , "block_id"   .= Dataflow.usBlock u
  , "stmt_index" .= Dataflow.usStmtIdx u
  , "line"       .= Dataflow.usLine u
  , "kind"       .= Dataflow.usKind u
  ]

writeDataflowAnalysis :: FilePath -> [ParsedFile] -> IO ()
writeDataflowAnalysis outDir parsed = do
  let toObj pf = case srTypeBlocks (pfSrFile pf) of
        (tb:_) -> tdName (tbDecl tb)
        []     -> ""
      -- Analyze every procedure once, yielding (file, obj, proc, ProcFlow).
      flows = [ (T.pack (pfPath pf), obj, proc, pf')
              | pf <- parsed
              , let obj = toObj pf
              , (_, proc, body) <- procBodies obj (pfSrFile pf)
              , let pf' = Dataflow.analyzeProcedure obj proc (buildCfg body)
              ]
      allDefs = [ defRowFull file obj proc d
                | (file, obj, proc, pf') <- flows
                , Dataflow.BlockFlow _ _ _ defs _ <- Map.elems (Dataflow.pfBlocks pf')
                , d <- defs
                ]
      allUses = [ useRowFull file obj proc u
                | (file, obj, proc, pf') <- flows
                , Dataflow.BlockFlow _ _ _ _ uses <- Map.elems (Dataflow.pfBlocks pf')
                , u <- uses
                ]
  BSL.writeFile (outDir </> "proc_defs.json") (encode allDefs)
  BSL.writeFile (outDir </> "proc_uses.json") (encode allUses)

-- ---------------------------------------------------------------------------
-- Pass 7 (111d-2): taint analysis → taint_*.json
--
-- Reads proc_defs.json, proc_uses.json, resolved_calls.json, global_vars.json
-- from Pass 5/6 output. For each file, classifies sources/sinks from the AST,
-- computes inter-proc edges, propagates taint, traces paths, builds annotations.
-- Writes taint_sources.json, taint_sinks.json, taint_paths.json, taint_annotations.json.

-- | Load a JSON array file into a list of decoded values.
loadJsonArray :: (FromJSON a) => FilePath -> IO [a]
loadJsonArray path = do
  exists <- doesFileExist path
  if not exists then pure [] else do
    result <- eitherDecodeFileStrict' path
    case result of
      Left _  -> pure []
      Right v -> pure v

writeTaintAnalysis :: FilePath -> [ParsedFile] -> IO ()
writeTaintAnalysis outDir parsed = do
  -- Load pre-computed rows from Pass 5/6 JSON
  allDefs    <- loadJsonArray (outDir </> "proc_defs.json")    :: IO [Taint.DefRow]
  allUses    <- loadJsonArray (outDir </> "proc_uses.json")    :: IO [Taint.UseRow]
  allRC      <- loadJsonArray (outDir </> "resolved_calls.json") :: IO [Taint.ResolvedCallRow]
  allGV      <- loadJsonArray (outDir </> "global_vars.json")  :: IO [Taint.GlobalVarRow]
  let globalVarNames = Set.fromList (map Taint.gvrVarName allGV)
      -- Run taint analysis per file
      results = [ Taint.taintAnalysis allRC allDefs allUses globalVarNames
                    (T.pack (pfPath pf)) (pfSrFile pf)
                | pf <- parsed
                ]
      allSources     = concatMap Taint.trSources     results
      allSinks       = concatMap Taint.trSinks       results
      allPaths       = concatMap Taint.trPaths       results
      allAnnotations = concatMap Taint.trAnnotations results
      allEdges       = concatMap Taint.trEdges       results
      allSummaries   = concatMap Taint.trProcedureSummaries results
  BSL.writeFile (outDir </> "taint_sources.json")     (encode allSources)
  BSL.writeFile (outDir </> "taint_sinks.json")       (encode allSinks)
  BSL.writeFile (outDir </> "taint_paths.json")       (encode allPaths)
  BSL.writeFile (outDir </> "taint_annotations.json") (encode allAnnotations)
  BSL.writeFile (outDir </> "interproc_edges.json")   (encode allEdges)
  BSL.writeFile (outDir </> "procedure_summaries.json") (encode allSummaries)

-- ---------------------------------------------------------------------------
-- Three-pass pipeline (runModeFiles)
--
-- Pass 1 (parseOutcome)  : parse all PowerScript files; classify others
-- Pass 2 (runModeFiles)  : build global InheritGraph from all parsed files
-- Pass 3+4 (emitOutcome) : compile with global env + write JSON output
--
-- runModeJsonl is a streaming mode that processes one file at a time and
-- cannot build a cross-file InheritGraph; it keeps per-file inh via runFile.

data ParsedFile = ParsedFile
  { pfPath  :: FilePath
  , pfSrFile :: SrFile
  , pfSpans :: SrSpans
  }

data ParseOutcome
  = PsParsed  ParsedFile
  | PsFailed  FilePath Text   -- IO or parse error
  | OtherFile FilePath        -- DataWindow / pipeline / project

outcomeFilePath :: ParseOutcome -> FilePath
outcomeFilePath (PsParsed pf)   = pfPath pf
outcomeFilePath (PsFailed fp _) = fp
outcomeFilePath (OtherFile fp)  = fp

-- | Pass 1: attempt to parse one file.
parseOutcome :: FilePath -> IO ParseOutcome
parseOutcome src = case fileKind src of
  PowerScript -> do
    readResult <- try (readFile src) :: IO (Either SomeException Text)
    pure $ case readResult of
      Left  ex -> PsFailed src (T.pack (show ex))
      Right contents ->
        case parsePowerScriptFile (stripBom contents) of
          Left  err      -> PsFailed src err
          Right (sf, sp) -> PsParsed (ParsedFile src sf sp)
  _ -> pure (OtherFile src)

-- | Pass 3 (pure): compile one parsed PowerScript file with the workspace env.
compileParsed :: TypeEnv -> ParsedFile -> Value
compileParsed wsEnv pf =
  wrapSrFile (pfPath pf) (pfSrFile pf) (pfSpans pf) wsEnv

-- | Pass 4: write one file's JSON output and return its manifest entry.
emitOutcome :: TypeEnv -> FilePath -> FilePath -> ParseOutcome -> IO (Maybe ManifestEntry)
emitOutcome wsEnv srcDir outDir outcome = do
  let src     = outcomeFilePath outcome
      rel     = makeRelative srcDir src
      outPath = outDir </> rel <> ".json"
  createDirectoryIfMissing True (takeDirectory outPath)
  (bytes, mEntry) <- case outcome of
    PsParsed pf ->
      let v = compileParsed wsEnv pf
      in pure (encode v, Just (manifestEntry src v))
    PsFailed _ err ->
      pure ( encode $ object
               [ "file"  .= src
               , "kind"  .= ("error" :: Text)
               , "error" .= err ]
           , Nothing )
    OtherFile _ -> do
      readResult <- try (readFile src) :: IO (Either SomeException Text)
      pure $ case readResult of
        Left ex ->
          ( encode $ object
              [ "file"  .= src
              , "kind"  .= ("error" :: Text)
              , "error" .= T.pack (show ex) ]
          , Nothing )
        Right contents -> case runFile src (stripBom contents) of
          Left err ->
            ( encode $ object
                [ "file"  .= src
                , "kind"  .= ("error" :: Text)
                , "error" .= err ]
            , Nothing )
          Right v -> (encode v, Just (manifestEntry src v))
  BSL.writeFile outPath bytes
  pure mEntry

runModeFiles :: FilePath -> FilePath -> IO ()
runModeFiles srcDir outDir = do
  files    <- walkAllSrFiles srcDir
  outcomes <- mapM parseOutcome files                            -- Pass 1
  let parsed = [pf | PsParsed pf <- outcomes]
      wsEnv  = buildWorkspaceTypeEnv (map pfSrFile parsed)      -- Pass 2
  entries  <- mapM (emitOutcome wsEnv srcDir outDir) outcomes   -- Pass 3+4
  writeResolution outDir [(pfPath pf, pfSrFile pf) | pf <- parsed]  -- Pass 5
  writeDataflowAnalysis outDir parsed                               -- Pass 6 (111d-1)
  writeTaintAnalysis outDir parsed                                     -- Pass 7 (111d-2)
  BSL.writeFile (outDir </> "manifest.json") (encode (catMaybes entries))

runModeJsonl :: FilePath -> IO ()
runModeJsonl srcDir = do
  files <- walkAllSrFiles srcDir
  mapM_ emitLine files
  where
    emitLine src = do
      readResult <- try (readFile src) :: IO (Either SomeException Text)
      let line = case readResult of
            Left ex ->
              encode $ object
                [ "file" .= src, "kind" .= ("error" :: Text)
                , "error" .= T.pack (show ex) ]
            Right contents -> case runFile src contents of
              Left  err -> encode $ object
                [ "file" .= src, "kind" .= ("error" :: Text), "error" .= err ]
              Right v   -> encode v
      BSL.putStr (line <> "\n")
