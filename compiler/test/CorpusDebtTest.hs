-- Ratchet gate: assert that ExRaw and BsRaw "other" counts stay at zero.
--
--   ExRaw = 0     after chainCalls property-access fix, 2026-06-11
--   ExRaw ≤ 1     after B5 (SQL body joining + TkLabel guard), 2026-06-10
--   BsRaw other = 0  after open/close cursor reclassification + BsAssignExpr, 2026-06-11
--   BsRaw other ≤ 18  after open/close SQL cursor fix, 2026-06-10
module CorpusDebtTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)
import PB.Pipeline.FileWalk   (walkDwFiles, walkPsFiles)
import RepoRoot (repoRoot)
import System.FilePath  ((</>))

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

-- ---------------------------------------------------------------------------
-- Corpus loader

-- The two corpus directories, resolved against the repo root -- Cabal runs
-- the built test binary with cwd = the package directory (@compiler/@), but
-- these directories live at the repo root, one level up.
corpusDirs :: IO [FilePath]
corpusDirs = do
    root <- repoRoot
    pure [ root </> "example" </> "PowerBuilder-Example-extract"
         , root </> "example" </> "openpay-0.1.1b-extract"
         ]

loadCorpus :: IO [Value]
loadCorpus = do
    dirs  <- corpusDirs
    paths <- fmap concat $ mapM walkPsFiles dirs
    results <- mapM (\p -> do
        src <- readFile p
        pure $ case runFile p src of { Left _ -> Nothing; Right v -> Just v }
        ) paths
    pure (concatMap maybeToList results)

-- ---------------------------------------------------------------------------
-- Debt counters

countWhere :: (Value -> Bool) -> Value -> Int
countWhere p v = (if p v then 1 else 0) + case v of
    Object m -> sum (map (countWhere p) (KM.elems m))
    Array vs -> sum (map (countWhere p) (toList vs))
    _        -> 0

-- ExRaw: tag=raw with "tokens" array (expression-level fallback).
isExRaw :: Value -> Bool
isExRaw v = tagOf v == "raw" && case lk "tokens" v of { Array _ -> True; _ -> False }

-- BsRaw keyword sets (mirrors analyze-debt.py SQL_KWS / CTRL_KWS / DECL_KWS / HANDLED).
isSqlKw, isCtrlKw, isDeclKw, isHandledKw :: Text -> Bool
isSqlKw w = w `elem`
    [ "select","selectblob","insert","update","updateblob","delete"
    , "commit","rollback","connect","disconnect","declare","cursor"
    , "execute","fetch","prepare","describe","descriptor"
    , "from","and","or","into","using","where","having","group","order","join"
    , "open","close" ]  -- cursor ops; open()/close() call forms are BsCall, not BsRaw
isCtrlKw w = w `elem`
    [ "if","else","elseif","end","choose","case","for","do","loop"
    , "while","until","try","catch","finally" ]
isDeclKw w = w `elem`
    [ "event","on","function","subroutine","type","variables","forward","prototypes" ]
isHandledKw w = w `elem`
    ["return","exit","continue","call","destroy","create","halt"]

-- BsRaw "other": tag=raw with "text" field whose first word is not in any known
-- category (sql/ctrl/decl/handled) and doesn't start with "{" (array init).
-- Mirrors the "other" bucket in analyze-debt.py.
isBsRawOther :: Value -> Bool
isBsRawOther v
    | tagOf v /= "raw" = False
    | otherwise = case lk "text" v of
        String txt ->
            let stripped  = T.strip txt
                firstWord = case T.words stripped of
                              (w:_) -> T.toLower (T.dropWhileEnd (== ';') w)
                              []    -> ""
            in not (T.isPrefixOf "{" stripped)
               && not (T.isSuffixOf ":" firstWord)   -- TkLabel: goto/access-modifier headers
               && not (isSqlKw firstWord || isCtrlKw firstWord
                       || isDeclKw firstWord || isHandledKw firstWord)
        _ -> False

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Corpus.Debt"
    [ testCase "ExRaw total = 0" $ do
        vals <- loadCorpus
        let total = sum (map (countWhere isExRaw) vals)
        assertBool ("ExRaw total = " <> show total <> ", expected 0") (total == 0)
    , testCase "BsRaw 'other' = 0" $ do
        vals <- loadCorpus
        let total = sum (map (countWhere isBsRawOther) vals)
        assertBool ("BsRaw 'other' total = " <> show total <> ", expected 0") (total == 0)
    , testCase "DW files not stub" $ do
        dirs  <- corpusDirs
        paths <- fmap concat $ mapM walkDwFiles dirs
        results <- mapM (\p -> do
            src <- readFile p
            pure $ runFile p src
            ) paths
        let stubCount = length
              [ () | Right v <- results
                   , String "unimplemented" <- [lk "status" v] ]
        assertBool ("DW stub count = " <> show stubCount <> ", expected 0")
                   (stubCount == 0)
    , testCase "PBSELECT: zero parse failures" $ do
        dirs  <- corpusDirs
        paths <- fmap concat $ mapM walkDwFiles dirs
        results <- mapM (\p -> do
            src <- readFile p
            pure $ runFile p src
            ) paths
        let failCount = length
              [ () | Right v <- results
                   , let r = lk "retrieve" (lk "table" v)
                   , String raw <- [lk "raw" r]
                   , "PBSELECT" `T.isPrefixOf` raw ]
        assertBool ("PBSELECT parse failures: " <> show failCount <> ", expected 0")
                   (failCount == 0)
    , testCase "DW table-block parsed" $ do
        dirs  <- corpusDirs
        paths <- fmap concat $ mapM walkDwFiles dirs
        triples <- mapM (\p -> do
            src <- readFile p
            let hasTable = any (T.isPrefixOf "table(") (T.lines src)
            pure (p, hasTable, runFile p src)
            ) paths
        let missing = [ p | (p, True, Right v) <- triples, lk "table" v == Null ]
        assertBool ("DW files with table(...) but null table field: "
                    <> show (length missing)) (null missing)
    ]
