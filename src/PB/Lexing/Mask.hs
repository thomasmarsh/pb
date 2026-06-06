module PB.Lexing.Mask
  ( maskLine
  , maskDocument
  ) where

import PB.Prelude
import qualified Data.Text as T

-- | Mask a single logical line: replace string content and line comments with
--   spaces, preserving character positions. Does not handle block comments.
maskLine :: Text -> Text
maskLine = T.pack . goLine LsCode . T.unpack

-- | Mask an entire document: replace string content, line comments, and block
--   comments with spaces, preserving newlines and character positions.
maskDocument :: Text -> Text
maskDocument = T.pack . goDoc DsCode . T.unpack

-- ---------------------------------------------------------------------------
-- Internal types

data StrKind = StrSingle | StrDouble

data LineState = LsCode | LsStr StrKind

data DocState
  = DsCode
  | DsStr StrKind
  | DsLineComment
  | DsBlock

delimChar :: StrKind -> Char
delimChar StrSingle = '\''
delimChar StrDouble = '"'

strKindOf :: Char -> StrKind
strKindOf '\'' = StrSingle
strKindOf _    = StrDouble

-- ---------------------------------------------------------------------------
-- Single-line masker

goLine :: LineState -> String -> String
goLine _         []             = []
goLine LsCode    ('/':'/':cs)   = ' ' : ' ' : map (const ' ') cs
goLine LsCode    (c:cs)
  | c == '"' || c == '\''       = c : goLine (LsStr (strKindOf c)) cs
  | otherwise                   = c : goLine LsCode cs
goLine (LsStr k) ('~':cs)       = ' ' : skipEscLine k cs
goLine (LsStr k) (c:cs)
  | c == delimChar k            = c : goLine LsCode cs
  | otherwise                   = ' ' : goLine (LsStr k) cs

-- Consume one PB escape sequence after '~'; continue in the same string state.
skipEscLine :: StrKind -> String -> String
skipEscLine k ('o':_:_:_:cs) = ' ':' ':' ':' ': goLine (LsStr k) cs  -- ~oNNN
skipEscLine k ('h':_:_:cs)   = ' ':' ':' ':    goLine (LsStr k) cs   -- ~hNN
skipEscLine k (_:cs)          = ' '           : goLine (LsStr k) cs   -- ~.
skipEscLine _ []              = []

-- ---------------------------------------------------------------------------
-- Document-level masker

goDoc :: DocState -> String -> String
goDoc _              []              = []
-- Newlines: always preserved; drive state transitions for single-quoted strings.
goDoc DsCode         ('\n':cs)       = '\n' : goDoc DsCode cs
goDoc DsLineComment  ('\n':cs)       = '\n' : goDoc DsCode cs
goDoc DsBlock        ('\n':cs)       = '\n' : goDoc DsBlock cs
goDoc (DsStr StrDouble) ('\n':cs)    = '\n' : goDoc (DsStr StrDouble) cs
goDoc (DsStr StrSingle) ('\n':cs)    = '\n' : goDoc DsCode cs  -- single-quoted ends at EOL
-- Block comment
goDoc DsBlock        ('*':'/':cs)    = ' ':' ': goDoc DsCode cs
goDoc DsBlock        (_:cs)          = ' '    : goDoc DsBlock cs
-- Line comment
goDoc DsLineComment  (_:cs)          = ' '    : goDoc DsLineComment cs
-- String
goDoc (DsStr k)      ('~':cs)        = ' '    : skipEscDoc k cs
goDoc (DsStr k)      (c:cs)
  | c == delimChar k                 = c      : goDoc DsCode cs
  | otherwise                        = ' '    : goDoc (DsStr k) cs
-- Code
goDoc DsCode         ('/':'/':cs)    = ' ':' ': goDoc DsLineComment cs
goDoc DsCode         ('/':'*':cs)    = ' ':' ': goDoc DsBlock cs
goDoc DsCode         (c:cs)
  | c == '"' || c == '\''            = c      : goDoc (DsStr (strKindOf c)) cs
  | otherwise                        = c      : goDoc DsCode cs

-- Consume one PB escape sequence after '~'; continue in the same string state.
skipEscDoc :: StrKind -> String -> String
skipEscDoc k ('o':_:_:_:cs) = ' ':' ':' ':' ': goDoc (DsStr k) cs  -- ~oNNN
skipEscDoc k ('h':_:_:cs)   = ' ':' ':' ':    goDoc (DsStr k) cs   -- ~hNN
skipEscDoc k (_:cs)          = ' '           : goDoc (DsStr k) cs   -- ~.
skipEscDoc _ []              = []
