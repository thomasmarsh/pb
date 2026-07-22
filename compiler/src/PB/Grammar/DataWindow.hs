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
import PB.AST.Expr           (Expr (ExRaw))
import PB.Grammar.Body       (parseExpr)
import PB.Lexing.DataWindow  (DwBlock (..), DwAttr (..), scanBlocks, scanBlockAttrs, extractParenBlock, resolveDwPos)
import PB.Lexing.Escape      (pbSelectTildeStr)
import PB.Lexing.Lexer       (LexLine (..), tokenize)
import qualified PB.Lexing.Token as Tok
import PB.Pipeline.Preprocess (mkLogicalLineAt, advanceThroughText)

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
classifyBlock dw blk@DwBlock { dwbKeyword = kw, dwbContent = content } = case kw of
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
            dw { dwControls = dwControls dw ++ [parseDwControl blk] }

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
    listToMaybe [v | DwAttrQuoted k v _ <- attrs, T.toLower k == T.toLower key]

-- | Like 'lookupQuoted' but returns the value's own relative @(line, col)@
-- (see 'DwAttrQuoted') instead of its text -- used to recover a real source
-- position for a quoted attribute that gets re-tokenized into an 'Expr'.
lookupQuotedPos :: Text -> [DwAttr] -> Maybe (Int, Int)
lookupQuotedPos key attrs =
    listToMaybe [p | DwAttrQuoted k _ p <- attrs, T.toLower k == T.toLower key]

subBlockContents :: Text -> [DwAttr] -> [Text]
subBlockContents key attrs =
    [c | DwAttrSubBlock k c <- attrs, T.toLower k == T.toLower key]

attrKV :: DwAttr -> (Text, Text)
attrKV (DwAttrUnquoted k v) = (k, v)
attrKV (DwAttrQuoted   k v _) = (k, v)
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

-- | Extract the PB expression from a format string, alongside the prefix
-- text consumed to reach it (including the "~t" marker itself) so a caller
-- can 'advanceThroughText' the format value's own anchor position forward
-- to the expression's true start.
-- DW format strings use "~t" as a tab separator: everything after the first
-- "~t" is a PB expression (e.g. "[GENERAL]~tfn_param_maskposo()").
-- Returns Nothing when no "~t" separator is present.
extractFormatExpr :: Text -> Maybe (Text, Text)
extractFormatExpr fmt =
    case T.breakOn "~t" fmt of
        (_, rest) | T.null rest -> Nothing
        (before, rest)          -> Just (before <> T.take 2 rest, T.drop 2 rest)

parseDwControl :: DwBlock -> DwControl
parseDwControl DwBlock { dwbKeyword = kw, dwbContent = content, dwbLine = blkLine, dwbCol = blkCol } =
    let attrs      = scanBlockAttrs content
        knownKeys  = ["name","band","id","x","y","width","height",
                      "visible","expression","format","tabsequence"]
        rawFmt     = lookupQuoted "format" attrs
        anchor     = resolveDwPos (blkLine, blkCol)
        exprPos    = anchor <$> lookupQuotedPos "expression" attrs
        fmtPos     = anchor <$> lookupQuotedPos "format" attrs
        fmtExprPos = do
            (line, col) <- fmtPos
            raw         <- rawFmt
            (prefix, _) <- extractFormatExpr raw
            pure (advanceThroughText (line, col) prefix)
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
        , dwcParsedExpression = parseExpr <$> (tokenizeExprAt <$> exprPos <*> lookupQuoted "expression" attrs)
        , dwcFormat           = rawFmt
        , dwcParsedFormat     = parseExpr <$> (tokenizeExprAt <$> fmtExprPos <*> (snd <$> (rawFmt >>= extractFormatExpr)))
        , dwcTabSeq           = parseIntAttr  "tabsequence" attrs
        , dwcAttrs            = collectResidualAttrs knownKeys attrs
        }

tokenizeExprAt :: (Int, Int) -> Text -> [Tok.Token]
tokenizeExprAt (line, col) txt =
    case tokenize [mkLogicalLineAt line col txt] of
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
    pure (DwWhereClause exp1 op exp2 logic
            (parseWhereOperand exp1) (parseWhereOperand exp2))

-- | Parse a WHERE-clause operand (dwcExp1/dwcExp2) through the same
-- tokenizeExprAt/parseExpr pipeline DwControl's expression/format fields use.
-- Strips surplus grouping parens first (see 'stripSurplusParens' — this is
-- the ".srd WHERE-clause paren leakage" fix, doc/spec.md 7.3). parseExpr is
-- total (ExRaw fallback); a top-level ExRaw means nothing structured was
-- recognized, so store Nothing rather than a useless raw-token wrapper.
-- No real anchor position is threaded through the PBSELECT/WHERE
-- sub-grammar yet (tracked separately in BACKLOG.md) -- (0, 1) preserves
-- this call site's prior behavior unchanged rather than regressing it.
parseWhereOperand :: Text -> Maybe Expr
parseWhereOperand raw =
    case parseExpr (tokenizeExprAt (0, 1) (stripSurplusParens raw)) of
        ExRaw _ -> Nothing
        expr    -> Just expr

-- | Strip a leading run of '(' from the front of the text while its net
-- paren count (opens minus closes) is positive, and a trailing run of ')'
-- from the back while net negative. Never touches an already-balanced
-- parenthesized sub-expression (a real function call, `(a+b)`) since those
-- have net-zero balance throughout. Fixes the ".srd WHERE-clause paren
-- leakage" bug (doc/spec.md 7.3, BACKLOG.md): PowerBuilder's WHERE grid
-- splices a visual group's literal parens onto whichever row sits at the
-- group's boundary, with no separate field recording the grouping — so
-- EXP1/EXP2 can carry a surplus of leading/trailing parens left over from
-- a group spanning that row and its siblings. Recovering each row's own
-- comparison operands only needs this local surplus stripped; the true
-- cross-row group nesting is discarded (not represented in DwWhereClause
-- at all) since dwcParsedExp1/dwcParsedExp2 only need the operand itself.
stripSurplusParens :: Text -> Text
stripSurplusParens = stripTrailingCloses . stripLeadingOpens
  where
    netParenBalance :: Text -> Int
    netParenBalance t = T.length (T.filter (== '(') t) - T.length (T.filter (== ')') t)

    stripLeadingOpens :: Text -> Text
    stripLeadingOpens t = case T.uncons (T.stripStart t) of
        Just ('(', rest) | netParenBalance t > 0 -> stripLeadingOpens rest
        _                                        -> t

    stripTrailingCloses :: Text -> Text
    stripTrailingCloses t = case T.unsnoc (T.stripEnd t) of
        Just (rest, ')') | netParenBalance t < 0 -> stripTrailingCloses rest
        _                                        -> t

pJoinBlock :: PbsP DwJoin
pJoinBlock = pPbsBlock "JOIN" $ do
    left   <- pKvStr "LEFT"
    op     <- pKvStr "OP"
    right  <- pKvStr "RIGHT"
    outer1 <- optional (try (pKvStr "OUTER1"))
    outer2 <- optional (try (pKvStr "OUTER2"))
    pPbsWs
    pure (DwJoin left op right outer1 outer2)

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

data PbsInner  = PbsTable Text | PbsColumn Text | PbsWhere DwWhereClause | PbsJoin DwJoin | PbsInnerSkip
data PbsOuter  = PbsArg DwArgument | PbsOuterSkip

pInnerBlock :: PbsP PbsInner
pInnerBlock =
    PbsTable      <$> try pTableBlock  <|>
    PbsColumn     <$> try pColumnBlock <|>
    PbsWhere      <$> try pWhereBlock  <|>
    PbsJoin       <$> try pJoinBlock   <|>
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
        joins   = [j | PbsJoin   j <- inner]
        args    = [a | PbsArg    a <- outer]
    pure (DwRetrieve version tables columns args wheres joins)
