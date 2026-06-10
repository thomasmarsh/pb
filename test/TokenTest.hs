module TokenTest (tests) where

import PB.Prelude
import PB.Lexing.Lexer (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Token (SourceSpan (..), Token (..), TokenKind (..))
import PB.Pipeline.Preprocess (LogicalLine (..))

import Data.Foldable (for_)
import qualified Data.Text as T

import Hedgehog (Property, assert, forAll, property, success)
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit   (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- ---------------------------------------------------------------------------
-- Helpers

mkLine :: Text -> LogicalLine
mkLine t = LogicalLine t 1 1

tokenKinds :: Text -> IO [TokenKind]
tokenKinds t =
  case tokenize [mkLine t] of
    [LexLine _ (Right ts)] -> return (map tkKind ts)
    [LexLine _ (Left le)]  -> assertFailure ("lex error at offset " <> show (leOffset le))
    _                      -> assertFailure "unexpected tokenize result length"

tokenKindTexts :: Text -> IO [(TokenKind, Text)]
tokenKindTexts t =
  case tokenize [mkLine t] of
    [LexLine _ (Right ts)] -> return (map (\tk -> (tkKind tk, tkText tk)) ts)
    [LexLine _ (Left le)]  -> assertFailure ("lex error at offset " <> show (leOffset le))
    _                      -> assertFailure "unexpected tokenize result length"

twoWordCase :: (Text, TokenKind) -> TestTree
twoWordCase (input, expected) =
  testCase (T.unpack input) $ do
    r <- tokenKindTexts input
    r @?= [(expected, input)]

twoWordCiCase :: (Text, TokenKind) -> TestTree
twoWordCiCase (input, expected) =
  testCase (T.unpack input) $ do
    r <- tokenKinds input
    r @?= [expected]

-- Asserts that the input produces a lex error (no token list).
assertLexError :: Text -> IO ()
assertLexError t =
  case tokenize [mkLine t] of
    [LexLine _ (Left _)]  -> return ()
    [LexLine _ (Right _)] -> assertFailure ("expected lex error but got tokens for: " <> T.unpack t)
    _                     -> assertFailure "unexpected tokenize result length"

-- Asserts a single keyword lexes to the expected kind with text preserved verbatim.
kwCase :: TokenKind -> Text -> TestTree
kwCase expected kw =
  testCase (T.unpack kw) $ do
    r <- tokenKindTexts kw
    r @?= [(expected, kw)]

-- Asserts that the input lexes to a single TkCompareOp.
cmpCase :: Text -> TestTree
cmpCase op =
  testCase (T.unpack op) $ do
    r <- tokenKinds op
    r @?= [TkCompareOp]

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Lexing"
  [ testGroup "Token"
    [ testGroup "two-word keywords" $ map twoWordCase
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
    , testGroup "two-word keywords: case-insensitive" $ map twoWordCiCase
        [ ("END IF",       TkControlKw)
        , ("End If",       TkControlKw)
        , ("END FUNCTION", TkDeclKw)
        ]
    , testGroup "string literals"
        [ testCase "double-quoted string" $ do
            r <- tokenKindTexts "\"hello\""
            r @?= [(TkStringDouble, "\"hello\"")]

        , testCase "single-quoted string" $ do
            r <- tokenKindTexts "'hello'"
            r @?= [(TkStringSingle, "'hello'")]

        , testCase "empty double-quoted string" $ do
            r <- tokenKindTexts "\"\""
            r @?= [(TkStringDouble, "\"\"")]

        , testCase "tilde-n escape" $ do
            r <- tokenKinds "\"~n\""
            r @?= [TkStringDouble]

        , testCase "tilde-t escape" $ do
            r <- tokenKinds "\"~t\""
            r @?= [TkStringDouble]

        , testCase "tilde-r escape" $ do
            r <- tokenKinds "\"~r\""
            r @?= [TkStringDouble]

        , testCase "tilde-tilde escape" $ do
            r <- tokenKinds "\"~~\""
            r @?= [TkStringDouble]

        , testCase "tilde-quote escape" $ do
            r <- tokenKinds "\"~\"\""
            r @?= [TkStringDouble]

        , testCase "tilde-h hex escape ~hFF" $ do
            r <- tokenKinds "\"~hFF\""
            r @?= [TkStringDouble]

        , testCase "tilde-o octal escape ~o101" $ do
            r <- tokenKinds "\"~o101\""
            r @?= [TkStringDouble]

        , testCase "block comment inside string is not stripped" $ do
            r <- tokenKinds "\"/* not a comment */\""
            r @?= [TkStringDouble]

        , testCase "line comment inside string is not stripped" $ do
            r <- tokenKinds "\"// not a comment\""
            r @?= [TkStringDouble]
        ]
    , testGroup "time literals"
        [ testCase "12:30:00" $ do
            r <- tokenKindTexts "12:30:00"
            r @?= [(TkTimeLiteral, "12:30:00")]

        , testCase "23:59:59.999 with fraction" $ do
            r <- tokenKindTexts "23:59:59.999"
            r @?= [(TkTimeLiteral, "23:59:59.999")]

        , testCase "00:00:00 midnight" $ do
            r <- tokenKindTexts "00:00:00"
            r @?= [(TkTimeLiteral, "00:00:00")]
        ]
    , testGroup "literals"
        [ testCase "enum literal Black!" $ do
            r <- tokenKindTexts "Black!"
            r @?= [(TkEnumLiteral, "Black!")]

        , testCase "enum literal does not split at !" $ do
            r <- tokenKinds "Primary!"
            r @?= [TkEnumLiteral]

        , testCase "date literal 2024-01-15" $ do
            r <- tokenKindTexts "2024-01-15"
            r @?= [(TkDateLiteral, "2024-01-15")]

        , testCase "float literal 3.14" $ do
            r <- tokenKindTexts "3.14"
            r @?= [(TkFloatLiteral, "3.14")]

        , testCase "float literal with exponent 1.5e10" $ do
            r <- tokenKindTexts "1.5e10"
            r @?= [(TkFloatLiteral, "1.5e10")]

        , testCase "int literal 42" $ do
            r <- tokenKindTexts "42"
            r @?= [(TkIntLiteral, "42")]

        , testCase "bool true" $ do
            r <- tokenKinds "true"
            r @?= [TkBoolTrue]

        , testCase "bool false" $ do
            r <- tokenKinds "false"
            r @?= [TkBoolFalse]

        , testCase "null" $ do
            r <- tokenKinds "null"
            r @?= [TkNull]
        ]
    , testGroup "numeric edge cases"
        [ testCase "int with exponent only: 1e10" $ do
            r <- tokenKindTexts "1e10"
            r @?= [(TkFloatLiteral, "1e10")]

        , testCase "float trailing dot: 1." $ do
            r <- tokenKindTexts "1."
            r @?= [(TkFloatLiteral, "1.")]

        , testCase "float no int part: .5" $ do
            r <- tokenKindTexts ".5"
            r @?= [(TkFloatLiteral, ".5")]

        , testCase "lone dot is TkDot not float" $ do
            r <- tokenKinds "."
            r @?= [TkDot]

        , testCase "int with explicit plus: +42" $ do
            r <- tokenKindTexts "+42"
            r @?= [(TkIntLiteral, "+42")]

        , testCase "int with explicit minus: -42" $ do
            r <- tokenKindTexts "-42"
            r @?= [(TkIntLiteral, "-42")]

        , testCase "signed float with uppercase exponent: +1.5E-3" $ do
            r <- tokenKindTexts "+1.5E-3"
            r @?= [(TkFloatLiteral, "+1.5E-3")]
        ]
    , testGroup "datatypes (exhaustive)" $ map (kwCase TkDatatype)
        [ "any", "blob", "boolean", "byte", "char", "character"
        , "date", "datetime", "dec", "decimal", "double"
        , "int", "integer", "long", "longlong", "longptr"
        , "real", "string", "time", "uint", "ulong"
        , "unsignedint", "unsignedinteger", "unsignedlong"
        ]
    , testGroup "access modifiers (exhaustive)" $ map (kwCase TkAccessModifier)
        [ "public", "private", "protected"
        , "privateread", "privatewrite"
        , "protectedread", "protectedwrite"
        , "systemread", "systemwrite"
        , "global", "shared"
        ]
    , testGroup "storage modifiers (exhaustive)" $ map (kwCase TkStorageModifier)
        [ "readonly", "constant", "ref", "indirect", "static" ]
    , testGroup "SQL keywords (exhaustive)" $ map (kwCase TkSqlKw)
        [ "select", "selectblob", "insert", "update", "updateblob", "delete"
        , "commit", "rollback", "connect", "disconnect"
        , "declare", "cursor", "execute", "fetch", "prepare"
        , "describe", "descriptor", "open", "close"
        ]
    , testGroup "SQL keywords: case-insensitive"
        [ testCase "SELECT upper-case" $ do
            r <- tokenKinds "SELECT"
            r @?= [TkSqlKw]
        ]
    , testGroup "control keywords (single-word, exhaustive)" $ map (kwCase TkControlKw)
        [ "if", "then", "else", "elseif", "end"
        , "for", "to", "step", "next"
        , "do", "loop", "while", "until"
        , "choose", "case"
        , "try", "catch", "finally"
        , "exit", "continue", "return", "goto", "halt"
        , "throw"
        ]
    , testGroup "decl keywords (single-word, exhaustive)" $ map (kwCase TkDeclKw)
        [ "function", "subroutine", "event", "on", "type"
        , "variables", "prototypes", "forward"
        , "external", "intrinsic", "library", "alias"
        , "from", "within", "throws", "enumerated"
        , "autoinstantiate"
        ]
    , testGroup "other keywords (exhaustive)" $ map (kwCase TkOtherKw)
        [ "and", "or", "not", "xor"
        , "call", "post", "trigger", "create", "destroy"
        , "dynamic", "with", "using", "into", "of", "is", "it"
        , "as", "procedure", "rpcfunc", "namespace"
        , "this", "super", "parent", "parentwindow"
        , "sqlca", "sqlsa", "sqlda", "error", "message"
        ]
    , testGroup "compare operators" $ map cmpCase
        [ ">", "<", ">=", "<=", "<>" ]
    , testGroup "punctuation"
        [ testCase "double colon is TkDoubleColon" $ do
            r <- tokenKinds "x::y"
            r @?= [TkIdent, TkDoubleColon, TkIdent]

        , testCase "single colon is TkColon" $ do
            r <- tokenKinds "x:y"
            r @?= [TkIdent, TkColon, TkIdent]

        , testCase "label at column 1" $ do
            r <- tokenKindTexts "myLabel:"
            r @?= [(TkLabel, "myLabel:")]

        , testCase "dot" $ do
            r <- tokenKinds "."
            r @?= [TkDot]

        , testCase "left bracket" $ do
            r <- tokenKinds "["
            r @?= [TkLBracket]

        , testCase "right bracket" $ do
            r <- tokenKinds "]"
            r @?= [TkRBracket]

        , testCase "semicolon" $ do
            r <- tokenKinds ";"
            r @?= [TkSemi]

        , testCase "assign op" $ do
            r <- tokenKinds "x = 5"
            r @?= [TkIdent, TkAssignOp, TkIntLiteral]
        ]
    , testGroup "pathological"
        [ testCase "adjacent calls foo()bar()" $ do
            r <- tokenKinds "foo()bar()"
            r @?= [TkIdent, TkLParen, TkRParen, TkIdent, TkLParen, TkRParen]

        , testCase "bare end is a keyword" $ do
            r <- tokenKinds "end"
            r @?= [TkControlKw]

        , testCase "end followed by unknown word is two tokens" $ do
            r <- tokenKinds "end release"
            r @?= [TkControlKw, TkIdent]
        ]
    , testGroup "keyword-as-prefix-of-identifier"
        [ testCase "endure is TkIdent not TkControlKw" $ do
            r <- tokenKinds "endure"
            r @?= [TkIdent]

        , testCase "globally is TkIdent not TkAccessModifier" $ do
            r <- tokenKinds "globally"
            r @?= [TkIdent]

        , testCase "function_name is TkIdent" $ do
            r <- tokenKinds "function_name"
            r @?= [TkIdent]

        , testCase "selectall is TkIdent not TkSqlKw" $ do
            r <- tokenKinds "selectall"
            r @?= [TkIdent]
        ]
    , testGroup "binary operators"
        [ testCase "a + b: plus between identifiers" $ do
            r <- tokenKinds "a + b"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "x - y: minus between identifiers" $ do
            r <- tokenKinds "x - y"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "a * b: multiply" $ do
            r <- tokenKinds "a * b"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "a / b: divide" $ do
            r <- tokenKinds "a / b"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "a ^ b: exponent" $ do
            r <- tokenKinds "a ^ b"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "ii_count++: postfix increment" $ do
            r <- tokenKinds "ii_count++"
            r @?= [TkIdent, TkAugmentOp]

        , testCase "x += 1: augmented assignment" $ do
            r <- tokenKinds "x += 1"
            r @?= [TkIdent, TkAugmentOp, TkIntLiteral]

        , testCase "x -= y: augmented minus" $ do
            r <- tokenKinds "x -= y"
            r @?= [TkIdent, TkAugmentOp, TkIdent]
        ]
    , testGroup "dash-in-identifier ambiguity"
        [ testCase "foo-bar: no spaces fuses into single ident" $ do
            r <- tokenKindTexts "foo-bar"
            r @?= [(TkIdent, "foo-bar")]

        , testCase "foo - bar: spaced is ident op ident" $ do
            r <- tokenKinds "foo - bar"
            r @?= [TkIdent, TkArithOp, TkIdent]

        , testCase "cb-1: real corpus pattern stays single ident" $ do
            r <- tokenKindTexts "cb-1"
            r @?= [(TkIdent, "cb-1")]

        , testCase "foo - 5: spaced digit is ident op literal" $ do
            r <- tokenKinds "foo - 5"
            r @?= [TkIdent, TkArithOp, TkIntLiteral]

        , testCase "foo-bar-baz: chained dashes fuse" $ do
            r <- tokenKindTexts "foo-bar-baz"
            r @?= [(TkIdent, "foo-bar-baz")]
        ]
    , testGroup "comments are stripped"
        [ testCase "line comment: foo // bar yields only foo" $ do
            r <- tokenKinds "foo // bar"
            r @?= [TkIdent]

        , testCase "block comment: /* comment */ foo yields only foo" $ do
            r <- tokenKinds "/* comment */ foo"
            r @?= [TkIdent]

        , testCase "inline block comment: foo /* mid */ bar" $ do
            r <- tokenKinds "foo /* mid */ bar"
            r @?= [TkIdent, TkIdent]
        ]
    , testGroup "identifier special characters"
        [ testCase "dollar sign in ident: foo$bar" $ do
            r <- tokenKindTexts "foo$bar"
            r @?= [(TkIdent, "foo$bar")]

        , testCase "hash in ident: foo#bar" $ do
            r <- tokenKindTexts "foo#bar"
            r @?= [(TkIdent, "foo#bar")]

        , testCase "underscore-led ident: _foo" $ do
            r <- tokenKindTexts "_foo"
            r @?= [(TkIdent, "_foo")]

        , testCase "at-sign with underscore: @_param" $ do
            r <- tokenKindTexts "@_param"
            r @?= [(TkIdent, "@_param")]
        ]
    , testGroup "brace literals (array/struct initializers)"
        [ testCase "open brace is TkLBrace" $ do
            r <- tokenKinds "{"
            r @?= [TkLBrace]

        , testCase "close brace is TkRBrace" $ do
            r <- tokenKinds "}"
            r @?= [TkRBrace]

        , testCase "array literal {a, b}" $ do
            r <- tokenKinds "{a, b}"
            r @?= [TkLBrace, TkIdent, TkComma, TkIdent, TkRBrace]
        ]
    , testGroup "backtick in type references"
        [ testCase "ancestor`control in type ref" $ do
            r <- tokenKindTexts "w_parent`cb_ok"
            r @?= [(TkIdent, "w_parent`cb_ok")]
        ]
    , testGroup "embedded SQL at-sign identifiers"
        [ testCase "@action tokenizes as TkIdent with @ included" $ do
            r <- tokenKindTexts "@action"
            r @?= [(TkIdent, "@action")]

        , testCase "@contact_id tokenizes as single TkIdent" $ do
            r <- tokenKinds "@contact_id"
            r @?= [TkIdent]

        , testCase "@param = :var tokenizes correctly" $ do
            r <- tokenKinds "@param = :var"
            r @?= [TkIdent, TkAssignOp, TkColon, TkIdent]
        ]
    , testGroup "augmented ops (exhaustive)"
        [ testCase "-- standalone is TkAugmentOp" $ do
            r <- tokenKinds "--"
            r @?= [TkAugmentOp]
        , testCase "x--: dash in isIdentCont fuses into single ident" $ do
            r <- tokenKindTexts "x--"
            r @?= [(TkIdent, "x--")]
        , testCase "x -- (spaced): ident then decrement" $ do
            r <- tokenKinds "x --"
            r @?= [TkIdent, TkAugmentOp]
        , testCase "x *= 2: augmented multiply" $ do
            r <- tokenKinds "x *= 2"
            r @?= [TkIdent, TkAugmentOp, TkIntLiteral]
        , testCase "x /= 2: augmented divide" $ do
            r <- tokenKinds "x /= 2"
            r @?= [TkIdent, TkAugmentOp, TkIntLiteral]
        ]
    , testGroup "string literals: edge cases"
        [ testCase "empty single-quoted string" $ do
            r <- tokenKindTexts "''"
            r @?= [(TkStringSingle, "''")]
        , testCase "multiple escapes in one string" $ do
            r <- tokenKinds "\"~n~t~r~~\""
            r @?= [TkStringDouble]
        , testCase "adjacent double-quoted strings" $ do
            r <- tokenKinds "\"foo\"\"bar\""
            r @?= [TkStringDouble, TkStringDouble]
        , testCase "mixed adjacent: double then single" $ do
            r <- tokenKinds "\"foo\"'bar'"
            r @?= [TkStringDouble, TkStringSingle]
        ]
    , testGroup "block comment edge cases"
        [ testCase "no spaces around block comment: foo/*mid*/bar" $ do
            r <- tokenKinds "foo/*mid*/bar"
            r @?= [TkIdent, TkIdent]
        , testCase "empty block comment strips to nothing" $ do
            r <- tokenKinds "/**/"
            r @?= []
        , testCase "unterminated block comment is a lex error" $
            assertLexError "/* no end"
        ]
    , testGroup "enum beats keyword"
        [ testCase "true! is TkEnumLiteral" $ do
            r <- tokenKindTexts "true!"
            r @?= [(TkEnumLiteral, "true!")]
        , testCase "false! is TkEnumLiteral" $ do
            r <- tokenKindTexts "false!"
            r @?= [(TkEnumLiteral, "false!")]
        , testCase "null! is TkEnumLiteral" $ do
            r <- tokenKindTexts "null!"
            r @?= [(TkEnumLiteral, "null!")]
        , testCase "if! is TkEnumLiteral" $ do
            r <- tokenKindTexts "if!"
            r @?= [(TkEnumLiteral, "if!")]
        ]
    , testGroup "label edge cases"
        [ testCase "col > 1: leading space suppresses label" $ do
            r <- tokenKinds " myLabel:"
            r @?= [TkIdent, TkColon]
        , testCase "keyword text is still a label at col 1" $ do
            r <- tokenKindTexts "if:"
            r @?= [(TkLabel, "if:")]
        , testCase "label followed by statement on same line" $ do
            r <- tokenKindTexts "myLabel: x = 1"
            r @?= [ (TkLabel, "myLabel:"), (TkIdent, "x")
                  , (TkAssignOp, "="), (TkIntLiteral, "1") ]
        ]
    , testGroup "two-word keyword spacing"
        [ testCase "double space normalizes to single in token text" $ do
            r <- tokenKindTexts "end  if"
            r @?= [(TkControlKw, "end if")]
        , testCase "tab between words is accepted" $ do
            r <- tokenKinds "end\tif"
            r @?= [TkControlKw]
        , testCase "no space: endif is a single TkIdent" $ do
            r <- tokenKinds "endif"
            r @?= [TkIdent]
        ]
    , testGroup "lone parens"
        [ testCase "standalone ( is TkLParen" $ do
            r <- tokenKinds "("
            r @?= [TkLParen]
        , testCase "standalone ) is TkRParen" $ do
            r <- tokenKinds ")"
            r @?= [TkRParen]
        ]
    , testGroup "percent in identifier"
        [ testCase "foo%bar fuses into single ident" $ do
            r <- tokenKindTexts "foo%bar"
            r @?= [(TkIdent, "foo%bar")]
        , testCase "a % b is a lex error (% cannot start a token)" $
            assertLexError "a % b"
        ]
    , testGroup "numeric sign and ident disambiguation"
        [ testCase "1-foo: notFollowedBy isIdentCont fires, lex error" $
            assertLexError "1-foo"
        , testCase "1 - foo: spaced subtraction tokenizes correctly" $ do
            r <- tokenKindTexts "1 - foo"
            r @?= [(TkIntLiteral, "1"), (TkArithOp, "-"), (TkIdent, "foo")]
        , testCase "-.5: negative leading-dot float" $ do
            r <- tokenKindTexts "-.5"
            r @?= [(TkFloatLiteral, "-.5")]
        , testCase "+.5: positive leading-dot float" $ do
            r <- tokenKindTexts "+.5"
            r @?= [(TkFloatLiteral, "+.5")]
        , testCase "1e-10: negative exponent" $ do
            r <- tokenKindTexts "1e-10"
            r @?= [(TkFloatLiteral, "1e-10")]
        ]
    , testGroup "properties"
        [ testProperty "tokens carry correct line number" prop_tokensCorrectLine
        , testProperty "token text reconstructs input"   prop_tokenTextReconstructsInput
        ]
    ]
  ]

-- ---------------------------------------------------------------------------
-- Properties

prop_tokensCorrectLine :: Property
prop_tokensCorrectLine = property $ do
  t  <- forAll $ Gen.text (Range.linear 0 80)
                   (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let ll  = LogicalLine t 5 7
      res = tokenize [ll]
  case res of
    [LexLine _ (Right ts)] ->
      for_ ts $ \tk -> do
        assert (ssStartLine (tkSpan tk) == 5)
        assert (ssEndLine   (tkSpan tk) == 7)
    _ -> success

prop_tokenTextReconstructsInput :: Property
prop_tokenTextReconstructsInput = property $ do
  t <- forAll $ Gen.text (Range.linear 0 80)
                  (Gen.filter (\c -> c /= '\n' && c /= '\r') Gen.ascii)
  let ll  = LogicalLine t 1 1
      res = tokenize [ll]
  case res of
    [LexLine _ (Right ts)] ->
      for_ ts $ \tk ->
        assert (T.isInfixOf (tkText tk) t)
    _ -> success
