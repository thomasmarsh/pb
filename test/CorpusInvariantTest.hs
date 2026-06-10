module CorpusInvariantTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import qualified Data.Text as T

import System.Directory (listDirectory, doesDirectoryExist)
import System.FilePath  ((</>), takeExtension)

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

-- Collect all parseable source files under a directory recursively.
collectFiles :: FilePath -> IO [FilePath]
collectFiles dir = do
    entries <- listDirectory dir
    fmap concat $ mapM (\e -> do
        let path = dir </> e
        isDir <- doesDirectoryExist path
        if isDir
            then collectFiles path
            else pure [path | takeExtension path `elem` [".srf",".srw",".sru",".srm",".sra",".srx"]]
        ) entries

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
    paths <- fmap concat $ mapM collectFiles
        [ "example/PowerBuilder-Example/export"
        , "example/openpay"
        ]
    results <- mapM loadFile paths
    pure (concatMap toList results)

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
-- Test tree

invariant :: String -> NodeCheck -> TestTree
invariant name check = testCase name $ do
    viols <- runNodeCheck check
    assertNoViolations name viols

fileInvariant :: String -> (FilePath -> Value -> [Text]) -> TestTree
fileInvariant name check = testCase name $ do
    viols <- runFileCheck check
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
    ]
