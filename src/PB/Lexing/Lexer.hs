module PB.Lexing.Lexer
  ( tokenize
  , LexLine (..)
  , LexError (..)
  ) where

import PB.Prelude
import PB.Lexing.Token (SourceSpan (..), Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Data.Char (isAlpha, isAlphaNum, isSpace)
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
  case parse (sc *> many (oneToken sl el <* sc) <* eof) "" (llText ll) of
    Left  bundle -> LexLine ll (Left  (LexError ll (pstateOffset (bundlePosState bundle))))
    Right ts     -> LexLine ll (Right ts)
  where
    sl = llStartLine ll
    el = llEndLine ll

-- ---------------------------------------------------------------------------
-- Megaparsec internals

type Lexer = Parsec Void Text

-- Skips whitespace, line comments (//), and block comments (/* */).
sc :: Lexer ()
sc = L.space space1 (L.skipLineComment "//") (L.skipBlockComment "/*" "*/")

currentCol :: Lexer Int
currentCol = (fromIntegral . unPos . sourceColumn) <$> getSourcePos

mkTok :: Int -> Int -> Int -> TokenKind -> Text -> Token
mkTok sl el c k t = Token k t (SourceSpan sl el c)

-- ---------------------------------------------------------------------------
-- Token dispatcher (try ordering follows §11.1)

oneToken :: Int -> Int -> Lexer Token
oneToken sl el = do
  c <- currentCol
  let mk = mkTok sl el c
  choice
    [ pTwoWordKw sl el c
    , pStringLiteral mk
    , try (pDateLiteral mk)
    , try (pTimeLiteral mk)
    , try (pFloatLiteral mk)
    , try (pIntLiteral mk)
    , pIdentOrEnum c mk
    , pOperator mk
    , pPunctuation mk
    ]

-- ---------------------------------------------------------------------------
-- Two-word keywords  (§2.2; tried before single-word keywords)

pTwoWordKw :: Int -> Int -> Int -> Lexer Token
pTwoWordKw sl el c = try $ do
  w1 <- identText
  _ <- space1
  w2 <- identText
  let combined = T.toLower w1 <> " " <> T.toLower w2
  case Map.lookup combined twoWordKwMap of
    Just k  -> return (Token k (w1 <> " " <> w2) (SourceSpan sl el c))
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

pStringLiteral :: (TokenKind -> Text -> Token) -> Lexer Token
pStringLiteral mk = do
  delim <- char '"' <|> char '\''
  let kind = if delim == '"' then TkStringDouble else TkStringSingle
  chunks <- many (pbStringChunk delim)
  _ <- char delim
  return (mk kind (T.singleton delim <> T.concat chunks <> T.singleton delim))

-- One chunk inside a PB string: an escape sequence or a single non-delimiter char.
pbStringChunk :: Char -> Lexer Text
pbStringChunk delim = pbEscape <|> fmap T.singleton (satisfy (\c -> c /= delim && c /= '\n'))

pbEscape :: Lexer Text
pbEscape = do
  _ <- char '~'
  c <- anySingle
  case c of
    'o' -> do { d1 <- anySingle; d2 <- anySingle; d3 <- anySingle
              ; return (T.pack ['~','o',d1,d2,d3]) }
    'h' -> do { d1 <- anySingle; d2 <- anySingle
              ; return (T.pack ['~','h',d1,d2]) }
    _   -> return (T.pack ['~', c])

-- ---------------------------------------------------------------------------
-- Numeric literals  (§2.6)

-- YYYY-MM-DD
pDateLiteral :: (TokenKind -> Text -> Token) -> Lexer Token
pDateLiteral mk = try $ do
  y  <- T.pack <$> count 4 digitChar
  _  <- char '-'
  mo <- T.pack <$> count 2 digitChar
  _  <- char '-'
  d  <- T.pack <$> count 2 digitChar
  notFollowedBy (satisfy isIdentCont)
  return (mk TkDateLiteral (y <> "-" <> mo <> "-" <> d))

-- HH:MM:SS[.frac]
pTimeLiteral :: (TokenKind -> Text -> Token) -> Lexer Token
pTimeLiteral mk = try $ do
  h  <- T.pack <$> count 2 digitChar
  _  <- char ':'
  m  <- T.pack <$> count 2 digitChar
  _  <- char ':'
  s  <- T.pack <$> count 2 digitChar
  fr <- option "" $ do { _ <- char '.'; ds <- T.pack <$> some digitChar; return ("." <> ds) }
  notFollowedBy (satisfy isIdentCont)
  return (mk TkTimeLiteral (h <> ":" <> m <> ":" <> s <> fr))

-- Floating-point: must contain a '.' or exponent
pFloatLiteral :: (TokenKind -> Text -> Token) -> Lexer Token
pFloatLiteral mk = try $ do
  sign    <- option "" (T.singleton <$> (char '+' <|> char '-'))
  intPart <- T.pack <$> many digitChar
  dot     <- optional (char '.')
  case dot of
    Nothing -> do
      exp' <- pExp
      notFollowedBy (satisfy isIdentCont)
      return (mk TkFloatLiteral (sign <> intPart <> exp'))
    Just _  -> do
      fracPart <- T.pack <$> many digitChar
      exp'     <- option "" pExp
      notFollowedBy (satisfy isIdentCont)
      let raw = sign <> intPart <> "." <> fracPart <> exp'
      -- Require at least one digit on either side of the dot
      if T.null intPart && T.null fracPart
        then fail "not a float"
        else return (mk TkFloatLiteral raw)

pExp :: Lexer Text
pExp = do
  e    <- char 'e' <|> char 'E'
  sign <- option "" (T.singleton <$> (char '+' <|> char '-'))
  ds   <- T.pack <$> some digitChar
  return (T.singleton e <> sign <> ds)

pIntLiteral :: (TokenKind -> Text -> Token) -> Lexer Token
pIntLiteral mk = do
  sign <- option "" (T.singleton <$> (char '+' <|> char '-'))
  ds   <- T.pack <$> some digitChar
  notFollowedBy (satisfy isIdentCont)
  return (mk TkIntLiteral (sign <> ds))

-- ---------------------------------------------------------------------------
-- Identifiers, keywords, enum literals, labels  (§2.1, §2.2, §2.7)

pIdentOrEnum :: Int -> (TokenKind -> Text -> Token) -> Lexer Token
pIdentOrEnum atCol mk = do
  t <- identText
  -- Enum literal: Ident! (§2.7)
  isEnum <- option False (True <$ char '!')
  if isEnum
    then return (mk TkEnumLiteral (t <> "!"))
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
        then return (mk TkLabel (t <> ":"))
        else return (mk (classifyIdent (T.toLower t)) t)

identText :: Lexer Text
identText = do
  h <- satisfy isIdentStart
  t <- takeWhileP Nothing isIdentCont
  return (T.cons h t)

isIdentStart :: Char -> Bool
isIdentStart c = isAlpha c || c == '_' || c == '@'

isIdentCont :: Char -> Bool
isIdentCont c = isAlphaNum c || c `elem` ("_$#%`-" :: String)

-- ---------------------------------------------------------------------------
-- Operators  (§2.9; multi-char alternatives tried first)

pOperator :: (TokenKind -> Text -> Token) -> Lexer Token
pOperator mk = choice
  [ try (string "<>" >> return (mk TkCompareOp "<>"))
  , try (string ">=" >> return (mk TkCompareOp ">="))
  , try (string "<=" >> return (mk TkCompareOp "<="))
  , try (string "++" >> return (mk TkAugmentOp "++"))
  , try (string "--" >> return (mk TkAugmentOp "--"))
  , try (string "+=" >> return (mk TkAugmentOp "+="))
  , try (string "-=" >> return (mk TkAugmentOp "-="))
  , try (string "*=" >> return (mk TkAugmentOp "*="))
  , try (string "/=" >> return (mk TkAugmentOp "/="))
  , try (string "::" >> return (mk TkDoubleColon "::"))
  , char '>'  >> return (mk TkCompareOp ">")
  , char '<'  >> return (mk TkCompareOp "<")
  , char '+'  >> return (mk TkArithOp   "+")
  , char '-'  >> return (mk TkArithOp   "-")
  , char '*'  >> return (mk TkArithOp   "*")
  , char '/'  >> return (mk TkArithOp   "/")
  , char '^'  >> return (mk TkArithOp   "^")
  , char '='  >> return (mk TkAssignOp  "=")
  , char '.'  >> return (mk TkDot       ".")
  , char ':'  >> return (mk TkColon     ":")
  ]

-- ---------------------------------------------------------------------------
-- Punctuation  (§2.9)

pPunctuation :: (TokenKind -> Text -> Token) -> Lexer Token
pPunctuation mk = choice
  [ char '(' >> return (mk TkLParen   "(")
  , char ')' >> return (mk TkRParen   ")")
  , char '[' >> return (mk TkLBracket "[")
  , char ']' >> return (mk TkRBracket "]")
  , char '{' >> return (mk TkLBrace   "{")
  , char '}' >> return (mk TkRBrace   "}")
  , char ',' >> return (mk TkComma    ",")
  , char ';' >> return (mk TkSemi     ";")
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
    withKind k = map (\x -> (x, k))

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
