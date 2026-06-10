module PB.Pipeline.Runner
  ( runFile
  , collectStatements
  ) where

import PB.Prelude
import PB.AST.Object
import PB.Grammar.File      (parseSrFile)
import PB.Lexing.Lexer      (LexError (..), LexLine (..), tokenize)
import PB.Lexing.Splitter   (Statement (..), splitStatements)
import PB.Pipeline.Preprocess (LogicalLine (..), normalizeText, stripHeaders)

import Data.Aeson  (Value, object, toJSON, (.=))
import Data.Char   (toLower)
import qualified Data.Text as T
import System.FilePath (takeExtension)

-- ---------------------------------------------------------------------------
-- Entry point

runFile :: FilePath -> Text -> Either Text Value
runFile path src = case classifyFile path of
  DataWindow  -> runDataWindow  path src
  Pipeline    -> runPipeline    path src
  Project     -> runProject     path src
  PowerScript -> runPowerScript path src

data FileKind = DataWindow | Pipeline | Project | PowerScript

classifyFile :: FilePath -> FileKind
classifyFile fp = case map toLower (takeExtension fp) of
  ".srd" -> DataWindow
  ".srp" -> Pipeline
  ".srj" -> Project
  _      -> PowerScript

-- ---------------------------------------------------------------------------
-- DataWindow (stub)

runDataWindow :: FilePath -> Text -> Either Text Value
runDataWindow path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("datawindow" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

runPipeline :: FilePath -> Text -> Either Text Value
runPipeline path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("pipeline" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

runProject :: FilePath -> Text -> Either Text Value
runProject path _src = Right $ object
  [ "file"   .= path
  , "kind"   .= ("project" :: Text)
  , "status" .= ("unimplemented" :: Text)
  ]

-- ---------------------------------------------------------------------------
-- PowerScript pipeline

runPowerScript :: FilePath -> Text -> Either Text Value
runPowerScript path src = do
  let logicalLines         = normalizeText src
      (headers, bodyLines) = stripHeaders logicalLines
      lexLines             = tokenize bodyLines
  stmts  <- collectStatements lexLines
  srFile <- parseSrFile headers stmts
  Right (encodeSrFile path srFile)

-- | Convert lex results to statements, failing on the first lex error.
--   Empty-token statements (blank lines) are filtered out so the grammar
--   parser's eof succeeds on trailing whitespace.
collectStatements :: [LexLine] -> Either Text [Statement]
collectStatements lexLines =
  let results = splitStatements lexLines
  in case [err | Left err <- results] of
    (e : _) -> Left
        ("lex error at offset " <> T.pack (show (leOffset e))
         <> " line "            <> T.pack (show (llStartLine (leSource e))))
    [] -> Right [s | Right s <- results, not (null (stmtTokens s))]

-- ---------------------------------------------------------------------------
-- JSON encoding

encodeSrFile :: FilePath -> SrFile -> Value
encodeSrFile path sf = object
  [ "file"            .= path
  , "kind"            .= ("powerscript" :: Text)
  , "headers"         .= srHeaders sf
  , "forward"         .= fmap encodeForwardBlock (srForward sf)
  , "prototypes"      .= fmap encodePrototypesBlock (srPrototypes sf)
  , "variables"       .= fmap encodeVariablesBlock (srVariables sf)
  , "globalInstances" .= map encodeGlobalInstance (srGlobalInstances sf)
  , "typeBlocks"      .= map encodeTypeBlock (srTypeBlocks sf)
  , "onBlocks"        .= map encodeOnBlock (srOnBlocks sf)
  , "events"          .= map encodeEventBlock (srEvents sf)
  , "functions"       .= map encodeFunctionBlock (srFunctions sf)
  , "subroutines"     .= map encodeSubroutineBlock (srSubroutines sf)
  ]

encodeForwardBlock :: ForwardBlock -> Value
encodeForwardBlock fb = object
  [ "types"     .= map encodeTypeDecl      (fwdTypes     fb)
  , "instances" .= map encodeGlobalInstance (fwdInstances fb)
  ]

encodePrototypesBlock :: PrototypesBlock -> Value
encodePrototypesBlock pb = object
  [ "decls" .= map encodeProtoDecl (protoDecls pb) ]

encodeVariablesBlock :: VariablesBlock -> Value
encodeVariablesBlock vb = object
  [ "scope" .= encodeVarScope (varScope vb)
  , "decls" .= map encodeVarDecl (varDecls vb)
  ]

encodeVarScope :: VarScope -> Text
encodeVarScope GlobalVars = "global"
encodeVarScope TypeVars   = "type"

encodeTypeDecl :: TypeDecl -> Value
encodeTypeDecl td = object
  [ "name"     .= tdName td
  , "ancestor" .= tdAncestor td
  , "within"   .= tdWithin td
  ]

encodeTypeBlock :: TypeBlock -> Value
encodeTypeBlock tb = object
  [ "decl" .= encodeTypeDecl (tbDecl tb)
  , "body" .= encodeBody     (tbBody  tb)
  ]

encodeVarDecl :: VarDecl -> Value
encodeVarDecl vd = object
  [ "modifiers" .= vdModifiers vd
  , "type"      .= vdType vd
  , "name"      .= vdName vd
  ]

encodeGlobalInstance :: GlobalInstance -> Value
encodeGlobalInstance gi = object
  [ "type" .= giType gi
  , "name" .= giName gi
  ]

encodeProtoDecl :: ProtoDecl -> Value
encodeProtoDecl (ProtoFn  fs) = object ["tag" .= ("fn"  :: Text), "sig" .= encodeFnSig  fs]
encodeProtoDecl (ProtoSub ss) = object ["tag" .= ("sub" :: Text), "sig" .= encodeSubSig ss]
encodeProtoDecl (ProtoEv  es) = object ["tag" .= ("ev"  :: Text), "sig" .= encodeEventSig es]

encodeFnSig :: FnSig -> Value
encodeFnSig fs = object
  [ "modifiers"  .= fnsMods fs
  , "returnType" .= fnsRetType fs
  , "name"       .= fnsName fs
  , "params"     .= fnsParams fs
  , "throws"     .= fnsThrows fs
  ]

encodeSubSig :: SubSig -> Value
encodeSubSig ss = object
  [ "modifiers" .= ssMods ss
  , "name"      .= ssName ss
  , "params"    .= ssParams ss
  , "throws"    .= ssThrows ss
  ]

encodeEventSig :: EventSig -> Value
encodeEventSig es = object
  [ "name"   .= esName es
  , "rawSig" .= esRawSig es
  ]

encodeFunctionBlock :: FunctionBlock -> Value
encodeFunctionBlock fb = object
  [ "sig"  .= encodeFnSig (fbSig fb)
  , "body" .= encodeBody (fbBody fb)
  ]

encodeSubroutineBlock :: SubroutineBlock -> Value
encodeSubroutineBlock sb = object
  [ "sig"  .= encodeSubSig (sbSig sb)
  , "body" .= encodeBody (sbBody sb)
  ]

encodeEventBlock :: EventBlock -> Value
encodeEventBlock eb = object
  [ "sig"  .= encodeEventSig (evSig eb)
  , "body" .= encodeBody (evBody eb)
  ]

encodeOnBlock :: OnBlock -> Value
encodeOnBlock ob = object
  [ "qualName" .= obQualName ob
  , "owner"    .= obOwner ob
  , "event"    .= obEvent ob
  , "body"     .= encodeBody (obBody ob)
  ]

encodeBody :: [Statement] -> Value
encodeBody = toJSON . map (llText . stmtSource)
