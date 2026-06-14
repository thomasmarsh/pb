{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module PB.Pipeline.Serialise
  ( allTypeScriptDeclarations
  , formatTSDeclarations
  ) where

import PB.Prelude
import Data.Aeson              (Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Aeson.TypeScript.TH (TSDeclaration, TypeScript (..), deriveTypeScript, formatTSDeclarations)
import Data.Char               (isLower, toLower)
import Data.Proxy              (Proxy (..))

import PB.AST.BodyStmt
import PB.AST.DataWindow
import PB.AST.Expr
import PB.AST.SourceFile

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

-- Expr layer
instance ToJSON LvSegment    where toJSON = genericToJSON customOptions
instance ToJSON Lvalue       where toJSON = genericToJSON customOptions
instance ToJSON BinOp        where toJSON = genericToJSON customOptions
instance ToJSON DispatchMode where toJSON = genericToJSON customOptions
instance ToJSON DispatchExpr where toJSON = genericToJSON customOptions
instance ToJSON Expr         where toJSON = genericToJSON customOptions

-- BodyStmt layer
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

-- ---------------------------------------------------------------------------
-- TypeScript instances — one combined splice so mutually recursive types
-- (ElseIf ↔ BodyStmt) are generated as a single declaration group.
-- ---------------------------------------------------------------------------

$(let strip s = case span isLower s of { ([], _) -> s; (_, []) -> s; (_, c:cs) -> toLower c : cs }
      opts  = defaultOptions { fieldLabelModifier = strip }
  in concat <$> mapM (deriveTypeScript opts)
  -- Expr layer
  [ ''LvSegment, ''Lvalue, ''BinOp, ''DispatchMode, ''DispatchExpr, ''Expr
  -- BodyStmt layer
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
  -- BodyStmt layer
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
