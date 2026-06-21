module EscapeTest (tests) where

import PB.Prelude
import PB.Lexing.Escape (pbStringChunk, pbDwStringChunk, pbSelectTildeStr)

import Text.Megaparsec (Parsec, parse, many)

import Test.Tasty              (TestTree, testGroup)
import Test.Tasty.HUnit        (testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

runParser :: Parsec Void Text a -> Text -> Either String a
runParser p input = case parse p "<test>" input of
  Left err -> Left (show err)
  Right x  -> Right x

runChunks :: Char -> Text -> Either String [Text]
runChunks delim input = runParser (many (pbStringChunk delim)) input

runDwChunks :: Char -> Text -> Either String [Text]
runDwChunks delim input = runParser (many (pbDwStringChunk delim)) input

runTildeStr :: Text -> Either String Text
runTildeStr input = runParser pbSelectTildeStr input

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Lexing"
  [ testGroup "Escape"
    [ testGroup "pbStringChunk"
      [ testCase "single char" $
          runChunks '"' "a" @?= Right ["a"]
      , testCase "multiple chars" $
          runChunks '"' "hello" @?= Right ["h","e","l","l","o"]
      , testCase "tilde escape ~n (newline seq)" $
          runChunks '"' "~n" @?= Right ["~n"]
      , testCase "tilde escape ~t (tab seq)" $
          runChunks '"' "~t" @?= Right ["~t"]
      , testCase "tilde escape ~r (cr seq)" $
          runChunks '"' "~r" @?= Right ["~r"]
      , testCase "tilde escape ~~ (double-tilde)" $
          runChunks '"' "~~" @?= Right ["~~"]
      , testCase "tilde-o escape (4 chars after ~)" $
          runChunks '"' "~o123" @?= Right ["~o123"]
      , testCase "tilde-h escape (3 chars after ~)" $
          runChunks '"' "~h45" @?= Right ["~h45"]
      , testCase "tilde escape ~'" $
          runChunks '\'' "~'" @?= Right ["~'"]
      , testCase "mixed text and escapes" $
          runChunks '"' "a~nb" @?= Right ["a","~n","b"]
      , testCase "stops at delimiter (remainder unconsumed)" $
          case runChunks '"' "abc" of
            Right cs -> cs @?= ["a","b","c"]
            Left e   -> error e
      , testCase "rejects newline" $
          case runChunks '"' "ab" of
            Right cs -> cs @?= ["a","b"]
            Left e   -> error e
      , testCase "empty input" $
          runChunks '"' "" @?= Right []
      ]
    , testGroup "pbDwStringChunk"
      [ testCase "single char" $
          runDwChunks '"' "a" @?= Right ["a"]
      , testCase "allows newline" $
          runDwChunks '"' "ab\ncd" @?= Right ["a","b","\n","c","d"]
      , testCase "tilde escape in DW" $
          runDwChunks '"' "~n" @?= Right ["~n"]
      , testCase "empty input" $
          runDwChunks '"' "" @?= Right []
      ]
    , testGroup "pbSelectTildeStr"
      [ testCase "simple content" $
          runTildeStr "~\"hello~\"" @?= Right "hello"
      , testCase "empty content" $
          runTildeStr "~\"~\"" @?= Right ""
      , testCase "escaped ~~ (literal tilde)" $
          runTildeStr "~\"~~~\"" @?= Right "~~"
      , testCase "content with ~~ embedded" $
          runTildeStr "~\"abc~~def~\"" @?= Right "abc~~def"
      , testCase "escaped ~~\" (tilde-quote)" $
          runTildeStr "~\"~~\"~\"" @?= Right "~~\""
      ]
    ]
  ]
