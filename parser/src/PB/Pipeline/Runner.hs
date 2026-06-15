module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  , wrapSrFile
  , runModeFiles
  , runModeJsonl
  , ManifestEntry (..)
  , manifestEntry
  ) where

import PB.Prelude
import PB.AST.DataWindow
import PB.AST.SourceFile
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Grammar.File       (parseSrFileWithSpans, SrSpans (..))
import PB.Lexing.Lexer      (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Splitter   (Statement (..), splitStatements)
import PB.Pipeline.Preprocess  (LogicalLine (..), normalizeText, stripHeaders)
import PB.Pipeline.PrettyPrint (prettyBodyStmts)
import PB.Pipeline.Serialise   ()

import Data.Aeson          (ToJSON (..), Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL
import Control.Exception   (SomeException, try)
import Data.Char           (intToDigit, toLower)
import Data.Word           (Word8)
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.Directory    (createDirectoryIfMissing)
import System.FilePath     (makeRelative, takeBaseName, takeDirectory
                           , takeExtension, (</>))
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
  let logicalLines         = normalizeText src
      (headers, bodyLines) = stripHeaders logicalLines
      lexLines             = tokenize bodyLines
  stmts          <- collectStatements lexLines
  (srFile, spans) <- parseSrFileWithSpans headers stmts
  Right (wrapSrFile path srFile spans)

wrapSrFile :: FilePath -> SrFile -> SrSpans -> Value
wrapSrFile path sf spans =
    let (objName, ancestor) = case srTypeBlocks sf of
          (tb:_) -> (tdName (tbDecl tb), Just (tdAncestor (tbDecl tb)))
          []     -> (T.pack path, Nothing)
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
        , "onBlocks"    .= [ injectRendered (obBody ob) (injectMeta sp (toJSON ob))
                           | (sp, ob) <- zip (spOnBlocks    spans) (srOnBlocks    sf) ]
        , "events"      .= [ injectRendered (evBody ev) (injectMeta sp (toJSON ev))
                           | (sp, ev) <- zip (spEvents      spans) (srEvents      sf) ]
        , "functions"   .= [ injectRendered (fbBody fn) (injectMeta sp (toJSON fn))
                           | (sp, fn) <- zip (spFunctions   spans) (srFunctions   sf) ]
        , "subroutines" .= [ injectRendered (sbBody sb) (injectMeta sp (toJSON sb))
                           | (sp, sb) <- zip (spSubroutines spans) (srSubroutines sf) ]
        ]

-- | Convert lex results to statements, failing on the first lex error.
--   Empty-token statements (blank lines) are filtered out so the grammar
--   parser's eof succeeds on trailing whitespace.
collectStatements :: [LexLine] -> Either Text [Statement]
collectStatements lexLines =
  let results = splitStatements lexLines
  in case [err | Left err <- results] of
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

-- Formats up to 16 bytes as xxd-style pairs, padded to 40 chars so the
-- ASCII column stays aligned on short final rows.
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
-- Output modes

runModeFiles :: FilePath -> FilePath -> IO ()
runModeFiles srcDir outDir = do
  files   <- walkAllSrFiles srcDir
  entries <- mapM (processOneFile srcDir outDir) files
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

-- | Parse one file, write its JSON to the mirrored output path, return a
--   manifest entry on success (Nothing on encoding or parse error).
processOneFile :: FilePath -> FilePath -> FilePath -> IO (Maybe ManifestEntry)
processOneFile srcDir outDir src = do
  let rel     = makeRelative srcDir src
      outPath = outDir </> rel <> ".json"
  createDirectoryIfMissing True (takeDirectory outPath)
  readResult <- try (readFile src) :: IO (Either SomeException Text)
  let (bytes, mEntry) = case readResult of
        Left ex ->
          ( encode $ object
              [ "file" .= src, "kind" .= ("error" :: Text)
              , "error" .= T.pack (show ex) ]
          , Nothing )
        Right contents -> case runFile src contents of
          Left err ->
            ( encode $ object
                [ "file" .= src, "kind" .= ("error" :: Text), "error" .= err ]
            , Nothing )
          Right v  -> (encode v, Just (manifestEntry src v))
  BSL.writeFile outPath bytes
  pure mEntry

