module CorpusInvariantTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)
import PB.Pipeline.Walk   (walkDwFiles, walkPsFiles)

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

-- ---------------------------------------------------------------------------
-- JSON helpers

lk :: Text -> Value -> Value
lk k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
lk _ _          = Null

tagOf :: Value -> Text
tagOf v = case lk "tag" v of { String t -> t; _ -> "" }

segsOf :: Value -> [Value]
segsOf v = case lk "segments" v of { Array vs -> toList vs; _ -> [] }

isEmptyExRaw :: Value -> Bool
isEmptyExRaw v = tagOf v == "raw" && case lk "tokens" v of
    Array ts -> null (toList ts)
    _        -> False

-- ---------------------------------------------------------------------------
-- Tree walker

-- Walk every node in a JSON tree depth-first, accumulating violation strings.
walkTree :: (Value -> [Text]) -> Value -> [Text]
walkTree check val = check val ++ case val of
    Object m  -> concatMap (walkTree check) (KM.elems m)
    Array  vs -> concatMap (walkTree check) (toList vs)
    _         -> []

-- ---------------------------------------------------------------------------
-- Corpus loader

-- Run the parser on one file; return Nothing on Left (parse error).
loadFile :: FilePath -> IO (Maybe (FilePath, Value))
loadFile path = do
    src <- readFile path
    pure $ case runFile path src of
        Left  _  -> Nothing
        Right v  -> Just (path, v)

-- Load all successfully-parsed files from both corpora.
loadCorpus :: IO [(FilePath, Value)]
loadCorpus = do
    paths <- fmap concat $ mapM walkPsFiles
        [ "example/PowerBuilder-Example-extract"
        , "example/openpay-0.1.1b-extract"
        ]
    results <- mapM loadFile paths
    pure (concatMap maybeToList results)

-- Load all successfully-parsed .srd files.
loadDwCorpus :: IO [(FilePath, Value)]
loadDwCorpus = do
    paths <- fmap concat $ mapM walkDwFiles
        [ "example/PowerBuilder-Example-extract"
        , "example/openpay-0.1.1b-extract"
        ]
    results <- mapM loadFile paths
    pure (concatMap maybeToList results)

-- ---------------------------------------------------------------------------
-- Invariant runner

type NodeCheck = Value -> [Text]

-- Run a node-level check across all corpus trees; collect (file, msg) pairs.
runNodeCheck :: NodeCheck -> IO [(FilePath, Text)]
runNodeCheck check = do
    pairs <- loadCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- walkTree check v]

-- Run a file-level check (operates on the top-level Value per file).
runFileCheck :: (FilePath -> Value -> [Text]) -> IO [(FilePath, Text)]
runFileCheck check = do
    pairs <- loadCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- check f v]

runDwNodeCheck :: NodeCheck -> IO [(FilePath, Text)]
runDwNodeCheck check = do
    pairs <- loadDwCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- walkTree check v]

runDwFileCheck :: (FilePath -> Value -> [Text]) -> IO [(FilePath, Text)]
runDwFileCheck check = do
    pairs <- loadDwCorpus
    pure [(f, msg) | (f, v) <- pairs, msg <- check f v]

assertNoViolations :: String -> [(FilePath, Text)] -> IO ()
assertNoViolations name viols =
    assertBool msg (null viols)
  where
    shown = concatMap (\(f, m) -> "  " <> f <> ": " <> T.unpack m <> "\n") (take 10 viols)
    total = length viols
    msg   = "Invariant '" <> name <> "' — " <> show total
              <> " violation(s):\n" <> shown

-- ---------------------------------------------------------------------------
-- Node checks

chkLvalueSegs :: NodeCheck
chkLvalueSegs v
    | tagOf v == "lvalue" && null (segsOf v) = ["lvalue with empty segments"]
    | otherwise                               = []

chkCallExprCallee :: NodeCheck
chkCallExprCallee v
    | tagOf v == "call_expr"
    , null (segsOf (lk "callee" v)) = ["call_expr with empty callee segments"]
    | otherwise                      = []

chkAssignLhs :: NodeCheck
chkAssignLhs v
    | tagOf v == "assign"
    , null (segsOf (lk "lhs" v)) = ["assign with empty lhs segments"]
    | otherwise                   = []

chkHostVarSegs :: NodeCheck
chkHostVarSegs v
    | tagOf v == "host_var"
    , null (segsOf (lk "lvalue" v)) = ["host_var with empty lvalue segments"]
    | otherwise                      = []

chkForVarSegs :: NodeCheck
chkForVarSegs v
    | tagOf v == "for"
    , null (segsOf (lk "var" v)) = ["for with empty var segments"]
    | otherwise                   = []

chkNoEmptyExRaw :: NodeCheck
chkNoEmptyExRaw v
    | isEmptyExRaw v = ["ExRaw node with zero tokens"]
    | otherwise      = []

chkBinopOperands :: NodeCheck
chkBinopOperands v
    | tagOf v == "binop"
    = [msg | (field, side) <- [("lhs", lk "lhs" v), ("rhs", lk "rhs" v)]
            , isEmptyExRaw side
            , let msg = "binop " <> field <> " is empty ExRaw"]
    | otherwise = []

chkIfCond :: NodeCheck
chkIfCond v
    | tagOf v == "if" && isEmptyExRaw (lk "cond" v) = ["if cond is empty ExRaw"]
    | otherwise                                       = []

chkForBounds :: NodeCheck
chkForBounds v
    | tagOf v == "for"
    = [msg | (field, side) <- [("from", lk "from" v), ("to", lk "to" v)]
            , isEmptyExRaw side
            , let msg = "for " <> field <> " is empty ExRaw"]
    | otherwise = []

chkChooseExpr :: NodeCheck
chkChooseExpr v
    | tagOf v == "choose" && isEmptyExRaw (lk "expr" v) = ["choose expr is empty ExRaw"]
    | otherwise                                           = []

-- ---------------------------------------------------------------------------
-- File-level checks

chkFnNames :: FilePath -> Value -> [Text]
chkFnNames _ v = case lk "functions" v of
    Array fs -> [msg | f <- toList fs
                     , let name = case lk "name" (lk "sig" f) of
                                    String t -> t; _ -> ""
                     , T.null name
                     , let msg = "function with empty sig.name"]
    _        -> []

chkSubNames :: FilePath -> Value -> [Text]
chkSubNames _ v = case lk "subroutines" v of
    Array ss -> [msg | s <- toList ss
                     , let name = case lk "name" (lk "sig" s) of
                                    String t -> t; _ -> ""
                     , T.null name
                     , let msg = "subroutine with empty sig.name"]
    _        -> []

-- ---------------------------------------------------------------------------
-- PS meta checks

-- Collects all callable blocks from a PS file value.
psCallableBlocks :: Value -> [Value]
psCallableBlocks v
    | lk "kind" v /= String "powerscript" = []
    | otherwise = concatMap (\k -> case lk k v of { Array bs -> toList bs; _ -> [] })
                            ["functions", "events", "onBlocks", "subroutines"]

chkPsMetaFile :: FilePath -> Value -> [Text]
chkPsMetaFile _ v =
    [ "callable block missing meta.file"
    | b <- psCallableBlocks v
    , case lk "file" (lk "meta" b) of { String _ -> False; _ -> True }
    ]

chkPsMetaObject :: FilePath -> Value -> [Text]
chkPsMetaObject _ v =
    [ "callable block missing meta.object"
    | b <- psCallableBlocks v
    , case lk "object" (lk "meta" b) of { String _ -> False; _ -> True }
    ]

chkPsMetaStartLine :: FilePath -> Value -> [Text]
chkPsMetaStartLine _ v =
    [ "callable block meta.startLine not > 0"
    | b <- psCallableBlocks v
    , case lk "startLine" (lk "meta" b) of { Number n -> n <= 0; _ -> True }
    ]

chkPsMetaEndLine :: FilePath -> Value -> [Text]
chkPsMetaEndLine _ v =
    [ "callable block meta.endLine < meta.startLine"
    | b <- psCallableBlocks v
    , let meta = lk "meta" b
    , case (lk "startLine" meta, lk "endLine" meta) of
        (Number sl, Number el) -> el < sl
        _                      -> True
    ]

-- ---------------------------------------------------------------------------
-- DW-specific node and file checks

chkDwArgConsistency :: FilePath -> Value -> [Text]
chkDwArgConsistency _ v
    | lk "kind" v /= String "datawindow" = []
    | otherwise =
        let tableV = lk "table" v
            retrieve = lk "retrieve" tableV
        in case lk "version" retrieve of
            Null -> []  -- DwRetrieveRaw or no table: skip
            _    ->
                let dtCount = case lk "arguments" tableV  of { Array xs -> length (toList xs); _ -> 0 }
                    drCount = case lk "arguments" retrieve of { Array xs -> length (toList xs); _ -> 0 }
                in if dtCount == drCount then []
                   else [ "dtArguments count " <> T.pack (show dtCount)
                        <> " != drArguments count " <> T.pack (show drCount) ]

chkDwNotStub :: FilePath -> Value -> [Text]
chkDwNotStub _ v
    | lk "kind"   v == String "datawindow"
    , lk "status" v == String "unimplemented" = ["DW file is stub"]
    | otherwise = []

chkDwBandsNonEmpty :: FilePath -> Value -> [Text]
chkDwBandsNonEmpty _ v
    | lk "kind" v /= String "datawindow" = []
    | otherwise = case lk "bands" v of
        Array bs | not (null (toList bs)) -> []
        _                                 -> ["DW file has no bands"]

-- Fires on DwControl nodes with type="column" that are missing an id.
-- "column" is a DW control type; PB data types (long/char/date/etc.) are
-- never literally "column", so this safely identifies DwControl column nodes.
chkDwColumnControlHasId :: NodeCheck
chkDwColumnControlHasId v
    | lk "type" v == String "column"
    , lk "id"   v == Null = ["column control has null id"]
    | otherwise = []

-- Fires on DwColumn nodes (identified by presence of "db_name" key) that
-- have a null or empty "name".  Uses KM.member to distinguish "absent" from
-- "present but null" when checking for the discriminating key.
chkDwTableColumnNameNonEmpty :: NodeCheck
chkDwTableColumnNameNonEmpty (Object m)
    | KM.member (Key.fromText "db_name") m =
        case KM.lookup (Key.fromText "name") m of
          Just (String t) | T.null t -> ["table column with empty name"]
          Just (String _)            -> []
          _                          -> ["table column with null name"]
chkDwTableColumnNameNonEmpty _ = []

-- ---------------------------------------------------------------------------
-- Test tree

invariant :: String -> NodeCheck -> TestTree
invariant name check = testCase name $ do
    viols <- runNodeCheck check
    assertNoViolations name viols

fileInvariant :: String -> (FilePath -> Value -> [Text]) -> TestTree
fileInvariant name check = testCase name $ do
    viols <- runFileCheck check
    assertNoViolations name viols

invariantDw :: String -> NodeCheck -> TestTree
invariantDw name check = testCase name $ do
    viols <- runDwNodeCheck check
    assertNoViolations name viols

fileInvariantDw :: String -> (FilePath -> Value -> [Text]) -> TestTree
fileInvariantDw name check = testCase name $ do
    viols <- runDwFileCheck check
    assertNoViolations name viols

tests :: TestTree
tests = testGroup "Corpus.Invariants"
    [ invariant "lvalue segments non-empty"          chkLvalueSegs
    , invariant "call_expr callee non-empty"         chkCallExprCallee
    , invariant "assign lhs non-empty"               chkAssignLhs
    , invariant "host_var lvalue segments non-empty" chkHostVarSegs
    , invariant "for var segments non-empty"         chkForVarSegs
    , invariant "no empty ExRaw anywhere"            chkNoEmptyExRaw
    , invariant "binop operands not empty ExRaw"     chkBinopOperands
    , invariant "if cond not empty ExRaw"            chkIfCond
    , invariant "for bounds not empty ExRaw"         chkForBounds
    , invariant "choose expr not empty ExRaw"        chkChooseExpr
    , fileInvariant "function sig.name non-empty"    chkFnNames
    , fileInvariant "subroutine sig.name non-empty"  chkSubNames
    , testGroup "Corpus.Meta.PS"
        [ fileInvariant "callable blocks have meta.file"                 chkPsMetaFile
        , fileInvariant "callable blocks have meta.object"               chkPsMetaObject
        , fileInvariant "callable blocks have meta.startLine > 0"        chkPsMetaStartLine
        , fileInvariant "callable blocks have meta.endLine >= startLine"  chkPsMetaEndLine
        ]
    , testGroup "Corpus.DW.Invariants"
        [ fileInvariantDw "DW files not stub"                   chkDwNotStub
        , fileInvariantDw "DW bands non-empty"                  chkDwBandsNonEmpty
        , invariantDw     "column control has id"                chkDwColumnControlHasId
        , invariantDw     "table column name non-empty"          chkDwTableColumnNameNonEmpty
        , fileInvariantDw "dtArguments == drArguments count"     chkDwArgConsistency
        ]
    ]
