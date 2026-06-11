module DataWindowTest (tests) where

import PB.Prelude
import PB.AST.DataWindow
import PB.Lexing.DataWindow  (DwAttr (..), extractParenBlock, scanBlockAttrs)
import PB.Grammar.DataWindow (parseDataWindow, parseBandKind, parseDwTable, parseColumn)

import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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

      , testCase "retrieve string preserved verbatim" $ do
          let attrs = scanBlockAttrs "retrieve=\"SELECT 1 FROM dual\" "
          dtRetrieve (parseDwTable attrs) @?= Just "SELECT 1 FROM dual"

      , testCase "PBSELECT retrieve string preserved verbatim" $ do
          let attrs = scanBlockAttrs "retrieve=\"PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") )\" "
          dtRetrieve (parseDwTable attrs) @?= Just "PBSELECT( VERSION(400) TABLE(NAME=~\"t~\") )"

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
  ]

-- | Total head for test use — list is always non-empty at call site.
head' :: [a] -> a
head' (x:_) = x
head' []    = error "impossible: head' called on empty list in test"
