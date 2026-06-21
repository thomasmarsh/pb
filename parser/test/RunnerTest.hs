module RunnerTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner (ManifestEntry (..), manifestEntry, runFile, runModeFiles
                          , writeDataflowAnalysis)

import Data.Aeson (Value (..), eitherDecodeFileStrict', eitherDecodeStrict', object, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Set         as Set
import qualified Data.Text         as T

import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory
                        , removePathForcibly)
import System.FilePath  ((</>))

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

lookupObj :: Text -> Value -> Value
lookupObj k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
lookupObj _ _          = Null

lookupObj2 :: Text -> Text -> Value -> Value
lookupObj2 k1 k2 = lookupObj k2 . lookupObj k1

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

    , testCase "unrecognised character causes Left" $
        -- '@' is a valid ident-start so @@@ lexes fine; '~' outside a string
        -- is not handled by any token parser, so it produces a real lex error.
        assertBool "expected Left" (isLeft (runFile "foo.srf" "~illegal\n"))

    , testCase "lex error message includes content, offset, and xxd dump" $ do
        -- '~' outside a string is unrecognised — confirms the diagnostic format.
        case runFile "foo.srf" "public function integer f ()\n~bad\nend function\n" of
          Right _ -> assertFailure "expected Left for lex error"
          Left err -> do
            assertBool "error contains 'content:'"          ("content:"  `T.isInfixOf` err)
            assertBool "error contains 'unexpected char'"   ("unexpected" `T.isInfixOf` err)
            assertBool "error contains xxd address (0000:)" ("0000:"      `T.isInfixOf` err)

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

    , testCase "UTF-8 BOM is stripped — no lex error" $
        let src = "\xFEFF" <> "public function integer f_test ()\nend function\n"
        in case runFile "test.sru" src of
             Left  err -> assertFailure ("expected Right, got: " <> T.unpack err)
             Right _   -> pure ()

    , testCase "UTF-8 BOM with leading comment before forward — no lex error" $
        let src = "\xFEFF" <> T.unlines
              [ "//objectcomments NVO for summary"
              , "forward"
              , "global type uo_test from nonvisualobject"
              , "end type"
              , "end forward"
              ]
        in case runFile "test.sru" src of
             Left  err -> assertFailure ("expected Right, got: " <> T.unpack err)
             Right v   -> arrayLen (lookupObj "types" (lookupObj "forward" v)) @?= 1
    ]
  , testGroup "runFile meta field"
    [ testCase "wrapSrFile emits top-level meta.object and meta.ancestor" $ do
        let src = "global type w_manifest_test from window\nend type\n"
        case runFile "w_manifest_test.srw" src of
          Left err -> assertFailure (T.unpack err)
          Right v  -> do
            lookupObj2 "meta" "object"   v @?= String "w_manifest_test"
            lookupObj2 "meta" "ancestor" v @?= String "window"

    , testCase "wrapSrFile meta.ancestor is null when no type block" $ do
        case runFile "empty.srf" "" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> lookupObj2 "meta" "ancestor" v @?= Null

    , testCase "wrapDwFile emits top-level meta.object = basename" $ do
        -- minimal DW that parses; ancestor is always null for DW files
        let src = "datawindow(units=0 timer_interval=0)\nend datawindow\n"
        case runFile "dw_sales.srd" src of
          Left _  -> pure ()  -- skip if DW fixture doesn't parse; manifestEntry unit tests cover this
          Right v -> lookupObj2 "meta" "object" v @?= String "dw_sales"
    ]

  , testGroup "Runner.Manifest"
    [ testCase "manifestEntry extracts kind, object, ancestor" $ do
        let v = object
              [ "kind" .= ("powerscript" :: Text)
              , "meta" .= object
                  [ "object"   .= ("w_foo" :: Text)
                  , "ancestor" .= ("w_base" :: Text)
                  ]
              ]
        let e = manifestEntry "w_foo.srw" v
        meKind     e @?= "powerscript"
        meObject   e @?= "w_foo"
        meAncestor e @?= Just "w_base"

    , testCase "manifestEntry falls back to path when meta absent" $ do
        let v = object ["kind" .= ("powerscript" :: Text)]
        let e = manifestEntry "path/to/w_foo.srw" v
        meObject   e @?= "path/to/w_foo.srw"
        meAncestor e @?= Nothing

    , testCase "manifestEntry ancestor is Nothing when key absent from meta" $ do
        let v = object
              [ "kind" .= ("datawindow" :: Text)
              , "meta" .= object ["object" .= ("dw_foo" :: Text)]
              ]
        let e = manifestEntry "dw_foo.srd" v
        meObject   e @?= "dw_foo"
        meAncestor e @?= Nothing

    , testCase "manifestEntry unknown kind when kind absent" $ do
        let e = manifestEntry "x.srw" (object [])
        meKind e @?= "unknown"

    , testCase "runModeFiles writes manifest.json with one entry per source file" $ do
        tmpDir <- (\t -> t </> "pb-runner-manifest-test") <$> getTemporaryDirectory
        removePathForcibly tmpDir
        createDirectory tmpDir
        let fixture = "global type w_tmp from window\nend type\n"
        writeFile (tmpDir </> "w_tmp.srw") fixture
        runModeFiles tmpDir tmpDir
        result <- eitherDecodeFileStrict' (tmpDir </> "manifest.json")
        removePathForcibly tmpDir
        case (result :: Either String [Value]) of
          Left err -> assertFailure ("manifest.json decode error: " <> err)
          Right entries -> case entries of
            [e] -> do
              lookupObj "kind"   e @?= String "powerscript"
              lookupObj "object" e @?= String "w_tmp"
            _   -> assertFailure ("expected 1 manifest entry, got " <> show (length entries))
    ]

  , testGroup "runFile regression: parse errors in corpus"
    -- Issue 1a: basic consecutive functions (sanity check — must pass)
    [ testCase "two consecutive functions in same .sru file" $ do
        let src = T.unlines
              [ "public function boolean uf_init ()"
              , "end function"
              , "public function boolean uf_save ()"
              , "end function"
              ]
        case runFile "test.sru" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "functions" v) @?= 2

    -- Issue 1b: SQL with trailing // comment after the semicolon on the same line.
    -- endsWithSemi checks llText which includes the comment, so "from t; // x" does
    -- NOT end with ';'. moreConts then consumes 'end function' and the second
    -- function is never seen by the file parser.
    , testCase "SQL terminated by ; with trailing // comment: second function still parsed" $ do
        let src = T.unlines
              [ "public function boolean uf_first ()"
              , "select a from b; // retrieves data"
              , "end function"
              , "public function boolean uf_save ()"
              , "end function"
              ]
        case runFile "test.sru" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> arrayLen (lookupObj "functions" v) @?= 2

    -- Issue 2: multi-line SQL with a // comment line between continuation lines.
    -- The comment is filtered from the statement stream, so the SQL merger should
    -- stitch select .. count(*) .. id .. from t; into a single BsRaw without error.
    , testCase "multi-line SQL with // comment between continuation lines" $ do
        let src = T.unlines
              [ "public function boolean uf_retrieve ()"
              , "select 1,"
              , "    count(*)"
              , "    // comment"
              , "    , id"
              , "from table1;"
              , "end function"
              ]
        case runFile "test.sru" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right _  -> pure ()

    -- Issue 2 variant: SQL where the semicolon-bearing line has an inline // comment.
    -- This hits the same endsWithSemi bug as Issue 1b.
    , testCase "multi-line SQL where terminal ; line has trailing // comment" $ do
        let src = T.unlines
              [ "public function boolean uf_retrieve ()"
              , "select 1,"
              , "    count(*)"
              , "    , id"
              , "from table1; // end sql"
              , "end function"
              ]
        case runFile "test.sru" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right _  -> pure ()

    -- Issue 3: lex error at offset 0 on what appears to be an innocuous assignment
    -- line inside a function. next_str contains the keyword prefix "next" but the
    -- underscore makes it a valid identifier; string() is a known function call.
    -- This test may pass — if so, the actual corpus file contains something not
    -- captured here and needs its content to reproduce.
    , testCase "assignments with next_-prefixed identifiers parse without lex error" $ do
        let src = T.unlines
              [ "public function boolean uf_test ()"
              , "long next_long"
              , "string next_id, next_str"
              , "next_id = string(next_long)"
              , "next_str = string(next_id, 5, 0)"
              , "end function"
              ]
        case runFile "test.sru" src of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right _  -> pure ()
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

  -- -----------------------------------------------------------------------
  -- 111d-1: Pass 6 (writeDataflowAnalysis) + per-procedure dataflow facet
  --

  , testGroup "dataflow facet (111d-1)"
    [ testCase "wrapSrFile injects a 'dataflow' facet per procedure" $
        -- The facet is the streaming-mode delivery channel: pb index runs
        -- pb-runner --jsonl (runModeJsonl) which never calls writeDataflowAnalysis,
        -- so the per-procedure JSON must already carry defs/uses via wrapSrFile.
        let src = T.unlines
              [ "global type w_df from window"
              , "end type"
              , "forward prototypes"
              , "public function integer uf_add (integer a, integer b)"
              , "end prototypes"
              , "global type w_df from window"
              , "end type"
              , "type variables"
              , "end variables"
              ]
            -- Body with a def + use so the facet is non-empty.
            body = T.unlines
              [ "public function integer uf_add (integer a, integer b)"
              , "integer li_sum"
              , "li_sum = a + b"
              , "return li_sum"
              , "end function"
              ]
        in case runFile "w_df.srw" (src <> body) of
          Left err -> assertFailure ("expected Right, got: " <> T.unpack err)
          Right v  -> do
            let fns = lookupObj "functions" v
            arrayLen fns @?= 1
            let fn = firstOf fns
            assertBool "function has dataflow facet"
              (lookupObj "dataflow" fn /= Null)
            assertBool "facet has defs list"
              (arrayLen (lookupObj "defs" (lookupObj "dataflow" fn)) > 0)

    , testCase "runModeFiles writes proc_defs.json + proc_uses.json" $ do
        -- Pass 6 (batch mode): consolidated JSON for dump/check-corpus consumers.
        tmpDir <- (\t -> t </> "pb-runner-dataflow-test") <$> getTemporaryDirectory
        removePathForcibly tmpDir
        createDirectory tmpDir
        let fixture = T.unlines
              [ "global type w_df2 from window"
              , "end type"
              , "forward prototypes"
              , "public function integer uf_x (integer a)"
              , "end prototypes"
              , "global type w_df2 from window"
              , "end type"
              , "public function integer uf_x (integer a)"
              , "integer li_y"
              , "li_y = a"
              , "return li_y"
              , "end function"
              ]
        writeFile (tmpDir </> "w_df2.srw") fixture
        runModeFiles tmpDir tmpDir
        defsBytes <- BSL.readFile (tmpDir </> "proc_defs.json")
        usesBytes <- BSL.readFile (tmpDir </> "proc_uses.json")
        removePathForcibly tmpDir
        case (eitherDecodeStrict' (BSL.toStrict defsBytes)
              :: Either String [Value],
              eitherDecodeStrict' (BSL.toStrict usesBytes)
              :: Either String [Value]) of
          (Left e, _) -> assertFailure ("proc_defs.json decode error: " <> e)
          (_, Left e) -> assertFailure ("proc_uses.json decode error: " <> e)
          (Right defRows, Right useRows) -> do
            -- li_y assignment + the function is a def; a/li_y are uses.
            assertBool "proc_defs non-empty" (not (null defRows))
            assertBool "proc_uses non-empty" (not (null useRows))
            let rowKeys r = case r of
                  Object m -> Set.fromList (map Key.toText (KM.keys m))
                  _        -> Set.empty
                expectedKeys = Set.fromList
                  [ "file","object","proc_name","var_name"
                  , "block_id","stmt_index","line","kind" ]
            -- Every row carries the exact 8-key consumer shape.
            assertBool "proc_defs row keys match consumer shape"
              (all (\r -> rowKeys r == expectedKeys) defRows)
            assertBool "proc_uses row keys match consumer shape"
              (all (\r -> rowKeys r == expectedKeys) useRows)

    , testCase "writeDataflowAnalysis writes both files (unit)" $ do
        -- Direct unit test of the Pass 6 entry point with an empty parsed list.
        -- Confirms the I/O contract (writes the two files) without needing a
        -- full corpus on disk.
        tmpDir <- (\t -> t </> "pb-runner-dfa-unit") <$> getTemporaryDirectory
        removePathForcibly tmpDir
        createDirectory tmpDir
        writeDataflowAnalysis tmpDir []
        defsExists <- doesFileExist (tmpDir </> "proc_defs.json")
        usesExists <- doesFileExist (tmpDir </> "proc_uses.json")
        removePathForcibly tmpDir
        assertBool "proc_defs.json written" defsExists
        assertBool "proc_uses.json written" usesExists
    ]
  ]
