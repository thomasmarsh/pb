{-# LANGUAGE StrictData #-}
module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  , wrapSrFile
  , runModeFiles
  , runModeJsonl
  , writeDataflowAnalysis
  , writeTaintAnalysis
  , writeDeadCodeAnalysis
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
import PB.Pipeline.DeadCode    qualified as DeadCode
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
import Control.Concurrent.Async (mapConcurrently)
import GHC.Compact (compact, getCompact)
import Control.Exception   (SomeException, try)
import Data.Char           (intToDigit, toLower)
import Data.Either         (lefts)
import Data.Word           (Word8)
import qualified Data.Set           as Set
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.Directory    (createDirectoryIfMissing, doesFileExist)
import System.FilePath     (makeRelative, takeBaseName, takeDirectory
                           , takeExtension, (</>))
import PB.Pipeline.PbApi    (builtinFnNames, builtinMethodNames)
import PB.Pipeline.TypeResolve
  ( LocalVar, CallSite, GlobalVar
  , buildInheritsMap, buildObjectSet, buildProcMap, buildUserTypeSet
  , extractCallSites, extractDwCallSites, extractGlobalVars, extractLocalVars
  , resolveTypes, resolveCalls
  , parseParams
  )
import qualified Data.Map.Strict as Map
import PB.Pipeline.Walk    (walkAllSrFiles)

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

        injectRendered body (Object o) =
            Object (KM.insert "source_rendered" (toJSON (prettyBodyStmts body)) o)
        injectRendered _ v = v

        injectCompiled env body (Object o) =
            let cfg = buildCfg body
            in Object
              $ KM.insert "cfg"      (toJSON cfg)
              $ KM.insert "dataflow" (toJSON (Dataflow.dataflowFacet (Dataflow.analyzeProcedure objName "" cfg)))
              $ KM.insert "cpsGraph" (toJSON (compileProcedure env userFns body))
              $ o
        injectCompiled _ _ v = v

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

-- | Write Pass 5 resolution outputs from pre-extracted per-file data.
-- lvs/css/gvs are accumulated across all files by the streaming pass.
-- css must already include DW call sites (extracted in analyseOutcome for PsDw).
writeResolution
  :: FilePath
  -> [LocalVar] -> [CallSite] -> [GlobalVar]
  -> Set.Set Text -> Set.Set Text -> Map.Map Text Text -> Map.Map Text (Set.Set Text)
  -> IO ()
writeResolution outDir lvs css gvs objSet usrTypes inh procMap = do
  let rt  = resolveTypes lvs objSet usrTypes
      rc  = resolveCalls css procMap inh builtinFnNames builtinMethodNames
      !_rt  = length rt
      !_rc  = length rc
      !_gvs = length gvs
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

-- | (obj, procName, procType, body) quads for every procedure in a file.
-- Single traversal of the four procedure collections; replaces the old
-- separate procBodies + procTypes helpers.
allProcedures :: Text -> SrFile -> [(Text, Text, Text, [Located BodyStmt])]
allProcedures obj sf =
     [ (obj, fnsName (fbSig fb), "function",   fbBody fb) | fb <- srFunctions   sf ]
  <> [ (obj, ssName  (sbSig sb), "subroutine", sbBody sb) | sb <- srSubroutines sf ]
  <> [ (obj, esName  (evSig ev), "event",      evBody ev) | ev <- srEvents      sf ]
  <> [ (obj, obEvent ob,         "on",         obBody ob) | ob <- srOnBlocks    sf ]

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

writeDataflowAnalysis :: FilePath -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
writeDataflowAnalysis outDir flows = do
  let allDefs = [ defRowFull file obj proc d
                | (file, obj, proc, pf') <- flows
                , Dataflow.BlockFlow _ _ _ defs _ <- Map.elems (Dataflow.pfBlocks pf')
                , d <- defs
                ]
      allUses = [ useRowFull file obj proc u
                | (file, obj, proc, pf') <- flows
                , Dataflow.BlockFlow _ _ _ _ uses <- Map.elems (Dataflow.pfBlocks pf')
                , u <- uses
                ]
      !_defs = length allDefs
      !_uses = length allUses
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

writeTaintAnalysis :: FilePath -> [Taint.TaintFileInputs] -> IO ()
writeTaintAnalysis outDir taintInputs = do
  allDefs <- loadJsonArray (outDir </> "proc_defs.json")      :: IO [Taint.DefRow]
  allUses <- loadJsonArray (outDir </> "proc_uses.json")      :: IO [Taint.UseRow]
  allRC   <- loadJsonArray (outDir </> "resolved_calls.json") :: IO [Taint.ResolvedCallRow]
  allGV   <- loadJsonArray (outDir </> "global_vars.json")    :: IO [Taint.GlobalVarRow]
  let globalVarNames = Set.fromList (map Taint.gvrVarName allGV)
      results        = [ Taint.taintAnalysis allRC allDefs allUses globalVarNames tfi
                       | tfi <- taintInputs ]
      allSources     = concatMap Taint.trSources           results
      allSinks       = concatMap Taint.trSinks             results
      allPaths       = concatMap Taint.trPaths             results
      allAnnotations = concatMap Taint.trAnnotations       results
      allEdges       = concatMap Taint.trEdges             results
      allSummaries   = concatMap Taint.trProcedureSummaries results
      !_src  = length allSources
      !_snk  = length allSinks
      !_pth  = length allPaths
      !_ann  = length allAnnotations
      !_edg  = length allEdges
      !_sum  = length allSummaries
  BSL.writeFile (outDir </> "taint_sources.json")       (encode allSources)
  BSL.writeFile (outDir </> "taint_sinks.json")         (encode allSinks)
  BSL.writeFile (outDir </> "taint_paths.json")         (encode allPaths)
  BSL.writeFile (outDir </> "taint_annotations.json")   (encode allAnnotations)
  BSL.writeFile (outDir </> "interproc_edges.json")     (encode allEdges)
  BSL.writeFile (outDir </> "procedure_summaries.json") (encode allSummaries)

-- ---------------------------------------------------------------------------
-- Pass 8: dead code analysis → dead_procedures.json
--
-- Reads resolved_calls.json from Pass 5. Computes BFS reachability from
-- entry points (event/on handlers, DW procedures with calls) through
-- same-object, cross-object, and override call edges.

writeDeadCodeAnalysis
  :: FilePath -> [DeadCode.ProcInfo] -> [(FilePath, DataWindowFile)]
  -> Map.Map Text Text     -- ^ pre-built inheritance map from runModeFiles
  -> IO ()
writeDeadCodeAnalysis outDir procs dwParsed inh = do
  allRC <- loadJsonArray (outDir </> "resolved_calls.json") :: IO [Taint.ResolvedCallRow]
  let rawCalls = [ (Taint.rcrObject rc, Taint.rcrFromProc rc, lastName (Taint.rcrToName rc))
                 | rc <- allRC ]
      resolvedCalls = [ (Taint.rcrObject rc, Taint.rcrFromProc rc, tgtObj, tgtProc)
                      | rc <- allRC
                      , Just tgtObj <- [Taint.rcrTargetObject rc]
                      , Just tgtProc <- [Taint.rcrTargetProc rc]
                      ]
      inherits  = Map.toList inh
      dwObjects = Set.fromList [ T.pack (takeBaseName fp) | (fp, _) <- dwParsed ]
      dead      = DeadCode.computeDeadProcedures procs rawCalls resolvedCalls inherits dwObjects
      !_dead    = length dead
  BSL.writeFile (outDir </> "dead_procedures.json") (encode dead)


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
  | PsDw      FilePath DataWindowFile  -- successfully parsed DataWindow
  | PsFailed  FilePath Text            -- IO or parse error
  | OtherFile FilePath                 -- pipeline / project

outcomeFilePath :: ParseOutcome -> FilePath
outcomeFilePath (PsParsed pf)   = pfPath pf
outcomeFilePath (PsDw fp _)     = fp
outcomeFilePath (PsFailed fp _) = fp
outcomeFilePath (OtherFile fp)  = fp

-- | Lightweight per-file result from the streaming analysis pass.
-- All heavy SrFile data is consumed and released; only extracted summaries remain.
data FileAnalysis = FileAnalysis
  { faManifest    :: Maybe ManifestEntry
  , faLocalVars   :: [LocalVar]
  , faCallSites   :: [CallSite]
  , faGlobalVars  :: [GlobalVar]
  , faProcFlows   :: [(Text, Text, Text, Dataflow.ProcFlow)]  -- (file, obj, proc, flow)
  , faTaintInputs :: [Taint.TaintFileInputs]   -- empty for DW/error files
  , faProcInfos   :: [DeadCode.ProcInfo]
  }

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
  DataWindow -> do
    readResult <- try (readFile src) :: IO (Either SomeException Text)
    pure $ case readResult of
      Left  ex       -> PsFailed src (T.pack (show ex))
      Right contents -> case parseDataWindow (stripBom contents) of
        Left  err -> PsFailed src err
        Right dw  -> PsDw src dw
  _ -> pure (OtherFile src)

-- | Pass 3 (pure): compile one parsed PowerScript file with the workspace env.
compileParsed :: TypeEnv -> ParsedFile -> Value
compileParsed wsEnv pf =
  wrapSrFile (pfPath pf) (pfSrFile pf) (pfSpans pf) wsEnv

-- | Write one file's JSON output and extract all per-file analysis data in one pass.
-- Replaces the old emitOutcome + separate per-file extraction loops.
-- After this returns, the SrFile inside PsParsed is no longer referenced.
analyseOutcome :: TypeEnv -> FilePath -> FilePath -> ParseOutcome -> IO FileAnalysis
analyseOutcome wsEnv srcDir outDir outcome = do
  let src     = outcomeFilePath outcome
      rel     = makeRelative srcDir src
      outPath = outDir </> rel <> ".json"
  createDirectoryIfMissing True (takeDirectory outPath)
  case outcome of
    PsParsed pf -> do
      let sf  = pfSrFile pf
          fp  = T.pack (pfPath pf)
          obj = case srTypeBlocks sf of
                  (tb:_) -> tdName (tbDecl tb)
                  []     -> ""    -- matches srFileObject / buildProcMap keying
          v   = compileParsed wsEnv pf
      BSL.writeFile outPath (encode v)
      let lvs    = extractLocalVars  fp obj sf
          css    = extractCallSites  fp obj sf
          gvs    = extractGlobalVars fp obj sf
          procPairs = [ let cfg   = buildCfg body
                            flow  = (fp, obj, proc, Dataflow.analyzeProcedure obj proc cfg)
                            pinfo = DeadCode.ProcInfo
                                      { DeadCode.piObject     = obj
                                      , DeadCode.piName       = proc
                                      , DeadCode.piProcType   = ptype
                                      , DeadCode.piCyclomatic = Just (DeadCode.cyclomaticComplexity cfg)
                                      }
                        in (flow, pinfo)
                      | (_, proc, ptype, body) <- allProcedures obj sf ]
          flows  = map fst procPairs
          tfi    = Taint.extractTaintInputs fp sf
          pinfos = map snd procPairs
      pure FileAnalysis
        { faManifest    = Just (manifestEntry src v)
        , faLocalVars   = lvs
        , faCallSites   = css
        , faGlobalVars  = gvs
        , faProcFlows   = flows
        , faTaintInputs = [tfi]
        , faProcInfos   = pinfos
        }
    PsDw _ dw -> do
      let v   = wrapDwFile src dw
          obj = T.pack (takeBaseName src)
          css = extractDwCallSites (T.pack src) obj dw
      BSL.writeFile outPath (encode v)
      pure FileAnalysis
        { faManifest    = Just (manifestEntry src v)
        , faLocalVars   = []
        , faCallSites   = css
        , faGlobalVars  = []
        , faProcFlows   = []
        , faTaintInputs = []
        , faProcInfos   = []
        }
    PsFailed _ err -> do
      BSL.writeFile outPath $ encode $ object
        [ "file"  .= src
        , "kind"  .= ("error" :: Text)
        , "error" .= err ]
      pure FileAnalysis
        { faManifest    = Nothing
        , faLocalVars   = []
        , faCallSites   = []
        , faGlobalVars  = []
        , faProcFlows   = []
        , faTaintInputs = []
        , faProcInfos   = []
        }
    OtherFile _ -> do
      readResult <- try (readFile src) :: IO (Either SomeException Text)
      (bytes, mEntry) <- case readResult of
        Left ex -> pure
          ( encode $ object
              [ "file"  .= src
              , "kind"  .= ("error" :: Text)
              , "error" .= T.pack (show ex) ]
          , Nothing )
        Right contents -> case runFile src (stripBom contents) of
          Left err -> pure
            ( encode $ object
                [ "file"  .= src
                , "kind"  .= ("error" :: Text)
                , "error" .= err ]
            , Nothing )
          Right v -> pure (encode v, Just (manifestEntry src v))
      BSL.writeFile outPath bytes
      pure FileAnalysis
        { faManifest    = mEntry
        , faLocalVars   = []
        , faCallSites   = []
        , faGlobalVars  = []
        , faProcFlows   = []
        , faTaintInputs = []
        , faProcInfos   = []
        }

runModeFiles :: FilePath -> FilePath -> IO ()
runModeFiles srcDir outDir = do
  files    <- walkAllSrFiles srcDir
  outcomes <- mapConcurrently parseOutcome files               -- Pass 1
  -- Build workspace-wide context (forces all SrFiles into memory).
  let allParsed = [pf      | PsParsed pf  <- outcomes]
      dwParsed  = [(fp,dw) | PsDw    fp dw <- outcomes]
      allSfs    = map pfSrFile allParsed
      wsEnv     = buildWorkspaceTypeEnv allSfs                 -- Pass 2
      objSet    = buildObjectSet   allSfs
      usrTypes  = buildUserTypeSet allSfs
      inh       = buildInheritsMap allSfs
      procMap   = buildProcMap     allSfs
  -- Single streaming pass (passes 3+4 + per-file extraction for 5–8).
  -- After mapM completes, outcomes/allParsed/allSfs go out of scope
  -- once wsEnv/objSet/usrTypes/inh/procMap are fully evaluated by
  -- writeResolution below — SrFiles become GC-eligible before passes 7+8.
  analyses <- mapConcurrently (analyseOutcome wsEnv srcDir outDir) outcomes
  let entries     = catMaybes (map faManifest    analyses)
      lvs         = concatMap faLocalVars         analyses
      css         = concatMap faCallSites         analyses  -- includes DW call sites
      gvs         = concatMap faGlobalVars        analyses
      flows       = concatMap faProcFlows         analyses
      taintInputs = concatMap faTaintInputs       analyses
      procInfos   = concatMap faProcInfos         analyses
  writeResolution outDir lvs css gvs objSet usrTypes inh procMap  -- Pass 5
  writeDataflowAnalysis outDir flows                               -- Pass 6
  -- Move long-lived data into compact regions so passes 7+8 GC cycles treat
  -- each as a single root rather than scanning every interior pointer.
  taintC  <- compact taintInputs
  procC   <- compact procInfos
  dwC     <- compact dwParsed
  writeTaintAnalysis    outDir (getCompact taintC)                          -- Pass 7
  writeDeadCodeAnalysis outDir (getCompact procC) (getCompact dwC) inh      -- Pass 8
  BSL.writeFile (outDir </> "manifest.json") (encode entries)

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
