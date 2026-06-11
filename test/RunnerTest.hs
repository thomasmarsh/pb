module RunnerTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (runFile)

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text         as T

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

lookupObj :: Text -> Value -> Value
lookupObj k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
lookupObj _ _          = Null

arrayLen :: Value -> Int
arrayLen (Array v) = length (toList v)
arrayLen _         = 0

firstOf :: Value -> Value
firstOf (Array v) = case toList v of { (x : _) -> x ; [] -> Null }
firstOf _         = Null

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Pipeline.Runner"
  [ testGroup "runFile PowerScript"
    [ testCase "empty source returns Right with empty sections" $ do
        case runFile "test.srf" "" of
          Left err -> assertFailure ("expected Right, got Left: " <> T.unpack err)
          Right v  -> do
            lookupObj "kind"       v @?= String "powerscript"
            arrayLen (lookupObj "headers"    v) @?= 0
            arrayLen (lookupObj "functions"  v) @?= 0
            arrayLen (lookupObj "subroutines" v) @?= 0
            arrayLen (lookupObj "onBlocks"   v) @?= 0

    , testCase "PBExportHeader line appears in headers array" $ do
        case runFile "foo.srs" "$PBExportHeader$foo.srs\n" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> arrayLen (lookupObj "headers" v) @?= 1

    , testCase "forward block populates forward.types" $ do
        let src = T.unlines
              [ "forward"
              , "type w_foo from window"
              , "end type"
              , "end forward"
              ]
        case runFile "foo.srw" src of
          Left err -> assertFailure (T.unpack err)
          Right v  -> arrayLen (lookupObj "types" (lookupObj "forward" v)) @?= 1

    , testCase "one function block populates functions array" $ do
        let src = T.unlines
              [ "public function integer f_add (integer a, integer b)"
              , "end function"
              ]
        case runFile "foo.srf" src of
          Left err -> assertFailure (T.unpack err)
          Right v  -> arrayLen (lookupObj "functions" v) @?= 1

    , testCase "lex error in body returns Left" $
        assertBool "expected Left" (isLeft (runFile "foo.srf" "@@@\n"))

    , testCase "real snippet: global type + on create + function" $ do
        let src = T.unlines
              [ "$PBExportHeader$w_example.srw"
              , "global type w_example from window"
              , "end type"
              , "on w_example.create"
              , "end on"
              , "public function integer f_add (integer a, integer b)"
              , "end function"
              ]
        case runFile "w_example.srw" src of
          Left err -> assertFailure (T.unpack err)
          Right v  -> do
            arrayLen (lookupObj "headers"    v) @?= 1
            arrayLen (lookupObj "typeBlocks" v) @?= 1
            arrayLen (lookupObj "onBlocks"   v) @?= 1
            arrayLen (lookupObj "functions"  v) @?= 1
            let sig = lookupObj "sig" (firstOf (lookupObj "functions" v))
            lookupObj "name"       sig @?= String "f_add"
            lookupObj "returnType" sig @?= String "integer"

    , testCase "type block with event decl + child instance in body" $ do
        let src = T.unlines
              [ "global type w_loadfilter from w_singleform"
              , "string title = \"\""
              , "event ie_checkbuttons ( )"
              , "cb_delete cb_delete"
              , "end type"
              ]
        case runFile "w_loadfilter.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "typeBlocks" v) @?= 1

    , testCase "forward block with type+vars inside (w_misth_ypal_form.srw pattern)" $ do
        let src = T.unlines
              [ "forward"
              , "type page3 from userobject within tab1"
              , "uo_yvar uo_yvar"
              , "end type"
              , "end forward"
              ]
        case runFile "test.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "types" (lookupObj "forward" v)) @?= 1

    , testCase "forward block with global instances inside (.sra pattern)" $ do
        let src = T.unlines
              [ "forward"
              , "global type openpay from application"
              , "end type"
              , "global transaction sqlca"
              , "global error error"
              , "end forward"
              ]
        case runFile "test.sra" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  ->
            arrayLen (lookupObj "types" (lookupObj "forward" v)) @?= 1

    , testCase "multi-line block comment does not cause lex error" $ do
        let src = T.unlines
              [ "public function boolean of_check (ref datawindow adw, long row);/*"
              , "string lstring"
              , "long   llong"
              , "*/"
              , "end function"
              ]
        case runFile "test.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right _  -> pure ()

    , testCase "on open/close blocks are parsed (TkSqlKw event names)" $ do
        let src = T.unlines
              [ "global type w_foo from window"
              , "end type"
              , "on open;"
              , "end on"
              , "on close;"
              , "end on"
              ]
        case runFile "test.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "onBlocks" v) @?= 2

    , testCase "type variables after global instance (w_dynsql_format4 pattern)" $ do
        let src = T.unlines
              [ "global type w_dynsql_format4 from w_center"
              , "end type"
              , "global w_dynsql_format4 w_dynsql_format4"
              , "type variables"
              , "integer i_count"
              , "end variables"
              ]
        case runFile "test.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> do
            arrayLen (lookupObj "typeBlocks" v) @?= 1
            arrayLen (lookupObj "globalInstances" v) @?= 1

    , testCase "variables block with declare cursor body (w_dynsql pattern)" $ do
        let src = T.unlines
              [ "type variables"
              , "declare ic_cursor dynamic cursor for sqlsa;"
              , "integer i_count"
              , "end variables"
              ]
        case runFile "test.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right _  -> pure ()

    , testCase "inline comment with /* pattern does not merge lines (f_dept_lookup pattern)" $ do
        let src = T.unlines
              [ "forward prototypes"
              , "global function boolean f_test (string a)"
              , "end prototypes"
              , "global function boolean f_test (string a);//***"
              , "// some comment"
              , "boolean lb_result"
              , "end function"
              ]
        case runFile "test.srf" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "functions" v) @?= 1

    , testCase "@action in function body does not cause lex error (w_sp_update pattern)" $ do
        let src = T.unlines
              [ "public function boolean f_test ()"
              , "declare sp procedure for sp_do"
              , "@action = :ls_action,"
              , "@id = :li_id"
              , "end function"
              ]
        case runFile "test.srw" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right _  -> pure ()

    , testCase "forward prototypes with public: access header parses (.srx pattern)" $ do
        let src = T.unlines
              [ "global type uo_sales from NonVisualObject"
              , "end type"
              , "forward prototypes"
              , "public:"
              , "function long SetConnect (connection theConnection)"
              , "end prototypes"
              ]
        case runFile "test.srx" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "decls" (lookupObj "prototypes" v)) @?= 1
    ]
  , testGroup "runFile stub extensions"
    [ testCase ".srp returns pipeline stub without touching the lexer" $ do
        case runFile "test.srp" "PIPELINE(source_connect=foo)\n" of
          Left err -> assertFailure ("expected Right stub, got: " <> T.unpack err)
          Right v  -> do
            lookupObj "kind"   v @?= String "pipeline"
            lookupObj "status" v @?= String "unimplemented"

    , testCase ".srj returns project stub without touching the lexer" $ do
        case runFile "test.srj" "EXE:test.exe,,0,1\n" of
          Left err -> assertFailure ("expected Right stub, got: " <> T.unpack err)
          Right v  -> do
            lookupObj "kind"   v @?= String "project"
            lookupObj "status" v @?= String "unimplemented"

    , testCase ".srp and .srj extension matching is case-insensitive" $ do
        assertBool ".SRP should stub" (isRight (runFile "X.SRP" ""))
        assertBool ".SRJ should stub" (isRight (runFile "X.SRJ" ""))
    ]
  ]
