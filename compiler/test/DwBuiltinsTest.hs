module DwBuiltinsTest (tests) where

import PB.Prelude
import PB.AST.DwPropertySchema
import PB.Analysis.DwBuiltins

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "DwBuiltins"
  [ testGroup "classifyDwControlKind"
    [ testCase "recognizes every real dwcType keyword" $
        map classifyDwControlKind
          [ "column", "text", "compute", "button", "bitmap", "graph"
          , "groupbox", "line", "rectangle", "report", "tableblob"
          , "cssgen", "xmlgen", "jsgen", "xhtmlgen", "xsltgen"
          ]
        @?=
          map Just
          [ DwCkColumn, DwCkText, DwCkCompute, DwCkButton, DwCkBitmap, DwCkGraph
          , DwCkGroupBox, DwCkLine, DwCkRectangle, DwCkReport, DwCkTableBlob
          , DwCkCssGen, DwCkXmlGen, DwCkJsGen, DwCkXhtmlGen, DwCkXsltGen
          ]

    , testCase "case-insensitive: a live-parsed dwcType keeps its source casing" $
        classifyDwControlKind "Graph" @?= Just DwCkGraph

    , testCase "rejects an unrecognized control keyword" $
        classifyDwControlKind "gauge" @?= Nothing
    ]
  ]
