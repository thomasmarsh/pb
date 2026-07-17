{-# LANGUAGE StrictData #-}
-- | Type-family vocabulary and compatibility relation.
--
-- Pure module — no I/O. Defines 'TypeFamily' (a compatibility-checking
-- classification of 'PbType', finer than
-- 'PB.Analysis.TypeResolve.classifyPbType''s identity-resolution "kind"),
-- the 'compatible' assignability relation (including the object-subtype
-- ancestor-chain check), and the 'TypeMismatchFinding' shape. No expression
-- typing or AST walking lives here — see 'PB.Analysis.TypeCheck.inferExpr'
-- \/'PB.Analysis.TypeCheck.checkBody' for the decorating walk that consumes
-- this vocabulary.
module PB.Analysis.TypeFamily
  ( TypeFamily (..)
  , MismatchKind (..)
  , mismatchKindText
  , TypeMismatchFinding (..)
  , renderFamily
  , classifyFamily
  , familyOfResolvedType
  , compatible
  ) where

import PB.Prelude
import PB.AST.Ident       (Ident, identOrig, mkIdent, IdentSet)
import PB.AST.Type        (PbType (..), renderPbType)
import PB.Analysis.TypeResolve (ResolvedType (..), classifyPbType, ancestorChain)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T
import GHC.Generics (Generic)

-- ---------------------------------------------------------------------------
-- Type families

-- | A compatibility-checking classification of 'PbType', finer than
-- 'PB.Analysis.TypeResolve.classifyPbType''s "primitive" bucket (which
-- doesn't distinguish numeric from string from boolean — identity
-- resolution doesn't need to, compatibility checking does).
data TypeFamily
  = FamNumeric
  | FamString
  | FamBoolean
  | FamDateTime
  | FamBlob
  | FamObject   Ident
  | FamUserType Ident
  | FamAny
  deriving (Eq, Show, Generic)

renderFamily :: TypeFamily -> Text
renderFamily FamNumeric      = "numeric"
renderFamily FamString       = "string"
renderFamily FamBoolean      = "boolean"
renderFamily FamDateTime     = "datetime"
renderFamily FamBlob         = "blob"
renderFamily (FamObject t)   = "object:" <> identOrig t
renderFamily (FamUserType t) = "user_type:" <> identOrig t
renderFamily FamAny          = "any"

numericNames, stringNames, dateTimeNames :: Set.Set Text
numericNames = Set.fromList
  [ "byte", "dec", "decimal", "double", "int", "integer", "long"
  , "longlong", "longptr", "real", "uint", "ulong"
  , "unsignedint", "unsignedinteger", "unsignedlong" ]
stringNames   = Set.fromList ["char", "character", "string"]
dateTimeNames = Set.fromList ["date", "datetime", "time"]

-- | Classify a 'PbType' into a 'TypeFamily'. Delegates object\/user_type\/
-- any\/unresolved classification to 'classifyPbType' (do not re-derive that
-- policy here); only refines its "primitive" bucket into
-- numeric\/string\/boolean\/datetime\/blob, which compatibility checking
-- needs and identity resolution doesn't.
classifyFamily :: PbType -> IdentSet -> IdentSet -> TypeFamily
classifyFamily ty objs userTypes = case classifyPbType ty objs userTypes of
  ("object", Just t)    -> FamObject (mkIdent t)
  ("user_type", Just t) -> FamUserType (mkIdent t)
  ("primitive", _)      -> primitiveFamily (renderPbType ty)
  _                     -> FamAny -- "any" / "unresolved": never guess, always compatible

-- | Sub-classify a primitive type's rendered text into a finer family.
-- Takes raw text (not 'PbType') so both 'classifyFamily' and
-- 'familyOfResolvedType' (which only has 'ResolvedType''s already-rendered
-- @rtRawType@, not the original 'PbType') can share it.
primitiveFamily :: Text -> TypeFamily
primitiveFamily raw
  | "decimal{" `T.isPrefixOf` lower  = FamNumeric
  | lower `Set.member` numericNames  = FamNumeric
  | lower `Set.member` stringNames   = FamString
  | lower == "boolean"               = FamBoolean
  | lower `Set.member` dateTimeNames = FamDateTime
  | lower == "blob"                  = FamBlob
  | otherwise                        = FamAny -- unrecognised primitive text: never guess
  where lower = T.toLower raw

-- | Classify an already-resolved 'ResolvedType' into a 'TypeFamily'. Builds
-- directly on 'PB.Analysis.TypeResolve.resolveTypes''s own @rtKind@\/@rtTarget@
-- output rather than re-deriving kind\/target from @rtRawType@ independently
-- — 'resolveTypes' applies its own control-name-inference fallback
-- ('PB.Analysis.TypeResolve.classifyControlType') before producing @rtKind@,
-- and re-deriving from raw text here would silently drop that fallback for
-- any variable it resolved.
familyOfResolvedType :: ResolvedType -> TypeFamily
familyOfResolvedType rt = case rtKind rt of
  "object"    -> maybe FamAny (FamObject . mkIdent) (rtTarget rt)
  "user_type" -> maybe FamAny (FamUserType . mkIdent) (rtTarget rt)
  "primitive" -> primitiveFamily (rtRawType rt)
  _           -> FamAny -- "any" / "unresolved": never guess

-- ---------------------------------------------------------------------------
-- Compatibility

-- | Is a value of family @rhs@ assignable to a variable of family @lhs@?
-- Object compatibility checks both ancestor directions: PowerBuilder
-- resolves an object assignment/argument/return at runtime regardless of
-- which side is the more specific type (an ancestor-typed expression
-- assigned into a descendant-typed slot is an implicit, runtime-checked
-- downcast -- ordinary, idiomatic PB, not a compile-time error), so a
-- one-directional ancestor check would flag every such assignment as a
-- false positive. The direct @l == r@ check and the 'ancestorChain' walk
-- both use 'Ident''s own case-insensitive 'Eq' (Plan 179 Phase 5) --
-- 'inherits' is passed straight to 'PB.Analysis.TypeResolve.ancestorChain',
-- no lowercase projection needed now that walk is itself canonical-keyed.
compatible :: Map.Map Ident Ident -> TypeFamily -> TypeFamily -> Bool
compatible _        FamAny        _            = True
compatible _        _             FamAny       = True
compatible inherits (FamObject l) (FamObject r) =
  l == r
    || l `elem` ancestorChain r inherits
    || r `elem` ancestorChain l inherits
compatible _        l             r             = l == r

-- ---------------------------------------------------------------------------
-- Findings

data MismatchKind = AssignMismatch | ReturnMismatch | CallArgMismatch
  deriving (Eq, Ord, Show, Generic)

mismatchKindText :: MismatchKind -> Text
mismatchKindText AssignMismatch  = "assign-mismatch"
mismatchKindText ReturnMismatch  = "return-mismatch"
mismatchKindText CallArgMismatch = "call-arg-mismatch"

data TypeMismatchFinding = TypeMismatchFinding
  { tmfObject  :: Text
  , tmfProc    :: Text
  , tmfLine    :: Int
  , tmfTarget  :: Text  -- ^ LHS var name (AssignMismatch), function name (ReturnMismatch), or param name (CallArgMismatch)
  , tmfLhsType :: Text  -- ^ rendered 'TypeFamily' of the declared/expected side
  , tmfRhsDesc :: Text  -- ^ rendered description of the offending expression
  , tmfKind    :: MismatchKind
  } deriving (Eq, Show, Generic)
