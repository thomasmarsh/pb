module PB.Grammar.DataWindow
  ( parseDataWindow
  , parseBandKind
  , parseDwTable
  , parsePbSelect
  , parseColumn
  , parseDwBand
  , parseDwGroup
  , parseGroupBy
  , parseDwObjectAttrs
  , extractFormatExpr
  ) where

import PB.Prelude
import PB.AST.DataWindow
import PB.Grammar.Body       (parseExpr)
import PB.Lexing.DataWindow  (DwBlock (..), DwAttr (..), scanBlocks, scanBlockAttrs, extractParenBlock)
import PB.Lexing.Escape      (pbSelectTildeStr)
import PB.Lexing.Lexer       (LexLine (..), tokenize)
import qualified PB.Lexing.Token as Tok
import PB.Pipeline.Preprocess (LogicalLine (..))

import Data.List     (nubBy)
import Text.Read     (readMaybe)
import qualified Data.Map.Strict  as Map
import qualified Data.Text        as T
import qualified Data.Text.Read   as TR

import Text.Megaparsec
import Text.Megaparsec.Char         (char, string')
import qualified Text.Megaparsec.Char.Lexer as L

-- ---------------------------------------------------------------------------
-- Entry point

parseDataWindow :: Text -> Either Text DataWindowFile
parseDataWindow src = do
    (release, blocks) <- scanBlocks src
    return (foldl' classifyBlock (emptyDwFile release) blocks)

emptyDwFile :: Int -> DataWindowFile
emptyDwFile n = DataWindowFile
    { dwRelease  = n
    , dwObject   = DwObjectAttrs Map.empty
    , dwTable    = Nothing
    , dwBands    = []
    , dwGroups   = []
    , dwControls = []
    , dwUnknowns = []
    , dwMeta     = Map.empty
    }

-- ---------------------------------------------------------------------------
-- Block classifier

classifyBlock :: DataWindowFile -> DwBlock -> DataWindowFile
classifyBlock dw (DwBlock kw content) = case kw of
    "datawindow" ->
        dw { dwObject = parseDwObjectAttrs content }
    "table" ->
        dw { dwTable = Just (parseDwTable (scanBlockAttrs content)) }
    "group" ->
        dw { dwGroups = dwGroups dw ++ maybeToList (parseDwGroup content) }
    _ | Just bk <- parseBandKind kw ->
            dw { dwBands = dwBands dw ++ [parseDwBand bk content] }
      | "." `T.isInfixOf` kw ->
            let innerMap = collectResidualAttrs [] (scanBlockAttrs content)
            in dw { dwMeta = Map.insertWith Map.union kw innerMap (dwMeta dw) }
      | kw `elem` knownNonControlDirectives ->
            let innerAttrs = collectResidualAttrs [] (scanBlockAttrs content)
            in dw { dwUnknowns = dwUnknowns dw ++ [DwUnknownBlock kw innerAttrs] }
      | otherwise ->
            dw { dwControls = dwControls dw ++ [parseDwControl kw content] }

-- Non-control block keywords known to appear in .srd files.
-- Anything NOT in this list falls through to dwControls, so unknown
-- control types remain accessible rather than being silently lost.
knownNonControlDirectives :: [Text]
knownNonControlDirectives =
    [ "sort", "filter", "sparse", "crosstab", "data" ]

-- ---------------------------------------------------------------------------
-- Band kind

parseBandKind :: Text -> Maybe DwBandKind
parseBandKind kw
    | kw == "header"     = Just BkHeader
    | kw == "detail"     = Just BkDetail
    | kw == "footer"     = Just BkFooter
    | kw == "summary"    = Just BkSummary
    | kw == "background" = Just BkBackground
    | kw == "foreground" = Just BkForeground
    | Just n <- readDotNum  "header"  kw = Just (BkGroupHeader  n)
    | Just n <- readDotNum  "trailer" kw = Just (BkGroupTrailer n)
    | Just n <- readBrackNum "header"  kw = Just (BkGroupHeader  n)
    | Just n <- readBrackNum "trailer" kw = Just (BkGroupTrailer n)
    | Just n <- readDotNum  "tree.level" kw = Just (BkTreeLevel n)
    | Just n <- readBrackNum "tree.level" kw = Just (BkTreeLevel n)
    | otherwise = Nothing

readDotNum :: Text -> Text -> Maybe Int
readDotNum prefix kw = do
    rest <- T.stripPrefix (prefix <> ".") kw
    readAllDigits rest

readBrackNum :: Text -> Text -> Maybe Int
readBrackNum prefix kw = do
    rest      <- T.stripPrefix (prefix <> "[") kw
    (n, tail_) <- either (const Nothing) Just (TR.decimal rest)
    guard (tail_ == "]")
    return n

readAllDigits :: Text -> Maybe Int
readAllDigits t = case TR.decimal t of
    Right (n, "") -> Just n
    _             -> Nothing

-- ---------------------------------------------------------------------------
-- Table block

parseDwTable :: [DwAttr] -> DwTable
parseDwTable attrs = DwTable
    { dtColumns     = extractColumns attrs
    , dtRetrieve    = fmap parsePbSelect rawRetrieve
    , dtUpdate      = lookupQuoted "update" attrs
                      <|> lookupUnquoted "update" attrs
    , dtUpdateWhere = readMaybe . T.unpack =<< lookupUnquoted "updatewhere" attrs
    , dtArguments   = dedupeArgs (extractArguments attrs ++ argFromRetrieve)
    }
  where
    rawRetrieve     = lookupQuoted "retrieve" attrs
    argFromRetrieve = maybe [] extractArgEntries rawRetrieve

-- ---------------------------------------------------------------------------
-- Attr lookup helpers

lookupUnquoted :: Text -> [DwAttr] -> Maybe Text
lookupUnquoted key attrs =
    listToMaybe [v | DwAttrUnquoted k v <- attrs, T.toLower k == T.toLower key]

lookupQuoted :: Text -> [DwAttr] -> Maybe Text
lookupQuoted key attrs =
    listToMaybe [v | DwAttrQuoted k v <- attrs, T.toLower k == T.toLower key]

subBlockContents :: Text -> [DwAttr] -> [Text]
subBlockContents key attrs =
    [c | DwAttrSubBlock k c <- attrs, T.toLower k == T.toLower key]

attrKV :: DwAttr -> (Text, Text)
attrKV (DwAttrUnquoted k v) = (k, v)
attrKV (DwAttrQuoted   k v) = (k, v)
attrKV (DwAttrSubBlock k _) = (k, "")

parseBool :: Maybe Text -> Bool -> Bool
parseBool (Just "yes") _ = True
parseBool (Just "no")  _ = False
parseBool _            d = d

-- ---------------------------------------------------------------------------
-- Column extraction

extractColumns :: [DwAttr] -> [DwColumn]
extractColumns attrs =
    mapMaybe (parseColumn . scanBlockAttrs) (subBlockContents "column" attrs)

parseColumn :: [DwAttr] -> Maybe DwColumn
parseColumn attrs = do
    name     <- lookupUnquoted "name" attrs
    typ      <- lookupUnquoted "type" attrs
    let dbName   = lookupQuoted "dbname" attrs
        upd      = parseBool (lookupUnquoted "update"            attrs) False
        key      = parseBool (lookupUnquoted "key"               attrs) False
        updWhere = parseBool (lookupUnquoted "updatewhereclause" attrs) False
        dddwName = lookupUnquoted "dddw.name" attrs
                   <|> lookupQuoted "dddw.name" attrs
        knownKeys = ["name","type","dbname","update","key","updatewhereclause","dddw.name"]
        extras   = Map.fromList
                     [ (k, v)
                     | attr  <- attrs
                     , let (k, v) = attrKV attr
                     , T.toLower k `notElem` knownKeys
                     ]
    return DwColumn
        { dcName        = name
        , dcType        = typ
        , dcDbName      = dbName
        , dcUpdate      = upd
        , dcKey         = key
        , dcUpdateWhere = updWhere
        , dcDddwName    = dddwName
        , dcAttrs       = extras
        }

-- ---------------------------------------------------------------------------
-- Argument extraction

extractArguments :: [DwAttr] -> [DwArgument]
extractArguments attrs =
    case subBlockContents "arguments" attrs of
        []        -> []
        (blk : _) -> parseArgPairs blk 0

parseArgPairs :: Text -> Int -> [DwArgument]
parseArgPairs t off =
    let off' = off + T.length (T.takeWhile (\c -> c == ',' || c == ' ' || c == '\t' || c == '\n') (T.drop off t))
    in case T.drop off' t of
        rest | T.null rest    -> []
             | T.head rest /= '(' -> []
             | otherwise ->
                 case extractParenBlock t off' of
                     Left  _           -> []
                     Right (pair, end) ->
                         case parseArgPair pair of
                             Just arg -> arg : parseArgPairs t end
                             Nothing  -> parseArgPairs t end

parseArgPair :: Text -> Maybe DwArgument
parseArgPair p = do
    let p' = T.dropWhile (\c -> c == ' ' || c == '\t') p
    guard (not (T.null p') && T.head p' == '"')
    let nameRaw = T.takeWhile (/= '"') (T.tail p')
        rest    = T.drop (T.length nameRaw + 2) p'  -- past closing "
        typ     = T.strip (T.dropWhile (\c -> c == ',' || c == ' ' || c == '\t') rest)
    guard (not (T.null nameRaw) && not (T.null typ))
    return (DwArgument nameRaw typ)

-- | Extract ARG(NAME=~"name~" TYPE=type) entries from a verbatim retrieve string.
-- ARG inner content never contains nested parens, so we use takeWhile (/= ')')
-- rather than the pBlockContent-based extractParenBlock (which treats bare '"'
-- as a string delimiter and fails on tilde-escaped pairs like ~"name~").
-- Argument count is always tiny so O(n) linear scan is appropriate.
extractArgEntries :: Text -> [DwArgument]
extractArgEntries retrieve = go 0
  where
    go off =
        case T.breakOn "ARG(" (T.drop off retrieve) of
            (_, "")    -> []
            (before, _) ->
                let innerStart = off + T.length before + 4  -- past "ARG("
                    inner      = T.takeWhile (/= ')') (T.drop innerStart retrieve)
                    endOff     = innerStart + T.length inner + 1
                in case parseArgEntry inner of
                    Just arg -> arg : go endOff
                    Nothing  -> go endOff

parseArgEntry :: Text -> Maybe DwArgument
parseArgEntry inner = do
    -- inner: NAME = ~"argname~" TYPE = string
    let (_, tl) = T.breakOn "~\"" inner
    guard (not (T.null tl))
    let (name, tl2) = T.breakOn "~\"" (T.drop 2 tl)
    guard (not (T.null name) && not (T.null tl2))
    let afterClose = T.drop 2 tl2
        (_, eqPart) = T.breakOn "=" afterClose
    guard (not (T.null eqPart))
    let typeVal = T.strip
                    (T.takeWhile (\c -> c /= ' ' && c /= '\t' && c /= '\n' && c /= '\r' && c /= ')')
                       (T.dropWhile (\c -> c == '=' || c == ' ' || c == '\t') eqPart))
    guard (not (T.null typeVal))
    return (DwArgument name typeVal)

-- Tiny lists (always < 10 entries) so O(n²) nubBy is fine here.
dedupeArgs :: [DwArgument] -> [DwArgument]
dedupeArgs = nubBy (\a b -> T.toLower (daName a) == T.toLower (daName b)
                          && T.toLower (daType a) == T.toLower (daType b))

-- ---------------------------------------------------------------------------
-- Control block parser

-- | Extract the PB expression from a format string.
-- DW format strings use "~t" as a tab separator: everything after the first
-- "~t" is a PB expression (e.g. "[GENERAL]~tfn_param_maskposo()").
-- Returns Nothing when no "~t" separator is present.
extractFormatExpr :: Text -> Maybe Text
extractFormatExpr fmt =
    case T.breakOn "~t" fmt of
        (_, rest) | T.null rest -> Nothing
        (_, rest)               -> Just (T.drop 2 rest)

parseDwControl :: Text -> Text -> DwControl
parseDwControl kw content =
    let attrs     = scanBlockAttrs content
        knownKeys = ["name","band","id","x","y","width","height",
                     "visible","expression","format","tabsequence"]
        rawFmt    = lookupQuoted "format" attrs
    in DwControl
        { dwcType             = kw
        , dwcName             = lookupUnquoted "name" attrs
        , dwcBand             = parseBandKind =<< lookupUnquoted "band" attrs
        , dwcId               = parseIntAttr  "id"          attrs
        , dwcX                = parseIntAttr  "x"           attrs
        , dwcY                = parseIntAttr  "y"           attrs
        , dwcWidth            = parseIntAttr  "width"       attrs
        , dwcHeight           = parseIntAttr  "height"      attrs
        , dwcVisible          = parseBoolAttr "visible"     attrs
        , dwcExpression       = lookupQuoted  "expression"  attrs
        , dwcParsedExpression = fmap (parseExpr . tokenizeExpr) (lookupQuoted "expression" attrs)
        , dwcFormat           = rawFmt
        , dwcParsedFormat     = fmap (parseExpr . tokenizeExpr) (rawFmt >>= extractFormatExpr)
        , dwcTabSeq           = parseIntAttr  "tabsequence" attrs
        , dwcAttrs            = collectResidualAttrs knownKeys attrs
        }

tokenizeExpr :: Text -> [Tok.Token]
tokenizeExpr txt =
    case tokenize [LogicalLine { llText = txt, llStartLine = 0, llEndLine = 0 }] of
        [ll] -> case lexResult ll of { Left _ -> []; Right ts -> ts }
        _    -> []

parseIntAttr :: Text -> [DwAttr] -> Maybe Int
parseIntAttr key attrs =
    readMaybe . T.unpack =<<
        (lookupUnquoted key attrs <|> lookupQuoted key attrs)

parseBoolAttr :: Text -> [DwAttr] -> Maybe Bool
parseBoolAttr key attrs =
    interpretBool =<<
        (lookupQuoted key attrs <|> lookupUnquoted key attrs)

interpretBool :: Text -> Maybe Bool
interpretBool v = case T.toLower v of
    "1"     -> Just True
    "yes"   -> Just True
    "true"  -> Just True
    "0"     -> Just False
    "no"    -> Just False
    "false" -> Just False
    _       -> Nothing

collectResidualAttrs :: [Text] -> [DwAttr] -> Map.Map Text Text
collectResidualAttrs excluded attrs = Map.fromList
    [ (k, v)
    | attr <- attrs
    , let (k, v) = attrKV attr
    , T.toLower k `notElem` excluded
    ]

-- ---------------------------------------------------------------------------
-- Band / group / datawindow-object block parsers

parseDwObjectAttrs :: Text -> DwObjectAttrs
parseDwObjectAttrs content =
    DwObjectAttrs $ collectResidualAttrs [] (scanBlockAttrs content)

parseDwBand :: DwBandKind -> Text -> DwBand
parseDwBand bk content =
    let attrs = scanBlockAttrs content
    in DwBand
        { dbKind     = bk
        , dbHeight   = parseIntAttr "height" attrs
        , dbColor    = lookupQuoted "color" attrs <|> lookupUnquoted "color" attrs
        , dbAutoSize = lookupUnquoted "height.autosize" attrs == Just "yes"
        , dbAttrs    = collectResidualAttrs ["height","color","height.autosize"] attrs
        }

parseDwGroup :: Text -> Maybe DwGroup
parseDwGroup content = do
    let attrs = scanBlockAttrs content
    level <- parseIntAttr "level" attrs
    return DwGroup
        { dgLevel         = level
        , dgHeaderHeight  = parseIntAttr "header.height"  attrs
        , dgTrailerHeight = parseIntAttr "trailer.height" attrs
        , dgBy            = parseGroupBy content
        , dgNewPage       = parseBool (lookupUnquoted "newpage" attrs) False
        , dgAttrs         = collectResidualAttrs
                              ["level","header.height","trailer.height","by","newpage"] attrs
        }

parseGroupBy :: Text -> [Text]
parseGroupBy content =
    case subBlockContents "by" (scanBlockAttrs content) of
        []      -> []
        (blk:_) ->
            [ stripped
            | seg <- T.splitOn "," blk
            , let t = T.strip seg
            , not (T.null t)
            , let stripped = stripOuterQuotes t
            , not (T.null stripped)
            ]
  where
    stripOuterQuotes t
        | T.length t >= 2 && T.head t == '"' && T.last t == '"'
        = T.init (T.tail t)
        | otherwise = t

-- ---------------------------------------------------------------------------
-- PBSELECT parser

type PbsP = Parsec Void Text

parsePbSelect :: Text -> DwRetrieveOrRaw
parsePbSelect src = case parse pPbSelect "" src of
    Left  _ -> DwRetrieveRaw src
    Right r -> DwRetrieveOk r

pPbsWs :: PbsP ()
pPbsWs = skipMany (satisfy (`elem` (" \t\n\r" :: String)))

-- Parse KEYWORD(inner) — inner is responsible for consuming up to but not
-- including the closing ')'; pPbsBlock consumes it.
pPbsBlock :: Text -> PbsP a -> PbsP a
pPbsBlock kw inner = do
    _ <- string' kw
    pPbsWs
    _ <- char '('
    result <- inner
    pPbsWs
    _ <- char ')'
    pure result

-- A PBSELECT string value: either ~"..."~" (tilde-quoted) or '...' (single-quoted).
pPbsStr :: PbsP Text
pPbsStr =
    pbSelectTildeStr <|>
    (char '\'' *> (T.pack <$> manyTill anySingle (char '\'')))

-- KEY ws* = ws* <pPbsStr>
pKvStr :: Text -> PbsP Text
pKvStr key = do
    pPbsWs
    _ <- string' key
    pPbsWs
    _ <- char '='
    pPbsWs
    pPbsStr

pVersionBlock :: PbsP Int
pVersionBlock = pPbsBlock "VERSION" (pPbsWs *> L.decimal <* pPbsWs)

pTableBlock :: PbsP Text
pTableBlock = pPbsBlock "TABLE" (pKvStr "NAME" <* pPbsWs)

pColumnBlock :: PbsP Text
pColumnBlock = pPbsBlock "COLUMN" (pKvStr "NAME" <* pPbsWs)

pWhereBlock :: PbsP DwWhereClause
pWhereBlock = pPbsBlock "WHERE" $ do
    exp1  <- pKvStr "EXP1"
    op    <- pKvStr "OP"
    exp2  <- pKvStr "EXP2"
    logic <- optional (try (pKvStr "LOGIC"))
    pPbsWs
    pure (DwWhereClause exp1 op exp2 logic)

pArgBlock :: PbsP DwArgument
pArgBlock = pPbsBlock "ARG" $ do
    name <- pKvStr "NAME"
    pPbsWs
    _ <- string' "TYPE"
    pPbsWs
    _ <- char '='
    pPbsWs
    typ  <- takeWhile1P (Just "type name")
                (\c -> c /= ')' && c /= ' ' && c /= '\t' && c /= '\n' && c /= '\r')
    pPbsWs
    pure (DwArgument name typ)

-- Skip the content of any block, handling tilde strings and nested parens,
-- stopping before the unmatched ')'.
pSkipPbsContent :: PbsP ()
pSkipPbsContent = skipMany pSkipAtom
  where
    pSkipAtom :: PbsP ()
    pSkipAtom =
        try pSkipTildeStr <|>
        try pSkipNested   <|>
        void (satisfy (/= ')'))
    pSkipTildeStr :: PbsP ()
    pSkipTildeStr = void pbSelectTildeStr
    pSkipNested :: PbsP ()
    pSkipNested = do
        _ <- char '('
        pSkipPbsContent
        _ <- char ')'
        pure ()

-- Skip any named block whose name is not known to the caller.
-- Matches BLOCK_NAME( ... ) where BLOCK_NAME is any non-whitespace, non-paren chars.
pSkipAnyNamedBlock :: PbsP ()
pSkipAnyNamedBlock = do
    _ <- takeWhile1P (Just "block name")
             (\c -> c /= '(' && c /= ')' && c /= ' ' && c /= '\t' && c /= '\n' && c /= '\r')
    pPbsWs
    _ <- char '('
    pSkipPbsContent
    _ <- char ')'
    pure ()

data PbsInner  = PbsTable Text | PbsColumn Text | PbsWhere DwWhereClause | PbsInnerSkip
data PbsOuter  = PbsArg DwArgument | PbsOuterSkip

pInnerBlock :: PbsP PbsInner
pInnerBlock =
    PbsTable      <$> try pTableBlock  <|>
    PbsColumn     <$> try pColumnBlock <|>
    PbsWhere      <$> try pWhereBlock  <|>
    PbsInnerSkip  <$  try pSkipAnyNamedBlock

pOuterBlock :: PbsP PbsOuter
pOuterBlock =
    PbsArg       <$> try pArgBlock <|>
    PbsOuterSkip <$  try pSkipAnyNamedBlock

pPbSelect :: PbsP DwRetrieve
pPbSelect = do
    pPbsWs
    _ <- string' "PBSELECT"
    pPbsWs
    _ <- char '('
    pPbsWs
    version <- fromMaybe 0 <$> optional (try pVersionBlock)
    pPbsWs
    inner   <- many (try pInnerBlock <* pPbsWs)
    _ <- optional (char ')')
    pPbsWs
    outer   <- many (try pOuterBlock <* pPbsWs)
    pPbsWs
    eof
    let tables  = [t | PbsTable  t <- inner]
        columns = [c | PbsColumn c <- inner]
        wheres  = [w | PbsWhere  w <- inner]
        args    = [a | PbsArg    a <- outer]
    pure (DwRetrieve version tables columns args wheres)
