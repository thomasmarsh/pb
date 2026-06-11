-- Ratchet gate: assert that ExRaw and BsRaw "other" counts stay below
-- their thresholds. Update after each B-track session; never increase.
--
--   ExRaw ≤ 133   after B4 (ExMethodCall chain + dec{N} localvar), 2026-06-10
--   ExRaw ≤ 156   after B3 (ExDispatch), 2026-06-10
--   BsRaw other ≤ 18  after open/close SQL cursor fix, 2026-06-10
module CorpusDebtTest (tests) where

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

-- ---------------------------------------------------------------------------
-- Corpus loader

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

loadCorpus :: IO [Value]
loadCorpus = do
    paths <- fmap concat $ mapM collectFiles
        [ "example/PowerBuilder-Example/export"
        , "example/openpay"
        ]
    results <- mapM (\p -> do
        src <- readFile p
        pure $ case runFile p src of { Left _ -> Nothing; Right v -> Just v }
        ) paths
    pure (concatMap toList results)

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
    , "from","and","or","into","using","where","having","group","order","join" ]
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
               && not (isSqlKw firstWord || isCtrlKw firstWord
                       || isDeclKw firstWord || isHandledKw firstWord)
        _ -> False

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Corpus.Debt"
    [ testCase "ExRaw total \8804 133" $ do
        vals <- loadCorpus
        let total = sum (map (countWhere isExRaw) vals)
        assertBool ("ExRaw total = " <> show total <> ", expected \8804 133") (total <= 133)
    , testCase "BsRaw 'other' \8804 18" $ do
        vals <- loadCorpus
        let total = sum (map (countWhere isBsRawOther) vals)
        assertBool ("BsRaw 'other' total = " <> show total <> ", expected \8804 18") (total <= 18)
    ]
