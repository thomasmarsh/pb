module PB.Grammar.DataWindow
  ( parseDataWindow
  , parseBandKind
  , parseDwTable
  , parseColumn
  , parseDwBand
  , parseDwGroup
  , parseGroupBy
  , parseDwObjectAttrs
  ) where

import PB.Prelude
import PB.AST.DataWindow
import PB.Lexing.DataWindow (DwBlock (..), DwAttr (..), scanBlocks, scanBlockAttrs, extractParenBlock)

import Data.List     (nubBy)
import Text.Read     (readMaybe)
import qualified Data.Map.Strict  as Map
import qualified Data.Text        as T
import qualified Data.Text.Read   as TR

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
        dw { dwGroups = dwGroups dw ++ maybe [] (:[]) (parseDwGroup content) }
    _ | Just bk <- parseBandKind kw ->
            dw { dwBands = dwBands dw ++ [parseDwBand bk content] }
      | "." `T.isInfixOf` kw ->
            dw { dwMeta = Map.insert kw Map.empty (dwMeta dw) }
      | otherwise ->
            dw { dwControls = dwControls dw ++ [parseDwControl kw content] }

-- ---------------------------------------------------------------------------
-- Band kind

parseBandKind :: Text -> Maybe DwBandKind
parseBandKind kw = case kw of
    "header"     -> Just BkHeader
    "detail"     -> Just BkDetail
    "footer"     -> Just BkFooter
    "summary"    -> Just BkSummary
    "background" -> Just BkBackground
    "foreground" -> Just BkForeground
    _            -> tryGroupBand kw

tryGroupBand :: Text -> Maybe DwBandKind
tryGroupBand kw
    | Just n <- readDotNum  "header"  kw = Just (BkGroupHeader  n)
    | Just n <- readDotNum  "trailer" kw = Just (BkGroupTrailer n)
    | Just n <- readBrackNum "header"  kw = Just (BkGroupHeader  n)
    | Just n <- readBrackNum "trailer" kw = Just (BkGroupTrailer n)
    | otherwise                           = Nothing

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
    , dtRetrieve    = lookupQuoted "retrieve" attrs
    , dtUpdate      = lookupQuoted "update" attrs
                      <|> lookupUnquoted "update" attrs
    , dtUpdateWhere = readMaybe . T.unpack =<< lookupUnquoted "updatewhere" attrs
    , dtArguments   = dedupeArgs (extractArguments attrs ++ argFromRetrieve)
    }
  where
    argFromRetrieve = maybe [] extractArgEntries (lookupQuoted "retrieve" attrs)

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

parseDwControl :: Text -> Text -> DwControl
parseDwControl kw content =
    let attrs     = scanBlockAttrs content
        knownKeys = ["name","band","id","x","y","width","height",
                     "visible","expression","tabsequence"]
    in DwControl
        { dwcType       = kw
        , dwcName       = lookupUnquoted "name" attrs
        , dwcBand       = parseBandKind =<< lookupUnquoted "band" attrs
        , dwcId         = parseIntAttr  "id"          attrs
        , dwcX          = parseIntAttr  "x"           attrs
        , dwcY          = parseIntAttr  "y"           attrs
        , dwcWidth      = parseIntAttr  "width"       attrs
        , dwcHeight     = parseIntAttr  "height"      attrs
        , dwcVisible    = parseBoolAttr "visible"     attrs
        , dwcExpression = lookupQuoted  "expression"  attrs
        , dwcTabSeq     = parseIntAttr  "tabsequence" attrs
        , dwcAttrs      = collectResidualAttrs knownKeys attrs
        }

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
