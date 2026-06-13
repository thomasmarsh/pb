{-# OPTIONS_GHC -Wno-orphans #-}
-- Orphan ToJSON instances for PB.AST.* types, derived from HasCodec via
-- toJSONViaCodec. All encoding logic lives in PB.Pipeline.Codec.
module PB.Pipeline.Serialise () where

import Autodocodec       (toJSONViaCodec)
import Data.Aeson        (ToJSON (..))

import PB.AST.BodyStmt      ( AugOp, BodyStmt, PbCall
                            , IfStmt, ForStmt, DoCondition
                            , DoStmt, CaseClause, ChooseStmt )
import PB.AST.DataWindow
import PB.AST.Expr          ( BinOp, CallExpr, Expr
                            , DispatchMode, DispatchExpr
                            , LvSegment, Lvalue )
import PB.AST.SourceFile
import PB.Pipeline.Codec    ()   -- HasCodec instances

instance ToJSON SrFile           where toJSON = toJSONViaCodec
instance ToJSON ForwardBlock     where toJSON = toJSONViaCodec
instance ToJSON PrototypesBlock  where toJSON = toJSONViaCodec
instance ToJSON VariablesBlock   where toJSON = toJSONViaCodec
instance ToJSON VarScope         where toJSON = toJSONViaCodec
instance ToJSON TypeDecl         where toJSON = toJSONViaCodec
instance ToJSON TypeBlock        where toJSON = toJSONViaCodec
instance ToJSON VarDecl          where toJSON = toJSONViaCodec
instance ToJSON GlobalInstance   where toJSON = toJSONViaCodec
instance ToJSON ProtoDecl        where toJSON = toJSONViaCodec
instance ToJSON FnSig            where toJSON = toJSONViaCodec
instance ToJSON SubSig           where toJSON = toJSONViaCodec
instance ToJSON EventSig         where toJSON = toJSONViaCodec
instance ToJSON FunctionBlock    where toJSON = toJSONViaCodec
instance ToJSON SubroutineBlock  where toJSON = toJSONViaCodec
instance ToJSON EventBlock       where toJSON = toJSONViaCodec
instance ToJSON OnBlock          where toJSON = toJSONViaCodec

instance ToJSON AugOp            where toJSON = toJSONViaCodec
instance ToJSON BodyStmt         where toJSON = toJSONViaCodec
instance ToJSON PbCall           where toJSON = toJSONViaCodec
instance ToJSON IfStmt           where toJSON = toJSONViaCodec
instance ToJSON ForStmt          where toJSON = toJSONViaCodec
instance ToJSON DoCondition      where toJSON = toJSONViaCodec
instance ToJSON DoStmt           where toJSON = toJSONViaCodec
instance ToJSON CaseClause       where toJSON = toJSONViaCodec
instance ToJSON ChooseStmt       where toJSON = toJSONViaCodec

instance ToJSON BinOp            where toJSON = toJSONViaCodec
instance ToJSON CallExpr         where toJSON = toJSONViaCodec
instance ToJSON Expr             where toJSON = toJSONViaCodec
instance ToJSON DispatchMode     where toJSON = toJSONViaCodec
instance ToJSON DispatchExpr     where toJSON = toJSONViaCodec
instance ToJSON LvSegment        where toJSON = toJSONViaCodec
instance ToJSON Lvalue           where toJSON = toJSONViaCodec

instance ToJSON DataWindowFile   where toJSON = toJSONViaCodec
instance ToJSON DwObjectAttrs    where toJSON = toJSONViaCodec
instance ToJSON DwTable          where toJSON = toJSONViaCodec
instance ToJSON DwColumn         where toJSON = toJSONViaCodec
instance ToJSON DwArgument       where toJSON = toJSONViaCodec
instance ToJSON DwWhereClause    where toJSON = toJSONViaCodec
instance ToJSON DwRetrieve       where toJSON = toJSONViaCodec
instance ToJSON DwRetrieveOrRaw  where toJSON = toJSONViaCodec
instance ToJSON DwBandKind       where toJSON = toJSONViaCodec
instance ToJSON DwBand           where toJSON = toJSONViaCodec
instance ToJSON DwGroup          where toJSON = toJSONViaCodec
instance ToJSON DwControl        where toJSON = toJSONViaCodec
instance ToJSON DwUnknownBlock   where toJSON = toJSONViaCodec
