{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.Serialise () where

import PB.Prelude
import Data.Aeson              (Options (..), ToJSON (..), defaultOptions, genericToJSON, (.=))
import qualified Data.Aeson as J
import Data.Char               (isLower, toLower)

import PB.AST.BodyStmt
import PB.AST.DataWindow
import PB.AST.Expr
import PB.AST.Located     (Located)
import PB.AST.SourceFile
import PB.AST.Type        (PbType)
import PB.Lexing.Token    (Token (..))
import PB.Analysis.Cfg   (CfgBlock, CfgEdge, Cfg)
import PB.Compile.InstrTypes   (InstrNode, InstrGraph)
import PB.Compile.Flatten (WiringNode (..), WiringGraph (..))
import PB.Analysis.Taint      (InterprocEdge (..), ProcedureSummary (..), ProcSummaryReturnFlow (..))

-- | Strip a camelCase field-name prefix, e.g. "fnsMods" → "mods",
--   "fnsReturnType" → "returnType", "srForward" → "forward".
--   Names with no lowercase prefix (like "name", "segments") are unchanged.
stripCamelCasePrefix :: String -> String
stripCamelCasePrefix s = case span isLower s of
  ([], _)    -> s
  (_,  [])   -> s
  (_,  c:cs) -> toLower c : cs

customOptions :: Options
customOptions = defaultOptions { fieldLabelModifier = stripCamelCasePrefix }

-- ---------------------------------------------------------------------------
-- ToJSON instances — all in one group (no TH splices between them) so that
-- mutually recursive types like ElseIf ↔ BodyStmt resolve cleanly.
-- ---------------------------------------------------------------------------

-- Lexer layer — Token serialises as just its text to preserve wire format
instance ToJSON Token where toJSON t = toJSON (tkText t)

-- Expr layer
instance ToJSON LvSegment    where toJSON = genericToJSON customOptions
instance ToJSON Lvalue       where toJSON = genericToJSON customOptions
instance ToJSON BinOp        where toJSON = genericToJSON customOptions
instance ToJSON DispatchMode where toJSON = genericToJSON customOptions
instance ToJSON DispatchExpr where toJSON = genericToJSON customOptions
instance ToJSON Expr         where toJSON = genericToJSON customOptions
instance ToJSON PbType       where toJSON = genericToJSON customOptions

-- BodyStmt layer
instance ToJSON a => ToJSON (Located a) where toJSON = genericToJSON customOptions
instance ToJSON AugOp        where toJSON = genericToJSON customOptions
instance ToJSON PbCall       where toJSON = genericToJSON customOptions
instance ToJSON ElseIf       where toJSON = genericToJSON customOptions
instance ToJSON IfStmt       where toJSON = genericToJSON customOptions
instance ToJSON ForStmt      where toJSON = genericToJSON customOptions
instance ToJSON DoCondition  where toJSON = genericToJSON customOptions
instance ToJSON DoStmt       where toJSON = genericToJSON customOptions
instance ToJSON CaseClause   where toJSON = genericToJSON customOptions
instance ToJSON ChooseStmt   where toJSON = genericToJSON customOptions
instance ToJSON CatchClause  where toJSON = genericToJSON customOptions
instance ToJSON TryStmt      where toJSON = genericToJSON customOptions
instance ToJSON BodyStmt     where toJSON = genericToJSON customOptions

-- SourceFile layer
instance ToJSON VarScope         where toJSON = genericToJSON customOptions
instance ToJSON TypeDecl         where toJSON = genericToJSON customOptions
instance ToJSON GlobalInstance   where toJSON = genericToJSON customOptions
instance ToJSON VarDecl          where toJSON = genericToJSON customOptions
instance ToJSON Param            where toJSON = genericToJSON customOptions
instance ToJSON FnSig            where toJSON = genericToJSON customOptions
instance ToJSON SubSig           where toJSON = genericToJSON customOptions
instance ToJSON EventSig         where toJSON = genericToJSON customOptions
instance ToJSON ProtoDecl        where toJSON = genericToJSON customOptions
instance ToJSON ForwardBlock     where toJSON = genericToJSON customOptions
instance ToJSON PrototypesBlock  where toJSON = genericToJSON customOptions
instance ToJSON VariablesBlock   where toJSON = genericToJSON customOptions
instance ToJSON TypeBlock        where toJSON = genericToJSON customOptions
instance ToJSON FunctionBlock    where toJSON = genericToJSON customOptions
instance ToJSON SubroutineBlock  where toJSON = genericToJSON customOptions
instance ToJSON EventBlock       where toJSON = genericToJSON customOptions
instance ToJSON OnBlock          where toJSON = genericToJSON customOptions
instance ToJSON SrFile           where toJSON = genericToJSON customOptions

-- DataWindow layer
instance ToJSON DwBandKind      where toJSON = genericToJSON customOptions
instance ToJSON DwWhereClause   where toJSON = genericToJSON customOptions
instance ToJSON DwArgument      where toJSON = genericToJSON customOptions
instance ToJSON DwJoin          where toJSON = genericToJSON customOptions
instance ToJSON DwRetrieve      where toJSON = genericToJSON customOptions
instance ToJSON DwRetrieveOrRaw where toJSON = genericToJSON customOptions
instance ToJSON DwColumn        where toJSON = genericToJSON customOptions
instance ToJSON DwObjectAttrs   where toJSON = genericToJSON customOptions
instance ToJSON DwTable         where toJSON = genericToJSON customOptions
instance ToJSON DwBand          where toJSON = genericToJSON customOptions
instance ToJSON DwGroup         where toJSON = genericToJSON customOptions
instance ToJSON DwControl       where toJSON = genericToJSON customOptions
instance ToJSON DwUnknownBlock  where toJSON = genericToJSON customOptions
instance ToJSON DataWindowFile  where toJSON = genericToJSON customOptions

instance ToJSON CfgBlock  where toJSON = genericToJSON customOptions
instance ToJSON CfgEdge   where toJSON = genericToJSON customOptions
instance ToJSON Cfg       where toJSON = genericToJSON customOptions
instance ToJSON InstrNode   where toJSON = genericToJSON customOptions
instance ToJSON InstrGraph  where toJSON = genericToJSON customOptions

-- WiringGraph/WiringNode (wiring diagrams) — plain genericToJSON: the
-- graph is already flat and name-addressed (a node is defined once per
-- name, referenced by name elsewhere), so no manual term/sharedBlocks
-- split is needed.
instance ToJSON p => ToJSON (WiringNode p)  where toJSON = genericToJSON customOptions
instance ToJSON p => ToJSON (WiringGraph p) where toJSON = genericToJSON customOptions

-- InterprocEdge — manual instance to match Python snake_case keys
instance ToJSON InterprocEdge where
  toJSON e = J.object
    [ "caller_object"  .= ieCallerObject e
    , "caller_proc"    .= ieCallerProc e
    , "caller_line"    .= ieCallerLine e
    , "callee_object"  .= ieCalleeObject e
    , "callee_proc"    .= ieCalleeProc e
    , "edge_kind"      .= ieEdgeKind e
    , "var_name"       .= ieVarName e
    , "caller_context" .= ieCallerContext e
    , "callee_context" .= ieCalleeContext e
    ]

-- ProcSummaryReturnFlow — manual instance for nested objects
instance ToJSON ProcSummaryReturnFlow where
  toJSON f = J.object
    [ "object"  .= psrfObject f
    , "proc"    .= psrfProc f
    , "lhs_var" .= psrfLhsVar f
    ]

-- ProcedureSummary — manual instance to match Python snake_case keys
instance ToJSON ProcedureSummary where
  toJSON s = J.object
    [ "file"            .= psFile s
    , "object"          .= psObject s
    , "proc_name"       .= psProcName s
    , "params_in"       .= psParamsIn s
    , "globals_read"    .= psGlobalsRead s
    , "globals_written" .= psGlobalsWritten s
     , "return_flows_to" .= psReturnFlowsTo s
     ]
