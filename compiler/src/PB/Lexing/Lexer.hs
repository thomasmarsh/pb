{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}
module PB.Lexing.Lexer
  ( tokenize
  , tokenizeLine
  , LexLine (..)
  , LexError (..)
  ) where

import PB.Prelude
import PB.Lexing.Escape (pbStringChunk)
import PB.Lexing.Token (SourceSpan (..), Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine (..), resolveRawPos)

import Data.Char (isAlpha, isAlphaNum, isSpace)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Text as T

import Text.Megaparsec hiding (Token)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

-- ---------------------------------------------------------------------------
-- Result types

-- | One logical line, tokenized.  Errors carry the originating line for
--   full source reconstruction; lineage is also embedded in each Token's span.
data LexError = LexError
  { leSource :: LogicalLine
  , leOffset :: Int
  } deriving (Eq, Show)

data LexLine = LexLine
  { lexSource :: LogicalLine
  , lexResult :: Either LexError [Token]
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Entry point

tokenize :: [LogicalLine] -> [LexLine]
tokenize = map tokenizeLine

tokenizeLine :: LogicalLine -> LexLine
tokenizeLine ll =
  case parse (sc *> many (oneToken ll <* sc) <* eof) "" (llText ll) of
    Left  bundle -> LexLine ll (Left  (LexError ll (bundleErrorOffset bundle)))
    Right ts     -> LexLine ll (Right ts)

bundleErrorOffset :: ParseErrorBundle Text Void -> Int
bundleErrorOffset bundle = case NE.head (bundleErrors bundle) of
  TrivialError o _ _ -> o
  FancyError   o _   -> o

-- ---------------------------------------------------------------------------
-- Megaparsec internals

type Lexer = Parsec Void Text

-- Skips whitespace, line comments (//), and block comments (/* */).
sc :: Lexer ()
sc = L.space space1 (L.skipLineComment "//") (L.skipBlockComment "/*" "*/")

-- Column within the joined logical-line text -- used only by 'pIdentOrEnum's
-- label heuristic (label must start the line), not for 'SourceSpan'
-- construction, which resolves the true raw position via 'resolveRawPos'.
currentCol :: Lexer Int
currentCol = fromIntegral . unPos . sourceColumn <$> getSourcePos

-- ---------------------------------------------------------------------------
-- Token dispatcher (try ordering follows §11.1)

oneToken :: LogicalLine -> Lexer Token
oneToken ll = do
  startOff <- getOffset
  (k, t) <- choice
    [ pTwoWordKw
    , pStringLiteral
    , try pDateLiteral
    , try pTimeLiteral
    , try pFloatLiteral
    , try pIntLiteral
    , pIdentOrEnum
    , pOperator
    , pPunctuation
    ]
  endOff <- getOffset
  let (sLine, sCol) = resolveRawPos ll startOff
      (eLine, eCol) = resolveRawPos ll endOff
  return (Token k t (SourceSpan sLine sCol eLine eCol))

-- ---------------------------------------------------------------------------
-- Two-word keywords  (§2.2; tried before single-word keywords)

pTwoWordKw :: Lexer (TokenKind, Text)
pTwoWordKw = try $ do
  w1 <- identText
  _ <- space1
  w2 <- identText
  let combined = T.toLower w1 <> " " <> T.toLower w2
  case Map.lookup combined twoWordKwMap of
    Just k  -> return (k, w1 <> " " <> w2)
    Nothing -> fail "not a two-word keyword"

twoWordKwMap :: Map.Map Text TokenKind
twoWordKwMap = Map.fromList
  [ ("end if",             TkControlKw)
  , ("end choose",         TkControlKw)
  , ("end try",            TkControlKw)
  , ("end function",       TkDeclKw)
  , ("end subroutine",     TkDeclKw)
  , ("end event",          TkDeclKw)
  , ("end on",             TkDeclKw)
  , ("end type",           TkDeclKw)
  , ("end variables",      TkDeclKw)
  , ("end prototypes",     TkDeclKw)
  , ("end forward",        TkDeclKw)
  , ("choose case",        TkControlKw)
  , ("forward prototypes", TkDeclKw)
  , ("type variables",     TkDeclKw)
  , ("type prototypes",    TkDeclKw)
  ]

-- ---------------------------------------------------------------------------
-- String literals  (§2.5)

pStringLiteral :: Lexer (TokenKind, Text)
pStringLiteral = do
  delim <- char '"' <|> char '\''
  let kind = if delim == '"' then TkStringDouble else TkStringSingle
  chunks <- many (pbStringChunk delim)
  _ <- char delim
  return (kind, T.singleton delim <> T.concat chunks <> T.singleton delim)


-- ---------------------------------------------------------------------------
-- Numeric literals  (§2.6)

-- YYYY-MM-DD
pDateLiteral :: Lexer (TokenKind, Text)
pDateLiteral = try $ do
  y  <- T.pack <$> count 4 digitChar
  _  <- char '-'
  mo <- T.pack <$> count 2 digitChar
  _  <- char '-'
  d  <- T.pack <$> count 2 digitChar
  notFollowedBy (satisfy isNumericCont)
  return (TkDateLiteral, y <> "-" <> mo <> "-" <> d)

-- HH:MM:SS[.frac]
pTimeLiteral :: Lexer (TokenKind, Text)
pTimeLiteral = try $ do
  h  <- T.pack <$> count 2 digitChar
  _  <- char ':'
  m  <- T.pack <$> count 2 digitChar
  _  <- char ':'
  s  <- T.pack <$> count 2 digitChar
  fr <- option "" $ do { _ <- char '.'; ds <- T.pack <$> some digitChar; return ("." <> ds) }
  notFollowedBy (satisfy isNumericCont)
  return (TkTimeLiteral, h <> ":" <> m <> ":" <> s <> fr)

-- Floating-point: must contain a '.' or exponent
pFloatLiteral :: Lexer (TokenKind, Text)
pFloatLiteral = try $ do
  sign    <- option "" (T.singleton <$> (char '+' <|> char '-'))
  intPart <- T.pack <$> many digitChar
  dot     <- optional (char '.')
  case dot of
    Nothing -> do
      exp' <- pExp
      notFollowedBy (satisfy isNumericCont)
      return (TkFloatLiteral, sign <> intPart <> exp')
    Just _  -> do
      fracPart <- T.pack <$> many digitChar
      exp'     <- option "" pExp
      notFollowedBy (satisfy isNumericCont)
      let raw = sign <> intPart <> "." <> fracPart <> exp'
      -- Require at least one digit on either side of the dot
      if T.null intPart && T.null fracPart
        then fail "not a float"
        else return (TkFloatLiteral, raw)

pExp :: Lexer Text
pExp = do
  e    <- char 'e' <|> char 'E'
  sign <- option "" (T.singleton <$> (char '+' <|> char '-'))
  ds   <- T.pack <$> some digitChar
  return (T.singleton e <> sign <> ds)

pIntLiteral :: Lexer (TokenKind, Text)
pIntLiteral = do
  ds <- T.pack <$> some digitChar
  notFollowedBy (satisfy isNumericCont)
  return (TkIntLiteral, ds)

-- ---------------------------------------------------------------------------
-- Identifiers, keywords, enum literals, labels  (§2.1, §2.2, §2.7)

pIdentOrEnum :: Lexer (TokenKind, Text)
pIdentOrEnum = do
  atCol <- currentCol
  t <- identText
  -- Enum literal: Ident! (§2.7)
  isEnum <- option False (True <$ char '!')
  if isEnum
    then return (TkEnumLiteral, t <> "!")
    else do
      -- Label: Ident: at column 1, not ::, colon followed by space or EOL  (§10)
      isLabel <- if atCol == 1
                 then option False $ try $ do
                   _ <- char ':'
                   notFollowedBy (char ':')
                   notFollowedBy (satisfy (not . isSpace))
                   return True
                 else return False
      if isLabel
        then return (TkLabel, t <> ":")
        else return (classifyIdent (T.toLower t), t)

identText :: Lexer Text
identText = do
  h <- satisfy isIdentStart
  t <- takeWhileP Nothing isIdentCont
  return (T.cons h t)

isIdentStart :: Char -> Bool
isIdentStart c = isAlpha c || c == '_' || c == '@'

isIdentCont :: Char -> Bool
isIdentCont c = isAlphaNum c || c `elem` ("_$#%`-" :: String)

-- '-' is always an arithmetic operator when it follows a numeric literal,
-- never an identifier continuation in that position.
isNumericCont :: Char -> Bool
isNumericCont c = isAlphaNum c || c `elem` ("_$#%`" :: String)

-- ---------------------------------------------------------------------------
-- Operators  (§2.9; multi-char alternatives tried first)

pOperator :: Lexer (TokenKind, Text)
pOperator = choice
  [ try (string "<>" >> return (TkCompareOp, "<>"))
  , try (string ">=" >> return (TkCompareOp, ">="))
  , try (string "<=" >> return (TkCompareOp, "<="))
  , try (string "++" >> return (TkAugmentOp, "++"))
  , try (string "--" >> return (TkAugmentOp, "--"))
  , try (string "+=" >> return (TkAugmentOp, "+="))
  , try (string "-=" >> return (TkAugmentOp, "-="))
  , try (string "*=" >> return (TkAugmentOp, "*="))
  , try (string "/=" >> return (TkAugmentOp, "/="))
  , try (string "||" >> return (TkArithOp,     "||"))
  , try (string "::" >> return (TkDoubleColon, "::"))
  , char '>'  >> return (TkCompareOp, ">")
  , char '<'  >> return (TkCompareOp, "<")
  , char '+'  >> return (TkArithOp,   "+")
  , char '-'  >> return (TkArithOp,   "-")
  , char '*'  >> return (TkArithOp,   "*")
  , char '/'  >> return (TkArithOp,   "/")
  , char '^'  >> return (TkArithOp,   "^")
  , char '='  >> return (TkAssignOp,  "=")
  , char '.'  >> return (TkDot,       ".")
  , char ':'  >> return (TkColon,     ":")
  ]

-- ---------------------------------------------------------------------------
-- Punctuation  (§2.9)

pPunctuation :: Lexer (TokenKind, Text)
pPunctuation = choice
  [ char '(' >> return (TkLParen,   "(")
  , char ')' >> return (TkRParen,   ")")
  , char '[' >> return (TkLBracket, "[")
  , char ']' >> return (TkRBracket, "]")
  , char '{' >> return (TkLBrace,   "{")
  , char '}' >> return (TkRBrace,   "}")
  , char ',' >> return (TkComma,    ",")
  , char ';' >> return (TkSemi,     ";")
  ]

-- ---------------------------------------------------------------------------
-- Keyword classification

classifyIdent :: Text -> TokenKind
classifyIdent t = fromMaybe TkIdent (Map.lookup t keywordMap)

keywordMap :: Map.Map Text TokenKind
keywordMap = Map.fromList $
     withKind TkBoolTrue        ["true"]
  <> withKind TkBoolFalse       ["false"]
  <> withKind TkNull            ["null"]
  <> withKind TkAccessModifier  accessMods
  <> withKind TkStorageModifier storageMods
  <> withKind TkDatatype        scalarTypes
  <> withKind TkSqlKw           sqlKws
  <> withKind TkDeclKw          declKws
  <> withKind TkControlKw       controlKws
  <> withKind TkOtherKw         otherKws
  where
    withKind k = map (, k)

accessMods :: [Text]
accessMods =
  [ "public", "private", "protected"
  , "privateread", "privatewrite"
  , "protectedread", "protectedwrite"
  , "systemread", "systemwrite"
  , "global", "shared"
  ]

storageMods :: [Text]
storageMods = ["readonly", "constant", "ref", "indirect", "static"]

scalarTypes :: [Text]
scalarTypes =
  [ "any", "blob", "boolean", "byte", "char", "character"
  , "date", "datetime", "dec", "decimal", "double"
  , "int", "integer", "long", "longlong", "longptr"
  , "real", "string", "time", "uint", "ulong"
  , "unsignedint", "unsignedinteger", "unsignedlong"
  ]

sqlKws :: [Text]
sqlKws =
  [ "select", "selectblob", "insert", "update", "updateblob", "delete"
  , "commit", "rollback", "connect", "disconnect"
  , "declare", "cursor", "execute", "fetch", "prepare"
  , "describe", "descriptor", "open", "close"
  ]

declKws :: [Text]
declKws =
  [ "function", "subroutine", "event", "on", "type"
  , "variables", "prototypes", "forward"
  , "external", "intrinsic", "library", "alias"
  , "from", "within", "throws", "enumerated"
  , "autoinstantiate"
  ]

controlKws :: [Text]
controlKws =
  [ "if", "then", "else", "elseif", "end"
  , "for", "to", "step", "next"
  , "do", "loop", "while", "until"
  , "choose", "case"
  , "try", "catch", "finally"
  , "exit", "continue", "return", "goto", "halt"
  , "throw"
  ]

otherKws :: [Text]
otherKws =
  [ "and", "or", "not", "xor"
  , "call", "post", "trigger", "create", "destroy"
  , "dynamic", "with", "using", "into", "of", "is", "it"
  , "as", "procedure", "rpcfunc", "namespace"
  , "this", "super", "parent", "parentwindow"
  , "sqlca", "sqlsa", "sqlda", "error", "message"
  ]
