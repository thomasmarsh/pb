{-# OPTIONS_GHC -Wno-orphans #-}
-- | HasCodec orphan instances for all PB.AST.* types.
-- From these, ToJSON (via toJSONViaCodec) and JSON Schema
-- (via jsonSchemaViaCodec) are both derived.
module PB.Pipeline.Codec () where

import PB.Prelude
import Autodocodec

import Data.List.NonEmpty (NonEmpty ((:|)))

import PB.AST.BodyStmt      ( AugOp (..), BodyStmt (..), PbCall (..)
                            , IfStmt (..), ForStmt (..), DoCondition (..)
                            , DoStmt (..), CaseClause (..), ChooseStmt (..) )
import PB.AST.DataWindow
import PB.AST.Expr          ( BinOp (..), CallExpr (..), CreateExpr (..), Expr (..)
                            , DispatchMode (..), DispatchExpr (..)
                            , Literal (..), LvSegment (..), Lvalue (..) )
import PB.AST.SourceFile
import PB.Lexing.Splitter   (Statement (..))
import PB.Lexing.Token      (Token, tkText)
import PB.Pipeline.Preprocess (LogicalLine (..))

import qualified Data.Aeson           as A
import qualified Data.HashMap.Strict  as HashMap

-- ---------------------------------------------------------------------------
-- Helper codecs
-- Token/Statement types can't round-trip; decode direction returns Left.

-- [Token] → [Text]
tokenListCodec :: JSONCodec [Token]
tokenListCodec = bimapCodec
  (const (Left "Token decode not supported"))
  (map tkText)
  (codec @[Text])

-- [[Token]] → [[Text]]
tokenArgsCodec :: JSONCodec [[Token]]
tokenArgsCodec = bimapCodec
  (const (Left "Token args decode not supported"))
  (map (map tkText))
  (codec @[[Text]])

-- Maybe [Token] → null | [Text]  (encodes null for Nothing)
maybeTokenListCodec :: JSONCodec (Maybe [Token])
maybeTokenListCodec = bimapCodec
  (const (Right Nothing))
  (fmap (map tkText))
  (codec @(Maybe [Text]))

-- Statement → Text  (only the source text is encoded)
statementTextCodec :: JSONCodec Statement
statementTextCodec = bimapCodec
  (const (Left "Statement decode not supported"))
  (llText . stmtSource)
  (codec @Text)

-- (Expr, [BodyStmt]) → {"cond":…,"body":[…]}
elseIfValueCodec :: JSONCodec (Expr, [BodyStmt])
elseIfValueCodec = object "ElseIf" $ (,)
  <$> requiredField "cond" "" .= fst
  <*> requiredField "body" "" .= snd

-- ---------------------------------------------------------------------------
-- Phase 1 — Simple enums (stringConstCodec)

instance HasCodec AugOp where
  codec = stringConstCodec $
    (AugAdd, "add") :| [(AugSub, "sub"), (AugMul, "mul"), (AugDiv, "div")]

instance HasCodec VarScope where
  codec = stringConstCodec $ (GlobalVars, "global") :| [(TypeVars, "type")]

instance HasCodec DispatchMode where
  codec = stringConstCodec $
    (DmPost, "post") :| [(DmTrigger, "trigger"), (DmSync, "sync")]

instance HasCodec BinOp where
  codec = stringConstCodec $
    (BopAdd, "+")   :|
    [ (BopSub, "-"), (BopMul, "*"), (BopDiv, "/"), (BopPow, "^")
    , (BopEq,  "="), (BopNe, "<>"), (BopLt, "<"), (BopGt, ">")
    , (BopLe, "<="), (BopGe, ">=")
    , (BopAnd, "and"), (BopOr, "or"), (BopXor, "xor")
    ]

-- ---------------------------------------------------------------------------
-- Phase 2 — Simple records

instance HasCodec LvSegment where
  codec = object "LvSegment" $ LvSegment
    <$> requiredField    "name"      "" .= lvsName
    <*> requiredFieldWith "subscript" maybeTokenListCodec "" .= lvsSubscript

instance HasCodec Lvalue where
  codec = object "Lvalue" $ Lvalue
    <$> requiredField "segments" "" .= lvSegments

instance HasCodec TypeDecl where
  codec = object "TypeDecl" $ TypeDecl
    <$> requiredField                          "name"     "" .= tdName
    <*> requiredField                          "ancestor" "" .= tdAncestor
    <*> requiredFieldWith "within" (maybeCodec codec)    "" .= tdWithin

instance HasCodec VarDecl where
  codec = object "VarDecl" $ VarDecl
    <$> requiredField "modifiers" "" .= vdModifiers
    <*> requiredField "type"      "" .= vdType
    <*> requiredField "name"      "" .= vdName

instance HasCodec GlobalInstance where
  codec = object "GlobalInstance" $ GlobalInstance
    <$> requiredField "type" "" .= giType
    <*> requiredField "name" "" .= giName

instance HasCodec FnSig where
  codec = object "FnSig" $ FnSig
    <$> requiredField                           "modifiers"  "" .= fnsMods
    <*> requiredField                           "returnType" "" .= fnsRetType
    <*> requiredField                           "name"       "" .= fnsName
    <*> requiredField                           "params"     "" .= fnsParams
    <*> requiredFieldWith "throws" (maybeCodec codec)       "" .= fnsThrows

instance HasCodec SubSig where
  codec = object "SubSig" $ SubSig
    <$> requiredField                           "modifiers" "" .= ssMods
    <*> requiredField                           "name"      "" .= ssName
    <*> requiredField                           "params"    "" .= ssParams
    <*> requiredFieldWith "throws" (maybeCodec codec)      "" .= ssThrows

instance HasCodec EventSig where
  codec = object "EventSig" $ EventSig
    <$> requiredField "name"   "" .= esName
    <*> requiredField "rawSig" "" .= esRawSig

instance HasCodec DwArgument where
  codec = object "DwArgument" $ DwArgument
    <$> requiredField "name" "" .= daName
    <*> requiredField "type" "" .= daType

instance HasCodec DwWhereClause where
  codec = object "DwWhereClause" $ DwWhereClause
    <$> requiredField                           "exp1"  "" .= dwcExp1
    <*> requiredField                           "op"    "" .= dwcOp
    <*> requiredField                           "exp2"  "" .= dwcExp2
    <*> requiredFieldWith "logic" (maybeCodec codec)   "" .= dwcLogic

instance HasCodec DwColumn where
  codec = object "DwColumn" $ DwColumn
    <$> requiredField                               "name"         "" .= dcName
    <*> requiredField                               "type"         "" .= dcType
    <*> requiredFieldWith "db_name"   (maybeCodec codec)          "" .= dcDbName
    <*> requiredField                               "update"       "" .= dcUpdate
    <*> requiredField                               "key"          "" .= dcKey
    <*> requiredField                               "update_where" "" .= dcUpdateWhere
    <*> requiredFieldWith "dddw_name" (maybeCodec codec)          "" .= dcDddwName
    <*> requiredField                               "attrs"        "" .= dcAttrs

-- ---------------------------------------------------------------------------
-- Phase 3 — Sum types without recursion

instance HasCodec DoCondition where
  codec = object "DoCondition" $ discriminatedUnionCodec "tag"
    (\case
      DoWhile e -> ("while", mapToEncoder e (requiredField "expr" ""))
      DoUntil e -> ("until", mapToEncoder e (requiredField "expr" "")))
    (HashMap.fromList
      [ ("while", ("DoWhile", mapToDecoder DoWhile (requiredField "expr" "")))
      , ("until", ("DoUntil", mapToDecoder DoUntil (requiredField "expr" ""))) ])

instance HasCodec DwBandKind where
  codec = object "DwBandKind" $ discriminatedUnionCodec "tag"
    (\case
      BkHeader        -> ("header",        pureCodec ())
      BkDetail        -> ("detail",        pureCodec ())
      BkFooter        -> ("footer",        pureCodec ())
      BkSummary       -> ("summary",       pureCodec ())
      BkBackground    -> ("background",    pureCodec ())
      BkForeground    -> ("foreground",    pureCodec ())
      BkGroupHeader n -> ("group_header",  mapToEncoder n (requiredField "level" ""))
      BkGroupTrailer n -> ("group_trailer", mapToEncoder n (requiredField "level" ""))
      BkTreeLevel    n -> ("tree_level",   mapToEncoder n (requiredField "level" "")))
    (HashMap.fromList
      [ ("header",        ("BkHeader",       pureCodec BkHeader))
      , ("detail",        ("BkDetail",       pureCodec BkDetail))
      , ("footer",        ("BkFooter",       pureCodec BkFooter))
      , ("summary",       ("BkSummary",      pureCodec BkSummary))
      , ("background",    ("BkBackground",   pureCodec BkBackground))
      , ("foreground",    ("BkForeground",   pureCodec BkForeground))
      , ("group_header",  ("BkGroupHeader",  mapToDecoder BkGroupHeader  (requiredField "level" "")))
      , ("group_trailer", ("BkGroupTrailer", mapToDecoder BkGroupTrailer (requiredField "level" "")))
      , ("tree_level",    ("BkTreeLevel",    mapToDecoder BkTreeLevel    (requiredField "level" ""))) ])

instance HasCodec DwRetrieve where
  codec = object "DwRetrieve" $ DwRetrieve
    <$> requiredField "version"   "" .= drVersion
    <*> requiredField "tables"    "" .= drTables
    <*> requiredField "columns"   "" .= drColumns
    <*> requiredField "arguments" "" .= drArguments
    <*> requiredField "where"     "" .= drWhere

-- DwRetrieveOrRaw cannot use discriminatedUnionCodec because the current JSON
-- format has no tag field: DwRetrieveOk encodes as the DwRetrieve object
-- directly and DwRetrieveRaw encodes as {"raw":"…"}.
-- We use bimapCodec over Value to preserve the exact JSON structure.
instance HasCodec DwRetrieveOrRaw where
  codec = bimapCodec
    (\_ -> Left "DwRetrieveOrRaw decode not supported")
    encDRoR
    (codec @A.Value)
    where
      encDRoR :: DwRetrieveOrRaw -> A.Value
      encDRoR (DwRetrieveOk  dr) = toJSONViaCodec dr
      encDRoR (DwRetrieveRaw t)  = A.object ["raw" A..= t]

-- ---------------------------------------------------------------------------
-- Phase 4 — Recursive Expr
--
-- Object-codec helpers for types whose fields appear *inline* (not nested)
-- inside the Expr discriminated union.

callExprObjCodec :: ObjectCodec CallExpr CallExpr
callExprObjCodec = CallExpr
  <$> requiredField    "callee" "" .= ceCallee
  <*> requiredFieldWith "args"  tokenArgsCodec "" .= ceArgs

instance HasCodec CallExpr where
  codec = object "CallExpr" callExprObjCodec

dispatchExprObjCodec :: ObjectCodec DispatchExpr DispatchExpr
dispatchExprObjCodec = DispatchExpr
  <$> requiredFieldWith "object"  (maybeCodec codec) "" .= dspObject
  <*> requiredField               "mode"             "" .= dspMode
  <*> requiredField               "dynamic"          "" .= dspDynamic
  <*> requiredField               "event"            "" .= dspEvent
  <*> requiredField               "name"             "" .= dspName
  <*> requiredFieldWith           "args"  tokenArgsCodec "" .= dspArgs

instance HasCodec DispatchExpr where
  codec = object "DispatchExpr" dispatchExprObjCodec

-- Expr is self-recursive (ExBinOp, ExMethodCall, ExNot, ExUnaryMinus,
-- ExArray, ExCreate/CreateUsing). Use `named` so the schema emits $defs/$ref.
instance HasCodec Expr where
  codec = named "Expr" $ object "Expr" $ discriminatedUnionCodec "tag"
    encExpr
    decExpr

encExpr :: Expr -> (Text, ObjectCodec Expr ())
encExpr = \case
  -- Literal variants (tag = literal type, fields inline)
  ExLit (LitBool b)  -> ("bool",         mapToEncoder b  (requiredField "value" ""))
  ExLit (LitInt  t)  -> ("int",          mapToEncoder t  (requiredField "value" ""))
  ExLit (LitReal t)  -> ("real",         mapToEncoder t  (requiredField "value" ""))
  ExLit (LitStr  t)  -> ("string",       mapToEncoder t  (requiredField "value" ""))
  ExLit (LitDate t)  -> ("date",         mapToEncoder t  (requiredField "value" ""))
  ExLit (LitTime t)  -> ("time",         mapToEncoder t  (requiredField "value" ""))
  ExLit  LitNull     -> ("null",         pureCodec ())
  -- Other Expr constructors
  ExEnum   name      -> ("enum",         mapToEncoder name (requiredField "name" ""))
  ExLvalue lv        -> ("lvalue",       mapToEncoder (lvSegments lv) (requiredField "segments" ""))
  ExCall   ce        -> ("call_expr",    mapToEncoder ce  callExprObjCodec)
  ExCreate (CreateClass cls) -> ("create",       mapToEncoder cls (requiredField "class" ""))
  ExCreate (CreateUsing e)   -> ("create_using", mapToEncoder e   (requiredField "expr"  ""))
  ExArray  es        -> ("array",        mapToEncoder es  (requiredField "items" ""))
  ExNot    e         -> ("not",          mapToEncoder e   (requiredField "expr" ""))
  ExHostVar lv       -> ("host_var",     mapToEncoder lv  (requiredField "lvalue" ""))
  ExBinOp  l op r    -> ("binop",        void $ ExBinOp
                           <$> (requiredField "lhs" "" .= const l)
                           <*> (requiredField "op"  "" .= const op)
                           <*> (requiredField "rhs" "" .= const r))
  ExUnaryMinus e     -> ("neg",          mapToEncoder e   (requiredField "expr" ""))
  ExDispatch   de    -> ("dispatch",     mapToEncoder de  dispatchExprObjCodec)
  ExMethodCall rv m args -> ("method_call", void $ ExMethodCall
                           <$> (requiredField    "receiver" "" .= const rv)
                           <*> (requiredField    "method"   "" .= const m)
                           <*> (requiredFieldWith "args" tokenArgsCodec "" .= const args))
  ExRaw    ts        -> ("raw",          mapToEncoder ts (requiredFieldWith "tokens" tokenListCodec ""))

decExpr :: HashMap.HashMap Text (Text, ObjectCodec Void Expr)
decExpr = HashMap.fromList
  [ ("bool",         ("LitBool",      mapToDecoder (ExLit . LitBool) (requiredField "value" "")))
  , ("int",          ("LitInt",       mapToDecoder (ExLit . LitInt)  (requiredField "value" "")))
  , ("real",         ("LitReal",      mapToDecoder (ExLit . LitReal) (requiredField "value" "")))
  , ("string",       ("LitStr",       mapToDecoder (ExLit . LitStr)  (requiredField "value" "")))
  , ("date",         ("LitDate",      mapToDecoder (ExLit . LitDate) (requiredField "value" "")))
  , ("time",         ("LitTime",      mapToDecoder (ExLit . LitTime) (requiredField "value" "")))
  , ("null",         ("LitNull",      pureCodec (ExLit LitNull)))
  , ("enum",         ("ExEnum",       mapToDecoder ExEnum    (requiredField "name" "")))
  , ("lvalue",       ("ExLvalue",     mapToDecoder (ExLvalue . Lvalue) (requiredField "segments" "")))
  , ("call_expr",    ("ExCall",       mapToDecoder ExCall    callExprObjCodec))
  , ("create",       ("CreateClass",  mapToDecoder (ExCreate . CreateClass) (requiredField "class" "")))
  , ("create_using", ("CreateUsing",  mapToDecoder (ExCreate . CreateUsing) (requiredField "expr"  "")))
  , ("array",        ("ExArray",      mapToDecoder ExArray   (requiredField "items" "")))
  , ("not",          ("ExNot",        mapToDecoder ExNot     (requiredField "expr" "")))
  , ("host_var",     ("ExHostVar",    mapToDecoder ExHostVar (requiredField "lvalue" "")))
  , ("binop",        ("ExBinOp",      mapToDecoder id $ ExBinOp
                        <$> mapToDecoder id (requiredField "lhs" "")
                        <*> mapToDecoder id (requiredField "op"  "")
                        <*> mapToDecoder id (requiredField "rhs" "")))
  , ("neg",          ("ExUnaryMinus", mapToDecoder ExUnaryMinus (requiredField "expr" "")))
  , ("dispatch",     ("ExDispatch",   mapToDecoder ExDispatch   dispatchExprObjCodec))
  , ("method_call",  ("ExMethodCall", mapToDecoder id $ ExMethodCall
                        <$> mapToDecoder id (requiredField "receiver" "")
                        <*> mapToDecoder id (requiredField "method"   "")
                        <*> mapToDecoder id (requiredFieldWith "args" tokenArgsCodec "")))
  , ("raw",          ("ExRaw",        mapToDecoder ExRaw (requiredFieldWith "tokens" tokenListCodec "")))
  ]

-- ---------------------------------------------------------------------------
-- Phase 5 — Recursive BodyStmt
--
-- Object-codec helpers for compound statement types whose fields are
-- written inline (no nesting) inside the BodyStmt discriminated union.

pbCallObjCodec :: ObjectCodec PbCall PbCall
pbCallObjCodec = PbCall
  <$> requiredField "ancestor" "" .= pbcAncestor
  <*> requiredField "event"    "" .= pbcEvent

instance HasCodec PbCall where
  codec = object "PbCall" pbCallObjCodec

instance HasCodec CaseClause where
  codec = object "CaseClause" $ CaseClause
    <$> requiredFieldWith "expr" maybeTokenListCodec "" .= ccExpr
    <*> requiredField     "body" ""                    .= ccBody

chooseStmtObjCodec :: ObjectCodec ChooseStmt ChooseStmt
chooseStmtObjCodec = ChooseStmt
  <$> requiredField "expr"    "" .= chooseExpr
  <*> requiredField "clauses" "" .= chooseClauses

instance HasCodec ChooseStmt where
  codec = object "ChooseStmt" chooseStmtObjCodec

forStmtObjCodec :: ObjectCodec ForStmt ForStmt
forStmtObjCodec = ForStmt
  <$> requiredField                           "var"  "" .= forVar
  <*> requiredField                           "from" "" .= forFrom
  <*> requiredField                           "to"   "" .= forTo
  <*> requiredFieldWith "step" (maybeCodec codec)    "" .= forStep
  <*> requiredField                           "body" "" .= forBody

instance HasCodec ForStmt where
  codec = object "ForStmt" forStmtObjCodec

doStmtObjCodec :: ObjectCodec DoStmt DoStmt
doStmtObjCodec = DoStmt
  <$> requiredFieldWith "cond" (maybeCodec codec) "" .= doCond
  <*> requiredField     "body"                    "" .= doBody
  <*> requiredFieldWith "loop" (maybeCodec codec) "" .= doLoop

instance HasCodec DoStmt where
  codec = object "DoStmt" doStmtObjCodec

ifStmtObjCodec :: ObjectCodec IfStmt IfStmt
ifStmtObjCodec = IfStmt
  <$> requiredField                                              "cond"    "" .= ifCond
  <*> requiredField                                              "then"    "" .= ifThen
  <*> requiredFieldWith "elseIfs" (listCodec elseIfValueCodec)  ""           .= ifElseIfs
  <*> requiredFieldWith "else"    (maybeCodec (listCodec codec)) ""           .= ifElse

instance HasCodec IfStmt where
  codec = object "IfStmt" ifStmtObjCodec

-- BodyStmt is self-recursive through IfStmt, ForStmt, DoStmt, ChooseStmt.
-- Use `named` so the schema emits $defs/$ref.
instance HasCodec BodyStmt where
  codec = named "BodyStmt" $ object "BodyStmt" $ discriminatedUnionCodec "tag"
    encBodyStmt
    decBodyStmt

encBodyStmt :: BodyStmt -> (Text, ObjectCodec BodyStmt ())
encBodyStmt = \case
  BsLocalVar   ts       -> ("local_var",   mapToEncoder ts   (requiredFieldWith "tokens" tokenListCodec ""))
  BsAssign     lhs rhs  -> ("assign",      void $ BsAssign
                              <$> (requiredField "lhs" "" .= const lhs)
                              <*> (requiredField "rhs" "" .= const rhs))
  BsAssignExpr lhs rhs  -> ("assign_expr", void $ BsAssignExpr
                              <$> (requiredField "lhs" "" .= const lhs)
                              <*> (requiredField "rhs" "" .= const rhs))
  BsAugAssign  lhs op r -> ("aug_assign",  void $ BsAugAssign
                              <$> (requiredFieldWith "lhs" tokenListCodec "" .= const lhs)
                              <*> (requiredField     "op"  ""               .= const op)
                              <*> (requiredFieldWith "rhs" tokenListCodec "" .= const r))
  BsInc        lhs      -> ("inc",         mapToEncoder lhs  (requiredFieldWith "lhs" tokenListCodec ""))
  BsDec        lhs      -> ("dec",         mapToEncoder lhs  (requiredFieldWith "lhs" tokenListCodec ""))
  BsCall       e        -> ("call",        mapToEncoder e    (requiredField "expr" ""))
  BsPbCall     pc       -> ("pb_call",     mapToEncoder pc   pbCallObjCodec)
  BsReturn     me       -> ("return",      mapToEncoder me   (optionalField "value" ""))
  BsIf         is       -> ("if",          mapToEncoder is   ifStmtObjCodec)
  BsFor        fs       -> ("for",         mapToEncoder fs   forStmtObjCodec)
  BsDo         ds       -> ("do",          mapToEncoder ds   doStmtObjCodec)
  BsChoose     cs       -> ("choose",      mapToEncoder cs   chooseStmtObjCodec)
  BsExit                -> ("exit",        pureCodec ())
  BsContinue            -> ("continue",    pureCodec ())
  BsDestroy    lv       -> ("destroy",     mapToEncoder lv   (requiredField "lvalue" ""))
  BsRaw        s        -> ("raw",         mapToEncoder s    (requiredFieldWith "text" statementTextCodec ""))

decBodyStmt :: HashMap.HashMap Text (Text, ObjectCodec Void BodyStmt)
decBodyStmt = HashMap.fromList
  [ ("local_var",   ("BsLocalVar",   mapToDecoder BsLocalVar   (requiredFieldWith "tokens" tokenListCodec "")))
  , ("assign",      ("BsAssign",     mapToDecoder id $ BsAssign
                       <$> mapToDecoder id (requiredField "lhs" "")
                       <*> mapToDecoder id (requiredField "rhs" "")))
  , ("assign_expr", ("BsAssignExpr", mapToDecoder id $ BsAssignExpr
                       <$> mapToDecoder id (requiredField "lhs" "")
                       <*> mapToDecoder id (requiredField "rhs" "")))
  , ("aug_assign",  ("BsAugAssign",  mapToDecoder id $ BsAugAssign
                       <$> mapToDecoder id (requiredFieldWith "lhs" tokenListCodec "")
                       <*> mapToDecoder id (requiredField     "op"  "")
                       <*> mapToDecoder id (requiredFieldWith "rhs" tokenListCodec "")))
  , ("inc",         ("BsInc",        mapToDecoder BsInc   (requiredFieldWith "lhs" tokenListCodec "")))
  , ("dec",         ("BsDec",        mapToDecoder BsDec   (requiredFieldWith "lhs" tokenListCodec "")))
  , ("call",        ("BsCall",       mapToDecoder BsCall  (requiredField "expr" "")))
  , ("pb_call",     ("BsPbCall",     mapToDecoder BsPbCall pbCallObjCodec))
  , ("return",      ("BsReturn",     mapToDecoder BsReturn (optionalField "value" "")))
  , ("if",          ("BsIf",         mapToDecoder BsIf    ifStmtObjCodec))
  , ("for",         ("BsFor",        mapToDecoder BsFor   forStmtObjCodec))
  , ("do",          ("BsDo",         mapToDecoder BsDo    doStmtObjCodec))
  , ("choose",      ("BsChoose",     mapToDecoder BsChoose chooseStmtObjCodec))
  , ("exit",        ("BsExit",       pureCodec BsExit))
  , ("continue",    ("BsContinue",   pureCodec BsContinue))
  , ("destroy",     ("BsDestroy",    mapToDecoder BsDestroy (requiredField "lvalue" "")))
  , ("raw",         ("BsRaw",        mapToDecoder (\_ -> error "impossible: BsRaw decode")
                                       (requiredFieldWith "text" statementTextCodec "")))
  ]

-- ---------------------------------------------------------------------------
-- Phase 6 — SourceFile types

instance HasCodec ProtoDecl where
  codec = object "ProtoDecl" $ discriminatedUnionCodec "tag"
    (\case
      ProtoFn  fs -> ("fn",  mapToEncoder fs (requiredField "sig" ""))
      ProtoSub ss -> ("sub", mapToEncoder ss (requiredField "sig" ""))
      ProtoEv  es -> ("ev",  mapToEncoder es (requiredField "sig" "")))
    (HashMap.fromList
      [ ("fn",  ("ProtoFn",  mapToDecoder ProtoFn  (requiredField "sig" "")))
      , ("sub", ("ProtoSub", mapToDecoder ProtoSub (requiredField "sig" "")))
      , ("ev",  ("ProtoEv",  mapToDecoder ProtoEv  (requiredField "sig" ""))) ])

instance HasCodec ForwardBlock where
  codec = object "ForwardBlock" $ ForwardBlock
    <$> requiredField "types"     "" .= fwdTypes
    <*> requiredField "instances" "" .= fwdInstances

instance HasCodec PrototypesBlock where
  codec = object "PrototypesBlock" $ PrototypesBlock
    <$> requiredField "decls" "" .= protoDecls

instance HasCodec VariablesBlock where
  codec = object "VariablesBlock" $ VariablesBlock
    <$> requiredField "scope" "" .= varScope
    <*> requiredField "decls" "" .= varDecls

instance HasCodec TypeBlock where
  codec = object "TypeBlock" $ TypeBlock
    <$> requiredField "decl" "" .= tbDecl
    <*> requiredField "body" "" .= tbBody

instance HasCodec FunctionBlock where
  codec = object "FunctionBlock" $ FunctionBlock
    <$> requiredField "sig"  "" .= fbSig
    <*> requiredField "body" "" .= fbBody

instance HasCodec SubroutineBlock where
  codec = object "SubroutineBlock" $ SubroutineBlock
    <$> requiredField "sig"  "" .= sbSig
    <*> requiredField "body" "" .= sbBody

instance HasCodec EventBlock where
  codec = object "EventBlock" $ EventBlock
    <$> requiredField "sig"  "" .= evSig
    <*> requiredField "body" "" .= evBody

instance HasCodec OnBlock where
  codec = object "OnBlock" $ OnBlock
    <$> requiredField "qualName" "" .= obQualName
    <*> requiredField "owner"    "" .= obOwner
    <*> requiredField "event"    "" .= obEvent
    <*> requiredField "body"     "" .= obBody

instance HasCodec SrFile where
  codec = object "SrFile" $ SrFile
    <$> requiredField                                   "headers"         "" .= srHeaders
    <*> requiredFieldWith "forward"    (maybeCodec codec) ""                 .= srForward
    <*> requiredFieldWith "prototypes" (maybeCodec codec) ""                 .= srPrototypes
    <*> requiredFieldWith "variables"  (maybeCodec codec) ""                 .= srVariables
    <*> requiredField                                   "globalInstances" "" .= srGlobalInstances
    <*> requiredField                                   "typeBlocks"      "" .= srTypeBlocks
    <*> requiredField                                   "onBlocks"        "" .= srOnBlocks
    <*> requiredField                                   "events"          "" .= srEvents
    <*> requiredField                                   "functions"       "" .= srFunctions
    <*> requiredField                                   "subroutines"     "" .= srSubroutines

-- ---------------------------------------------------------------------------
-- Phase 7 — DataWindow types

instance HasCodec DwObjectAttrs where
  codec = object "DwObjectAttrs" $ DwObjectAttrs
    <$> requiredField "attrs" "" .= doaAttrs

instance HasCodec DwTable where
  codec = object "DwTable" $ DwTable
    <$> requiredField                                 "columns"      "" .= dtColumns
    <*> requiredFieldWith "retrieve" (maybeCodec codec) ""               .= dtRetrieve
    <*> requiredFieldWith "update"   (maybeCodec codec) ""               .= dtUpdate
    <*> requiredFieldWith "update_where" (maybeCodec codec) ""           .= dtUpdateWhere
    <*> requiredField                                 "arguments"    "" .= dtArguments

instance HasCodec DwBand where
  codec = object "DwBand" $ DwBand
    <$> requiredField                                 "kind"      "" .= dbKind
    <*> requiredFieldWith "height"   (maybeCodec codec) ""            .= dbHeight
    <*> requiredFieldWith "color"    (maybeCodec codec) ""            .= dbColor
    <*> requiredField                                 "auto_size" "" .= dbAutoSize
    <*> requiredField                                 "attrs"     "" .= dbAttrs

instance HasCodec DwGroup where
  codec = object "DwGroup" $ DwGroup
    <$> requiredField                                       "level"          "" .= dgLevel
    <*> requiredFieldWith "header_height"  (maybeCodec codec) ""                .= dgHeaderHeight
    <*> requiredFieldWith "trailer_height" (maybeCodec codec) ""                .= dgTrailerHeight
    <*> requiredField                                       "by"             "" .= dgBy
    <*> requiredField                                       "new_page"       "" .= dgNewPage
    <*> requiredField                                       "attrs"          "" .= dgAttrs

instance HasCodec DwControl where
  codec = object "DwControl" $ DwControl
    <$> requiredField                                       "type"       "" .= dwcType
    <*> requiredFieldWith "name"       (maybeCodec codec)  ""               .= dwcName
    <*> requiredFieldWith "band"       (maybeCodec codec)  ""               .= dwcBand
    <*> requiredFieldWith "id"         (maybeCodec codec)  ""               .= dwcId
    <*> requiredFieldWith "x"          (maybeCodec codec)  ""               .= dwcX
    <*> requiredFieldWith "y"          (maybeCodec codec)  ""               .= dwcY
    <*> requiredFieldWith "width"      (maybeCodec codec)  ""               .= dwcWidth
    <*> requiredFieldWith "height"     (maybeCodec codec)  ""               .= dwcHeight
    <*> requiredFieldWith "visible"    (maybeCodec codec)  ""               .= dwcVisible
    <*> requiredFieldWith "expression" (maybeCodec codec)  ""               .= dwcExpression
    <*> requiredFieldWith "tab_seq"    (maybeCodec codec)  ""               .= dwcTabSeq
    <*> requiredField                                       "attrs"      "" .= dwcAttrs

instance HasCodec DwUnknownBlock where
  codec = object "DwUnknownBlock" $ DwUnknownBlock
    <$> requiredField "keyword" "" .= dubKeyword
    <*> requiredField "attrs"   "" .= dubAttrs

instance HasCodec DataWindowFile where
  codec = object "DataWindowFile" $ DataWindowFile
    <$> requiredField                              "release"  "" .= dwRelease
    <*> requiredField                              "object"   "" .= dwObject
    <*> requiredFieldWith "table" (maybeCodec codec) ""           .= dwTable
    <*> requiredField                              "bands"    "" .= dwBands
    <*> requiredField                              "groups"   "" .= dwGroups
    <*> requiredField                              "controls" "" .= dwControls
    <*> requiredField                              "unknowns" "" .= dwUnknowns
    <*> requiredField                              "meta"     "" .= dwMeta
