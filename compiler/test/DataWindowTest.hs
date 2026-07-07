module DataWindowTest (tests) where

import PB.Prelude
import PB.AST.DataWindow
import PB.AST.Expr           (Expr (..), Lvalue (..), LvSegment (..))
import PB.Lexing.DataWindow  (DwAttr (..), extractParenBlock, scanBlockAttrs)
import PB.Lexing.Lexer       (tokenizeLine, LexLine (..))
import PB.Lexing.Token       (Token (..), TokenKind (..), SourceSpan (..))
import PB.Pipeline.Preprocess (LogicalLine (..))
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
-- Helpers

tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk
  _            -> Token TkIdent t (SourceSpan 1 1 1)
  where ll = LogicalLine t 1 1

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
            [DwAttrQuoted "dbname" "foo.bar"]

      , testCase "sub-block attr" $
          scanBlockAttrs "column=(type=long name=foo )" @?=
            [DwAttrSubBlock "column" "type=long name=foo "]

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
            [DwAttrQuoted "retrieve" "a~\"b"]

      , testCase "multiline — newlines treated as whitespace between attrs" $
          scanBlockAttrs "type=long\nname=x" @?=
            [DwAttrUnquoted "type" "long", DwAttrUnquoted "name" "x"]

      , testCase "multiple sub-blocks" $
          scanBlockAttrs "column=(type=long name=a ) column=(type=char(10) name=b )" @?=
            [ DwAttrSubBlock "column" "type=long name=a "
            , DwAttrSubBlock "column" "type=char(10) name=b "
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

  , testGroup "parseColumn"
      [ testCase "returns Nothing when name absent" $
          parseColumn [DwAttrUnquoted "type" "long"] @?= Nothing

      , testCase "returns Nothing when type absent" $
          parseColumn [DwAttrUnquoted "name" "aa"] @?= Nothing

      , testCase "returns Nothing for empty attr list" $
          parseColumn [] @?= Nothing

      , testCase "minimal column — name and type only" $
          parseColumn [DwAttrUnquoted "type" "long", DwAttrUnquoted "name" "aa"] @?=
            Just DwColumn
              { dcName        = "aa"
              , dcType        = "long"
              , dcDbName      = Nothing
              , dcUpdate      = False
              , dcKey         = False
              , dcUpdateWhere = False
              , dcDddwName    = Nothing
              , dcAttrs       = Map.empty
              }

      , testCase "update=yes and key=yes parsed as Bool" $
          parseColumn [ DwAttrUnquoted "type" "long"
                      , DwAttrUnquoted "name" "id"
                      , DwAttrUnquoted "update" "yes"
                      , DwAttrUnquoted "key" "yes"
                      , DwAttrUnquoted "updatewhereclause" "yes"
                      ] @?=
            Just DwColumn
              { dcName        = "id"
              , dcType        = "long"
              , dcDbName      = Nothing
              , dcUpdate      = True
              , dcKey         = True
              , dcUpdateWhere = True
              , dcDddwName    = Nothing
              , dcAttrs       = Map.empty
              }

      , testCase "dbname extracted from quoted attr" $
          parseColumn [ DwAttrUnquoted "type" "long"
                      , DwAttrUnquoted "name" "aa"
                      , DwAttrQuoted   "dbname" "tbl.aa"
                      ] @?=
            Just DwColumn
              { dcName        = "aa"
              , dcType        = "long"
              , dcDbName      = Just "tbl.aa"
              , dcUpdate      = False
              , dcKey         = False
              , dcUpdateWhere = False
              , dcDddwName    = Nothing
              , dcAttrs       = Map.empty
              }

      , testCase "char(50) type stored verbatim" $
          fmap dcType (parseColumn [ DwAttrUnquoted "type" "char(50)"
                                   , DwAttrUnquoted "name" "foo" ]) @?=
            Just "char(50)"

      , testCase "dddw.name captured" $
          fmap dcDddwName (parseColumn [ DwAttrUnquoted "type" "long"
                                       , DwAttrUnquoted "name" "x"
                                       , DwAttrUnquoted "dddw.name" "pick_foo" ]) @?=
            Just (Just "pick_foo")

      , testCase "unknown attrs go into dcAttrs map" $
          fmap dcAttrs (parseColumn [ DwAttrUnquoted "type" "long"
                                    , DwAttrUnquoted "name" "x"
                                    , DwAttrUnquoted "values" "A/B/" ]) @?=
            Just (Map.singleton "values" "A/B/")
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
                assertBool "color in attrs" (elem "color" ks)
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "compute expression — user fn call parses to ExCall" $ do
          let src = dwMin <> "\ncompute(band=summary name=cmp1 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_foo( bar )\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                dwcExpression c @?= Just "fn_foo( bar )"
                let expected = ExCall { callee   = Lvalue [LvSegment "fn_foo" Nothing]
                                      , callArgs = [[tok "bar"]] }
                stripExprSpans (dwcParsedExpression c) @?= stripExprSpans (Just expected)
              cs -> assertFailure ("expected 1 control, got " <> show (length cs))

      , testCase "compute expression — multi-arg fn call preserves args" $ do
          let src = dwMin <> "\ncompute(band=summary name=cmp2 x=\"0\" y=\"0\" width=\"100\" height=\"40\" visible=\"1\" expression=\"fn_fullname( a , b )\" )"
          case parseDataWindow src of
            Left err -> assertFailure ("parse error: " <> T.unpack err)
            Right dw -> case dwControls dw of
              [c] -> do
                let expected = ExCall { callee   = Lvalue [LvSegment "fn_fullname" Nothing]
                                      , callArgs = [[tok "a"], [tok "b"]] }
                stripExprSpans (dwcParsedExpression c) @?= stripExprSpans (Just expected)
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
      ]

  , testGroup "DwTable"
      [ testCase "no columns, no retrieve" $
          parseDwTable (scanBlockAttrs "") @?=
            DwTable [] Nothing Nothing Nothing []

      , testCase "single column extracted" $ do
          let attrs = scanBlockAttrs
                "column=(type=long name=aa dbname=\"aa\" ) "
          let tbl = parseDwTable attrs
          length (dtColumns tbl) @?= 1
          dcName (head' (dtColumns tbl)) @?= "aa"
          dcType (head' (dtColumns tbl)) @?= "long"

      , testCase "multiple columns extracted" $ do
          let attrs = scanBlockAttrs
                "column=(type=long name=a ) column=(type=char(10) name=b )"
          length (dtColumns (parseDwTable attrs)) @?= 2

      , testCase "raw SQL retrieve stored as DwRetrieveRaw" $ do
          let attrs = scanBlockAttrs "retrieve=\"SELECT 1 FROM dual\" "
          dtRetrieve (parseDwTable attrs) @?= Just (DwRetrieveRaw "SELECT 1 FROM dual")

      , testCase "PBSELECT retrieve parsed into DwRetrieveOk" $ do
          let attrs = scanBlockAttrs "retrieve=\"PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") )\" "
          dtRetrieve (parseDwTable attrs) @?=
              Just (DwRetrieveOk (DwRetrieve 400 ["t"] [] [] [] []))

      , testCase "update table name extracted" $ do
          let attrs = scanBlockAttrs "update=\"misth_ypal\" updatewhere=0 "
          dtUpdate      (parseDwTable attrs) @?= Just "misth_ypal"
          dtUpdateWhere (parseDwTable attrs) @?= Just 0

      , testCase "arguments=((...)) format parsed" $ do
          let attrs = scanBlockAttrs
                "arguments=((\"arg1\", string),(\"arg2\", long)) "
          dtArguments (parseDwTable attrs) @?=
            [DwArgument "arg1" "string", DwArgument "arg2" "long"]

      , testCase "ARG() format parsed from retrieve when arguments= absent" $ do
          let attrs = scanBlockAttrs
                "retrieve=\"PBSELECT( ARG(NAME = ~\"myarg~\" TYPE = string) )\" "
          dtArguments (parseDwTable attrs) @?= [DwArgument "myarg" "string"]

      , testCase "both arg formats present — deduplicated" $ do
          let attrs = scanBlockAttrs $ T.unwords
                [ "retrieve=\"PBSELECT( ARG(NAME = ~\"a~\" TYPE = string) )\""
                , "arguments=((\"a\", string))"
                ]
          dtArguments (parseDwTable attrs) @?= [DwArgument "a" "string"]

      , testCase "column with dddw.name" $ do
          let attrs = scanBlockAttrs
                "column=(type=long name=x dddw.name=pick_foo ) "
          let cols = dtColumns (parseDwTable attrs)
          length cols @?= 1
          dcDddwName (head' cols) @?= Just "pick_foo"

      , testCase "column missing name skipped" $ do
          let attrs = scanBlockAttrs
                "column=(type=long ) column=(type=char(10) name=ok ) "
          let cols = dtColumns (parseDwTable attrs)
          length cols @?= 1
          dcName (head' cols) @?= "ok"
      ]

  , testGroup "PBSELECT"
      [ testCase "single table, no where" $
          parsePbSelect "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") )"
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] [] [] [] [])

      , testCase "single table with column" $
          parsePbSelect
            "PBSELECT( VERSION(400) TABLE(NAME=~\"emp~\") COLUMN(NAME=~\"emp.id~\") )"
          @?= DwRetrieveOk (DwRetrieve 400 ["emp"] ["emp.id"] [] [] [])

      , testCase "single table, one where clause" $
          parsePbSelect
            ( "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") COLUMN(NAME=~\"t.x~\")"
           <> "WHERE( EXP1 =~\"t.x~\" OP =~\"=~\" EXP2 =~\":arg_x~\" ) )" )
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] ["t.x"] []
                [DwWhereClause "t.x" "=" ":arg_x" Nothing] [])

      , testCase "multi-table, multiple where clauses with LOGIC" $
          parsePbSelect
            ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") TABLE(NAME=~\"b~\")"
           <> " COLUMN(NAME=~\"a.x~\")"
           <> " WHERE( EXP1 =~\"a.x~\" OP =~\"=~\" EXP2 =~\":p~\" LOGIC =~\"and~\" )"
           <> " WHERE( EXP1 =~\"b.y~\" OP =~\"=~\" EXP2 =~\":q~\" ) )" )
          @?= DwRetrieveOk (DwRetrieve 400 ["a","b"] ["a.x"] []
                [ DwWhereClause "a.x" "=" ":p" (Just "and")
                , DwWhereClause "b.y" "=" ":q" Nothing ] [])

      , testCase "host var in EXP2 retains colon prefix" $ do
          let result = parsePbSelect
                "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
                \WHERE( EXP1 =~\"t.id~\" OP =~\"=~\" EXP2 =~\":my_arg~\" ) )"
          case result of
            DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
            DwRetrieveOk dr -> dwcExp2 (head' (drWhere dr)) @?= ":my_arg"

      , testCase "operator with multi-char value" $
          parsePbSelect
            "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") \
            \WHERE( EXP1 =~\"t.x~\" OP =~\"is not~\" EXP2 =~\"null~\" ) )"
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] [] []
                [DwWhereClause "t.x" "is not" "null" Nothing] [])

      , testCase "ARG outside outer paren parsed" $
          parsePbSelect
            ( "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\")"
           <> " WHERE( EXP1 =~\"t.id~\" OP =~\"=~\" EXP2 =~\":aid~\" ) )"
           <> " ARG(NAME = ~\"aid~\" TYPE = string)" )
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] []
                [DwArgument "aid" "string"]
                [DwWhereClause "t.id" "=" ":aid" Nothing] [])

      , testCase "ARG date type" $
          parsePbSelect
            "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") ) ARG(NAME = ~\"dt~\" TYPE = date)"
          @?= DwRetrieveOk (DwRetrieve 400 ["t"] [] [DwArgument "dt" "date"] [] [])

      , testCase "fallback raw on non-PBSELECT input" $
          parsePbSelect "SELECT x FROM t"
          @?= DwRetrieveRaw "SELECT x FROM t"

      , testGroup "PBSELECT JOIN"
          [ testCase "single join parsed into drJoins" $
              parsePbSelect
                ( "PBSELECT( VERSION(400) TABLE(NAME=~\"usruserperm~\") \
                  \TABLE(NAME=~\"usrapps~\") \
                  \JOIN (LEFT=~\"usruserperm.kodapp~\" OP =~\"=~\" \
                  \RIGHT=~\"usrapps.kodapp~\") )" )
              @?= DwRetrieveOk (DwRetrieve 400 ["usruserperm", "usrapps"] [] [] []
                    [DwJoin "usruserperm.kodapp" "=" "usrapps.kodapp" Nothing Nothing])

          , testCase "chained joins preserved in order" $
              case parsePbSelect
                     ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") \
                       \JOIN (LEFT=~\"a.x~\" OP =~\"=~\" RIGHT=~\"b.x~\") \
                       \JOIN (LEFT=~\"b.y~\" OP =~\"=~\" RIGHT=~\"c.y~\") \
                       \JOIN (LEFT=~\"c.z~\" OP =~\"=~\" RIGHT=~\"d.z~\") )" ) of
                DwRetrieveRaw _ -> assertFailure "expected DwRetrieveOk"
                DwRetrieveOk dr -> map djLeft (drJoins dr) @?= ["a.x", "b.y", "c.z"]

          , testCase "join with OUTER1 attribute" $
              parsePbSelect
                ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") \
                  \JOIN (LEFT=~\"a.x~\" OP =~\"=~\" RIGHT=~\"b.x~\" \
                  \OUTER1 =~\"a.x~\") )" )
              @?= DwRetrieveOk (DwRetrieve 400 ["a"] [] [] []
                    [DwJoin "a.x" "=" "b.x" (Just "a.x") Nothing])

          , testCase "join with OUTER2 attribute" $
              parsePbSelect
                ( "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") \
                  \JOIN (LEFT=~\"a.x~\" OP =~\"=~\" RIGHT=~\"b.x~\" \
                  \OUTER2 =~\"b.x~\") )" )
              @?= DwRetrieveOk (DwRetrieve 400 ["a"] [] [] []
                    [DwJoin "a.x" "=" "b.x" Nothing (Just "b.x")])

          , testCase "malformed join block degrades to skip, whole PBSELECT still parses" $
              parsePbSelect
                "PBSELECT( VERSION(400) TABLE(NAME=~\"a~\") JOIN(GARBAGE) )"
              @?= DwRetrieveOk (DwRetrieve 400 ["a"] [] [] [] [])

          , testProperty "n JOIN blocks parsed into drJoins of length n" $ property $ do
              n <- forAll $ Gen.int (Range.linear 0 5)
              let joinText i = "JOIN (LEFT=~\"t.a" <> T.pack (show i) <> "~\" OP =~\"=~\" \
                               \RIGHT=~\"t.b" <> T.pack (show i) <> "~\") "
                  src = "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") "
                     <> T.concat [joinText i | i <- [1 .. n]]
                     <> ")"
              case parsePbSelect src of
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

-- | Normalize token spans to SourceSpan 0 0 0 for comparison.
-- The DW expression parser produces tokens with different spans than @tok@.
stripExprSpans :: Maybe Expr -> Maybe Expr
stripExprSpans = fmap go
  where
    normToken t = t { tkSpan = SourceSpan 0 0 0 }
    go (ExCall c args) = ExCall c (map (map normToken) args)
    go e = e
