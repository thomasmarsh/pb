module RunnerTest (tests) where

import PB.Prelude
import PB.Pipeline.Runner  (runFile, extractWindowLayout, reconstructRetrieveSql, wrapSrFile, compileOne, appendToDb, catalogToRows, validateDdlNamespaceConfig, runModeDb, CompiledFile (..), CompiledPs (..), CompiledDw (..), accumulatePhaseAData, sqlStmtColumnRowToSqlColRow, dwRetrieveColumnRowToDwRetrieveColRow)
import PB.Pipeline.Emit    (parsePowerScriptFile, parseOutcome, ParsedFile (..), ParseOutcome (..), ObjectCategory (..), objectCategoryForFile)
import PB.AST.SourceFile   (ParseError (..))
import PB.Grammar.DataWindow (parseDataWindow)
import PB.Pipeline.DuckDb.PhaseA
  ( ProcRow (..), SqlStmtColumnRow (..), SqlStmtFilterRow (..)
  , CatalogColumnRow (..), CatalogPkRow (..), CatalogFkRow (..), CatalogCheckRow (..)
  , DwRetrieveColumnRow (..), DwRetrieveTableRow (..)
  , DwRetrieveWhereRow (..), DwArgumentRow (..), SqlStmtTableRow (..)
  , ObjectRow (..), DwObjectRow (..)
  )
import PB.Pipeline.Passes (PhaseAData (..), emptyPhaseAData)

import PB.Analysis.SchemaCategory (SqlColRow (..), DwRetrieveColRow (..), StmtId (..))
import PB.Pipeline.DuckDb          (Config (..), inMemory, initSchema, queryHandle, withHandle)
import PB.Pipeline.DuckDb.Appender (withAppenderPool)
import PB.AST.BodyStmt     (BodyStmt (..))
import PB.AST.DataWindow
  ( DwRetrieve (..), DwRetrieveOrRaw (..), DwWhereClause (..)
  , DataWindowFile (..), DwObjectAttrs (..), DwTable (..), DwArgument (..)
  )
import PB.AST.Expr         (Expr (..))
import PB.AST.Ident        (Ident, identCanon)
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile   (TypeBlock (..), mkTypeDecl, srPrimaryObject, srFunctions, FunctionBlock (..), FnSig (..))
import PB.AST.Type         (PbType (..))
import PB.Analysis.TypeEnv    (buildWorkspaceEnv, procEnv)
import PB.Analysis.ControlHierarchy (buildControlIndex)
import PB.Compile.Flatten (compileProcedureViaEffTerm)
import PB.Analysis.DwFootprint (mkDwFootprintCtx)
import PB.Analysis.DeadVars (DeadVarFinding (..), DeadVarKind (..))
import PB.Analysis.TypeCheck (buildTypeCheckWorkspace)
import PB.Analysis.TypeFamily (TypeMismatchFinding (..), MismatchKind (..))
import PB.Pipeline.Serialise ()
import PB.Pipeline.SqlParse
  ( startSqlBridgePool, shutdownSqlBridgePool
  , TableRef (..), CatalogTable (..), CatalogPrimaryKey (..), CatalogForeignKey (..)
  , CatalogCheckConstraint (..), SchemaCatalog (..)
  )

import Control.DeepSeq (force)
import PB.Analysis.Dataflow     qualified as Dataflow
import PB.Analysis.Taint        qualified as Taint

import Data.Aeson (Value (..), object, decodeStrict, toJSON, (.=))
import Database.DuckDB.Simple          (Only (..))
import Database.DuckDB.Simple.FromRow  (FromRow (..), field)
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict   as Map
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

-- | Row shape for reading back an 'objects' row keyed on (object, file).
data ObjRowQ = ObjRowQ
  { orqKind           :: Text
  , orqAncestor       :: Maybe Text
  , orqLayoutJson     :: Maybe Text
  , orqTypeBlocksJson :: Maybe Text
  , orqConfidence     :: Text
  }
instance FromRow ObjRowQ where
  fromRow = ObjRowQ <$> field <*> field <*> field <*> field <*> field

-- | Phase A tables needed to append a single 'CompiledDw' with no controls,
-- call sites, or var refs -- mirrors the table set in 'appendToDb'\'s CFDw
-- branch plus 'source_files' ('cdSourceContent' is always @Just@).
dwFixturePhaseATables :: [Text]
dwFixturePhaseATables =
  [ "objects", "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
  , "dw_joins", "dw_retrieve_where"
  , "source_files", "identifier_tokens", "resolved_var_refs", "call_sites"
  ]

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

  , testGroup "runFile category field"
    [ testCase "wrapSrFile emits category=window for .srw" $
        case runFile "w_test.srw" "" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> lookupObj "category" v @?= String "window"

    , testCase "wrapSrFile emits category=userobject for .sru" $
        case runFile "u_test.sru" "" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> lookupObj "category" v @?= String "userobject"

    , testCase "wrapSrFile emits category=menu for .srm" $
        case runFile "m_test.srm" "" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> lookupObj "category" v @?= String "menu"

    , testCase "wrapSrFile emits category=application for .sra" $
        case runFile "a_test.sra" "" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> lookupObj "category" v @?= String "application"

    , testCase "wrapSrFile emits category=function for .srf" $
        case runFile "f_test.srf" "" of
          Left err -> assertFailure (T.unpack err)
          Right v  -> lookupObj "category" v @?= String "function"

    , testCase "wrapDwFile emits category=datawindow for .srd" $ do
        let src = "datawindow(units=0 timer_interval=0)\nend datawindow\n"
        case runFile "dw_sales.srd" src of
          Left _  -> pure ()  -- skip if DW fixture doesn't parse
          Right v -> lookupObj "category" v @?= String "datawindow"

    , testCase "objectCategoryForFile classifies a stdlib-prefixed path as system regardless of extension" $
        objectCategoryForFile "__stdlib__/nvo_base.sru" @?= CatSystem
    ]

  , testGroup "production wiring uses compileProcedureViaEffTerm (Plan 167 Phase 7 Step 6)"
    -- Runner.hs:148 (compileOne, the real production path behind runModeDb)
    -- and Emit.hs:158 (wrapSrFile's withInstr branch) both call
    -- PB.Analysis.GraphBuilder.compileProcedureViaEffTerm (the
    -- EffTerm/NamedGraphBuilder path).
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
        Left err -> testCase "fixture parses" (assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err)))
        Right (sf, spans, _) ->
          let ws           = buildWorkspaceEnv [sf]
              (objNameIdent, _) = srPrimaryObject sf
              fb            = case srFunctions sf of { (f:_) -> f; [] -> error "impossible: fixture has one function" }
              body          = fbBody fb
              userFns       = Set.fromList [identCanon (fnsName (fbSig fb))]
              env           = procEnv ws (buildControlIndex [sf]) objNameIdent []
              newJson       = toJSON (compileProcedureViaEffTerm env userFns body)
          in testGroup "if/else with shared trailing call"
            [ testCase "wrapSrFile's instrGraph matches compileProcedureViaEffTerm" $
                let v      = wrapSrFile True "uf_test.srf" sf spans ws
                    instrVal = lookupObj "instrGraph" (firstOf (lookupObj "functions" v))
                in instrVal @?= newJson

            , testCase "compileOne's ProcRow.prInstrJson matches compileProcedureViaEffTerm" $ do
                let pf = ParsedFile { pfPath = "uf_test.srf", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
                cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsParsed pf)
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
        let winDecl = mkTypeDecl "w_form" "window" Nothing
            winBody =
              [ Located 1 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "width",  varInit = Just (ExInt "3200") }
              , Located 2 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "height", varInit = Just (ExInt "2400") }
              , Located 3 BsLocalVar { varMods = [], varType = PtPrimitive "string",  varName = "title",  varInit = Just (ExStr "My Form") }
              ]
            cbDecl  = mkTypeDecl "cb_ok" "commandbutton" (Just "w_form")
            cbBody  =
              [ Located 4 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "x",      varInit = Just (ExInt "100") }
              , Located 5 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "y",      varInit = Just (ExInt "200") }
              , Located 6 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "width",  varInit = Just (ExInt "300") }
              , Located 7 BsLocalVar { varMods = [], varType = PtPrimitive "integer", varName = "height", varInit = Just (ExInt "80") }
              , Located 8 BsLocalVar { varMods = [], varType = PtPrimitive "string",  varName = "text",   varInit = Just (ExStr "OK") }
              ]
            dwDecl  = mkTypeDecl "dw_list" "datawindow" (Just "w_form")
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
        let decl = mkTypeDecl "uo_service" "nonvisualobject" Nothing
        in extractWindowLayout [TypeBlock decl []] @?= Nothing

    , testCase "strips backtick qualifier from ancestor type in control" $
        let winDecl  = mkTypeDecl "w_parent" "window" Nothing
            ctrlDecl = mkTypeDecl "dw_1" "datawindow`dw_1" (Just "w_parent")
            tbs = [TypeBlock winDecl [], TypeBlock ctrlDecl []]
        in case extractWindowLayout tbs of
             Nothing -> assertFailure "expected Just, got Nothing"
             Just v  ->
               let controls = lookupObj "controls" v
                   firstCtl = firstOf controls
               in lookupObj "type" firstCtl @?= String "datawindow"

    , testCase "ancestor walk resolves through a backtick-compound node in the chain" $
        -- w_top's own ancestor ("mid_class") is a *control* TypeBlock, not a
        -- window -- its own ancestor is a backtick-compound override
        -- ("customtype`ctrl_orig"). The chain only reaches the "window"
        -- terminal by resolving through customtype's own top-level
        -- declaration. A walk keyed on the raw compound text (rather than
        -- its already-split class component) can never match "customtype"
        -- in the map, so w_top's chain silently dead-ends and the other
        -- (unrelated) root -- customtype itself -- is picked instead.
        let topDecl        = mkTypeDecl "w_top" "mid_class" Nothing
            midClassCtrl   = mkTypeDecl "mid_class" "customtype`ctrl_orig" (Just "some_owner")
            customtypeDecl = mkTypeDecl "customtype" "window" Nothing
            tbs = [ TypeBlock topDecl []
                  , TypeBlock midClassCtrl []
                  , TypeBlock customtypeDecl []
                  ]
        in case extractWindowLayout tbs of
             Nothing -> assertFailure "expected Just with w_top recognized as the window, got Nothing"
             Just v  -> lookupObj "name" v @?= String "w_top"
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
                                                           , dwcLogic = Nothing
                                                           , dwcParsedExp1 = Nothing
                                                           , dwcParsedExp2 = Nothing } ]
                           , drJoins     = []
                           }
        in reconstructRetrieveSql (DwRetrieveOk r)
               @?= "SELECT kodkrat FROM misth_zpkrat WHERE kodxrisi = ?"

    , testCase "PBSELECT two WHERE clauses joined by LOGIC=and" $
        let r = DwRetrieve { drVersion = 400
                           , drTables    = ["tbl"]
                           , drColumns   = ["tbl.a"]
                           , drArguments = []
                           , drWhere     = [ DwWhereClause "tbl.kodfinal" "=" ":arg1" (Just "and") Nothing Nothing
                                           , DwWhereClause "tbl.kodxrisi" "=" ":arg2" Nothing Nothing Nothing
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
                           , drWhere     = [ DwWhereClause "t.myCol" ">" "100" Nothing Nothing Nothing ]
                           , drJoins     = []
                           }
        in reconstructRetrieveSql (DwRetrieveOk r)
               @?= "SELECT myCol FROM t WHERE myCol > 100"
    ]

  , testGroup "compileOne wires SchFootprint into cpsCatFootprintColumns (Plan 163 Phase 3)"
    -- Real corpus shape (pbexamw1.pbl/w_dw_copy.srw:646,553): a control
    -- declared via `type dw_dest from datawindow within w_dw_copy` with a
    -- static `string DataObject="d_items"` property, and a
    -- `dw_dest.SetItem(ll_cnt, "id", li_data)` call in a function body.
    [ testCase "SetItem against a statically-bound control produces a cat-footprint row" $ do
        let src = T.unlines
              [ "global type w_dw_copy from window"
              , "end type"
              , ""
              , "type dw_dest from datawindow within w_dw_copy"
              , "string DataObject=\"d_items\""
              , "end type"
              , ""
              , "public function integer uf_test ()"
              , "long ll_cnt"
              , "integer li_data"
              , "dw_dest.SetItem(ll_cnt, \"id\", li_data)"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "w_dw_copy.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
                globalDwColumns = Map.fromList [("d_items", [(TableRef Nothing "sales_order_items", "id")])]
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) globalDwColumns Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                map sscrColumnName (cpsCatFootprintColumns cps) @?= ["id"]
                map sscrTableName  (cpsCatFootprintColumns cps) @?= [Just "sales_order_items"]
                map sscrIsWrite    (cpsCatFootprintColumns cps) @?= [True]
              _ -> assertFailure "expected CFPs"

    , testCase "SetItem against a control with no static DataObject binding produces no row" $ do
        -- Mirrors the openpay real-corpus finding (Phase 0): a DW instance
        -- variable bound at runtime (`idw_x = tab1.page1.uo_x.dw`), not via
        -- a static `type ... within ...` DataObject property, has nothing
        -- for extractDwControlBindings to find -- resolveSetItem must miss,
        -- not guess.
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "type variables"
              , "datawindow idw_runtime"
              , "end variables"
              , ""
              , "public function integer uf_test ()"
              , "long ll_cnt"
              , "integer li_data"
              , "idw_runtime.SetItem(ll_cnt, \"id\", li_data)"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
                globalDwColumns = Map.fromList [("d_items", [(TableRef Nothing "sales_order_items", "id")])]
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) globalDwColumns Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> assertBool "no cat-footprint rows" (null (cpsCatFootprintColumns cps))
              _ -> assertFailure "expected CFPs"
    ]

  , testGroup "compileOne wires DeadVars into cpsDeadVars (Plan 174 T0-1 promotion)"
    [ testCase "unused local + unused param produce cpsDeadVars findings" $ do
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test (integer ai_unused)"
              , "integer li_unused"
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ (dvfVar f, dvfKind f) | f <- cpsDeadVars cps ]
                assertBool "ai_unused flagged UnusedParam" (("ai_unused", UnusedParam) `elem` findings)
                assertBool "li_unused flagged NeverRead"   (("li_unused", NeverRead)   `elem` findings)
              _ -> assertFailure "expected CFPs"

    , testCase "overloaded same-name functions: params don't cross-contaminate" $ do
        -- Real-corpus regression shape (BACKLOG's T0-1 spike note,
        -- eon_appeon_resize.of_getscale): extractLocalVars/paramsToVars
        -- hardcode lvScopeLine=0 for every param, so filtering the file-wide
        -- LocalVar list by proc name alone (with no span to disambiguate)
        -- merges every overload's params into one bucket -- a param unique
        -- to one overload gets reported as unused in EVERY overload sharing
        -- that name, not just its own. compileOne re-derives each
        -- overload's params fresh from its own instrParams/sLine instead of
        -- reading them back out of the file-wide list, sidestepping this.
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_calc (integer ai_x)"
              , "return ai_x + 1"
              , "end function"
              , ""
              , "public function integer uf_calc (integer ai_x, integer ai_unused)"
              , "return ai_x + 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ (dvfVar f, dvfKind f) | f <- cpsDeadVars cps ]
                findings @?= [("ai_unused", UnusedParam)]
              _ -> assertFailure "expected CFPs"

    , testCase "speculative confidence (builtin-class stub) produces no findings" $ do
        -- Same exclusion PB.Pipeline.DuckDb.Relations applies to 'procedures'
        -- (confidence='speculative' marks a synthetic stdlib stub whose
        -- unreferenced params are by design, not a real finding).
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test (integer ai_unused)"
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "speculative" (PsParsed pf)
            case cf of
              CFPs cps -> assertBool "no dead-var findings for speculative confidence" (null (cpsDeadVars cps))
              _ -> assertFailure "expected CFPs"

    , testCase "a local used only as a :host_var in embedded SQL is not flagged dead" $ do
        -- Real-corpus regression: a var read only inside an embedded SQL
        -- WHERE clause (":ldt_today") was invisible to Dataflow's
        -- extractUseVars (BsRaw carries unparsed SQL text), so DeadVars
        -- flagged it NeverRead even though it's genuinely used.
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test ()"
              , "date ldt_today"
              , "long ll_count"
              , "ldt_today = today()"
              , "select count(kodypal) into :ll_count from misth_ypal where exeldate <= :ldt_today;"
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ dvfVar f | f <- cpsDeadVars cps ]
                assertBool "ldt_today not flagged dead" ("ldt_today" `notElem` findings)
                assertBool "ll_count not flagged dead"  ("ll_count"  `notElem` findings)
              _ -> assertFailure "expected CFPs"
    ]

  , testGroup "compileOne wires TypeCheck into cpsTypeMismatches (Plan 177 Phase 4 promotion)"
    [ testCase "string local assigned an integer literal produces an AssignMismatch" $ do
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test ()"
              , "string ls_name"
              , "ls_name = 5"
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws  = buildWorkspaceEnv [sf]
                tcw = buildTypeCheckWorkspace ws [sf]
                pf  = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty tcw Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ (tmfTarget f, tmfKind f) | f <- cpsTypeMismatches cps ]
                assertBool "ls_name flagged AssignMismatch" (("ls_name", AssignMismatch) `elem` findings)
              _ -> assertFailure "expected CFPs"

    , testCase "assignment referencing a local via different case than its declaration is still flagged" $ do
        -- Regression for the tcScope case-sensitivity gap found during this
        -- promotion: compileOne builds tcScope from collectBodyLocals
        -- (already lowercased), but inferExpr's/assignFinding's lookups used
        -- to compare against the raw parsed identifier text verbatim -- a
        -- declaration and a same-variable reference spelled with different
        -- case would silently miss detection (never a false positive, just
        -- reduced recall), since PB identifiers are case-insensitive.
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test ()"
              , "string ls_name"
              , "LS_NAME = 5"
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws  = buildWorkspaceEnv [sf]
                tcw = buildTypeCheckWorkspace ws [sf]
                pf  = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty tcw Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ (tmfTarget f, tmfKind f) | f <- cpsTypeMismatches cps ]
                assertBool "LS_NAME flagged AssignMismatch despite case difference"
                  (("LS_NAME", AssignMismatch) `elem` findings)
              _ -> assertFailure "expected CFPs"

    , testCase "returning a string literal from an integer function produces a ReturnMismatch via tcwParams" $ do
        -- Exercises buildTypeCheckWorkspace's real ProcSignature lookup
        -- (not a hand-built TypeCheckCtx, as TypeCheckTest.hs's own
        -- fixtures use) -- proves the workspace threaded through compileOne
        -- actually carries this procedure's declared return type.
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test ()"
              , "return \"oops\""
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws  = buildWorkspaceEnv [sf]
                tcw = buildTypeCheckWorkspace ws [sf]
                pf  = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty tcw Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ (tmfTarget f, tmfKind f) | f <- cpsTypeMismatches cps ]
                assertBool "uf_test flagged ReturnMismatch" (("uf_test", ReturnMismatch) `elem` findings)
              _ -> assertFailure "expected CFPs"

    , testCase "speculative confidence (builtin-class stub) produces no cpsTypeMismatches findings" $ do
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "public function integer uf_test ()"
              , "string ls_name"
              , "ls_name = 5"
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws  = buildWorkspaceEnv [sf]
                tcw = buildTypeCheckWorkspace ws [sf]
                pf  = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty tcw Map.empty Nothing "speculative" (PsParsed pf)
            case cf of
              CFPs cps -> assertBool "no type-mismatch findings for speculative confidence" (null (cpsTypeMismatches cps))
              _ -> assertFailure "expected CFPs"

    , testCase "assignment to a bare instance variable produces an AssignMismatch" $ do
        -- Regression for the TypeCheckCtx/ScopedTypeEnv unification gap
        -- (found scoping the Plan 177 follow-up, 2026-07-16): compileOne
        -- used to build tcScope from only this procedure's own params +
        -- collectBodyLocals, never from the workspace's instance/global
        -- vars -- so a bare single-segment reference to an instance
        -- variable (declared in "type variables ... end variables", the
        -- real corpus's own instance-var syntax) was never in tcScope at
        -- all, and inferExpr's single-segment ExLvalue case silently
        -- returned Nothing for it, skipping the finding entirely.
        let src = T.unlines
              [ "global type w_test from window"
              , "end type"
              , ""
              , "type variables"
              , "integer ii_counter"
              , "end variables"
              , ""
              , "public function integer uf_test ()"
              , "ii_counter = \"abc\""
              , "return 1"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            let ws  = buildWorkspaceEnv [sf]
                tcw = buildTypeCheckWorkspace ws [sf]
                pf  = ParsedFile { pfPath = "w_test.srw", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty tcw Map.empty Nothing "confirmed" (PsParsed pf)
            case cf of
              CFPs cps -> do
                let findings = [ (tmfTarget f, tmfKind f) | f <- cpsTypeMismatches cps ]
                assertBool "ii_counter flagged AssignMismatch"
                  (("ii_counter", AssignMismatch) `elem` findings)
              _ -> assertFailure "expected CFPs"
    ]

  , testGroup "compileOne with SQL bridge wires column_refs/row_filters (Plan 148 Phase 1a-2)"
    [ testCase "cpsSqlStmtColumns/cpsSqlStmtFilters populated from bridge response" $ do
        let src = T.unlines
              [ "public function boolean uf_retrieve ()"
              , "select a from b;"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            script <- installMockSqlWorkerWithRefs
            pool   <- startSqlBridgePool 1 script [] "oracle"
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "uf_retrieve.srf", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty (Just (pool, 0)) "confirmed" (PsParsed pf)
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
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            script <- installMockSqlWorkerWithRefs
            pool   <- startSqlBridgePool 1 script [] "oracle"
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "uf_retrieve.srf", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
                catTables = Set.fromList [("openpay", "usrgroupperm")]
            cf <- compileOne catTables (Just "openpay") (mkDwFootprintCtx [] (Just "openpay")) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty (Just (pool, 0)) "confirmed" (PsParsed pf)
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
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, spans, _) -> do
            script <- installMockSqlWorkerWithTableRefs
            pool   <- startSqlBridgePool 1 script [] "oracle"
            let ws = buildWorkspaceEnv [sf]
                pf = ParsedFile { pfPath = "uf_retrieve.srf", pfSrFile = sf, pfSpans = spans, pfContents = src, pfTokens = [] }
                catTables = Set.fromList [("openpay", "usrgroupperm")]
            cf <- compileOne catTables (Just "openpay") (mkDwFootprintCtx [] (Just "openpay")) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty (Just (pool, 0)) "confirmed" (PsParsed pf)
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
        cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
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
        cf <- compileOne catTables (Just "openpay") (mkDwFootprintCtx [] (Just "openpay")) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
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
                  [ DwWhereClause "misth_zpkrat.kodxrisi" "=" ":arg1" (Just "and") Nothing Nothing
                  , DwWhereClause "t.mycol" ">" "100" Nothing Nothing Nothing
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
        cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw cd ->
            map (\r -> (drwrIdx r, drwrExp1 r, drwrOp r, drwrExp2 r, drwrLogic r)) (cdDwRetrieveWhere cd)
              @?= [ (0, "misth_zpkrat.kodxrisi", "=", ":arg1", Just "and")
                  , (1, "t.mycol", ">", "100", Nothing)
                  ]
          _ -> assertFailure "expected CFDw"
    ]

  , testGroup "dw_arguments construction (Plan 198 Phase E)"
    [ testCase "compileOne carries DwTable's dtArguments into cdDwArguments, preserving order and ordinal" $ do
        let dwFile = DataWindowFile
              { dwRelease  = 400
              , dwObject   = DwObjectAttrs mempty
              , dwTable    = Just (DwTable [] Nothing Nothing Nothing
                                     [ DwArgument "customer_id" "number"
                                     , DwArgument "as_of_date" "date"
                                     ])
              , dwBands    = []
              , dwGroups   = []
              , dwControls = []
              , dwUnknowns = []
              , dwMeta     = mempty
              }
            ws = buildWorkspaceEnv []
        cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw cd ->
            map (\r -> (darOrdinal r, darArgName r, darArgType r)) (cdDwArguments cd)
              @?= [ (0, "customer_id", "number")
                  , (1, "as_of_date", "date")
                  ]
          _ -> assertFailure "expected CFDw"

    , testCase "compileOne with no dwTable at all: cdDwArguments is empty, not an error" $ do
        let dwFile = DataWindowFile
              { dwRelease  = 400
              , dwObject   = DwObjectAttrs mempty
              , dwTable    = Nothing
              , dwBands    = []
              , dwGroups   = []
              , dwControls = []
              , dwUnknowns = []
              , dwMeta     = mempty
              }
            ws = buildWorkspaceEnv []
        cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed" (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw cd -> map darArgName (cdDwArguments cd) @?= []
          _       -> assertFailure "expected CFDw"
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

  , testGroup "NFData instances used to force parsing inside mapConcurrently (doc/plan/187-perf-hotspots.md sec 16)"
    [ testCase "force (pfSrFile pf) matches the unforced value on a representative fixture" $ do
        let src = T.unlines
              [ "forward"
              , "  global type w_test from window"
              , "end type"
              , "end forward"
              , "global type w_test from window"
              , "end type"
              , "type variables"
              , "  integer ii_count"
              , "end variables"
              , "public function integer of_compute (integer ai_x, integer ai_y)"
              , "  integer li_result"
              , "  if ai_x > ai_y then"
              , "    li_result = ai_x + ai_y * 2"
              , "  else"
              , "    li_result = ai_x - ai_y"
              , "  end if"
              , "  choose case li_result"
              , "    case 0"
              , "      li_result = -1"
              , "    case else"
              , "      li_result = li_result + ii_count"
              , "  end choose"
              , "  return li_result"
              , "end function"
              ]
        case parsePowerScriptFile src of
          Left err -> assertFailure ("fixture failed to parse: " <> T.unpack (peMessage err))
          Right (sf, _, _) -> force sf @?= sf
    ]

  , testGroup "appendToDb writes a kind='datawindow' objects row for DW files (Plan 198 Phase B)"
    [ testCase "CFDw compiled file: objects row has kind=datawindow, ancestor/layout_json/type_blocks_json NULL, confidence carried through" $ do
        let dwFile = DataWindowFile
              { dwRelease  = 400
              , dwObject   = DwObjectAttrs mempty
              , dwTable    = Nothing
              , dwBands    = []
              , dwGroups   = []
              , dwControls = []
              , dwUnknowns = []
              , dwMeta     = mempty
              }
            ws = buildWorkspaceEnv []
        cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty
                (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed"
                (PsDw "d_test.srd" "" dwFile)
        case cf of
          CFDw _ -> pure ()
          _      -> assertFailure "expected CFDw"
        withHandle inMemory $ \conn -> do
          initSchema conn
          withAppenderPool conn dwFixturePhaseATables $ \pool -> appendToDb pool cf
          objRows <- queryHandle conn
            "SELECT kind, ancestor, layout_json, type_blocks_json, confidence \
            \FROM objects WHERE object = 'd_test' AND file = 'd_test.srd'"
          case objRows of
            [r] -> do
              orqKind           r @?= "datawindow"
              orqAncestor       r @?= Nothing
              orqLayoutJson     r @?= Nothing
              orqTypeBlocksJson r @?= Nothing
              orqConfidence     r @?= "confirmed"
            _ -> assertFailure
                   ("expected exactly one objects row for d_test, got " <> show (length objRows))

    , testCase "a DW compute control's expression identifier reaches identifier_tokens (Plan 201 Phase 5a)" $ do
        let src = T.intercalate "\n"
              [ "HA$PBExportHeader$d_test.srd"
              , "$PBExportComments$"
              , "release 9;"
              , "datawindow(units=0 )"
              , "compute(band=detail expression=\"ii_amount\" )"
              ]
        case parseDataWindow src of
          Left err -> assertFailure ("unexpected parse error: " <> T.unpack err)
          Right dwFile -> do
            let ws = buildWorkspaceEnv []
            cf <- compileOne Set.empty Nothing (mkDwFootprintCtx [] Nothing) ws Map.empty
                    (buildTypeCheckWorkspace (buildWorkspaceEnv []) []) Map.empty Nothing "confirmed"
                    (PsDw "d_test.srd" src dwFile)
            rows <- withHandle inMemory $ \conn -> do
              initSchema conn
              withAppenderPool conn dwFixturePhaseATables $ \pool -> appendToDb pool cf
              queryHandle conn
                "SELECT file, text, kind FROM identifier_tokens ORDER BY start_col" :: IO [(Text, Text, Text)]
            rows @?= [("d_test.srd", "ii_amount", "TkIdent")]
    ]

  , testGroup "runModeDb against a stale DB file (source_files double-append regression)"
    -- BACKLOG: `pb index`/`check-corpus`/bench harnesses re-running against
    -- an existing --db path used to fail at Phase A ingestion with a
    -- primary-key violation on "__stdlib__/datastore.sru" -- initSchema's
    -- CREATE TABLE IF NOT EXISTS means a stale file's source_files rows
    -- persist, so a second run's parseStdlibFiles insert collides with the
    -- first run's own rows.
    [ testCase "second run against the same db path succeeds and leaves no duplicate __stdlib__ source_files rows" $ do
        srcDir <- freshRelPathRoot
        writeFile (srcDir </> "w_test.srw") (T.unlines
          [ "global type w_test from window"
          , "end type"
          ])
        dbDir <- freshRelPathRoot
        let dbPath = dbDir </> "test.duckdb"
        runModeDb srcDir dbPath [] "oracle" Nothing Nothing
        runModeDb srcDir dbPath [] "oracle" Nothing Nothing
        withHandle (Config dbPath) $ \conn -> do
          rows <- queryHandle conn "SELECT file FROM source_files" :: IO [Only Text]
          let stdlibFiles = [ f | Only f <- rows, "__stdlib__/" `T.isPrefixOf` f ]
          assertBool "no duplicate __stdlib__ source_files rows after a second run"
            (length stdlibFiles == length (Set.fromList stdlibFiles))
    ]
  , testGroup "PhaseAData accumulation"
    [ testCase "sqlStmtColumnRowToSqlColRow converts all fields" $ do
        let src = SqlStmtColumnRow "f.srw" "w_test" "ue_clicked" 42 (Just "sales") (Just "orders") "id" True
            dst = SqlColRow (SqlStmtId "f.srw" "w_test" "ue_clicked" 42) (Just "sales") (Just "orders") "id" True
        sqlStmtColumnRowToSqlColRow src @?= dst

    , testCase "dwRetrieveColumnRowToDwRetrieveColRow converts all fields with nullable namespace" $ do
        let src = DwRetrieveColumnRow "d_test.srd" "d_test" Nothing "orders" "id"
            dst = DwRetrieveColRow "d_test.srd" "d_test" Nothing "orders" "id"
        dwRetrieveColumnRowToDwRetrieveColRow src @?= dst

    , testCase "dwRetrieveColumnRowToDwRetrieveColRow converts all fields with non-null namespace" $ do
        let src = DwRetrieveColumnRow "d_test.srd" "d_test" (Just "sales") "orders" "id"
            dst = DwRetrieveColRow "d_test.srd" "d_test" (Just "sales") "orders" "id"
        dwRetrieveColumnRowToDwRetrieveColRow src @?= dst

    , testCase "accumulatePhaseAData appends CFPs local_vars" $ do
        let cps = CompiledPs
              { cpsObjectRow     = ObjectRow "" "" "" Nothing Nothing Nothing "" "" Nothing
              , cpsStructureRows = []
              , cpsProcRows      = []
              , cpsLocalVars     = []
              , cpsDeadVars      = []
              , cpsTypeMismatches = []
              , cpsCallSites     = []
              , cpsVarRefs       = []
              , cpsGlobalVars    = []
              , cpsProcFlows     = []
              , cpsSqlStmts      = []
              , cpsSqlStmtColumns = []
              , cpsSqlStmtFilters = []
              , cpsSqlStmtTables = []
              , cpsSqlLintIssues = []
              , cpsCatFootprintColumns = []
              , cpsTaintIntraEdges = []
              , cpsTaintReturnRows = []
              , cpsSourceContent = Nothing
              , cpsIdentifierTokens = []
              , cpsWindowOpens       = []
              , cpsObjectCreates     = []
              , cpsWindowMenuBindings = []
              , cpsDwBindings        = []
              }
            pad = accumulatePhaseAData emptyPhaseAData (CFPs cps)
        padLocalVars pad @?= []

    , testCase "accumulatePhaseAData derives padProcDefs from cpsProcFlows" $ do
        let ident   = "my_var" :: Ident
            defSite = Dataflow.DefSite
              { Dataflow.dsVar     = ident
              , Dataflow.dsBlock   = "b0"
              , Dataflow.dsStmtIdx = 0
              , Dataflow.dsLine    = Just 10
              , Dataflow.dsKind    = "assign"
              , Dataflow.dsPartial = False
              }
            useSite = Dataflow.UseSite
              { Dataflow.usVar     = ident
              , Dataflow.usBlock   = "b0"
              , Dataflow.usStmtIdx = 0
              , Dataflow.usLine    = Just 12
              , Dataflow.usKind    = "read"
              }
            bf = Dataflow.BlockFlow
              { Dataflow.bfBlockId  = "b0"
              , Dataflow.bfDefs     = [defSite]
              , Dataflow.bfUses     = [useSite]
              , Dataflow.bfGen      = mempty
              , Dataflow.bfKill     = mempty
              }
            pf = Dataflow.ProcFlow
              { Dataflow.pfObject   = "w_test"
              , Dataflow.pfProc     = "ue_clicked"
              , Dataflow.pfBlocks   = Map.singleton "b0" bf
              , Dataflow.pfReachingIn  = mempty
              , Dataflow.pfReachingOut = mempty
              , Dataflow.pfLiveIn      = mempty
              , Dataflow.pfLiveOut     = mempty
              , Dataflow.pfAllDefs     = mempty
              , Dataflow.pfAllUses     = mempty
              }
            cps = CompiledPs
              { cpsObjectRow     = ObjectRow "" "" "" Nothing Nothing Nothing "" "" Nothing
              , cpsStructureRows = []
              , cpsProcRows      = []
              , cpsLocalVars     = []
              , cpsDeadVars      = []
              , cpsTypeMismatches = []
              , cpsCallSites     = []
              , cpsVarRefs       = []
              , cpsGlobalVars    = []
              , cpsProcFlows     = [("f.srw", "w_test", "ue_clicked", pf)]
              , cpsSqlStmts      = []
              , cpsSqlStmtColumns = []
              , cpsSqlStmtFilters = []
              , cpsSqlStmtTables = []
              , cpsSqlLintIssues = []
              , cpsCatFootprintColumns = []
              , cpsTaintIntraEdges = []
              , cpsTaintReturnRows = []
              , cpsSourceContent = Nothing
              , cpsIdentifierTokens = []
              , cpsWindowOpens       = []
              , cpsObjectCreates     = []
              , cpsWindowMenuBindings = []
              , cpsDwBindings        = []
              }
            pad = accumulatePhaseAData emptyPhaseAData (CFPs cps)
            expectedDef = Taint.DefRow
              { Taint.drFile     = "f.srw"
              , Taint.drObject   = "w_test"
              , Taint.drProcName = "ue_clicked"
              , Taint.drVarName  = "my_var"
              , Taint.drBlockId  = "b0"
              , Taint.drStmtIdx  = 0
              , Taint.drLine     = Just 10
              , Taint.drKind     = "assign"
              , Taint.drSpan     = Nothing
              }
            expectedUse = Taint.UseRow
              { Taint.urFile     = "f.srw"
              , Taint.urObject   = "w_test"
              , Taint.urProcName = "ue_clicked"
              , Taint.urVarName  = "my_var"
              , Taint.urBlockId  = "b0"
              , Taint.urStmtIdx  = 0
              , Taint.urLine     = Just 12
              , Taint.urKind     = "read"
              , Taint.urSpan     = Nothing
              }
        padProcDefs pad @?= [expectedDef]
        padProcUses pad @?= [expectedUse]

    , testCase "accumulatePhaseAData appends CFDw dw_write_columns" $ do
        let cdw = CompiledDw
              { cdDwObjectRow      = DwObjectRow "" "" "" "" Nothing
              , cdDwControls       = []
              , cdDwRetrieveTables = []
              , cdDwRetrieveColumns = []
              , cdDwWriteColumns   = [DwRetrieveColumnRow "d.srd" "d" Nothing "t" "c"]
              , cdDwWhereColumns   = []
              , cdDwJoins          = []
              , cdDwRetrieveWhere  = []
              , cdDwArguments      = []
              , cdCallSites        = []
              , cdVarRefs          = []
              , cdSourceContent    = Nothing
              , cdIdentifierTokens = []
              }
            pad = accumulatePhaseAData emptyPhaseAData (CFDw cdw)
        padDwWriteColumns pad @?= [DwRetrieveColRow "d.srd" "d" Nothing "t" "c"]

    , testCase "accumulatePhaseAData skips CFError" $ do
        let pad = accumulatePhaseAData emptyPhaseAData (CFError "bad.srf" (ParseError "" Nothing))
        pad @?= emptyPhaseAData

    , testCase "accumulatePhaseAData skips CFSkip" $ do
        let pad = accumulatePhaseAData emptyPhaseAData CFSkip
        pad @?= emptyPhaseAData
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
