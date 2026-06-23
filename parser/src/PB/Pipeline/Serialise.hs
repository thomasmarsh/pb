{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.Serialise
  ( emitTypeScript
  , emitPython
  -- exposed for testing
  , transformType
  , parseFieldLine
  , extractClassName
  , emitTypeAlias
  , splitTupleParts
  ) where

import PB.Prelude
import Data.Aeson              (Options (..), ToJSON (..), defaultOptions, genericToJSON, (.=))
import qualified Data.Aeson as J
import Data.Aeson.TypeScript.TH (TSDeclaration, TypeScript (..), deriveTypeScript, formatTSDeclarations)
import Data.Char               (isLower, toLower)
import Data.Proxy              (Proxy (..))
import qualified Data.Text as T

import PB.AST.BodyStmt
import PB.AST.DataWindow
import PB.AST.Expr
import PB.AST.Located     (Located)
import PB.AST.SourceFile
import PB.AST.Type        (PbType)
import PB.Lexing.Token    (Token (..))
import PB.Pipeline.CfgBuild   (CfgBlock, CfgEdge, Cfg)
import PB.Pipeline.CpsCompile (CpsNode, CpsGraph)
import PB.Pipeline.Taint      (InterprocEdge (..), ProcedureSummary (..), ProcSummaryReturnFlow (..))
import PB.Pipeline.DeadCode   (DeadProcedure (..))

-- | Strip a camelCase field-name prefix, e.g. "fnsMods" → "mods",
--   "fnsReturnType" → "returnType", "srForward" → "forward".
--   Names with no lowercase prefix (like "name", "segments") are unchanged.
stripCamelCasePrefix :: String -> String
stripCamelCasePrefix s = case span isLower s of
  ([], _)    -> s  -- no lowercase prefix
  (_,  [])   -> s  -- all lowercase, nothing to strip
  (_,  c:cs) -> toLower c : cs

customOptions :: Options
customOptions = defaultOptions { fieldLabelModifier = stripCamelCasePrefix }

-- ---------------------------------------------------------------------------
-- ToJSON instances — all in one group (no TH splices between them) so that
-- mutually recursive types like ElseIf ↔ BodyStmt resolve cleanly.
-- ---------------------------------------------------------------------------

-- Lexer layer — Token serialises as just its text to preserve wire format
instance ToJSON Token where toJSON t = toJSON (tkText t)
instance TypeScript Token where
  getTypeScriptType _ = "string"

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
instance ToJSON BodyStmt     where toJSON = genericToJSON customOptions

-- SourceFile layer
instance ToJSON VarScope         where toJSON = genericToJSON customOptions
instance ToJSON TypeDecl         where toJSON = genericToJSON customOptions
instance ToJSON GlobalInstance   where toJSON = genericToJSON customOptions
instance ToJSON VarDecl          where toJSON = genericToJSON customOptions
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
instance ToJSON CpsNode   where toJSON = genericToJSON customOptions
instance ToJSON CpsGraph  where toJSON = genericToJSON customOptions

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

-- DeadProcedure — manual instance to match Python snake_case keys
instance ToJSON DeadProcedure where
  toJSON d = J.object
    [ "object"              .= dpObject d
    , "name"                .= dpName d
    , "proc_type"           .= dpProcType d
    , "cyclomatic"          .= dpCyclomatic d
    , "confidence"          .= dpConfidence d
    , "caller_count_naive"  .= dpCallerCountNaive d
    , "caller_count_scoped" .= dpCallerCountScoped d
    ]

-- ---------------------------------------------------------------------------
-- TypeScript instances — one combined splice so mutually recursive types
-- (ElseIf ↔ BodyStmt) are generated as a single declaration group.
-- ---------------------------------------------------------------------------

$(let strip s = case span isLower s of { ([], _) -> s; (_, []) -> s; (_, c:cs) -> toLower c : cs }
      opts  = defaultOptions { fieldLabelModifier = strip }
  in concat <$> mapM (deriveTypeScript opts)
  -- Expr layer
  [ ''LvSegment, ''Lvalue, ''BinOp, ''DispatchMode, ''DispatchExpr, ''Expr, ''PbType
  -- BodyStmt layer
  , ''Located
  , ''AugOp, ''PbCall, ''ElseIf, ''IfStmt, ''ForStmt, ''DoCondition, ''DoStmt
  , ''CaseClause, ''ChooseStmt, ''BodyStmt
  -- SourceFile layer
  , ''VarScope, ''TypeDecl, ''GlobalInstance, ''VarDecl, ''FnSig, ''SubSig
  , ''EventSig, ''ProtoDecl, ''ForwardBlock, ''PrototypesBlock, ''VariablesBlock
  , ''TypeBlock, ''FunctionBlock, ''SubroutineBlock, ''EventBlock, ''OnBlock, ''SrFile
  -- DataWindow layer
  , ''DwBandKind, ''DwWhereClause, ''DwArgument, ''DwRetrieve, ''DwRetrieveOrRaw
  , ''DwColumn, ''DwObjectAttrs, ''DwTable, ''DwBand, ''DwGroup, ''DwControl
  , ''DwUnknownBlock, ''DataWindowFile
  ])

-- ---------------------------------------------------------------------------

allTypeScriptDeclarations :: [TSDeclaration]
allTypeScriptDeclarations = concat
  -- Expr layer
  [ getTypeScriptDeclarations (Proxy @LvSegment)
  , getTypeScriptDeclarations (Proxy @Lvalue)
  , getTypeScriptDeclarations (Proxy @BinOp)
  , getTypeScriptDeclarations (Proxy @DispatchMode)
  , getTypeScriptDeclarations (Proxy @DispatchExpr)
  , getTypeScriptDeclarations (Proxy @Expr)
  , getTypeScriptDeclarations (Proxy @PbType)
  -- BodyStmt layer
  , getTypeScriptDeclarations (Proxy @(Located BodyStmt))
  , getTypeScriptDeclarations (Proxy @AugOp)
  , getTypeScriptDeclarations (Proxy @PbCall)
  , getTypeScriptDeclarations (Proxy @ElseIf)
  , getTypeScriptDeclarations (Proxy @IfStmt)
  , getTypeScriptDeclarations (Proxy @ForStmt)
  , getTypeScriptDeclarations (Proxy @DoCondition)
  , getTypeScriptDeclarations (Proxy @DoStmt)
  , getTypeScriptDeclarations (Proxy @CaseClause)
  , getTypeScriptDeclarations (Proxy @ChooseStmt)
  , getTypeScriptDeclarations (Proxy @BodyStmt)
  -- SourceFile layer
  , getTypeScriptDeclarations (Proxy @VarScope)
  , getTypeScriptDeclarations (Proxy @TypeDecl)
  , getTypeScriptDeclarations (Proxy @GlobalInstance)
  , getTypeScriptDeclarations (Proxy @VarDecl)
  , getTypeScriptDeclarations (Proxy @FnSig)
  , getTypeScriptDeclarations (Proxy @SubSig)
  , getTypeScriptDeclarations (Proxy @EventSig)
  , getTypeScriptDeclarations (Proxy @ProtoDecl)
  , getTypeScriptDeclarations (Proxy @ForwardBlock)
  , getTypeScriptDeclarations (Proxy @PrototypesBlock)
  , getTypeScriptDeclarations (Proxy @VariablesBlock)
  , getTypeScriptDeclarations (Proxy @TypeBlock)
  , getTypeScriptDeclarations (Proxy @FunctionBlock)
  , getTypeScriptDeclarations (Proxy @SubroutineBlock)
  , getTypeScriptDeclarations (Proxy @EventBlock)
  , getTypeScriptDeclarations (Proxy @OnBlock)
  , getTypeScriptDeclarations (Proxy @SrFile)
  -- DataWindow layer
  , getTypeScriptDeclarations (Proxy @DwBandKind)
  , getTypeScriptDeclarations (Proxy @DwWhereClause)
  , getTypeScriptDeclarations (Proxy @DwArgument)
  , getTypeScriptDeclarations (Proxy @DwRetrieve)
  , getTypeScriptDeclarations (Proxy @DwRetrieveOrRaw)
  , getTypeScriptDeclarations (Proxy @DwColumn)
  , getTypeScriptDeclarations (Proxy @DwObjectAttrs)
  , getTypeScriptDeclarations (Proxy @DwTable)
  , getTypeScriptDeclarations (Proxy @DwBand)
  , getTypeScriptDeclarations (Proxy @DwGroup)
  , getTypeScriptDeclarations (Proxy @DwControl)
  , getTypeScriptDeclarations (Proxy @DwUnknownBlock)
  , getTypeScriptDeclarations (Proxy @DataWindowFile)
  ]

emitTypeScript :: Text
emitTypeScript
  = T.unlines
  . map exportLine
  . T.lines
  . T.pack
  $ formatTSDeclarations allTypeScriptDeclarations
  where
    exportLine l
      | "type "      `T.isPrefixOf` l = "export " <> l
      | "interface " `T.isPrefixOf` l = "export " <> l
      | otherwise                      = l

-- ---------------------------------------------------------------------------
-- Python TypedDict codegen — transforms the TSDeclaration text output into
-- Python TypedDict classes.  Uses the same structured source as --emit-ts
-- (allTypeScriptDeclarations) but renders via a line-level text transformer
-- because TSDeclaration only exposes TSRawDeclaration String.
--
-- TODO: this is all a bit messy. Try to find another way at some point.
--
-- ---------------------------------------------------------------------------

emitPython :: Text
emitPython = T.unlines (header ++ classLines ++ [""] ++ aliasLines)
  where
    header =
      [ "# auto-generated -- do not edit; run: pnpm run codegen"
      , "# source: pb-runner --emit-py"
      , "from __future__ import annotations"
      , "from typing import Literal, TypedDict"
      , ""
      ]
    rawTs = T.pack $ formatTSDeclarations allTypeScriptDeclarations
    tsText = T.replace "Located<BodyStmt>" "LocatedBodyStmt" rawTs
    (classLines, aliasLines) = processTsLines (T.lines tsText)

-- State machine for line-by-line TS → Python transformation.
-- Separates classes (from interfaces) from type aliases so that aliases
-- (which may reference classes via unions) appear after all class defs.

data PState
  = PNormal
  | PSkipBlock !Int          -- skipping a generic block (brace depth)
  | PSkipLocated !Int        -- skipping Located<T> generic; emit concrete after
  | PCollectFields !Text ![(Text, Text)]  -- class name, fields in reverse

processTsLines :: [Text] -> ([Text], [Text])
processTsLines ls = (clsAcc, alsAcc)
  where
    (_, clsAcc, alsAcc) = foldl' step (PNormal, [], []) ls

    step :: (PState, [Text], [Text]) -> Text -> (PState, [Text], [Text])

    -- Normal state — between declarations
    step (PNormal, cls, als) l
      | T.null l = (PNormal, cls, als)
      | "type Located<T>" `T.isPrefixOf` T.strip l =
          (PSkipLocated 0, cls, als)
      | "type " `T.isPrefixOf` T.strip l =
          (PNormal, cls, als ++ transformTypeLine l)
      | "interface " `T.isPrefixOf` T.strip l =
          if "<" `T.isInfixOf` l
            then (PSkipBlock 1, cls, als)
            else let cn = extractClassName l
                 in (PCollectFields cn [], cls, als)
      | otherwise = (PNormal, cls, als)

    -- Skipping a generic block (e.g. interface with type parameters)
    step (PSkipBlock depth, cls, als) l
      | "{" `T.isInfixOf` l = (PSkipBlock (depth + 1), cls, als)
      | "}" `T.isPrefixOf` T.strip l =
          if depth <= 1 then (PNormal, cls, als)
          else (PSkipBlock (depth - 1), cls, als)
      | otherwise = (PSkipBlock depth, cls, als)

    -- Skipping the Located<T> generic declaration + interface
    step (PSkipLocated depth, cls, als) l
      | "interface ILocated<T>" `T.isPrefixOf` T.strip l =
          (PSkipLocated 1, cls, als)
      | depth == 0 =
          (PSkipLocated 0, cls, als)
      | "}" `T.isPrefixOf` T.strip l && depth == 1 =
          (PNormal, cls ++ locatedBodyStmtLines, als)
      | "{" `T.isInfixOf` l = (PSkipLocated (depth + 1), cls, als)
      | "}" `T.isInfixOf` l = (PSkipLocated (depth - 1), cls, als)
      | otherwise = (PSkipLocated depth, cls, als)

    -- Collecting fields inside a concrete interface
    step (PCollectFields cn fields, cls, als) l
      | "}" `T.isPrefixOf` T.strip l =
          (PNormal, cls ++ emitClass cn (reverse fields), als)
      | otherwise =
          (PCollectFields cn (parseFieldLine l : fields), cls, als)

-- | Python keywords that would clash with TypedDict field names.
pyKeywords :: [Text]
pyKeywords =
  [ "False", "None", "True", "and", "as", "assert", "async", "await"
  , "break", "class", "continue", "def", "del", "elif", "else", "except"
  , "finally", "for", "from", "global", "if", "import", "in", "is"
  , "lambda", "nonlocal", "not", "or", "pass", "raise", "return"
  , "try", "while", "with", "yield"
  ]

isPyKeyword :: Text -> Bool
isPyKeyword t = t `elem` pyKeywords

-- | Extract the Python class name from a TS interface declaration line.
--   Strips "interface " prefix and "I" prefix from the name.
extractClassName :: Text -> Text
extractClassName l =
  let stripped   = T.strip l
      afterKw    = T.drop 10 stripped          -- drop "interface "
      name       = T.takeWhile (\c -> c /= ' ' && c /= '<') afterKw
  in if T.isPrefixOf "I" name then T.drop 1 name else name

-- | Emit a Python class (or functional TypedDict) from collected interface fields.
emitClass :: Text -> [(Text, Text)] -> [Text]
emitClass cn fields
  | any (isPyKeyword . fst) fields = emitFunctionalForm cn fields
  | otherwise = emitClassForm cn fields

emitClassForm :: Text -> [(Text, Text)] -> [Text]
emitClassForm cn fields =
  ["class " <> cn <> "(TypedDict):"] ++
  map (\(fn, ft) -> "    " <> fn <> ": " <> ft) fields ++
  [""]

emitFunctionalForm :: Text -> [(Text, Text)] -> [Text]
emitFunctionalForm cn fields =
  [cn <> " = TypedDict(\"" <> cn <> "\", {" ] ++
  map (\(fn, ft) -> "    \"" <> fn <> "\": \"" <> ft <> "\",") fields ++
  ["})"]

-- | Parse a TS interface field line into (fieldName, transformedType).
parseFieldLine :: Text -> (Text, Text)
parseFieldLine l =
  let stripped   = T.strip l
      (name, rest) = T.breakOn ": " stripped
      fieldType  = T.dropEnd 1 (T.drop 2 rest)  -- drop ": " and trailing ";"
  in (T.strip name, transformType (T.strip fieldType))

-- | Transform a TypeScript type expression into its Python equivalent.
transformType :: Text -> Text
transformType t
  | T.null t = t
  | t == "string"  = "str"
  | t == "boolean" = "bool"
  | t == "number"  = "int"
  | " | null" `T.isSuffixOf` t =
      transformType (T.dropEnd 7 t) <> " | None"
  | "[]" `T.isSuffixOf` t =
      "list[" <> transformType (T.dropEnd 2 t) <> "]"
  | "{[k in string]?: " `T.isInfixOf` t = transformMapType t
  | T.isPrefixOf "[" t = transformTupleType t
  | T.isPrefixOf "\"" t && T.isSuffixOf "\"" t =
      "Literal[" <> t <> "]"
  | otherwise = t

-- | Transform {[k in string]?: T} → dict[str, T], handling nesting.
transformMapType :: Text -> Text
transformMapType = go
  where
    go t = case T.breakOn "{[k in string]?: " t of
      (before, match)
        | not (T.null match) ->
            let rest    = T.drop 17 match   -- drop "{[k in string]?: "
                (vt, after) = splitAtBrace rest
                after'  = case T.uncons after of
                            Just ('}', r) -> r
                            _             -> after
            in before <> "dict[str, " <> transformType (go vt) <> "]" <> go after'
      _ -> t

    splitAtBrace = go'' (0 :: Int)
      where
        go'' _ "" = ("", "")
        go'' n t' = case T.uncons t' of
          Nothing    -> ("", "")
          Just ('{', r) -> let (a, b) = go'' (n+1) r in ("{" <> a, b)
          Just ('}', r)
            | n == 0    -> ("", r)
            | otherwise -> let (a, b) = go'' (n-1) r in ("}" <> a, b)
          Just (c, r)   -> let (a, b) = go'' n r in (T.singleton c <> a, b)

-- | Transform [T1, T2, ...] → tuple[T1, T2, ...]
transformTupleType :: Text -> Text
transformTupleType t
  | T.isPrefixOf "[" t && T.isSuffixOf "]" t =
      let inner = T.init (T.drop 1 t)
          parts = splitTupleParts inner
      in "tuple[" <> T.intercalate ", " (map transformType parts) <> "]"
  | otherwise = t

-- | Split a comma-separated type list respecting nested brackets.
splitTupleParts :: Text -> [Text]
splitTupleParts = go (0 :: Int) [] ""
  where
    go _ acc cur "" = reverse (T.strip cur : acc)
    go n acc cur t' = case T.uncons t' of
      Nothing    -> reverse (T.strip cur : acc)
      Just ('[', r) -> go (n+1) acc (T.snoc cur '[') r
      Just (']', r) -> go (n-1) acc (T.snoc cur ']') r
      Just (',', r) | n == 0 -> go 0 (T.strip cur : acc) "" r
      Just (c, r)  -> go n acc (T.snoc cur c) r

-- | Transform a TS type alias line into Python.
--   Single interface aliases are skipped (class is emitted from the interface).
--   Literal unions become Literal[...].
--   Named unions become A | B | ...
transformTypeLine :: Text -> [Text]
transformTypeLine l =
  let stripped    = T.strip l
      withoutType = T.drop 5 stripped              -- "type "
      (name, rest) = T.breakOn " = " withoutType
      rhs         = T.dropEnd 1 (T.drop 3 rest)    -- drop " = " and ";"
  in emitTypeAlias name (T.splitOn " | " rhs)

emitTypeAlias :: Text -> [Text] -> [Text]
emitTypeAlias name parts = case parts of
  [single]
    | T.isPrefixOf "I" single   -> []              -- skip: single interface alias
    | T.isPrefixOf "\"" single  -> [name <> " = Literal[" <> single <> "]"]
    | otherwise                 -> [name <> " = " <> single]
  _
    | all (T.isPrefixOf "\"") parts ->
        [name <> " = Literal[" <> T.intercalate ", " parts <> "]"]
    | otherwise ->
        [name <> " = " <> T.intercalate " | " (map stripIPrefix parts)]
  where
    stripIPrefix t | T.isPrefixOf "I" t = T.drop 1 t
                   | otherwise          = t

-- | Concrete LocatedBodyStmt class emitted in place of the generic Located<T>.
locatedBodyStmtLines :: [Text]
locatedBodyStmtLines =
  [ "class LocatedBodyStmt(TypedDict):"
  , "    line: int"
  , "    node: BodyStmt"
  , ""
  ]
