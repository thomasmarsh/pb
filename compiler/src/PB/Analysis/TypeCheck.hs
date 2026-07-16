{-# LANGUAGE StrictData #-}
-- | Static-type decoration and mismatch checking.
--
-- Pure module — no I/O. 'inferExpr' is a partial, compositional expression
-- typer, generalizing 'PB.Analysis.TypeMismatch''s former @typeOfExpr@ with
-- call-target return-type lookup ('ExCall'\/'ExMethodCall'), literal
-- @CREATE@ typing ('ExCreate'\/'ExCreateUsing'), and multi-hop member-chain
-- resolution ('ExLvalue' with 2+ segments) — reusing
-- 'PB.Analysis.TypeResolve''s identity-resolution primitives
-- ('resolveVirtual'\/'resolveStaticCall') and
-- 'PB.Analysis.ControlHierarchy.resolveMemberChainType' rather than
-- re-deriving a second resolver. 'Nothing' means "cannot determine
-- statically" — never a guess, the same precedent
-- 'PB.Analysis.TypeResolve.extractDwControlBindings' already sets.
--
-- 'checkBody' is the single traversal that replaces the former
-- @walkBodyAssigns@\/@walkBodyReturns@ (and the never-landed
-- @findCallArgMismatches@): one walk over a procedure body producing all
-- three 'PB.Analysis.TypeMismatch.MismatchKind' findings, checking a call's
-- arguments wherever the call appears — not just at statement top level.
--
-- 'TypeCheckCtx' is built once per compile run from workspace-wide data
-- ('PB.Analysis.TypeResolve.buildProcMap'\/'buildInheritsMap'\/'buildParamsMap',
-- 'PB.Analysis.ControlHierarchy.buildControlIndex') — a call may target any
-- object in the workspace, so every one of those aggregates must already
-- cover the whole workspace before 'checkBody' runs on any single file.
-- Only 'tcScope' varies per procedure. Public API:
--
--   buildParamsMap :: [SrFile] -> Map (Text, Text) ProcSignature
--   inferExpr      :: TypeCheckCtx -> Expr -> Maybe TypeFamily
--   checkBody      :: TypeCheckCtx -> Text -> [Located BodyStmt] -> [TypeMismatchFinding]
module PB.Analysis.TypeCheck
  ( ProcSignature (..)
  , TypeCheckCtx (..)
  , buildParamsMap
  , inferExpr
  , checkBody
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import PB.AST.Type        (PbType (..), parseTypeText)
import PB.Analysis.ControlHierarchy (ControlIndex, resolveMemberChainType)
import PB.Analysis.TypeMismatch
import PB.Analysis.TypeResolve (resolveVirtual, resolveStaticCall, parseParams, srFileObject)
import PB.Grammar.Body   (parseExpr)
import PB.Lexing.Token   (Token)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Context

-- | A function\/subroutine's declared signature. 'psReturnType' is 'Nothing'
-- for a subroutine (genuinely no return type — not an unresolved lookup).
data ProcSignature = ProcSignature
  { psParams     :: [(Text, PbType)]
  , psReturnType :: Maybe PbType
  } deriving (Eq, Show)

-- | Everything 'inferExpr'\/'checkBody' need to resolve a call target or a
-- member chain, beyond the per-procedure 'tcScope'. Every field except
-- 'tcScope' and 'tcObject' is workspace-wide and shared across every
-- procedure in every file for one compile run.
data TypeCheckCtx = TypeCheckCtx
  { tcScope          :: Map.Map Text TypeFamily
  , tcProcMap        :: Map.Map Text (Set.Set Text)
  , tcInherits       :: Map.Map Text Text
  , tcParams         :: Map.Map (Text, Text) ProcSignature
  , tcObjects        :: Set.Set Text
  , tcUserTypes      :: Set.Set Text
  , tcObject         :: Text
  , tcControlIdx     :: ControlIndex
  , tcBuiltinFns     :: Set.Set Text
  , tcBuiltinMethods :: Set.Set Text
  }

-- | Build a @(object, procName) -> ProcSignature@ map from every function\/
-- subroutine declaration across the whole workspace — mirrors
-- 'PB.Analysis.TypeResolve.buildProcMap''s per-file fold shape, one level
-- richer (keeps the parsed signature, not just the name). Workspace-wide
-- because a call's target proc may live in any file, not just the caller's
-- own — the same reason 'buildProcMap'\/'buildInheritsMap' are already
-- built once across every parsed file before any per-file resolution runs.
buildParamsMap :: [SrFile] -> Map.Map (Text, Text) ProcSignature
buildParamsMap = foldl' addFile Map.empty
  where
    addFile acc sf =
      let obj = srFileObject sf
          fnEntries =
            [ ( (obj, fnsName (fbSig fb))
              , ProcSignature
                  (parseParams (fnsParams (fbSig fb)))
                  (Just (parseTypeText (fnsReturnType (fbSig fb))))
              )
            | fb <- srFunctions sf
            ]
          subEntries =
            [ ( (obj, ssName (sbSig sb))
              , ProcSignature (parseParams (ssParams (sbSig sb))) Nothing
              )
            | sb <- srSubroutines sf
            ]
      in foldl' (\m (k, v) -> Map.insert k v m) acc (fnEntries <> subEntries)

-- ---------------------------------------------------------------------------
-- Expression typing

segName :: LvSegment -> Text
segName (LvSegment n _) = n

-- | Classify a literal\/resolved class name into a 'TypeFamily'.
-- Case-insensitive: 'resolveMemberChainType' always returns a lowercased
-- class name (see 'PB.Analysis.ControlHierarchy''s module haddock), while
-- 'tcObjects'\/'tcUserTypes' and 'tcInherits' preserve the source's original
-- declared case throughout. Returning the *original*-cased spelling here
-- (not the lowercased query) keeps every 'FamObject'\/'FamUserType' payload
-- in the one casing convention 'compatible''s ancestor-chain walk assumes —
-- a lowercased payload would silently never match 'tcInherits'' keys.
classifyClassName :: TypeCheckCtx -> Text -> TypeFamily
classifyClassName ctx cls
  | Just orig <- findOriginalCase cls (tcObjects ctx)   = FamObject orig
  | Just orig <- findOriginalCase cls (tcUserTypes ctx) = FamUserType orig
  | otherwise                                           = FamAny

findOriginalCase :: Text -> Set.Set Text -> Maybe Text
findOriginalCase needle haystack = case matches of
  (o:_) -> Just o
  []    -> Nothing
  where matches = [ o | o <- Set.toList haystack, T.toLower o == T.toLower needle ]

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

-- | Resolve an 'ExCall'\/'ExMethodCall''s target as @(object, procName)@,
-- reusing 'PB.Analysis.TypeResolve''s identity-resolution primitives
-- directly on the 'Expr' node — no 'PB.Analysis.TypeResolve.CallSite'
-- wrapper needed, since there is no line number or wire format to carry
-- here. 'ExMethodCall' additionally roots the search at the receiver's own
-- *inferred* type rather than the caller's object — 'resolveVirtual' is
-- generic in its starting object, so this is the same primitive applied at
-- a different root, not a second resolver.
resolveCallTarget :: TypeCheckCtx -> Expr -> Maybe (Text, Text)
resolveCallTarget ctx ExCall { callee = lv } =
  let toName = T.intercalate "." (map segName (segments lv))
  in if "." `T.isInfixOf` toName
       then case resolveStaticCall toName (tcProcMap ctx) of
              (Just o, Just p, _, _) -> Just (o, p)
              _                      -> Nothing
       else if T.toLower toName `Set.member` tcBuiltinFns ctx
              then Nothing
              else case resolveVirtual toName (tcObject ctx) (tcProcMap ctx) (tcInherits ctx) of
                     (Just o, Just p, _, _) -> Just (o, p)
                     _                      -> Nothing
resolveCallTarget ctx ExMethodCall { receiver = recv, method = m } =
  if T.toLower m `Set.member` tcBuiltinMethods ctx
    then Nothing
    else case inferExpr ctx recv of
           Just (FamObject cls) ->
             case resolveVirtual m cls (tcProcMap ctx) (tcInherits ctx) of
               (Just o, Just p, _, _) -> Just (o, p)
               _                      -> Nothing
           _ -> Nothing
resolveCallTarget _ _ = Nothing

procReturnFamily :: TypeCheckCtx -> (Text, Text) -> Maybe TypeFamily
procReturnFamily ctx target = do
  sig   <- Map.lookup target (tcParams ctx)
  retTy <- psReturnType sig
  Just (classifyFamily retTy (tcObjects ctx) (tcUserTypes ctx))

-- | A partial, compositional expression typer. 'Nothing' means "cannot
-- determine statically" — never a guess. Supersedes
-- 'PB.Analysis.TypeMismatch''s former @typeOfExpr@: the literal\/single-var\/
-- binop\/not\/neg cases are that function's logic, recursing into
-- 'inferExpr' itself (not the old @typeOfExpr@) so a call nested inside a
-- binop or another call's argument types correctly too.
inferExpr :: TypeCheckCtx -> Expr -> Maybe TypeFamily
inferExpr _   (ExBool _) = Just FamBoolean
inferExpr _   (ExInt _)  = Just FamNumeric
inferExpr _   (ExReal _) = Just FamNumeric
inferExpr _   (ExStr _)  = Just FamString
inferExpr _   (ExDate _) = Just FamDateTime
inferExpr _   (ExTime _) = Just FamDateTime
inferExpr _   ExNull     = Nothing -- handled specially by callers, not a family
inferExpr ctx (ExLvalue (Lvalue [LvSegment n Nothing])) = Map.lookup n (tcScope ctx)
inferExpr ctx (ExLvalue (Lvalue segs@(_ : _ : _))) =
  classifyClassName ctx <$>
    resolveMemberChainType (tcControlIdx ctx) (tcInherits ctx) (tcObject ctx) (map segName segs)
inferExpr ctx (ExBinOp l op r) = do
  lf <- inferExpr ctx l
  rf <- inferExpr ctx r
  combineBinOp op lf rf
inferExpr ctx (ExNot e) = case inferExpr ctx e of
  Just FamBoolean -> Just FamBoolean
  _               -> Nothing
inferExpr ctx (ExNeg e) = case inferExpr ctx e of
  Just FamNumeric -> Just FamNumeric
  _               -> Nothing
inferExpr ctx (ExCreate cls) = Just (classifyClassName ctx cls)
inferExpr ctx (ExCreateUsing (ExStr cls)) = Just (classifyClassName ctx cls)
inferExpr _   (ExCreateUsing _) = Nothing
inferExpr ctx e@ExCall{}       = resolveCallTarget ctx e >>= procReturnFamily ctx
inferExpr ctx e@ExMethodCall{} = resolveCallTarget ctx e >>= procReturnFamily ctx
inferExpr _   _ = Nothing -- ExEnum/ExDispatch/ExArray/ExHostVar/ExRaw: no static type

-- ---------------------------------------------------------------------------
-- Body walk

-- | Every 'ExCall'\/'ExMethodCall' reachable inside an expression, including
-- nested inside another call's own (parsed) arguments or a method call's
-- receiver — Plan 177's call-argument checking is not limited to top-level
-- call statements, since a nested call still needs its own arguments
-- checked wherever it appears.
callExprsIn :: Expr -> [Expr]
callExprsIn e = case e of
  ExCall { callArgs = as }                       -> e : concatMap (callExprsIn . parseExpr) as
  ExMethodCall { receiver = r, methodArgs = as }  -> e : callExprsIn r <> concatMap (callExprsIn . parseExpr) as
  ExBinOp { lhs = l, rhs = r }                    -> callExprsIn l <> callExprsIn r
  ExNot inner                                     -> callExprsIn inner
  ExNeg inner                                     -> callExprsIn inner
  ExArray es                                      -> concatMap callExprsIn es
  ExCreateUsing inner                             -> callExprsIn inner
  _                                                -> []

rawArgs :: Expr -> [[Token]]
rawArgs ExCall { callArgs = as }        = as
rawArgs ExMethodCall { methodArgs = as } = as
rawArgs _                                = []

-- | Every 'CallArgMismatch' finding for calls reachable in one expression
-- position. Arguments are zipped positionally against the resolved target's
-- declared params — 'zip''s truncation to the shorter list means an arity
-- mismatch (too few or too many arguments) is silently ignored, not
-- flagged; this pass only ever compares positions both sides actually have.
callArgFindings :: TypeCheckCtx -> Text -> Int -> Expr -> [TypeMismatchFinding]
callArgFindings ctx procN line e = concatMap oneCall (callExprsIn e)
  where
    oneCall callExpr = case resolveCallTarget ctx callExpr >>= (`Map.lookup` tcParams ctx) of
      Nothing  -> []
      Just sig ->
        [ TypeMismatchFinding (tcObject ctx) procN line paramN (renderFamily paramFam) (rhsDesc argExpr) CallArgMismatch
        | ((paramN, paramTy), argToks) <- zip (psParams sig) (rawArgs callExpr)
        , let paramFam = classifyFamily paramTy (tcObjects ctx) (tcUserTypes ctx)
        , let argExpr  = parseExpr argToks
        , Just argFam <- [inferExpr ctx argExpr]
        , not (compatible (tcInherits ctx) paramFam argFam)
        ]

-- | A short rendering of an expression for a finding's diagnostic text.
-- Only the shapes 'inferExpr' can actually type ever reach a finding, so the
-- fallback case is unreachable in practice — kept total regardless, per
-- this project's no-partial-functions rule.
rhsDesc :: Expr -> Text
rhsDesc (ExStr s)  = "\"" <> s <> "\""
rhsDesc (ExInt s)  = s
rhsDesc (ExReal s) = s
rhsDesc (ExDate s) = s
rhsDesc (ExTime s) = s
rhsDesc (ExBool b) = if b then "true" else "false"
rhsDesc (ExLvalue lv) = T.intercalate "." [n | LvSegment n _ <- segments lv]
rhsDesc _ = "<expr>"

assignFinding :: TypeCheckCtx -> Text -> Int -> Text -> Expr -> [TypeMismatchFinding]
assignFinding ctx procN line varN rhs =
  [ TypeMismatchFinding (tcObject ctx) procN line varN (renderFamily lhsFam) (rhsDesc rhs) AssignMismatch
  | Just lhsFam <- [Map.lookup varN (tcScope ctx)]
  , Just rhsFam <- [inferExpr ctx rhs]
  , not (compatible (tcInherits ctx) lhsFam rhsFam)
  ]

returnFinding :: TypeCheckCtx -> Text -> Int -> Expr -> [TypeMismatchFinding]
returnFinding ctx procN line e =
  [ TypeMismatchFinding (tcObject ctx) procN line procN (renderFamily retFam) (rhsDesc e) ReturnMismatch
  | Just sig   <- [Map.lookup (tcObject ctx, procN) (tcParams ctx)]
  , Just retTy <- [psReturnType sig]
  , let retFam = classifyFamily retTy (tcObjects ctx) (tcUserTypes ctx)
  , Just eFam  <- [inferExpr ctx e]
  , not (compatible (tcInherits ctx) retFam eFam)
  ]

condCallArgs :: TypeCheckCtx -> Text -> Int -> Maybe DoCondition -> [TypeMismatchFinding]
condCallArgs _   _     _    Nothing            = []
condCallArgs ctx procN line (Just (DoWhile e)) = callArgFindings ctx procN line e
condCallArgs ctx procN line (Just (DoUntil e)) = callArgFindings ctx procN line e

-- | One statement's findings, recursing into nested bodies. Mirrors
-- 'PB.Analysis.TypeResolve.walkBodyCallSites''s statement-position coverage
-- (every expression slot that traversal already visits gets scanned for
-- 'CallArgMismatch' here too), plus the assign\/return-specific positions
-- 'checkBody' needs for the other two finding kinds.
checkStmt :: TypeCheckCtx -> Text -> Located BodyStmt -> [TypeMismatchFinding]
checkStmt ctx procN (Located line stmt) = case stmt of
  BsAssign (Lvalue [LvSegment n Nothing]) rhs ->
    assignFinding ctx procN line n rhs <> callArgFindings ctx procN line rhs
  BsAssign _ rhs -> callArgFindings ctx procN line rhs
  BsAssignExpr l rhs -> callArgFindings ctx procN line l <> callArgFindings ctx procN line rhs
  BsReturn (Just e) -> returnFinding ctx procN line e <> callArgFindings ctx procN line e
  BsReturn Nothing -> []
  BsCall e -> callArgFindings ctx procN line e
  BsLocalVar { varInit = Just e } -> callArgFindings ctx procN line e
  BsLocalVar { varInit = Nothing } -> []
  BsIf IfStmt { ifCond = cond, ifThen = t, ifElseIfs = eis, ifElse = e } ->
    callArgFindings ctx procN line cond
    <> checkBody ctx procN t
    <> concatMap (\ei -> callArgFindings ctx procN line (eifCond ei) <> checkBody ctx procN (eifBody ei)) eis
    <> maybe [] (checkBody ctx procN) e
  BsFor ForStmt { forFrom = fr, forTo = to_, forStep = step, forBody = b } ->
    callArgFindings ctx procN line fr
    <> callArgFindings ctx procN line to_
    <> maybe [] (callArgFindings ctx procN line) step
    <> checkBody ctx procN b
  BsDo DoStmt { doCond = pre, doBody = b, doLoop = post } ->
    condCallArgs ctx procN line pre
    <> checkBody ctx procN b
    <> condCallArgs ctx procN line post
  BsChoose ChooseStmt { chooseExpr = x, chooseClauses = cs } ->
    callArgFindings ctx procN line x
    <> concatMap (\cl -> checkBody ctx procN (ccBody cl)) cs
  _ -> []

-- | Every 'AssignMismatch'\/'ReturnMismatch'\/'CallArgMismatch' finding
-- reachable in one procedure body. @procN@ names the enclosing procedure
-- (attributed on every finding, and used to key 'tcParams' for this
-- procedure's own declared return type). Supersedes the former
-- @walkBodyAssigns@\/@walkBodyReturns@ (and the never-landed
-- @findCallArgMismatches@) with one traversal.
checkBody :: TypeCheckCtx -> Text -> [Located BodyStmt] -> [TypeMismatchFinding]
checkBody ctx procN = concatMap (checkStmt ctx procN)
