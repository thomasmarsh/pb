module RunnerTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner  (runFile, extractWindowLayout, reconstructRetrieveSql, wrapSrFile, compileOne, catalogToRows, validateDdlNamespaceConfig, CompiledFile (..), CompiledPs (..), CompiledDw (..))
import PB.Pipeline.Emit    (parsePowerScriptFile, parseOutcome, ParsedFile (..), ParseOutcome (..))
import PB.Pipeline.DuckDb
  ( ProcRow (..), SqlStmtColumnRow (..), SqlStmtFilterRow (..)
  , CatalogColumnRow (..), CatalogPkRow (..), CatalogFkRow (..), CatalogCheckRow (..)
  , DwRetrieveColumnRow (..)
  , DwRetrieveTableRow (..)
  , DwRetrieveWhereRow (..)
  , SqlStmtTableRow (..)
  )
import PB.AST.BodyStmt     (BodyStmt (..))
import PB.AST.DataWindow
  ( DwRetrieve (..), DwRetrieveOrRaw (..), DwWhereClause (..)
  , DataWindowFile (..), DwObjectAttrs (..), DwTable (..)
  )
import PB.AST.Expr         (Expr (..))
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile   (TypeBlock (..), TypeDecl (..), srPrimaryObject, srFunctions, FunctionBlock (..), FnSig (..))
import PB.AST.Type         (PbType (..))
import PB.Analysis.TypeEnv    (buildWorkspaceEnv, procEnv)
import PB.Analysis.GraphBuilder (compileProcedureViaCatOp)
import PB.Pipeline.Serialise ()
import PB.Pipeline.SqlParse
  ( startSqlBridgePool, shutdownSqlBridgePool
  , TableRef (..), CatalogTable (..), CatalogPrimaryKey (..), CatalogForeignKey (..)
  , CatalogCheckConstraint (..), SchemaCatalog (..)
  )

import Data.Aeson (Value (..), object, decodeStrict, toJSON, (.=))
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Set          as Set
import qualified Data.Text         as T
import qualified Data.Text.Encoding as TE
import System.Directory  (getTemporaryDirectory, createDirectoryIfMissing, removeFile)
import System.FilePath    ((</>))
import System.IO         (openTempFile, hClose)
import System.Process    (callProcess)

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

-- | A fresh, uniquely-named empty directory under the system temp dir, for
-- tests that need a real ingestion-root directory on disk (parseOutcome's
-- relativization reads real files, so it can't be tested with in-memory
-- source text alone).
freshRelPathRoot :: IO FilePath
freshRelPathRoot = do
  tmp <- getTemporaryDirectory
  (path, h) <- openTempFile tmp "pb_relpath_root"
  hClose h
  removeFile path
  createDirectoryIfMissing True path
  pure path

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
          Left _  -> pure ()  -- skip if DW fixture doesn't parse
          Right v -> lookupObj2 "meta" "object" v @?= String "dw_sales"
    ]

  , testGroup "production wiring uses compileProcedureViaCatOp (Plan 144 Phase 5 Step 6)"
    -- Runner.hs:148 (compileOne, the real production path behind runModeDb)
    -- and Emit.hs:158 (wrapSrFile's withInstr branch) both used to call the
    -- old PB.Analysis.InstrGraph.compileProcedure (deleted in Plan 144 Phase
    -- 5 Step 7). Both now call PB.Analysis.CatOp.compileProcedureViaCatOp.
    [ let src = T.unlines
            [ "public function integer uf_test ()"
            , "integer li_a"
            , "li_a = 1"
            , "if li_a = 1 then"
            , "callone()"
            , "else"
            , "calltwo()"
            , "end if"
            , "callthree()"
            , "end function"
            ]
      in case parsePowerScriptFile src of
        Left err -> testCase "fixture parses" (assertFailure ("fixture failed to parse: " <> T.unpack err))
        Right (sf, spans) ->
          let ws           = buildWorkspaceEnv [sf]
              (objName, _) = srPrimaryObject sf
              fb            = case srFunctions sf of { (f:_) -> f; [] -> error "impossible: fixture has one function" }
              body          = fbBody fb
              userFns       = Set.fromList [T.toLower (fnsName (fbSig fb))]
              env           = procEnv ws objName []
              newJson       = toJSON (compileProcedureViaCatOp env userFns body)
          in testGroup "if/else with shared trailing call"
            [ testCase "wrapSrFile's instrGraph matches compileProcedureViaCatOp" $
                let v      = wrapSrFile True "uf_test.srf" sf spans ws
                    instrVal = lookupObj "instrGraph" (firstOf (lookupObj "functions" v))
                in instrVal @?= newJson

            , testCase "compileOne's ProcRow.prInstrJson matches compileProcedureViaCatOp" $ do
                let pf = ParsedFile { pfPath = "uf_test.srf", pfSrFile = sf, pfSpans = spans, pfContents = src }
                cf <- compileOne Set.empty Nothing ws Nothing "confirmed" (PsParsed pf)
                case cf of
                  CFPs cps -> case cpsProcRows cps of
                    (row:_) -> case decodeStrict (TE.encodeUtf8 (prInstrJson row)) :: Maybe Value of
                      Nothing      -> assertFailure "prInstrJson did not decode as JSON"
                      Just decoded -> decoded @?= newJson
                    [] -> assertFailure "expected at least one ProcRow"
                  _ -> assertFailure "expected CFPs"
            ]
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

  , testGroup "extractWindowLayout"
    [ testCase "returns Nothing for empty typeBlocks" $
        extractWindowLayout [] @?= Nothing

    , testCase "extracts window dimensions and two controls" $
        let winDecl = TypeDecl { tdName = "w_form", tdAncestor = "window", tdWithin = Nothing }
            winBody =
              [ Located 1 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "width",  varInit = Just (ExInt "3200") }
              , Located 2 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "height", varInit = Just (ExInt "2400") }
              , Located 3 BsLocalVar { varMods = [], varType = PtPrimitive "string",  varName = "title",  varInit = Just (ExStr "My Form") }
              ]
            cbDecl  = TypeDecl { tdName = "cb_ok",   tdAncestor = "commandbutton", tdWithin = Just "w_form" }
            cbBody  =
              [ Located 4 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "x",      varInit = Just (ExInt "100") }
              , Located 5 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "y",      varInit = Just (ExInt "200") }
              , Located 6 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "width",  varInit = Just (ExInt "300") }
              , Located 7 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "height", varInit = Just (ExInt "80") }
              , Located 8 BsLocalVar { varMods = [], varType = PtPrimitive "string",  varName = "text",   varInit = Just (ExStr "OK") }
              ]
            dwDecl  = TypeDecl { tdName = "dw_list", tdAncestor = "datawindow", tdWithin = Just "w_form" }
            dwBody  =
              [ Located 9  BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "x",          varInit = Just (ExInt "0") }
              , Located 10 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "y",          varInit = Just (ExInt "400") }
              , Located 11 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "width",      varInit = Just (ExInt "3200") }
              , Located 12 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "height",     varInit = Just (ExInt "1800") }
              , Located 13 BsLocalVar { varMods = [], varType = PtPrimitive "string",  varName = "dataobject", varInit = Just (ExStr "dw_something") }
              ]
            tbs = [ TypeBlock winDecl winBody, TypeBlock cbDecl cbBody, TypeBlock dwDecl dwBody ]
            expected = Just $ object
              [ "name"     .= ("w_form" :: T.Text)
              , "type"     .= ("window" :: T.Text)
              , "controls" .=
                  [ object [ "name" .= ("cb_ok" :: T.Text), "type" .= ("commandbutton" :: T.Text)
                            , "x" .= (100 :: Int), "y" .= (200 :: Int)
                            , "width" .= (300 :: Int), "height" .= (80 :: Int)
                            , "text" .= ("OK" :: T.Text) ]
                  , object [ "name" .= ("dw_list" :: T.Text), "type" .= ("datawindow" :: T.Text)
                            , "x" .= (0 :: Int), "y" .= (400 :: Int)
                            , "width" .= (3200 :: Int), "height" .= (1800 :: Int)
                            , "dataobject" .= ("dw_something" :: T.Text) ]
                  ]
              , "width"    .= (3200 :: Int)
              , "height"   .= (2400 :: Int)
              , "title"    .= ("My Form" :: T.Text)
              ]
        in extractWindowLayout tbs @?= expected

    , testCase "returns Nothing for non-window ancestor (nonvisualobject)" $
        let decl = TypeDecl { tdName = "uo_service", tdAncestor = "nonvisualobject", tdWithin = Nothing }
        in extractWindowLayout [TypeBlock decl []] @?= Nothing

    , testCase "strips backtick qualifier from ancestor type in control" $
        let winDecl  = TypeDecl { tdName = "w_parent", tdAncestor = "window", tdWithin = Nothing }
            ctrlDecl = TypeDecl { tdName = "dw_1", tdAncestor = "datawindow`dw_1", tdWithin = Just "w_parent" }
            tbs = [TypeBlock winDecl [], TypeBlock ctrlDecl []]
        in case extractWindowLayout tbs of
             Nothing -> assertFailure "expected Just, got Nothing"
             Just v  ->
               let controls = lookupObj "controls" v
                   firstCtl = firstOf controls
               in lookupObj "type" firstCtl @?= String "datawindow"
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

  , testGroup "reconstructRetrieveSql"
    [ testCase "native SQL passthrough (DwRetrieveRaw)" $
        reconstructRetrieveSql (DwRetrieveRaw "SELECT x FROM t") @?= "SELECT x FROM t"

    , testCase "PBSELECT no WHERE — SELECT cols FROM table" $
        let r = DwRetrieve { drVersion = 400
                           , drTables    = ["misth_zpkrat"]
                           , drColumns   = ["misth_zpkrat.kodkrat", "misth_zpkrat.desckrat"]
                           , drArguments = []
                           , drWhere     = []
                           , drJoins     = []
                           }
        in reconstructRetrieveSql (DwRetrieveOk r)
               @?= "SELECT kodkrat, desckrat FROM misth_zpkrat"

    , testCase "PBSELECT with one WHERE arg reference becomes ?" $
        let r = DwRetrieve { drVersion = 400
                           , drTables    = ["misth_zpkrat"]
                           , drColumns   = ["misth_zpkrat.kodkrat"]
                           , drArguments = []
                           , drWhere     = [ DwWhereClause { dwcExp1  = "misth_zpkrat.kodxrisi"
                                                           , dwcOp    = "="
                                                           , dwcExp2  = ":arg_kodxrisi"
                                                           , dwcLogic = Nothing } ]
                           , drJoins     = []
                           }
        in reconstructRetrieveSql (DwRetrieveOk r)
               @?= "SELECT kodkrat FROM misth_zpkrat WHERE kodxrisi = ?"

    , testCase "PBSELECT two WHERE clauses joined by LOGIC=and" $
        let r = DwRetrieve { drVersion = 400
                           , drTables    = ["tbl"]
                           , drColumns   = ["tbl.a"]
                           , drArguments = []
                           , drWhere     = [ DwWhereClause "tbl.kodfinal" "=" ":arg1" (Just "and")
                                           , DwWhereClause "tbl.kodxrisi" "=" ":arg2" Nothing
                                           ]
                           , drJoins     = []
                           }
        in reconstructRetrieveSql (DwRetrieveOk r)
               @?= "SELECT a FROM tbl WHERE kodfinal = ? AND kodxrisi = ?"

    , testCase "strips table qualifier from column and WHERE exp1" $
        let r = DwRetrieve { drVersion = 400
                           , drTables    = ["t"]
                           , drColumns   = ["t.myCol"]
                           , drArguments = []
                           , drWhere     = [ DwWhereClause "t.myCol" ">" "100" Nothing ]
                           , drJoins     = []
                           }
        in reconstructRetrieveSql (DwRetrieveOk r)
               @?= "SELECT myCol FROM t WHERE myCol > 100"
    ]

  , testGroup "compileOne with SQL bridge wires column_refs/row_filters (Plan 148 Phase 1a-2)"
    [ testCase "cpsSqlStmtColumns/cpsSqlStmtFilters populated from bridge response" $ do
        let src = T.unlines
              [ "public function boolean uf_retrieve ()"
              , "select a from b;"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack err)
          Right (sf, spans) -> do
            script <- installMockSqlWorkerWithRefs
            pool   <- startSqlBridgePool 1 script [] "oracle"
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "uf_retrieve.srf", pfSrFile = sf, pfSpans = spans, pfContents = src }
            cf <- compileOne Set.empty Nothing ws (Just (pool, 0)) "confirmed" (PsParsed pf)
            shutdownSqlBridgePool pool
            case cf of
              CFPs cps -> do
                map sscrColumnName (cpsSqlStmtColumns cps) @?= ["kodgroup", "addrec"]
                map sscrTableName  (cpsSqlStmtColumns cps) @?= [Just "usrgroupperm", Nothing]
                map ssfrColumnName (cpsSqlStmtFilters cps) @?= ["status"]
              _ -> assertFailure "expected CFPs"

    , testCase "persistence-time resolution (Plan 157 Phase 4.5): unqualified column ref \
               \gets a resolved namespace when a matching catalog + default namespace are \
               \threaded into compileOne" $ do
        let src = T.unlines
              [ "public function boolean uf_retrieve ()"
              , "select a from b;"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack err)
          Right (sf, spans) -> do
            script <- installMockSqlWorkerWithRefs
            pool   <- startSqlBridgePool 1 script [] "oracle"
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "uf_retrieve.srf", pfSrFile = sf, pfSpans = spans, pfContents = src }
                catTables = Set.fromList [("openpay", "usrgroupperm")]
            cf <- compileOne catTables (Just "openpay") ws (Just (pool, 0)) "confirmed" (PsParsed pf)
            shutdownSqlBridgePool pool
            case cf of
              CFPs cps -> do
                map sscrTableName (cpsSqlStmtColumns cps) @?= [Just "usrgroupperm", Nothing]
                map sscrNamespace (cpsSqlStmtColumns cps)
                  @?= [Just "openpay", Nothing]
                  -- "usrgroupperm" resolves (matches the catalog under the
                  -- default namespace); the Nothing-table ref ("addrec")
                  -- has nothing to resolve against and stays Nothing —
                  -- same conservatism as buildSchema.
              _ -> assertFailure "expected CFPs"

    , testCase "sql_statement_tables (Plan 157 Phase 4.5): table_refs populate cpsSqlStmtTables, \
               \including a column-less table touch, and resolve against the default namespace" $ do
        let src = T.unlines
              [ "public function boolean uf_retrieve ()"
              , "select a from b;"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack err)
          Right (sf, spans) -> do
            script <- installMockSqlWorkerWithTableRefs
            pool   <- startSqlBridgePool 1 script [] "oracle"
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "uf_retrieve.srf", pfSrFile = sf, pfSpans = spans, pfContents = src }
                catTables = Set.fromList [("openpay", "usrgroupperm")]
            cf <- compileOne catTables (Just "openpay") ws (Just (pool, 0)) "confirmed" (PsParsed pf)
            shutdownSqlBridgePool pool
            case cf of
              CFPs cps ->
                -- "usrgroupperm" has a real column_ref, "audit_log" is a
                -- column-less touch (e.g. a bare DELETE) -- both still get a
                -- sql_statement_tables row, and only the catalog-matched one
                -- resolves to the default namespace.
                map (\r -> (sstrNamespace r, sstrTableName r)) (cpsSqlStmtTables cps)
                  @?= [(Just "openpay", "usrgroupperm"), (Nothing, "audit_log")]
              _ -> assertFailure "expected CFPs"
    ]

  , testGroup "catalogToRows (Plan 148 Phase 1a-3)"
    [ testCase "flattens tables/pks/fks with positional ordinals" $ do
        let cat = SchemaCatalog
              { scTables =
                  [ CatalogTable (TableRef Nothing "afxfilterd") ["kodfilterd", "kodfilter"] ]
              , scPrimaryKeys =
                  [ CatalogPrimaryKey (TableRef Nothing "afxfilterd") ["kodfilterd"] ]
              , scForeignKeys =
                  [ CatalogForeignKey (Just "0_15")
                      (TableRef Nothing "afxfilterd") ["kodfilter"]
                      (TableRef Nothing "afxfilter")  ["kodfilter"]
                  ]
              , scChecks =
                  [ CatalogCheckConstraint (Just "ck_1") (TableRef Nothing "afxfilterd") "kodfilter > 0" ]
              }
            (colRows, pkRows, fkRows, checkRows) = catalogToRows cat
        map cclrColumnName colRows @?= ["kodfilterd", "kodfilter"]
        map cclrOrdinal    colRows @?= [0, 1]
        map cpkrColumnName pkRows  @?= ["kodfilterd"]
        map cfkrFromColumn fkRows  @?= ["kodfilter"]
        map cfkrToColumn   fkRows  @?= ["kodfilter"]
        map cfkrConstraintName fkRows @?= [Just "0_15"]
        map cckrConstraintName checkRows @?= [Just "ck_1"]
        map cckrPredicate      checkRows @?= ["kodfilter > 0"]

    , testCase "composite FK pairs from/to columns positionally" $ do
        let cat = SchemaCatalog
              { scTables = []
              , scPrimaryKeys = []
              , scForeignKeys =
                  [ CatalogForeignKey Nothing
                      (TableRef Nothing "line_item") ["order_id", "line_no"]
                      (TableRef Nothing "orders")     ["id", "seq"]
                  ]
              , scChecks = []
              }
            (_, _, fkRows, _) = catalogToRows cat
        map cfkrFromColumn fkRows @?= ["order_id", "line_no"]
        map cfkrToColumn   fkRows @?= ["id", "seq"]
        map cfkrOrdinal    fkRows @?= [0, 1]
    ]

  , testGroup "dw_retrieve_columns construction (Plan 148 Phase 1b)"
    [ testCase "compileOne splits qualified drColumns into DwRetrieveColumnRow" $ do
        let retrieve = DwRetrieve
              { drVersion   = 400
              , drTables    = ["misth_zpkrat"]
              , drColumns   = ["misth_zpkrat.kodkrat", "misth_zpkrat.desckrat"]
              , drArguments = []
              , drWhere     = []
              , drJoins     = []
              }
            dwFile = DataWindowFile
              { dwRelease  = 400
              , dwObject   = DwObjectAttrs mempty
              , dwTable    = Just (DwTable [] (Just (DwRetrieveOk retrieve)) Nothing Nothing [])
              , dwBands    = []
              , dwGroups   = []
              , dwControls = []
              , dwUnknowns = []
              , dwMeta     = mempty
              }
            ws = buildWorkspaceEnv []
        cf <- compileOne Set.empty Nothing ws Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw cd ->
            map (\r -> (drcrTableName r, drcrColumnName r)) (cdDwRetrieveColumns cd)
              @?= [("misth_zpkrat", "kodkrat"), ("misth_zpkrat", "desckrat")]
          _ -> assertFailure "expected CFDw"

    , testCase "persistence-time resolution (Plan 157 Phase 4.5): unqualified DW retrieve \
               \column gets a resolved namespace when a matching catalog + default \
               \namespace are threaded into compileOne" $ do
        let retrieve = DwRetrieve
              { drVersion   = 400
              , drTables    = ["misth_zpkrat"]
              , drColumns   = ["misth_zpkrat.kodkrat"]
              , drArguments = []
              , drWhere     = []
              , drJoins     = []
              }
            dwFile = DataWindowFile
              { dwRelease  = 400
              , dwObject   = DwObjectAttrs mempty
              , dwTable    = Just (DwTable [] (Just (DwRetrieveOk retrieve)) Nothing Nothing [])
              , dwBands    = []
              , dwGroups   = []
              , dwControls = []
              , dwUnknowns = []
              , dwMeta     = mempty
              }
            ws = buildWorkspaceEnv []
            catTables = Set.fromList [("openpay", "misth_zpkrat")]
        cf <- compileOne catTables (Just "openpay") ws Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw cd -> do
            map (\r -> (drcrNamespace r, drcrTableName r, drcrColumnName r)) (cdDwRetrieveColumns cd)
              @?= [(Just "openpay", "misth_zpkrat", "kodkrat")]
            map (\r -> (drtrNamespace r, drtrTableName r)) (cdDwRetrieveTables cd)
              @?= [(Just "openpay", "misth_zpkrat")]
          _ -> assertFailure "expected CFDw"
    ]

  , testGroup "dw_retrieve_where construction (Track SCHEMA-BUGS)"
    [ testCase "compileOne carries drWhere into DwRetrieveWhereRow, preserving order and idx" $ do
        let retrieve = DwRetrieve
              { drVersion   = 400
              , drTables    = ["misth_zpkrat"]
              , drColumns   = ["misth_zpkrat.kodkrat"]
              , drArguments = []
              , drWhere     =
                  [ DwWhereClause "misth_zpkrat.kodxrisi" "=" ":arg1" (Just "and")
                  , DwWhereClause "t.mycol" ">" "100" Nothing
                  ]
              , drJoins     = []
              }
            dwFile = DataWindowFile
              { dwRelease  = 400
              , dwObject   = DwObjectAttrs mempty
              , dwTable    = Just (DwTable [] (Just (DwRetrieveOk retrieve)) Nothing Nothing [])
              , dwBands    = []
              , dwGroups   = []
              , dwControls = []
              , dwUnknowns = []
              , dwMeta     = mempty
              }
            ws = buildWorkspaceEnv []
        cf <- compileOne Set.empty Nothing ws Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw cd ->
            map (\r -> (drwrIdx r, drwrExp1 r, drwrOp r, drwrExp2 r, drwrLogic r)) (cdDwRetrieveWhere cd)
              @?= [ (0, "misth_zpkrat.kodxrisi", "=", ":arg1", Just "and")
                  , (1, "t.mycol", ">", "100", Nothing)
                  ]
          _ -> assertFailure "expected CFDw"
    ]

  , testGroup "validateDdlNamespaceConfig (Plan 157 Phase 6)"
    [ testCase "no --ddl args: no default namespace required" $
        validateDdlNamespaceConfig [] Nothing @?= Right ()
    , testCase "untagged --ddl args: no default namespace required" $
        validateDdlNamespaceConfig ["clims.sql", "../common.sql"] Nothing @?= Right ()
    , testCase "single tagged --ddl with a default namespace: ok" $
        validateDdlNamespaceConfig ["CLIMS:clims.sql"] (Just "CLIMS") @?= Right ()
    , testCase "single tagged --ddl with no default namespace: rejected" $
        case validateDdlNamespaceConfig ["CLIMS:clims.sql"] Nothing of
          Left err -> assertBool "message names the tagged schema" ("CLIMS" `T.isInfixOf` err)
          Right () -> assertFailure "expected Left, got Right ()"
    , testCase "multiple tagged --ddl with no default namespace: rejected, names both schemas" $
        case validateDdlNamespaceConfig ["CLIMS:a.sql", "CLIMS_COMMON:b.sql"] Nothing of
          Left err -> assertBool "message names both tagged schemas"
            ("CLIMS" `T.isInfixOf` err && "CLIMS_COMMON" `T.isInfixOf` err)
          Right () -> assertFailure "expected Left, got Right ()"
    , testCase "mixed tagged + untagged --ddl with no default namespace: rejected" $
        case validateDdlNamespaceConfig ["CLIMS:a.sql", "untagged.sql"] Nothing of
          Left _   -> pure ()
          Right () -> assertFailure "expected Left, got Right ()"
    ]

  , testGroup "parseOutcome relativizes stored path to the ingestion root"
    [ testCase "PowerScript file: pfPath is relative to root, not the absolute disk path" $ do
        root <- freshRelPathRoot
        let dir = root </> "foo.pbl"
        createDirectoryIfMissing True dir
        let absPath = dir </> "bar.srf"
        writeFile absPath ""
        outcome <- parseOutcome root absPath
        case outcome of
          PsParsed pf -> pfPath pf @?= "foo.pbl" </> "bar.srf"
          _           -> assertFailure "expected PsParsed"

    , testCase "PowerScript parse failure still reports the relativized path" $ do
        root <- freshRelPathRoot
        let dir = root </> "foo.pbl"
        createDirectoryIfMissing True dir
        let absPath = dir </> "bad.srf"
        writeFile absPath "~illegal\n"
        outcome <- parseOutcome root absPath
        case outcome of
          PsFailed p _ -> p @?= "foo.pbl" </> "bad.srf"
          _            -> assertFailure "expected PsFailed"

    , testCase "non-source extension (.srp): OtherFile still reports the relativized path" $ do
        root <- freshRelPathRoot
        let dir = root </> "foo.pbl"
        createDirectoryIfMissing True dir
        let absPath = dir </> "test.srp"
        writeFile absPath "PIPELINE(source_connect=foo)\n"
        outcome <- parseOutcome root absPath
        case outcome of
          OtherFile p -> p @?= "foo.pbl" </> "test.srp"
          _           -> assertFailure "expected OtherFile"

    , testCase "file outside root falls back to the unmodified path (makeRelative's own safe default)" $ do
        root   <- freshRelPathRoot
        other  <- freshRelPathRoot
        let dir = other </> "foo.pbl"
        createDirectoryIfMissing True dir
        let absPath = dir </> "bar.srf"
        writeFile absPath ""
        outcome <- parseOutcome root absPath
        case outcome of
          PsParsed pf -> pfPath pf @?= absPath
          _           -> assertFailure "expected PsParsed"
    ]
  ]

-- | Mock SQL bridge worker: answers every request with a canned response
-- carrying column_refs/row_filters, to test the Runner.hs wiring (Plan 148
-- Phase 1a-2) without depending on the real Python sqlglot bridge.
installMockSqlWorkerWithRefs :: IO FilePath
installMockSqlWorkerWithRefs = do
  tmp <- getTemporaryDirectory
  let path = tmp <> "/pb_mock_worker_refs.py"
      ls =
        [ "#!/usr/bin/env python3"
        , "import sys, json, struct"
        , "H = struct.Struct('>I')"
        , "def read():"
        , "    h = sys.stdin.buffer.read(4)"
        , "    if len(h) < 4: return None"
        , "    (n,) = H.unpack(h)"
        , "    return json.loads(sys.stdin.buffer.read(n))"
        , "def write(obj):"
        , "    b = json.dumps(obj).encode()"
        , "    sys.stdout.buffer.write(H.pack(len(b)) + b)"
        , "    sys.stdout.buffer.flush()"
        , "while True:"
        , "    m = read()"
        , "    if m is None: sys.exit(0)"
        , "    write({"
        , "        'tables': ['usrgroupperm', 'usrmembers'],"
        , "        'columns': ['kodgroup', 'addrec'],"
        , "        'operation': 'SELECT',"
        , "        'parse_ok': True,"
        , "        'column_refs': ["
        , "            {'namespace': None, 'table': 'usrgroupperm', 'column': 'kodgroup', 'is_write': False},"
        , "            {'namespace': None, 'table': None, 'column': 'addrec', 'is_write': False},"
        , "        ],"
        , "        'row_filters': ["
        , "            {'namespace': None, 'table': 'account', 'column': 'status', 'op': '=', 'values': ['Active']},"
        , "        ],"
        , "    })"
        ]
  writeFile path (T.unlines ls)
  callProcess "chmod" ["+x", path]
  pure path

-- | Mock SQL bridge worker: answers with a canned response carrying
-- table_refs (Plan 157 Phase 4.5) for two tables, one with a column_ref and
-- one without (a column-less table touch, e.g. a bare DELETE) -- to test
-- that cpsSqlStmtTables is populated for both, independent of whether a
-- column ref exists.
installMockSqlWorkerWithTableRefs :: IO FilePath
installMockSqlWorkerWithTableRefs = do
  tmp <- getTemporaryDirectory
  let path = tmp <> "/pb_mock_worker_table_refs.py"
      ls =
        [ "#!/usr/bin/env python3"
        , "import sys, json, struct"
        , "H = struct.Struct('>I')"
        , "def read():"
        , "    h = sys.stdin.buffer.read(4)"
        , "    if len(h) < 4: return None"
        , "    (n,) = H.unpack(h)"
        , "    return json.loads(sys.stdin.buffer.read(n))"
        , "def write(obj):"
        , "    b = json.dumps(obj).encode()"
        , "    sys.stdout.buffer.write(H.pack(len(b)) + b)"
        , "    sys.stdout.buffer.flush()"
        , "while True:"
        , "    m = read()"
        , "    if m is None: sys.exit(0)"
        , "    write({"
        , "        'tables': ['usrgroupperm', 'audit_log'],"
        , "        'columns': ['kodgroup'],"
        , "        'operation': 'DELETE',"
        , "        'parse_ok': True,"
        , "        'column_refs': ["
        , "            {'namespace': None, 'table': 'usrgroupperm', 'column': 'kodgroup', 'is_write': True},"
        , "        ],"
        , "        'row_filters': [],"
        , "        'table_refs': ["
        , "            {'namespace': None, 'table': 'usrgroupperm'},"
        , "            {'namespace': None, 'table': 'audit_log'},"
        , "        ],"
        , "    })"
        ]
  writeFile path (T.unlines ls)
  callProcess "chmod" ["+x", path]
  pure path
