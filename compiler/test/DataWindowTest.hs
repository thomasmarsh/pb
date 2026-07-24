module DataWindowTest (tests) where

import PB.Prelude
import PB.AST.DataWindow
import PB.AST.Expr           (Expr (..), Lvalue (..), LvSegment (..), BinOp (..))
import PB.AST.Ident          (identSpan, provenanceSpan)
import PB.Lexing.DataWindow  (DwAttr (..), extractParenBlock, scanBlockAttrs)
import PB.Lexing.Token       (SourceSpan (..), tkText)
import PB.Grammar.DataWindow (parseDataWindow, parseBandKind, parseDwTable, parsePbSelect,
                               parseColumn, parseDwBand, parseDwGroup, parseGroupBy,
                               parseDwObjectAttrs)

import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

import Hedgehog (assert, forAll, property, (===))
import qualified Hedgehog.Gen   as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "DataWindow"
  [ testGroup "extractParenBlock"
      [ testCase "single-line block" $
          -- "keyword(hello)"  offsets: k=0..d=6  (=7  h..o=8..12  )=13
          extractParenBlock "keyword(hello)" 7 @?= Right ("hello", 14)

      , testCase "multi-line block" $
          -- "a(\nhello\n)"  (=1  \n=2  h..o=3..7  \n=8  )=9
          extractParenBlock "a(\nhello\n)" 1 @?= Right ("\nhello\n", 10)

      , testCase "nested parens" $
          -- "f(a(b)c)"  (=1  a=2  (=3  b=4  )=5  c=6  )=7
          extractParenBlock "f(a(b)c)" 1 @?= Right ("a(b)c", 8)

      , testCase "quoted value containing close-paren" $
          -- f(x="a)b")  (=1  x=2..==3  "=4  a=5  )=6  b=7  "=8  )=9
          -- the ) at offset 6 is inside quotes and must be ignored
          extractParenBlock "f(x=\"a)b\")" 1 @?= Right ("x=\"a)b\"", 10)

      , testCase "tilde-escape ~\" inside quoted value" $
          -- f(x="a~"b")  (=1  x=2=3  "=4  a=5  ~=6  "=7  b=8  "=9  )=10
          -- ~" at 6-7 is an escaped quote; string continues to "=9, then )=10 ends block
          extractParenBlock "f(x=\"a~\"b\")" 1 @?= Right ("x=\"a~\"b\"", 11)

      , testCase "double-tilde ~~ before close-quote" $
          -- f(x="te~~")  (=1  x=2=3  "=4  t=5  e=6  ~=7  ~=8  "=9  )=10
          -- ~~ at 7-8 is escaped tilde; " at 9 closes the string normally
          extractParenBlock "f(x=\"te~~\")" 1 @?= Right ("x=\"te~~\"", 11)

      , testCase "unclosed paren returns Left" $
          assertBool "expected Left for unclosed paren"
            (isLeft (extractParenBlock "f(hello" 1))
      ]

  , testGroup "parseBandKind"
      [ testCase "header → BkHeader"     $ parseBandKind "header"     @?= Just BkHeader
      , testCase "detail → BkDetail"     $ parseBandKind "detail"     @?= Just BkDetail
      , testCase "footer → BkFooter"     $ parseBandKind "footer"     @?= Just BkFooter
      , testCase "summary → BkSummary"   $ parseBandKind "summary"    @?= Just BkSummary
      , testCase "background → BkBackground" $
          parseBandKind "background" @?= Just BkBackground
      , testCase "foreground → BkForeground" $
          parseBandKind "foreground" @?= Just BkForeground
      , testCase "header.2 → BkGroupHeader 2" $
          parseBandKind "header.2"   @?= Just (BkGroupHeader 2)
      , testCase "trailer.3 → BkGroupTrailer 3" $
          parseBandKind "trailer.3"  @?= Just (BkGroupTrailer 3)
      , testCase "header[1] → BkGroupHeader 1" $
          parseBandKind "header[1]"  @?= Just (BkGroupHeader 1)
      , testCase "tree.level.1 → BkTreeLevel 1" $
          parseBandKind "tree.level.1" @?= Just (BkTreeLevel 1)
      , testCase "tree.level.3 → BkTreeLevel 3" $
          parseBandKind "tree.level.3" @?= Just (BkTreeLevel 3)
      , testCase "tree.level[2] → BkTreeLevel 2" $
          parseBandKind "tree.level[2]" @?= Just (BkTreeLevel 2)
      , testCase "unknown → Nothing" $
          parseBandKind "htmltable"  @?= Nothing
      ]

  , testGroup "parseDataWindow"
      [ testCase "minimal: release + datawindow block only" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> do
              dwRelease  dw @?= 9
              null (dwBands    dw) @?= True
              null (dwControls dw) @?= True
              isNothing (dwTable dw) @?= True

      , testCase "release number extracted correctly" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 12;"
                , "datawindow(units=0 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> dwRelease dw @?= 12

      , testCase "with table block (stub — table fields empty)" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "table(column=(type=char(10) name=foo ))"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> isJust (dwTable dw) @?= True

      , testCase "with header+detail+footer bands" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "header(height=72 )"
                , "detail(height=80 )"
                , "footer(height=0 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> do
              length (dwBands dw) @?= 3
              map dbKind (dwBands dw) @?= [BkHeader, BkDetail, BkFooter]

      , testCase "with group block" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "group(level=1 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> length (dwGroups dw) @?= 1

      , testCase "with text control" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "text(band=header x=\"0\" y=\"0\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case dwControls dw of
              [c] -> dwcType c @?= "text"
              cs  -> assertFailure
                       ("expected 1 control, got " <> show (length cs))

      , testCase "meta-block export.pdf" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "export.pdf(method=0 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  ->
              assertBool "export.pdf key present in meta"
                (Map.member "export.pdf" (dwMeta dw))

      , testCase "negative: missing release line" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "datawindow(units=0 )"
                ]
          assertBool "should fail when release line is absent"
            (isLeft (parseDataWindow src))
      ]

  , testGroup "DataWindow expression identifiers carry real source spans"
      [ testCase "compute control expression Ident has real line/col matching source" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "compute(band=detail expression=\"ii_amount\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case dwControls dw of
              [c] -> case dwcParsedExpression c of
                Just (ExLvalue (Lvalue [LvSegment ident Nothing])) ->
                  provenanceSpan (identSpan ident) @?= Just (SourceSpan 5 33 5 42)
                other -> assertFailure ("expected simple lvalue expression, got " <> show other)
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "format expression Ident position accounts for ~t prefix" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "compute(band=detail format=\"[GENERAL]~tii_amount\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case dwControls dw of
              [c] -> case dwcParsedFormat c of
                Just (ExLvalue (Lvalue [LvSegment ident Nothing])) ->
                  provenanceSpan (identSpan ident) @?= Just (SourceSpan 5 40 5 49)
                other -> assertFailure ("expected simple lvalue expression, got " <> show other)
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "dwcExpressionTokens/dwcFormatTokens carry the raw lexed tokens dwcParsedExpression/Format were parsed from (Plan 201 Phase 5a)" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "compute(band=detail expression=\"ii_amount\" format=\"[GENERAL]~tii_fmt\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case dwControls dw of
              [c] -> do
                map tkText (dwcExpressionTokens c) @?= ["ii_amount"]
                map tkText (dwcFormatTokens c)     @?= ["ii_fmt"]
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "dwcExpressionTokens/dwcFormatTokens are empty when no expression/format is present" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "compute(band=detail )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case dwControls dw of
              [c] -> do
                dwcExpressionTokens c @?= []
                dwcFormatTokens     c @?= []
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))
      ]

  , testGroup "WHERE-clause operand identifiers carry real source spans"
      [ testCase "plain table.column EXP1 / :hostvar EXP2 get real positions" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "table(retrieve=\"PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
                  \WHERE( EXP1 =~\"t.kodfilter~\" OP =~\"=~\" EXP2 =~\":kodfilter~\" ) )\" )"
                ]
          case parseDataWindow src of
            Left err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw -> case dwTable dw >>= dtRetrieve of
              Just (DwRetrieveOk r) -> case drWhere r of
                [wc] -> do
                  case dwcParsedExp1 wc of
                    Just (ExLvalue (Lvalue [LvSegment t' Nothing, LvSegment col Nothing])) -> do
                      provenanceSpan (identSpan t')  @?= Just (SourceSpan 5 73 5 74)
                      provenanceSpan (identSpan col) @?= Just (SourceSpan 5 75 5 84)
                    other -> assertFailure ("expected 2-segment lvalue, got " <> show other)
                  case dwcParsedExp2 wc of
                    Just (ExHostVar (Lvalue [LvSegment v Nothing])) ->
                      provenanceSpan (identSpan v) @?= Just (SourceSpan 5 106 5 115)
                    other -> assertFailure ("expected host var, got " <> show other)
                ws -> assertFailure ("expected 1 WHERE clause, got " <> show (length ws))
              other -> assertFailure ("expected DwRetrieveOk, got " <> show other)

      , testCase "leading-paren leakage: anchor advances past the stripped '(' to the real identifier column" $ do
          -- Real .srd shape (doc/spec.md 7.3): a boundary row's EXP1 carries a
          -- surplus leading '(' that 'stripSurplusParens' strips before
          -- parsing -- the anchor must advance past exactly that stripped
          -- prefix, not stay pinned at the raw attribute start.
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "table(retrieve=\"PBSELECT( VERSION(400) TABLE(NAME=~\"misth_final~\") \
                  \WHERE( EXP1 =~\"( misth_final.kodfinal~\" OP =~\"=~\" \
                  \EXP2 =~\":arg_kodfinal )~\" ) )\" )"
                ]
          case parseDataWindow src of
            Left err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw -> case dwTable dw >>= dtRetrieve of
              Just (DwRetrieveOk r) -> case drWhere r of
                [wc] -> do
                  case dwcParsedExp1 wc of
                    Just (ExLvalue (Lvalue [LvSegment t' Nothing, LvSegment col Nothing])) -> do
                      provenanceSpan (identSpan t')  @?= Just (SourceSpan 5 85 5 96)
                      provenanceSpan (identSpan col) @?= Just (SourceSpan 5 97 5 105)
                    other -> assertFailure ("expected 2-segment lvalue, got " <> show other)
                  case dwcParsedExp2 wc of
                    Just (ExHostVar (Lvalue [LvSegment v Nothing])) ->
                      provenanceSpan (identSpan v) @?= Just (SourceSpan 5 127 5 139)
                    other -> assertFailure ("expected host var, got " <> show other)
                ws -> assertFailure ("expected 1 WHERE clause, got " <> show (length ws))
              other -> assertFailure ("expected DwRetrieveOk, got " <> show other)
      ]

  , testGroup "scanBlockAttrs"
      [ testCase "empty string → []" $
          scanBlockAttrs "" @?= []

      , testCase "single unquoted attr" $
          scanBlockAttrs "type=long" @?= [DwAttrUnquoted "type" "long"]

      , testCase "multiple unquoted attrs separated by space" $
          scanBlockAttrs "update=yes key=no" @?=
            [DwAttrUnquoted "update" "yes", DwAttrUnquoted "key" "no"]

      , testCase "quoted attr value" $
          scanBlockAttrs "dbname=\"foo.bar\"" @?=
            [DwAttrQuoted "dbname" "foo.bar" (1, 9)]

      , testCase "sub-block attr" $
          scanBlockAttrs "column=(type=long name=foo )" @?=
            [DwAttrSubBlock "column" "type=long name=foo " (1, 9)]

      , testCase "type with parens captured whole — char(10)" $
          scanBlockAttrs "type=char(10) name=x" @?=
            [DwAttrUnquoted "type" "char(10)", DwAttrUnquoted "name" "x"]

      , testCase "type with parens captured whole — decimal(0)" $
          scanBlockAttrs "type=decimal(0) update=yes" @?=
            [DwAttrUnquoted "type" "decimal(0)", DwAttrUnquoted "update" "yes"]

      , testCase "dotted key" $
          scanBlockAttrs "dddw.name=pick_foo" @?=
            [DwAttrUnquoted "dddw.name" "pick_foo"]

      , testCase "tilde-escaped quote preserved verbatim in quoted value" $
          scanBlockAttrs "retrieve=\"a~\"b\"" @?=
            [DwAttrQuoted "retrieve" "a~\"b" (1, 11)]

      , testCase "multiline — newlines treated as whitespace between attrs" $
          scanBlockAttrs "type=long\nname=x" @?=
            [DwAttrUnquoted "type" "long", DwAttrUnquoted "name" "x"]

      , testCase "multiple sub-blocks" $
          scanBlockAttrs "column=(type=long name=a ) column=(type=char(10) name=b )" @?=
            [ DwAttrSubBlock "column" "type=long name=a " (1, 9)
            , DwAttrSubBlock "column" "type=char(10) name=b " (1, 36)
            ]

      , testCase "update= and updatewhere= are distinct keys" $
          scanBlockAttrs "update=yes updatewhere=0 updatewhereclause=yes" @?=
            [ DwAttrUnquoted "update" "yes"
            , DwAttrUnquoted "updatewhere" "0"
            , DwAttrUnquoted "updatewhereclause" "yes"
            ]

      , testCase "spaces around = are accepted" $
          scanBlockAttrs "units=0 print.orientation = 0 color=1" @?=
            [ DwAttrUnquoted "units" "0"
            , DwAttrUnquoted "print.orientation" "0"
            , DwAttrUnquoted "color" "1"
            ]
      ]

  , testGroup "scanBlockAttrs position tracking"
      [ testCase "quoted value position, single line" $
          case scanBlockAttrs "expression=\"foo\"" of
            [DwAttrQuoted _ _ pos] -> pos @?= (1, 13)
            as -> assertFailure ("expected one quoted attr, got " <> show as)

      , testCase "quoted value position after an embedded newline" $
          case scanBlockAttrs "a=\"x\"\nexpression=\"foo\"" of
            [_, DwAttrQuoted _ _ pos] -> pos @?= (2, 13)
            as -> assertFailure ("expected two attrs, got " <> show as)
      ]

  , testGroup "parseColumn"
      [ testCase "returns Nothing when name absent" $
          parseColumn (1,1) [DwAttrUnquoted "type" "long"] @?= Nothing

      , testCase "returns Nothing when type absent" $
          parseColumn (1,1) [DwAttrUnquoted "name" "aa"] @?= Nothing

      , testCase "returns Nothing for empty attr list" $
          parseColumn (1,1) [] @?= Nothing

      , testCase "minimal column — name and type only" $
          parseColumn (1,1) [DwAttrUnquoted "type" "long", DwAttrUnquoted "name" "aa"] @?=
            Just DwColumn
              { dcName                = "aa"
              , dcType                = "long"
              , dcDbName              = Nothing
              , dcUpdate              = False
              , dcKey                 = False
              , dcUpdateWhere         = False
              , dcDddwName            = Nothing
              , dcValidation          = Nothing
              , dcParsedValidation    = Nothing
              , dcValidationTokens    = []
              , dcValidationMsg       = Nothing
              , dcParsedValidationMsg = Nothing
              , dcValidationMsgTokens = []
              , dcAttrs               = Map.empty
              }

      , testCase "update=yes and key=yes parsed as Bool" $
          parseColumn (1,1)
                      [ DwAttrUnquoted "type" "long"
                      , DwAttrUnquoted "name" "id"
                      , DwAttrUnquoted "update" "yes"
                      , DwAttrUnquoted "key" "yes"
                      , DwAttrUnquoted "updatewhereclause" "yes"
                      ] @?=
            Just DwColumn
              { dcName                = "id"
              , dcType                = "long"
              , dcDbName              = Nothing
              , dcUpdate              = True
              , dcKey                 = True
              , dcUpdateWhere         = True
              , dcDddwName            = Nothing
              , dcValidation          = Nothing
              , dcParsedValidation    = Nothing
              , dcValidationTokens    = []
              , dcValidationMsg       = Nothing
              , dcParsedValidationMsg = Nothing
              , dcValidationMsgTokens = []
              , dcAttrs               = Map.empty
              }

      , testCase "dbname extracted from quoted attr" $
          parseColumn (1,1)
                      [ DwAttrUnquoted "type" "long"
                      , DwAttrUnquoted "name" "aa"
                      , DwAttrQuoted   "dbname" "tbl.aa" (1, 1)
                      ] @?=
            Just DwColumn
              { dcName                = "aa"
              , dcType                = "long"
              , dcDbName              = Just "tbl.aa"
              , dcUpdate              = False
              , dcKey                 = False
              , dcUpdateWhere         = False
              , dcDddwName            = Nothing
              , dcValidation          = Nothing
              , dcParsedValidation    = Nothing
              , dcValidationTokens    = []
              , dcValidationMsg       = Nothing
              , dcParsedValidationMsg = Nothing
              , dcValidationMsgTokens = []
              , dcAttrs               = Map.empty
              }

      , testCase "char(50) type stored verbatim" $
          fmap dcType (parseColumn (1,1) [ DwAttrUnquoted "type" "char(50)"
                                          , DwAttrUnquoted "name" "foo" ]) @?=
            Just "char(50)"

      , testCase "dddw.name captured" $
          fmap dcDddwName (parseColumn (1,1) [ DwAttrUnquoted "type" "long"
                                              , DwAttrUnquoted "name" "x"
                                              , DwAttrUnquoted "dddw.name" "pick_foo" ]) @?=
            Just (Just "pick_foo")

      , testCase "unknown attrs go into dcAttrs map" $
          fmap dcAttrs (parseColumn (1,1) [ DwAttrUnquoted "type" "long"
                                           , DwAttrUnquoted "name" "x"
                                           , DwAttrUnquoted "values" "A/B/" ]) @?=
            Just (Map.singleton "values" "A/B/")

      , testCase "validation= parsed into dcParsedValidation, anchored at real position" $
          -- "validation" spans columns 1-10 (key), "=" at 11, quote opens at 12,
          -- content starts at col 13; anchor (5, 1) simulates a column block
          -- whose own real file position is line 5 col 1.
          case parseColumn (5, 1) [ DwAttrUnquoted "type" "decimal(0)"
                                   , DwAttrUnquoted "name" "salary"
                                   , DwAttrQuoted "validation" "real(gettext()) > 0" (1, 13)
                                   ] of
            Just c -> do
              dcValidation c @?= Just "real(gettext()) > 0"
              case dcParsedValidation c of
                Just ExBinOp { lhs = ExCall { callee = Lvalue [LvSegment fn Nothing] }
                             , op = BopGt, rhs = ExInt "0" } -> do
                  fn @?= "real"
                  -- anchor (5,1) + validation's own relative position (1,13)
                  -- resolves to line 5 col 13 -- "real" is 4 chars.
                  provenanceSpan (identSpan fn) @?= Just (SourceSpan 5 13 5 17)
                other -> assertFailure ("expected ExBinOp real(gettext()) > 0, got " <> show other)
            Nothing -> assertFailure "expected Just DwColumn"

      , testCase "validationmsg= referencing a column parsed into dcParsedValidationMsg" $
          case parseColumn (1,1) [ DwAttrUnquoted "type" "long"
                                  , DwAttrUnquoted "name" "dept_id"
                                  , DwAttrQuoted "validationmsg" "dept_id" (1, 15)
                                  ] of
            Just c -> dcParsedValidationMsg c @?=
              Just (ExLvalue (Lvalue [LvSegment "dept_id" Nothing]))
            Nothing -> assertFailure "expected Just DwColumn"

      , testCase "validation=/validationmsg= absent — both Nothing, not in dcAttrs" $
          case parseColumn (1,1) [DwAttrUnquoted "type" "long", DwAttrUnquoted "name" "x"] of
            Just c -> do
              dcValidation c @?= Nothing
              dcParsedValidation c @?= Nothing
              dcValidationMsg c @?= Nothing
              dcParsedValidationMsg c @?= Nothing
              assertBool "validation should not be in residual attrs"
                (Map.notMember "validation" (dcAttrs c))
            Nothing -> assertFailure "expected Just DwColumn"
      ]

  , testGroup "DwControl"
      [ testCase "text control — name, band, position" $ do
          let src = dwMin <> "\ntext(band=header name=lbl_title x=\"9\" y=\"8\" width=\"500\" height=\"56\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcType    c @?= "text"
                dwcName    c @?= Just "lbl_title"
                dwcBand    c @?= Just BkHeader
                dwcX       c @?= Just 9
                dwcY       c @?= Just 8
                dwcWidth   c @?= Just 500
                dwcHeight  c @?= Just 56
                dwcVisible c @?= Just True
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "column control — id, tabsequence" $ do
          let src = dwMin <> "\ncolumn(band=detail id=2 tabsequence=32766 name=qty x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcId     c @?= Just 2
                dwcTabSeq c @?= Just 32766
                dwcName   c @?= Just "qty"
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "compute control — expression field" $ do
          let src = dwMin <> "\ncompute(band=summary name=cmp1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"sum(amount for all)\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcExpression c @?= Just "sum(amount for all)"
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "report control — dataobject in attrs" $ do
          let src = dwMin <> "\nreport(band=detail dataobject=\"sprn_sub\" x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcType c @?= "report"
                assertBool "dataobject in attrs"
                  (Map.member "dataobject" (dwcAttrs c))
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "graph control — attrs populated" $ do
          let src = dwMin <> "\ngraph(band=footer name=gr1 x=\"0\" y=\"0\" width=\"200\" height=\"100\" visible=\"1\" graphtype=0 )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcType c @?= "graph"
                dwcName c @?= Just "gr1"
                assertBool "graphtype in attrs"
                  (Map.member "graphtype" (dwcAttrs c))
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "band=header.2 → BkGroupHeader 2" $ do
          let src = dwMin <> "\ntext(band=header.2 name=lbl x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcBand c @?= Just (BkGroupHeader 2)
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "band=header[3] → BkGroupHeader 3" $ do
          let src = dwMin <> "\ntext(band=header[3] name=lbl x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcBand c @?= Just (BkGroupHeader 3)
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "band=background → BkBackground" $ do
          let src = dwMin <> "\ntext(band=background name=lbl x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcBand c @?= Just BkBackground
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "visible=1 → True (unquoted)" $ do
          let src = dwMin <> "\ntext(band=detail name=lbl x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=1 )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcVisible c @?= Just True
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "visible=\"0\" → False (quoted)" $ do
          let src = dwMin <> "\ntext(band=detail name=lbl x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"0\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcVisible c @?= Just False
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "control without name — name is Nothing" $ do
          let src = dwMin <> "\ntext(band=detail x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcName c @?= Nothing
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "unknown control type — stored in dwcType" $ do
          let src = dwMin <> "\nfoobarctrl(band=detail name=x x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcType c @?= "foobarctrl"
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "structural keys absent from dwcAttrs" $ do
          let src = dwMin <> "\ntext(band=header name=lbl id=1 x=\"9\" y=\"8\" width=\"500\" height=\"56\" visible=\"1\" tabsequence=10 color=\"0\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                let ks = Map.keys (dwcAttrs c)
                assertBool "name not in attrs"   (notElem "name"       ks)
                assertBool "band not in attrs"   (notElem "band"       ks)
                assertBool "id not in attrs"     (notElem "id"         ks)
                assertBool "x not in attrs"      (notElem "x"          ks)
                assertBool "y not in attrs"      (notElem "y"          ks)
                assertBool "width not in attrs"  (notElem "width"      ks)
                assertBool "height not in attrs" (notElem "height"     ks)
                assertBool "visible not in attrs" (notElem "visible"   ks)
                assertBool "tab_seq not in attrs" (notElem "tabsequence" ks)
                assertBool "color not in attrs" (notElem "color" ks)
                dwcColor c @?= Just "0"
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "compute expression — user fn call parses to ExCall" $ do
          let src = dwMin <> "\ncompute(band=summary name=cmp1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_foo( bar )\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcExpression c @?= Just "fn_foo( bar )"
                let expected = ExCall { callee   = Lvalue [LvSegment "fn_foo" Nothing]
                                      , callArgs = [ExLvalue (Lvalue [LvSegment "bar" Nothing])] }
                dwcParsedExpression c @?= Just expected
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "compute expression — multi-arg fn call preserves args" $ do
          let src = dwMin <> "\ncompute(band=summary name=cmp2 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_fullname( a , b )\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                let expected = ExCall { callee   = Lvalue [LvSegment "fn_fullname" Nothing]
                                      , callArgs = [ ExLvalue (Lvalue [LvSegment "a" Nothing])
                                                   , ExLvalue (Lvalue [LvSegment "b" Nothing])
                                                   ] }
                dwcParsedExpression c @?= Just expected
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "control without expression — parsedExpression is Nothing" $ do
          let src = dwMin <> "\ntext(band=header name=lbl x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> dwcParsedExpression c @?= Nothing
              cs  -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "format= with ~t separator — expression after ~t parsed as ExCall" $ do
          let src = dwMin <> "\ncolumn(band=detail name=mycol x=\"10\" y=\"10\" width=\"100\" height=\"50\" visible=\"1\" format=\"[GENERAL]~tfn_param_maskposo()\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcFormat c @?= Just "[GENERAL]~tfn_param_maskposo()"
                dwcParsedFormat c @?=
                  Just ExCall { callee   = Lvalue [LvSegment "fn_param_maskposo" Nothing]
                              , callArgs = [] }
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "format= without ~t — parsedFormat is Nothing" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c2 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" format=\"[GENERAL]\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcFormat       c @?= Just "[GENERAL]"
                dwcParsedFormat c @?= Nothing
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "format= with leading ~t (no display format) — expression parsed" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c3 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" format=\"~tfn_param_maskdate()\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcFormat c @?= Just "~tfn_param_maskdate()"
                dwcParsedFormat c @?=
                  Just ExCall { callee   = Lvalue [LvSegment "fn_param_maskdate" Nothing]
                              , callArgs = [] }
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "format= absent — dwcFormat and dwcParsedFormat both Nothing" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c4 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcFormat       c @?= Nothing
                dwcParsedFormat c @?= Nothing
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "format= not in dwcAttrs (it is a known key)" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c5 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" format=\"[GENERAL]~tfn_param_maskposo()\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> assertBool "format should not be in residual attrs"
                       (Map.notMember "format" (dwcAttrs c))
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "color= with ~t separator — dynamic half parsed as Expr" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c6 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" color=\"536870912~tfn_getcolor()\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcColor c @?= Just "536870912~tfn_getcolor()"
                dwcParsedColor c @?=
                  Just ExCall { callee = Lvalue [LvSegment "fn_getcolor" Nothing], callArgs = [] }
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "color= without ~t (static int) — parsedColor is Nothing" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c7 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" color=\"128\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcColor       c @?= Just "128"
                dwcParsedColor c @?= Nothing
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "color= unquoted static int — captured, parsedColor is Nothing" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c8 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" color=128 )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcColor       c @?= Just "128"
                dwcParsedColor c @?= Nothing
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "color= absent — dwcColor and dwcParsedColor both Nothing" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c9 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcColor       c @?= Nothing
                dwcParsedColor c @?= Nothing
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "color= not in dwcAttrs (it is a known key)" $ do
          let src = dwMin <> "\ncolumn(band=detail name=c10 x=\"0\" y=\"0\" width=\"50\" height=\"50\" visible=\"1\" color=\"128\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> assertBool "color should not be in residual attrs"
                       (Map.notMember "color" (dwcAttrs c))
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))
      ]

  , testGroup "DwTable"
      [ testCase "no columns, no retrieve" $
          parseDwTable (1,1) (scanBlockAttrs "") @?=
            DwTable [] Nothing Nothing Nothing []

      , testCase "single column extracted" $ do
          let attrs = scanBlockAttrs
                "column=(type=long name=aa dbname=\"aa\" ) "
          let tbl = parseDwTable (1,1) attrs
          length (dtColumns tbl) @?= 1
          dcName (head' (dtColumns tbl)) @?= "aa"
          dcType (head' (dtColumns tbl)) @?= "long"

      , testCase "multiple columns extracted" $ do
          let attrs = scanBlockAttrs
                "column=(type=long name=a ) column=(type=char(10) name=b )"
          length (dtColumns (parseDwTable (1,1) attrs)) @?= 2

      , testCase "raw SQL retrieve stored as DwRetrieveRaw" $ do
          let attrs = scanBlockAttrs "retrieve=\"SELECT 1 FROM dual\" "
          dtRetrieve (parseDwTable (1,1) attrs) @?= Just (DwRetrieveRaw "SELECT 1 FROM dual")

      , testCase "PBSELECT retrieve parsed into DwRetrieveOk" $ do
          let attrs = scanBlockAttrs "retrieve=\"PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") )\" "
          dtRetrieve (parseDwTable (1,1) attrs) @?=
              Just (DwRetrieveOk (DwRetrieve 400 ["t"] [] [] [] []))

      , testCase "update table name extracted" $ do
          let attrs = scanBlockAttrs "update=\"misth_ypal\" updatewhere=0 "
          dtUpdate      (parseDwTable (1,1) attrs) @?= Just "misth_ypal"
          dtUpdateWhere (parseDwTable (1,1) attrs) @?= Just 0

      , testCase "arguments=((...)) format parsed" $ do
          let attrs = scanBlockAttrs
                "arguments=((\"arg1\", string),(\"arg2\", long)) "
          dtArguments (parseDwTable (1,1) attrs) @?=
            [DwArgument "arg1" "string", DwArgument "arg2" "long"]

      , testCase "ARG() format parsed from retrieve when arguments= absent" $ do
          let attrs = scanBlockAttrs
                "retrieve=\"PBSELECT( ARG(NAME = ~\"myarg~\" TYPE = string) )\" "
          dtArguments (parseDwTable (1,1) attrs) @?= [DwArgument "myarg" "string"]

      , testCase "both arg formats present — deduplicated" $ do
          let attrs = scanBlockAttrs $ T.unwords
                [ "retrieve=\"PBSELECT( ARG(NAME = ~\"a~\" TYPE = string) )\""
                , "arguments=((\"a\", string))"
                ]
          dtArguments (parseDwTable (1,1) attrs) @?= [DwArgument "a" "string"]

      , testCase "column with dddw.name" $ do
          let attrs = scanBlockAttrs
                "column=(type=long name=x dddw.name=pick_foo ) "
          let cols = dtColumns (parseDwTable (1,1) attrs)
          length cols @?= 1
          dcDddwName (head' cols) @?= Just "pick_foo"

      , testCase "column missing name skipped" $ do
          let attrs = scanBlockAttrs
                "column=(type=long ) column=(type=char(10) name=ok ) "
          let cols = dtColumns (parseDwTable (1,1) attrs)
          length cols @?= 1
          dcName (head' cols) @?= "ok"
      ]

  , testGroup "PBSELECT"
      [ testCase "single table, no where" $
          parsePbSelect (1,1) "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") )"
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] [] [] [] [])

      , testCase "single table with column" $
          parsePbSelect (1,1)
            "PBSELECT( VERSION(400) TABLE(NAME=~\"emp~\") COLUMN(NAME=~\"emp.id~\") )"
          @?= DwRetrieveOk (DwRetrieve 400 ["emp"] ["emp.id"] [] [] [])

      , testCase "single table, one where clause" $
          parsePbSelect (1,1)
            ( "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") COLUMN(NAME=~\"t.x~\")"
           <> "WHERE( EXP1 =~\"t.x~\" OP =~\"=~\" EXP2 =~\":arg_x~\" ) )" )
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] ["t.x"] []
                [DwWhereClause "t.x" "=" ":arg_x" Nothing
                  (Just (ExLvalue (Lvalue [LvSegment "t" Nothing, LvSegment "x" Nothing])))
                  (Just (ExHostVar (Lvalue [LvSegment "arg_x" Nothing])))] [])

      , testCase "multi-table, multiple where clauses with LOGIC" $
          parsePbSelect (1,1)
            ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") TABLE(NAME=~\"b~\")"
           <> " COLUMN(NAME=~\"a.x~\")"
           <> " WHERE( EXP1 =~\"a.x~\" OP =~\"=~\" EXP2 =~\":p~\" LOGIC =~\"and~\" )"
           <> " WHERE( EXP1 =~\"b.y~\" OP =~\"=~\" EXP2 =~\":q~\" ) )" )
          @?= DwRetrieveOk (DwRetrieve 400 ["a","b"] ["a.x"] []
                [ DwWhereClause "a.x" "=" ":p" (Just "and")
                    (Just (ExLvalue (Lvalue [LvSegment "a" Nothing, LvSegment "x" Nothing])))
                    (Just (ExHostVar (Lvalue [LvSegment "p" Nothing])))
                , DwWhereClause "b.y" "=" ":q" Nothing
                    (Just (ExLvalue (Lvalue [LvSegment "b" Nothing, LvSegment "y" Nothing])))
                    (Just (ExHostVar (Lvalue [LvSegment "q" Nothing]))) ] [])

      , testCase "host var in EXP2 retains colon prefix" $ do
          let result = parsePbSelect (1,1)
                "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
                \WHERE( EXP1 =~\"t.id~\" OP =~\"=~\" EXP2 =~\":my_arg~\" ) )"
          case result of
            DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
            DwRetrieveOk dr -> dwcExp2 (head' (drWhere dr)) @?= ":my_arg"

      , testCase "operator with multi-char value" $
          parsePbSelect (1,1)
            "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
            \WHERE( EXP1 =~\"t.x~\" OP =~\"is not~\" EXP2 =~\"null~\" ) )"
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] [] []
                [DwWhereClause "t.x" "is not" "null" Nothing
                  (Just (ExLvalue (Lvalue [LvSegment "t" Nothing, LvSegment "x" Nothing])))
                  (Just ExNull)] [])

      , testCase "ARG outside outer paren parsed" $
          parsePbSelect (1,1)
            ( "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\")"
           <> " WHERE( EXP1 =~\"t.id~\" OP =~\"=~\" EXP2 =~\":aid~\" ) )"
           <> " ARG(NAME = ~\"aid~\" TYPE = string)" )
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] []
                [DwArgument "aid" "string"]
                [DwWhereClause "t.id" "=" ":aid" Nothing
                  (Just (ExLvalue (Lvalue [LvSegment "t" Nothing, LvSegment "id" Nothing])))
                  (Just (ExHostVar (Lvalue [LvSegment "aid" Nothing])))] [])

      , testCase "ARG date type" $
          parsePbSelect (1,1)
            "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") ) ARG(NAME = ~\"dt~\" TYPE = date)"
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] [] [DwArgument "dt" "date"] [] [])

      , testCase "fallback raw on non-PBSELECT input" $
          parsePbSelect (1,1) "SELECT x FROM t"
          @?= DwRetrieveRaw "SELECT x FROM t"

      , testGroup "WHERE operand parsing (dwcParsedExp1/dwcParsedExp2)"
          -- Real shapes sampled from pb.duckdb's dw_retrieve_where (openpay
          -- corpus, this session) — see doc/plan/163-unified-statement-footprint.md
          -- "Phase 0 findings" and the Plan 163 Phase 1 BACKLOG entry.
          [ testCase "plain table.column EXP1 parses to ExLvalue; :arg EXP2 to ExHostVar" $
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"afxfilterd~\") \
                     \WHERE( EXP1 =~\"afxfilterd.kodfilter~\" OP =~\"=~\" \
                     \EXP2 =~\":kodfilter~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> do
                  let wc = head' (drWhere dr)
                  dwcParsedExp1 wc @?=
                    Just (ExLvalue (Lvalue [LvSegment "afxfilterd" Nothing, LvSegment "kodfilter" Nothing]))
                  dwcParsedExp2 wc @?=
                    Just (ExHostVar (Lvalue [LvSegment "kodfilter" Nothing]))

          , testCase "literal NULL (uppercase) EXP2 parses to ExNull" $
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
                     \WHERE( EXP1 =~\"t.x~\" OP =~\"is~\" EXP2 =~\"NULL~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> dwcParsedExp2 (head' (drWhere dr)) @?= Just ExNull

          , testCase "literal negative-int EXP2 (-1) parses to ExNeg (ExInt)" $
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"usrusers~\") \
                     \WHERE( EXP1 =~\"usrusers.koduser~\" OP =~\"<>~\" EXP2 =~\"-1~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> do
                  let wc = head' (drWhere dr)
                  dwcParsedExp1 wc @?=
                    Just (ExLvalue (Lvalue [LvSegment "usrusers" Nothing, LvSegment "koduser" Nothing]))
                  dwcParsedExp2 wc @?= Just (ExNeg (ExInt "1"))

          , testCase "literal small-int EXP2 (1) parses to ExInt" $
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"misth_zpepidom~\") \
                     \WHERE( EXP1 =~\"misth_zpepidom.isasf~\" OP =~\"=~\" EXP2 =~\"1~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> dwcParsedExp2 (head' (drWhere dr)) @?= Just (ExInt "1")

          , testCase "unbalanced outer-paren boundary clause: raw text keeps the leaked \
                     \parens verbatim, but both parsed operands resolve cleanly" $
              -- Real .srd shape (final.pbl/dw_misth_final_form.srd), documented in
              -- doc/spec.md 7.3 "WHERE-clause grouping-paren leakage": PowerBuilder's
              -- WHERE grid splices a group's literal parens onto the boundary rows'
              -- EXP1/EXP2 text. dwcExp1/dwcExp2 preserve that verbatim (needed for
              -- reconstructRetrieveSql); dwcParsedExp1/dwcParsedExp2 strip the
              -- provably-surplus leading '(' / trailing ')' before parsing.
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"misth_final~\") \
                     \WHERE( EXP1 =~\"( misth_final.kodfinal~\" OP =~\"=~\" \
                     \EXP2 =~\":arg_kodfinal )~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> do
                  let wc = head' (drWhere dr)
                  dwcExp1 wc @?= "( misth_final.kodfinal"
                  dwcExp2 wc @?= ":arg_kodfinal )"
                  dwcParsedExp1 wc @?=
                    Just (ExLvalue (Lvalue [LvSegment "misth_final" Nothing, LvSegment "kodfinal" Nothing]))
                  dwcParsedExp2 wc @?= Just (ExHostVar (Lvalue [LvSegment "arg_kodfinal" Nothing]))

          , testCase "nested group boundary clause (3-row chain, depth-2 nesting): both \
                     \outer- and inner-group surplus parens stripped" $
              -- Real .srd shape (print.pbl/sprn_final_epidom_ypal.srd): the whole
              -- 3-row AND chain is itself wrapped in an outer group, so the first
              -- row's EXP1 carries 2 leading '(' (outer + this row's own) and the
              -- last row's EXP2 carries 2 trailing ')' (this row's own + outer).
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"misth_final_ypal_epidom~\") \
                     \WHERE( EXP1 =~\"( ( misth_final_ypal_epidom.kodfinal~\" OP =~\"=~\" \
                     \EXP2 =~\":arg_kodfinal )~\" LOGIC =~\"and~\" ) \
                     \WHERE( EXP1 =~\"( misth_final_ypal_epidom.kodypal~\" OP =~\"=~\" \
                     \EXP2 =~\":arg_kodypal )~\" LOGIC =~\"and~\" ) \
                     \WHERE( EXP1 =~\"( misth_final_ypal_epidom.kodxrisi~\" OP =~\"=~\" \
                     \EXP2 =~\":arg_kodxrisi ) )~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> case drWhere dr of
                  [w1, w2, w3] -> do
                    dwcParsedExp1 w1 @?=
                      Just (ExLvalue (Lvalue [LvSegment "misth_final_ypal_epidom" Nothing, LvSegment "kodfinal" Nothing]))
                    dwcParsedExp2 w1 @?= Just (ExHostVar (Lvalue [LvSegment "arg_kodfinal" Nothing]))
                    dwcParsedExp1 w2 @?=
                      Just (ExLvalue (Lvalue [LvSegment "misth_final_ypal_epidom" Nothing, LvSegment "kodypal" Nothing]))
                    dwcParsedExp2 w2 @?= Just (ExHostVar (Lvalue [LvSegment "arg_kodypal" Nothing]))
                    dwcParsedExp1 w3 @?=
                      Just (ExLvalue (Lvalue [LvSegment "misth_final_ypal_epidom" Nothing, LvSegment "kodxrisi" Nothing]))
                    dwcParsedExp2 w3 @?= Just (ExHostVar (Lvalue [LvSegment "arg_kodxrisi" Nothing]))
                  ws -> assertFailure ("expected exactly 3 WHERE clauses, got " <> show (length ws))

          , testCase "balanced internal parens are not stripped (real function call untouched)" $
              -- A legitimately balanced call in EXP2 must survive: only a strict
              -- paren-count imbalance triggers stripping, never a matched pair.
              case parsePbSelect (1,1)
                     "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
                     \WHERE( EXP1 =~\"t.x~\" OP =~\"=~\" EXP2 =~\"upper(x)~\" ) )" of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr ->
                  dwcParsedExp2 (head' (drWhere dr)) @?=
                    Just (ExCall (Lvalue [LvSegment "upper" Nothing]) [ExLvalue (Lvalue [LvSegment "x" Nothing])])
          ]

      , testGroup "PBSELECT JOIN"
          [ testCase "single join parsed into drJoins" $
              parsePbSelect (1,1)
                ( "PBSELECT( VERSION(400) TABLE(NAME=~\"usruserperm~\") \
                  \TABLE(NAME=~\"usrapps~\") \
                  \JOIN (LEFT=~\"usruserperm.kodapp~\" OP =~\"=~\" \
                  \RIGHT=~\"usrapps.kodapp~\") )" )
              @?= DwRetrieveOk (DwRetrieve 400 ["usruserperm", "usrapps"] [] [] []
                    [DwJoin "usruserperm.kodapp" "=" "usrapps.kodapp" Nothing Nothing])

          , testCase "chained joins preserved in order" $
              case parsePbSelect (1,1)
                     ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") \
                       \JOIN (LEFT=~\"a.x~\" OP =~\"=~\" RIGHT=~\"b.x~\") \
                       \JOIN (LEFT=~\"b.y~\" OP =~\"=~\" RIGHT=~\"c.y~\") \
                       \JOIN (LEFT=~\"c.z~\" OP =~\"=~\" RIGHT=~\"d.z~\") )" ) of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> map djLeft (drJoins dr) @?= ["a.x", "b.y", "c.z"]

          , testCase "join with OUTER1 attribute" $
              parsePbSelect (1,1)
                ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") \
                  \JOIN (LEFT=~\"a.x~\" OP =~\"=~\" RIGHT=~\"b.x~\" \
                  \OUTER1 =~\"a.x~\") )" )
              @?= DwRetrieveOk (DwRetrieve 400 ["a"] [] [] []
                    [DwJoin "a.x" "=" "b.x" (Just "a.x") Nothing])

          , testCase "join with OUTER2 attribute" $
              parsePbSelect (1,1)
                ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") \
                  \JOIN (LEFT=~\"a.x~\" OP =~\"=~\" RIGHT=~\"b.x~\" \
                  \OUTER2 =~\"b.x~\") )" )
              @?= DwRetrieveOk (DwRetrieve 400 ["a"] [] [] []
                    [DwJoin "a.x" "=" "b.x" Nothing (Just "b.x")])

          , testCase "malformed join block degrades to skip, whole PBSELECT still parses" $
              parsePbSelect (1,1)
                "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") JOIN(GARBAGE) )"
              @?= DwRetrieveOk (DwRetrieve 400 ["a"] [] [] [] [])

          , testProperty "n JOIN blocks parsed into drJoins of length n" $ property $ do
              n <- forAll $ Gen.int (Range.linear 0 5)
              let joinText i = "JOIN (LEFT=~\"t.a" <> T.pack (show i) <> "~\" OP =~\"=~\" \
                               \RIGHT=~\"t.b" <> T.pack (show i) <> "~\") "
                  src = "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") "
                     <> T.concat [joinText i | i <- [1 .. n]]
                     <> ")"
              case parsePbSelect (1,1) src of
                DwRetrieveRaw _ -> assert False
                DwRetrieveOk dr -> length (drJoins dr) === n
          ]
      ]

  , testGroup "DwBand"
      [ testCase "header band — height and color" $
          parseDwBand BkHeader "height=72 color=\"536870912\" " @?=
            DwBand BkHeader (Just 72) (Just "536870912") False Map.empty

      , testCase "detail band with height.autosize=yes" $
          parseDwBand BkDetail "height=88 color=\"536870912\"  height.autosize=yes" @?=
            DwBand BkDetail (Just 88) (Just "536870912") True Map.empty

      , testCase "footer band — no height" $
          parseDwBand BkFooter "" @?=
            DwBand BkFooter Nothing Nothing False Map.empty

      , testCase "summary band — residual attrs captured" $
          parseDwBand BkSummary "height=100 color=\"0\" extra=foo" @?=
            DwBand BkSummary (Just 100) (Just "0") False (Map.singleton "extra" "foo")
      ]

  , testGroup "DwGroup"
      [ testCase "single by-column" $
          parseDwGroup "level=1 header.height=96 trailer.height=80 by=(\"emp_id\" )" @?=
            Just (DwGroup 1 (Just 96) (Just 80) ["emp_id"] False Map.empty)

      , testCase "multiple by-columns" $
          parseDwGroup "level=2 header.height=120 trailer.height=80 by=(\"col1\" , \"col2\" )" @?=
            Just (DwGroup 2 (Just 120) (Just 80) ["col1","col2"] False Map.empty)

      , testCase "newpage=yes" $
          parseDwGroup "level=1 header.height=0 trailer.height=0 newpage=yes by=(\"x\" )" @?=
            Just (DwGroup 1 (Just 0) (Just 0) ["x"] True Map.empty)

      , testCase "group missing level — Nothing" $
          parseDwGroup "header.height=96 trailer.height=80 by=(\"x\" )" @?= Nothing
      ]

  , testGroup "parseGroupBy"
      [ testCase "single quoted column" $
          parseGroupBy "level=1 by=(\"emp_id\" )" @?= ["emp_id"]

      , testCase "multiple quoted columns with spaces around comma" $
          parseGroupBy "level=1 by=(\"col1\" , \"col2\" , \"col3\" )" @?= ["col1","col2","col3"]

      , testCase "unquoted column name" $
          parseGroupBy "level=1 by=(foo )" @?= ["foo"]

      , testCase "empty by=()" $
          parseGroupBy "level=1 by=( )" @?= []
      ]

  , testGroup "DwObjectAttrs"
      [ testCase "attrs collected into map" $
          parseDwObjectAttrs "units=0 timer_interval=0 color=1073741824" @?=
            DwObjectAttrs (Map.fromList [("units","0"),("timer_interval","0"),("color","1073741824")])

      , testCase "empty datawindow block" $
          parseDwObjectAttrs "" @?= DwObjectAttrs Map.empty
      ]

  , testGroup "Meta-blocks"
      [ testCase "export.pdf inner attrs parsed" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "export.pdf(method=0 distill.custompostscript=\"0\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case Map.lookup "export.pdf" (dwMeta dw) of
              Nothing -> assertFailure "export.pdf key missing from meta"
              Just m  -> do
                Map.lookup "method" m @?= Just "0"
                Map.lookup "distill.custompostscript" m @?= Just "0"

      , testCase "export.xml inner attrs parsed" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "export.xml(headgroups=\"1\" includewhitespace=\"0\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case Map.lookup "export.xml" (dwMeta dw) of
              Nothing -> assertFailure "export.xml key missing from meta"
              Just m  -> do
                Map.lookup "headgroups"      m @?= Just "1"
                Map.lookup "includewhitespace" m @?= Just "0"

      , testCase "import.xml empty inner map" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "import.xml()"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case Map.lookup "import.xml" (dwMeta dw) of
              Nothing -> assertFailure "import.xml key missing from meta"
              Just m  -> m @?= Map.empty

      , testCase "export.xhtml empty inner map" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "export.xhtml()"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case Map.lookup "export.xhtml" (dwMeta dw) of
              Nothing -> assertFailure "export.xhtml key missing from meta"
              Just m  -> m @?= Map.empty

      , testCase "multiple meta-blocks — all keys present with attrs" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "export.pdf(method=0 )"
                , "import.xml()"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> do
              let meta = dwMeta dw
              assertBool "export.pdf in meta" (Map.member "export.pdf" meta)
              assertBool "import.xml in meta" (Map.member "import.xml" meta)
              case Map.lookup "export.pdf" meta of
                Nothing -> assertFailure "export.pdf missing"
                Just m  -> Map.lookup "method" m @?= Just "0"

      , testCase "unknown dotted keyword stored in meta with attrs" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "foo.bar(x=1 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> case Map.lookup "foo.bar" (dwMeta dw) of
              Nothing -> assertFailure "foo.bar key missing from meta"
              Just m  -> m @?= Map.singleton "x" "1"
      ]

  , testGroup "DwUnknownBlock"
      [ testCase "sparse block routed to unknowns" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "detail(height=80 )"
                , "sparse(names=\"col1\\tcol2\" )"
                , "table(column=(type=long name=x ) )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> do
              null (dwControls dw) @?= True
              length (dwUnknowns dw) @?= 1
              dubKeyword (head' (dwUnknowns dw)) @?= "sparse"

      , testCase "sort block routed to unknowns with attrs" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "sort(names=\"emp_lname A\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> do
              length (dwUnknowns dw) @?= 1
              let u = head' (dwUnknowns dw)
              dubKeyword u @?= "sort"
              Map.lookup "names" (dubAttrs u) @?= Just "emp_lname A"

      , testCase "tree.level.1 parsed as band, not unknown" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "tree.level.1(height=100 color=\"0\" )"
                , "detail(height=80 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> do
              length (dwBands dw) @?= 2
              dbKind (head' (dwBands dw)) @?= BkTreeLevel 1
              null (dwUnknowns dw) @?= True

      , testCase "multiple unknown blocks preserved" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "sparse(names=\"a\" )"
                , "sort(names=\"b\" )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> length (dwUnknowns dw) @?= 2
      ]

  , testGroup "scanBlockAttrs resilience"
      [ testCase "malformed token between valid attrs — attrs before and after preserved" $ do
          let result = scanBlockAttrs "x=1 !!!??? y=2"
          length result @?= 2
          lookupUnquoted "x" result @?= Just "1"
          lookupUnquoted "y" result @?= Just "2"

      , testCase "sub-block attr value preserved through recovery" $ do
          let result = scanBlockAttrs "a=(inner=1 ) b=2"
          length result @?= 2
          lookupUnquoted "b" result @?= Just "2"
      ]

  , testGroup "scanBlocks header flexibility"
      [ testCase "three header lines before release — parses" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "// extra comment line"
                , "release 9;"
                , "datawindow(units=0 )"
                , "detail(height=80 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> length (dwBands dw) @?= 1

      , testCase "one header line before release — parses" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "release 9;"
                , "datawindow(units=0 )"
                , "detail(height=80 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> length (dwBands dw) @?= 1

      , testCase "five header lines before release — parses" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "// line 3"
                , "// line 4"
                , "// line 5"
                , "release 9;"
                , "datawindow(units=0 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> dwRelease dw @?= 9

      -- Issue 4: block keyword followed by a space before '(' is not parsed.
      -- pDwBlock expects keyword immediately followed by '(' with no whitespace gap.
      -- tableblob (band=detail table=...) — the space causes pDwBlock to fail,
      -- many stops early, and eof fails with "unexpected 't'".
      , testCase "block keyword with space before '(' parses (tableblob pattern)" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "detail(height=80 )"
                , "tableblob (band=detail table=t id=1 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> length (dwControls dw) @?= 1

      -- Issue 4 variant: any block keyword with a space before '(' should be handled.
      , testCase "standard control keyword with space before '(' parses (column pattern)" $ do
          let src = T.intercalate "\n"
                [ "HA$PBExportHeader$test.srd"
                , "$PBExportComments$"
                , "release 9;"
                , "datawindow(units=0 )"
                , "detail(height=80 )"
                , "column (band=detail name=id id=1 x=0 y=0 width=100 height=20 )"
                ]
          case parseDataWindow src of
            Left  err -> assertFailure ("unexpected parse error: " <> T.unpack err)
            Right dw  -> length (dwControls dw) @?= 1
      ]
  ]

-- | Minimal DW header for control test sources.
dwMin :: Text
dwMin = T.intercalate "\n"
  [ "HA$PBExportHeader$test.srd"
  , "$PBExportComments$"
  , "release 9;"
  , "datawindow(units=0 )"
  ]

-- | Total head for test use — list is always non-empty at call site.
head' :: [a] -> a
head' (x:_) = x
head' []    = error "impossible: head' called on empty list in test"

-- | Lookup an unquoted attribute value by key.
lookupUnquoted :: Text -> [DwAttr] -> Maybe Text
lookupUnquoted key attrs =
    listToMaybe [v | DwAttrUnquoted k v <- attrs, T.toLower k == T.toLower key]

