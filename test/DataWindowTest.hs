module DataWindowTest (tests) where

import PB.Prelude
import PB.AST.DataWindow
import PB.Lexing.DataWindow  (extractParenBlock)
import PB.Grammar.DataWindow (parseDataWindow, parseBandKind)

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
  ]
