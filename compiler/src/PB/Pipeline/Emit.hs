{-# LANGUAGE StrictData #-}
module PB.Pipeline.Emit
  ( runFile
  , collectStatements
  , wrapSrFile
  , extractWindowLayout
  , reconstructRetrieveSql
  , fileKind
  , FileKind (..)
  , ParsedFile (..)
  , ParseOutcome (..)
  , parseOutcome
  , parsePowerScriptFile
  , stripBom
  ) where

import PB.Prelude
import PB.AST.BodyStmt   (BodyStmt (..))
import PB.AST.DataWindow
import PB.AST.Expr       (Expr (..))
import PB.AST.Ident      (identCanon, identOrig)
import PB.AST.Located    (Located (..))
import PB.AST.SourceFile
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Grammar.File       (parseSrFileWithSpans, SrSpans (..))
import PB.Lexing.Lexer      (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Splitter   (Statement (..), splitStatements)
import PB.Pipeline.Preprocess  (LogicalLine (..), normalizeText, stripHeaders)
import PB.Analysis.TypeEnv     (WorkspaceEnv (..), buildWorkspaceEnv,
                                procEnv, ScopedTypeEnv)
import PB.Analysis.ControlHierarchy (buildControlIndex)
import PB.Analysis.Cfg    (buildCfg)
import PB.Compile.Flatten
  ( compileProcedureViaEffTerm, compileProcedureToWiring )
import PB.Analysis.TypeResolve (parseParams)
import PB.Pipeline.Serialise   ()

import Data.Aeson          (ToJSON (..), Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString      as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set           as Set
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import Data.Char           (intToDigit, toLower)
import Data.Either         (lefts)
import Data.Word           (Word8)
import System.FilePath     (takeBaseName, takeExtension, makeRelative)
import Text.Read           (readMaybe)
import Control.Exception   (SomeException, try)

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
  let ws = buildWorkspaceEnv [srFile]
  Right (wrapSrFile False path srFile spans ws)

-- | Parse PowerScript source text to (SrFile, SrSpans).
parsePowerScriptFile :: Text -> Either Text (SrFile, SrSpans)
parsePowerScriptFile src = do
  let logicalLines         = normalizeText src
      (headers, bodyLines) = stripHeaders logicalLines
      lexLines             = tokenize bodyLines
  stmts <- collectStatements lexLines
  parseSrFileWithSpans headers stmts

wrapSrFile :: Bool -> FilePath -> SrFile -> SrSpans -> WorkspaceEnv -> Value
wrapSrFile withInstr path sf spans ws =
    let (objNameIdent, ancestor) = srPrimaryObject sf
        objName = identOrig objNameIdent
        objName' = if T.null objName then T.pack path else objName

        -- Single-file mode: no cross-file workspace, so the ControlIndex is
        -- built from just this file (same scope 'ws' itself already has).
        controlIdx = buildControlIndex [sf]

        -- Per-procedure env: params + object instance vars from workspace.
        procEnvFor :: Text -> ScopedTypeEnv
        procEnvFor paramsText = procEnv ws controlIdx objName (parseParams paramsText)

        emptyProcEnv :: ScopedTypeEnv
        emptyProcEnv = procEnv ws controlIdx objName []

        -- User-defined function names (lower-cased) for InstrGraph callproc dispatch.
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
            in Object $ if withInstr
                then KM.insert "instrGraph" (toJSON (compileProcedureViaEffTerm env userFns body))
                   $ KM.insert "wiring" (toJSON (compileProcedureToWiring env userFns body)) base
                else base
        injectCompiled _ _ v = v

        injectAll env body sp v =
            injectCompiled env body (injectMeta sp v)

    in object
        [ "file"            .= path
        , "kind"            .= ("powerscript" :: Text)
        , "meta"            .= object ["object" .= objName', "ancestor" .= ancestor]
        , "headers"         .= srHeaders sf
        , "forward"         .= srForward sf
        , "prototypes"      .= srPrototypes sf
        , "variables"       .= srVariables sf
        , "globalInstances" .= srGlobalInstances sf
        , "typeBlocks"      .= srTypeBlocks sf
        , "onBlocks"    .= [ injectAll emptyProcEnv                           (obBody ob) sp (toJSON ob)
                           | (sp, ob) <- zip (spOnBlocks    spans) (srOnBlocks    sf) ]
        , "events"      .= [ injectAll emptyProcEnv                           (evBody ev) sp (toJSON ev)
                           | (sp, ev) <- zip (spEvents      spans) (srEvents      sf) ]
        , "functions"   .= [ injectAll (procEnvFor (fnsParams (fbSig fn))) (fbBody fn) sp (toJSON fn)
                           | (sp, fn) <- zip (spFunctions   spans) (srFunctions   sf) ]
        , "subroutines" .= [ injectAll (procEnvFor (ssParams  (sbSig sb))) (sbBody sb) sp (toJSON sb)
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

-- | Attempt to parse one file. @root@ is the ingestion root (the @-i@
-- directory); every stored/returned path is relative to it, not the
-- absolute disk path used to actually read the file -- an ingestion root
-- is often a throwaway extraction temp dir, and the absolute path is never
-- useful downstream (DB rows, JSON, progress events).
parseOutcome :: FilePath -> FilePath -> IO ParseOutcome
parseOutcome root src = case fileKind src of
  PowerScript -> do
    readResult <- try (readFile src) :: IO (Either SomeException Text)
    pure $ case readResult of
      Left  ex -> PsFailed rel (T.pack (show ex))
      Right contents ->
        case parsePowerScriptFile (stripBom contents) of
          Left  err      -> PsFailed rel err
          Right (sf, sp) -> PsParsed (ParsedFile rel sf sp contents)
  DataWindow -> do
    readResult <- try (readFile src) :: IO (Either SomeException Text)
    pure $ case readResult of
      Left  ex       -> PsFailed rel (T.pack (show ex))
      Right contents -> case parseDataWindow (stripBom contents) of
        Left  err -> PsFailed rel err
        Right dw  -> PsDw rel contents dw
  _ -> pure (OtherFile rel)
  where
    rel = makeRelative root src

-- ---------------------------------------------------------------------------
-- Window layout extraction

exprScalar :: Expr -> Maybe Value
exprScalar (ExStr t) = Just (String t)
exprScalar (ExInt t) = Just (maybe (String t) toJSON (readMaybe (T.unpack t) :: Maybe Int))
exprScalar (ExReal t) = Just (String t)
exprScalar _          = Nothing

typeBlockProps :: TypeBlock -> Map.Map Text Value
typeBlockProps tb = Map.fromList
  [ (T.toLower nm, v)
  | Located _ BsLocalVar { varName = nm, varInit = Just expr } <- tbBody tb
  , Just v <- [exprScalar expr]
  ]

isWindowAncestor :: Map.Map Text Text -> Set.Set Text -> Text -> Bool
isWindowAncestor amap visited t
  | Set.member t visited = False
  | t `elem` (["window", "w_pbgrid"] :: [Text]) = True
  | "w_" `T.isPrefixOf` t = True
  | otherwise = case Map.lookup t amap of
      Just p  -> isWindowAncestor amap (Set.insert t visited) p
      Nothing -> False

-- | Extract a JSON layout descriptor for window objects (.srw/.sru/.srf).
-- Returns Nothing for non-window objects (services, user-objects, structures).
extractWindowLayout :: [TypeBlock] -> Maybe Value
extractWindowLayout tbs =
  let amap = Map.fromList
        [ (identCanon (tdName (tbDecl tb)), T.toLower (tdAncestor (tbDecl tb)))
        | tb <- tbs ]
      roots = [ tb | tb <- tbs
                   , isNothing (tdWithin (tbDecl tb))
                   , isWindowAncestor amap Set.empty
                       (T.toLower (tdAncestor (tbDecl tb))) ]
  in case roots of
    []      -> Nothing
    (win:_) ->
      let winName  = identCanon (tdName (tbDecl win))
          props    = typeBlockProps win
          children = [ tb | tb <- tbs
                          , fmap T.toLower (tdWithin (tbDecl tb)) == Just winName ]
          mkControl tb =
            let cp      = typeBlockProps tb
                nm      = tdName (tbDecl tb)
                typ     = identCanon (tdAncestorClass (tbDecl tb))
                base    = ["name" .= nm, "type" .= typ]
                nums    = [ Key.fromText k .= v | k <- ["x","y","width","height"]
                                               , Just v <- [Map.lookup k cp] ]
                strs    = [ Key.fromText k .= v | k <- ["text","dataobject"]
                                               , Just v <- [Map.lookup k cp] ]
            in object (base <> nums <> strs)
          dims  = [ Key.fromText k .= v | k <- ["width","height"], Just v <- [Map.lookup k props] ]
          title = [ "title" .= v | Just v <- [Map.lookup "title" props] ]
      in Just $ object $
           [ "name"     .= tdName (tbDecl win)
           , "type"     .= ("window" :: Text)
           , "controls" .= map mkControl children
           ]
           <> dims <> title

-- ---------------------------------------------------------------------------
-- DW retrieve SQL reconstruction

-- | Reconstruct a runnable SQL string from a parsed DW retrieve clause.
-- For native SQL (DwRetrieveRaw), the text is returned verbatim.
-- For PBSELECT (DwRetrieveOk), SELECT/FROM/WHERE is reconstructed:
--   - Table-qualified column names ("tbl.col") are stripped to bare "col".
--   - Argument references (":argname") in WHERE exp2 become "?".
--   - WHERE clauses are joined with the LOGIC connector from each clause
--     (default AND when connector is absent mid-chain).
reconstructRetrieveSql :: DwRetrieveOrRaw -> Text
reconstructRetrieveSql (DwRetrieveRaw t) = t
reconstructRetrieveSql (DwRetrieveOk r)  =
    let cols   = T.intercalate ", " (map stripQual (drColumns r))
        tables = T.intercalate ", " (drTables r)
        select = "SELECT " <> cols <> " FROM " <> tables
    in case drWhere r of
        []  -> select
        ws  -> select <> " WHERE " <> buildWhere ws
  where
    stripQual t = case T.breakOnEnd "." t of
        ("", col) -> col
        (_,  col) -> col

    argToParam t
        | ":" `T.isPrefixOf` t = "?"
        | otherwise            = t

    buildWhere []     = ""
    buildWhere (w:ws) =
        let clause = stripQual (dwcExp1 w)
                  <> " " <> dwcOp w
                  <> " " <> argToParam (dwcExp2 w)
            logic  = maybe " AND " (\l -> " " <> T.toUpper l <> " ") (dwcLogic w)
        in clause <> (if null ws then "" else logic <> buildWhere ws)
