{-# LANGUAGE StrictData #-}
-- | Type-mismatch / compatibility checking.
--
-- Pure module — no I/O. A partial, compositional expression typer over
-- 'PB.Analysis.TypeResolve''s resolved local\/param types, used to flag
-- assignment- and return-statement type mismatches where both sides are
-- statically known. An expression this module cannot type produces no
-- finding, never a guess — the same "skip rather than guess" precedent
-- 'PB.Analysis.TypeResolve.extractDwControlBindings' already sets. Public
-- API:
--
--   findTypeMismatches :: [ResolvedType] -> Set Text -> Set Text
--                       -> Map Text Text -> Text -> Text -> SrFile
--                       -> [TypeMismatchFinding]
module PB.Analysis.TypeMismatch
  ( TypeFamily (..)
  , MismatchKind (..)
  , mismatchKindText
  , TypeMismatchFinding (..)
  , renderFamily
  , classifyFamily
  , familyOfResolvedType
  , compatible
  , typeOfExpr
  , findTypeMismatches
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import PB.AST.Type        (PbType (..), parseTypeText, renderPbType)
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
  | FamObject   Text
  | FamUserType Text
  | FamAny
  deriving (Eq, Show, Generic)

renderFamily :: TypeFamily -> Text
renderFamily FamNumeric      = "numeric"
renderFamily FamString       = "string"
renderFamily FamBoolean      = "boolean"
renderFamily FamDateTime     = "datetime"
renderFamily FamBlob         = "blob"
renderFamily (FamObject t)   = "object:" <> t
renderFamily (FamUserType t) = "user_type:" <> t
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
classifyFamily :: PbType -> Set.Set Text -> Set.Set Text -> TypeFamily
classifyFamily ty objs userTypes = case classifyPbType ty objs userTypes of
  ("object", Just t)    -> FamObject t
  ("user_type", Just t) -> FamUserType t
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
  "object"    -> maybe FamAny FamObject (rtTarget rt)
  "user_type" -> maybe FamAny FamUserType (rtTarget rt)
  "primitive" -> primitiveFamily (rtRawType rt)
  _           -> FamAny -- "any" / "unresolved": never guess

-- ---------------------------------------------------------------------------
-- Compatibility

-- | Is a value of family @rhs@ assignable to a variable of family @lhs@?
compatible :: Map.Map Text Text -> TypeFamily -> TypeFamily -> Bool
compatible _        FamAny        _            = True
compatible _        _             FamAny       = True
compatible inherits (FamObject l) (FamObject r) = l == r || l `elem` ancestorChain r inherits
compatible _        l             r             = l == r

-- ---------------------------------------------------------------------------
-- Expression typing

-- | A partial, compositional expression typer. 'Nothing' means "cannot
-- determine statically" — never a guess. Binop composition mirrors
-- 'PB.Compile.ValueModel.evalBinOp''s existing runtime widening semantics
-- rather than inventing a second, possibly-divergent table.
typeOfExpr :: Map.Map Text TypeFamily -> Expr -> Maybe TypeFamily
typeOfExpr _     (ExBool _) = Just FamBoolean
typeOfExpr _     (ExInt _)  = Just FamNumeric
typeOfExpr _     (ExReal _) = Just FamNumeric
typeOfExpr _     (ExStr _)  = Just FamString
typeOfExpr _     (ExDate _) = Just FamDateTime
typeOfExpr _     (ExTime _) = Just FamDateTime
typeOfExpr _     ExNull     = Nothing -- handled specially by callers, not a family
typeOfExpr scope (ExLvalue (Lvalue [LvSegment n Nothing])) = Map.lookup n scope
typeOfExpr scope (ExBinOp l op r) = do
  lf <- typeOfExpr scope l
  rf <- typeOfExpr scope r
  combineBinOp op lf rf
typeOfExpr scope (ExNot e) = case typeOfExpr scope e of
  Just FamBoolean -> Just FamBoolean
  _               -> Nothing
typeOfExpr scope (ExNeg e) = case typeOfExpr scope e of
  Just FamNumeric -> Just FamNumeric
  _               -> Nothing
typeOfExpr _ _ = Nothing -- calls, dispatch, create, host vars, arrays, raw:
                          -- real inference or cross-proc lookup, not this pass's job

-- | Combine two already-typed operand families through a 'BinOp'. Mirrors
-- 'PB.Compile.ValueModel.evalBinOp'\/'numericOp''s existing runtime widening
-- rules at the family level: arithmetic needs both operands numeric (or,
-- for '+', both string — PB's concatenation operator); comparisons and
-- logical ops always produce a boolean given well-typed operands.
combineBinOp :: BinOp -> TypeFamily -> TypeFamily -> Maybe TypeFamily
combineBinOp BopAdd FamString  FamString  = Just FamString
combineBinOp BopAdd FamNumeric FamNumeric = Just FamNumeric
combineBinOp BopAdd _          _          = Nothing
combineBinOp BopSub FamNumeric FamNumeric = Just FamNumeric
combineBinOp BopSub _          _          = Nothing
combineBinOp BopMul FamNumeric FamNumeric = Just FamNumeric
combineBinOp BopMul _          _          = Nothing
combineBinOp BopDiv FamNumeric FamNumeric = Just FamNumeric
combineBinOp BopDiv _          _          = Nothing
combineBinOp BopPow FamNumeric FamNumeric = Just FamNumeric
combineBinOp BopPow _          _          = Nothing
combineBinOp BopEq  _          _          = Just FamBoolean
combineBinOp BopNe  _          _          = Just FamBoolean
combineBinOp BopLt  _          _          = Just FamBoolean
combineBinOp BopGt  _          _          = Just FamBoolean
combineBinOp BopLe  _          _          = Just FamBoolean
combineBinOp BopGe  _          _          = Just FamBoolean
combineBinOp BopAnd FamBoolean FamBoolean = Just FamBoolean
combineBinOp BopAnd _          _          = Nothing
combineBinOp BopOr  FamBoolean FamBoolean = Just FamBoolean
combineBinOp BopOr  _          _          = Nothing
combineBinOp BopXor FamBoolean FamBoolean = Just FamBoolean
combineBinOp BopXor _          _          = Nothing

-- ---------------------------------------------------------------------------
-- Findings

data MismatchKind = AssignMismatch | ReturnMismatch
  deriving (Eq, Ord, Show, Generic)

mismatchKindText :: MismatchKind -> Text
mismatchKindText AssignMismatch = "assign-mismatch"
mismatchKindText ReturnMismatch = "return-mismatch"

data TypeMismatchFinding = TypeMismatchFinding
  { tmfObject  :: Text
  , tmfProc    :: Text
  , tmfLine    :: Int
  , tmfTarget  :: Text  -- ^ LHS var name (AssignMismatch) or function name (ReturnMismatch)
  , tmfLhsType :: Text  -- ^ rendered 'TypeFamily' of the declared/expected side
  , tmfRhsDesc :: Text  -- ^ rendered description of the offending expression
  , tmfKind    :: MismatchKind
  } deriving (Eq, Show, Generic)

-- | Every top-level @lhs = rhs@ assignment reachable in a body, as
-- @(line, lhsVarName, rhs)@ — single-segment, non-subscripted LHS only
-- ('BsAssign''s other LHS shapes have no direct 'ResolvedType' key; skipped,
-- not guessed, same precedent as
-- 'PB.Analysis.TypeResolve.extractDwControlBindings'). Recurses into
-- 'BsIf'\/'BsFor'\/'BsDo'\/'BsChoose' bodies, mirroring
-- 'PB.Analysis.TypeResolve.walkBodyCallSites'\'s traversal shape.
walkBodyAssigns :: [Located BodyStmt] -> [(Int, Text, Expr)]
walkBodyAssigns = concatMap go
  where
    go (Located line stmt) = case stmt of
      BsAssign (Lvalue [LvSegment n Nothing]) rhs -> [(line, n, rhs)]
      BsAssign _ _ -> []
      BsIf IfStmt { ifThen = t, ifElseIfs = eis, ifElse = e } ->
        walkBodyAssigns t
        <> concatMap (walkBodyAssigns . eifBody) eis
        <> maybe [] walkBodyAssigns e
      BsFor ForStmt { forBody = b } -> walkBodyAssigns b
      BsDo DoStmt { doBody = b }    -> walkBodyAssigns b
      BsChoose ChooseStmt { chooseClauses = cs } ->
        concatMap (walkBodyAssigns . ccBody) cs
      _ -> []

-- | Every @return expr@ reachable in a body, as @(line, expr)@. Same
-- recursion shape as 'walkBodyAssigns'.
walkBodyReturns :: [Located BodyStmt] -> [(Int, Expr)]
walkBodyReturns = concatMap go
  where
    go (Located line stmt) = case stmt of
      BsReturn (Just e) -> [(line, e)]
      BsReturn Nothing  -> []
      BsIf IfStmt { ifThen = t, ifElseIfs = eis, ifElse = e } ->
        walkBodyReturns t
        <> concatMap (walkBodyReturns . eifBody) eis
        <> maybe [] walkBodyReturns e
      BsFor ForStmt { forBody = b } -> walkBodyReturns b
      BsDo DoStmt { doBody = b }    -> walkBodyReturns b
      BsChoose ChooseStmt { chooseClauses = cs } ->
        concatMap (walkBodyReturns . ccBody) cs
      _ -> []

-- | A short rendering of an RHS expression for a finding's diagnostic text.
-- Only the shapes 'typeOfExpr' can actually type ever reach a finding, so
-- the fallback case is unreachable in practice — kept total regardless,
-- per this project's no-partial-functions rule.
rhsDesc :: Expr -> Text
rhsDesc (ExStr s)  = "\"" <> s <> "\""
rhsDesc (ExInt s)  = s
rhsDesc (ExReal s) = s
rhsDesc (ExDate s) = s
rhsDesc (ExTime s) = s
rhsDesc (ExBool b) = if b then "true" else "false"
rhsDesc (ExLvalue lv) = T.intercalate "." [n | LvSegment n _ <- segments lv]
rhsDesc _ = "<expr>"

-- | Assignment- and return-statement type mismatches for one file's
-- procedures. 'allResolved' is the whole-workspace 'ResolvedType' list (as
-- produced by 'PB.Analysis.TypeResolve.resolveTypes'); only entries for
-- @obj@ are used, matching 'PB.Analysis.TypeResolve.extractLocalVars'\'s own
-- per-object scoping convention.
findTypeMismatches
  :: [ResolvedType]
  -> Set.Set Text
  -> Set.Set Text
  -> Map.Map Text Text
  -> Text
  -> Text
  -> SrFile
  -> [TypeMismatchFinding]
findTypeMismatches allResolved objs userTypes inherits _file obj sf =
  concatMap assignFindingsFor procBodies <> concatMap returnFindingsFor (srFunctions sf)
  where
    resolvedForObj = filter ((== obj) . rtObject) allResolved

    scopeFor procN = Map.fromList
      [ (rtVarName rt, familyOfResolvedType rt)
      | rt <- resolvedForObj, rtProcName rt == procN
      ]

    procBodies :: [(Text, [Located BodyStmt])]
    procBodies =
      map (\fb -> (fnsName (fbSig fb), fbBody fb)) (srFunctions sf)
      <> map (\sb -> (ssName (sbSig sb), sbBody sb)) (srSubroutines sf)
      <> map (\ev -> (esName (evSig ev), evBody ev)) (srEvents sf)
      <> map (\ob -> (obEvent ob, obBody ob)) (srOnBlocks sf)

    assignFindingsFor (procN, body) =
      let scope = scopeFor procN
      in [ TypeMismatchFinding obj procN line varN (renderFamily lhsFam) (rhsDesc rhs) AssignMismatch
         | (line, varN, rhs) <- walkBodyAssigns body
         , Just lhsFam <- [Map.lookup varN scope]
         , Just rhsFam <- [typeOfExpr scope rhs]
         , not (compatible inherits lhsFam rhsFam)
         ]

    returnFindingsFor fb =
      let procN  = fnsName (fbSig fb)
          retFam = classifyFamily (parseTypeText (fnsReturnType (fbSig fb))) objs userTypes
          scope  = scopeFor procN
      in [ TypeMismatchFinding obj procN line procN (renderFamily retFam) (rhsDesc e) ReturnMismatch
         | (line, e) <- walkBodyReturns (fbBody fb)
         , Just eFam <- [typeOfExpr scope e]
         , not (compatible inherits retFam eFam)
         ]
