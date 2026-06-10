{-# OPTIONS_GHC -Wno-orphans #-}
-- Orphan ToJSON instances for PB.AST.* types. All JSON serialisation lives here;
-- PB.AST.* modules remain encoding-free.
module PB.Pipeline.Serialise () where

import PB.Prelude
import PB.AST.BodyStmt      ( AugOp (..), BodyStmt (..), PbCall (..)
                            , IfStmt (..), ForStmt (..), DoCondition (..)
                            , DoStmt (..), CaseClause (..), ChooseStmt (..) )
import PB.AST.Expr          ( CallExpr (..), CreateExpr (..), Expr (..)
                            , Literal (..), LvSegment (..), Lvalue (..) )
import PB.AST.SourceFile
import PB.Lexing.Splitter   (Statement (..))
import PB.Lexing.Token      (tkText)
import PB.Pipeline.Preprocess (LogicalLine (..))

import Data.Aeson (ToJSON (..), Value (..), object, (.=))

-- ---------------------------------------------------------------------------
-- Object

instance ToJSON SrFile where
  toJSON sf = object
    [ "headers"         .= srHeaders sf
    , "forward"         .= srForward sf
    , "prototypes"      .= srPrototypes sf
    , "variables"       .= srVariables sf
    , "globalInstances" .= srGlobalInstances sf
    , "typeBlocks"      .= srTypeBlocks sf
    , "onBlocks"        .= srOnBlocks sf
    , "events"          .= srEvents sf
    , "functions"       .= srFunctions sf
    , "subroutines"     .= srSubroutines sf
    ]

instance ToJSON ForwardBlock where
  toJSON fb = object
    [ "types"     .= fwdTypes fb
    , "instances" .= fwdInstances fb
    ]

instance ToJSON PrototypesBlock where
  toJSON pb = object ["decls" .= protoDecls pb]

instance ToJSON VariablesBlock where
  toJSON vb = object
    [ "scope" .= varScope vb
    , "decls" .= varDecls vb
    ]

instance ToJSON VarScope where
  toJSON GlobalVars = String "global"
  toJSON TypeVars   = String "type"

instance ToJSON TypeDecl where
  toJSON td = object
    [ "name"     .= tdName td
    , "ancestor" .= tdAncestor td
    , "within"   .= tdWithin td
    ]

instance ToJSON TypeBlock where
  toJSON tb = object
    [ "decl" .= tbDecl tb
    , "body" .= tbBody tb
    ]

instance ToJSON VarDecl where
  toJSON vd = object
    [ "modifiers" .= vdModifiers vd
    , "type"      .= vdType vd
    , "name"      .= vdName vd
    ]

instance ToJSON GlobalInstance where
  toJSON gi = object
    [ "type" .= giType gi
    , "name" .= giName gi
    ]

instance ToJSON ProtoDecl where
  toJSON (ProtoFn  fs) = object ["tag" .= ("fn"  :: Text), "sig" .= fs]
  toJSON (ProtoSub ss) = object ["tag" .= ("sub" :: Text), "sig" .= ss]
  toJSON (ProtoEv  es) = object ["tag" .= ("ev"  :: Text), "sig" .= es]

instance ToJSON FnSig where
  toJSON fs = object
    [ "modifiers"  .= fnsMods fs
    , "returnType" .= fnsRetType fs
    , "name"       .= fnsName fs
    , "params"     .= fnsParams fs
    , "throws"     .= fnsThrows fs
    ]

instance ToJSON SubSig where
  toJSON ss = object
    [ "modifiers" .= ssMods ss
    , "name"      .= ssName ss
    , "params"    .= ssParams ss
    , "throws"    .= ssThrows ss
    ]

instance ToJSON EventSig where
  toJSON es = object
    [ "name"   .= esName es
    , "rawSig" .= esRawSig es
    ]

instance ToJSON FunctionBlock where
  toJSON fb = object
    [ "sig"  .= fbSig fb
    , "body" .= fbBody fb
    ]

instance ToJSON SubroutineBlock where
  toJSON sb = object
    [ "sig"  .= sbSig sb
    , "body" .= sbBody sb
    ]

instance ToJSON EventBlock where
  toJSON eb = object
    [ "sig"  .= evSig eb
    , "body" .= evBody eb
    ]

instance ToJSON OnBlock where
  toJSON ob = object
    [ "qualName" .= obQualName ob
    , "owner"    .= obOwner ob
    , "event"    .= obEvent ob
    , "body"     .= obBody ob
    ]

-- ---------------------------------------------------------------------------
-- BodyStmt

instance ToJSON AugOp where
  toJSON AugAdd = String "add"
  toJSON AugSub = String "sub"
  toJSON AugMul = String "mul"
  toJSON AugDiv = String "div"

instance ToJSON BodyStmt where
  toJSON (BsLocalVar   ts)         = object ["tag" .= ("local_var"  :: Text), "tokens" .= map tkText ts]
  toJSON (BsAssign     lhs rhs)    = object ["tag" .= ("assign"     :: Text), "lhs" .= lhs, "rhs" .= rhs]
  toJSON (BsAugAssign  lhs op rhs) = object ["tag" .= ("aug_assign" :: Text), "lhs" .= map tkText lhs, "op" .= op, "rhs" .= map tkText rhs]
  toJSON (BsInc        lhs)        = object ["tag" .= ("inc"        :: Text), "lhs" .= map tkText lhs]
  toJSON (BsDec        lhs)        = object ["tag" .= ("dec"        :: Text), "lhs" .= map tkText lhs]
  toJSON (BsCall       expr)       = object ["tag" .= ("call"       :: Text), "expr" .= expr]
  toJSON (BsPbCall     pc)         = object ["tag" .= ("pb_call"    :: Text), "ancestor" .= pbcAncestor pc, "event" .= pbcEvent pc]
  toJSON (BsDestroy    lv)         = object ["tag" .= ("destroy"    :: Text), "lvalue" .= lv]
  toJSON (BsReturn     Nothing)    = object ["tag" .= ("return"     :: Text)]
  toJSON (BsReturn     (Just e))   = object ["tag" .= ("return"     :: Text), "value" .= e]
  toJSON (BsIf         is)         = jsonIfStmt is
  toJSON (BsFor        fs)         = jsonForStmt fs
  toJSON (BsDo         ds)         = jsonDoStmt ds
  toJSON (BsChoose     cs)         = jsonChooseStmt cs
  toJSON BsExit                    = object ["tag" .= ("exit"       :: Text)]
  toJSON BsContinue                = object ["tag" .= ("continue"   :: Text)]
  toJSON (BsRaw        s)          = object ["tag" .= ("raw"        :: Text), "text" .= (llText . stmtSource) s]

instance ToJSON DoCondition where
  toJSON (DoWhile e) = object ["tag" .= ("while" :: Text), "expr" .= e]
  toJSON (DoUntil e) = object ["tag" .= ("until" :: Text), "expr" .= e]

instance ToJSON CaseClause where
  toJSON cl = object
    [ "expr" .= fmap (map tkText) (ccExpr cl)
    , "body" .= ccBody cl
    ]

-- Private helpers for compound statements (only serialised via BodyStmt)

jsonIfStmt :: IfStmt -> Value
jsonIfStmt is = object
  [ "tag"     .= ("if" :: Text)
  , "cond"    .= ifCond is
  , "then"    .= ifThen is
  , "elseIfs" .= map (\(c, b) -> object ["cond" .= c, "body" .= b]) (ifElseIfs is)
  , "else"    .= ifElse is
  ]

jsonForStmt :: ForStmt -> Value
jsonForStmt fs = object
  [ "tag"  .= ("for" :: Text)
  , "var"  .= forVar  fs
  , "from" .= forFrom fs
  , "to"   .= forTo   fs
  , "step" .= forStep fs
  , "body" .= forBody fs
  ]

jsonDoStmt :: DoStmt -> Value
jsonDoStmt ds = object
  [ "tag"  .= ("do"  :: Text)
  , "cond" .= doCond ds
  , "body" .= doBody ds
  , "loop" .= doLoop ds
  ]

jsonChooseStmt :: ChooseStmt -> Value
jsonChooseStmt cs = object
  [ "tag"     .= ("choose" :: Text)
  , "expr"    .= chooseExpr cs
  , "clauses" .= chooseClauses cs
  ]

-- ---------------------------------------------------------------------------
-- Expr

instance ToJSON Expr where
  toJSON (ExLit    lit)  = toJSON lit
  toJSON (ExEnum   name) = object ["tag" .= ("enum"         :: Text), "name"  .= name]
  toJSON (ExLvalue lv)   = object ["tag" .= ("lvalue"       :: Text), "segments" .= lvSegments lv]
  toJSON (ExCall   ce)   = toJSON ce
  toJSON (ExCreate (CreateClass cls)) = object ["tag" .= ("create"       :: Text), "class" .= cls]
  toJSON (ExCreate (CreateUsing e))   = object ["tag" .= ("create_using" :: Text), "expr"  .= e]
  toJSON (ExArray  elems) = object ["tag" .= ("array" :: Text), "items" .= elems]
  toJSON (ExRaw    ts)   = object ["tag" .= ("raw"          :: Text), "tokens" .= map tkText ts]

instance ToJSON Literal where
  toJSON (LitBool b) = object ["tag" .= ("bool"   :: Text), "value" .= b]
  toJSON (LitInt  t) = object ["tag" .= ("int"    :: Text), "value" .= t]
  toJSON (LitReal t) = object ["tag" .= ("real"   :: Text), "value" .= t]
  toJSON (LitStr  t) = object ["tag" .= ("string" :: Text), "value" .= t]
  toJSON (LitDate t) = object ["tag" .= ("date"   :: Text), "value" .= t]
  toJSON (LitTime t) = object ["tag" .= ("time"   :: Text), "value" .= t]
  toJSON LitNull     = object ["tag" .= ("null"   :: Text)]

instance ToJSON CallExpr where
  toJSON ce = object
    [ "tag"    .= ("call_expr" :: Text)
    , "callee" .= ceCallee ce
    , "args"   .= map (map tkText) (ceArgs ce)
    ]

instance ToJSON Lvalue where
  toJSON lv = object ["segments" .= lvSegments lv]

instance ToJSON LvSegment where
  toJSON seg = object $
    ["name" .= lvsName seg] <>
    case lvsSubscript seg of
      Nothing  -> ["subscript" .= (Nothing :: Maybe Value)]
      Just sub -> ["subscript" .= map tkText sub]
