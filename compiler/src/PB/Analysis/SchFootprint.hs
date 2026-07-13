-- | Plan 148 Phase 3: the functor @F : CatOp -> Sch_|_@, implemented as
-- another instance of 'PB.Analysis.CatOp's
-- 'Category'\/'Cartesian'\/'Cocartesian'\/'Effectful' classes rather than a
-- hand-written match over the GADT (see
-- doc\/plan\/148-db-schema-category.md's "(a) Categorical structure" design
-- amendment). 'PB.Analysis.CatOp.foldCat' folds any compiled 'CatOp' term
-- into this instance for free.
--
-- 'callProc' recognizes a DataWindow @SetItem@ call with a literal column
-- name and resolves it to a real 'SchMorphism' via 'fcControlBindings'
-- (the DW-control -> DW-object binding this module's infra-slice session
-- found missing) and 'fcDwColumns'. Deliberately uses 'callProc', not
-- 'suspend': @SetItem@ does not currently classify as a suspending call
-- ('PB.Analysis.CallClassify.dwMethods' omits it), and that is semantically
-- correct — unlike @Retrieve@\/@Open@\/@Close@, @SetItem@ is a synchronous,
-- in-process buffer mutation with no async round-trip, so 'suspend' (the
-- hook the interpreter and UI runtime use to mean "must await an external
-- response") is the wrong mechanism. @SetItem@ already compiles to
-- @CatCall (calleeName expr) parsedArgs@ today, so 'callProc' is the
-- correct, zero-risk hook — no change to 'PB.Analysis.CallClassify' needed.
-- Every other 'Effectful' method remains a constant empty footprint;
-- 'suspend' and the @ExHostVar@ case remain unimplemented (not needed —
-- the 'callProc' path below already reaches Phase 3's done-condition
-- against a real corpus example, see @doc\/plan\/148-db-schema-category.md@).
module PB.Analysis.SchFootprint
  ( FunctorCtx (..)
  , SchFootprint (..)
  , foldSchFootprint
  , controlBindingsMap
  , dwColumnsFromRows
  , runtimeDwAliasBindings
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.AST.BodyStmt (BodyStmt (..), IfStmt (..), ForStmt (..), DoStmt (..), ChooseStmt (..), ElseIf (..), CaseClause (..))
import PB.AST.Located (Located (..))
import PB.AST.Type (renderPbType)
import PB.Analysis.CallClassify (segName)
import PB.Analysis.CatOp (Category (..), Cartesian (..), Cocartesian (..), Effectful (..), CatOp (..))
import PB.Analysis.ControlHierarchy (ControlIndex, resolveMemberChainDwBinding)
import PB.Analysis.SchemaCategory (SchMorphism (..), SchObject (..), StmtId (..), LegKind (..), LegSource (..), DwRetrieveColRow (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv, lookupScopedVar)
import PB.Analysis.TypeResolve (DwControlBinding (..))
import PB.AST.Expr (Expr (..), Lvalue (..), LvSegment (..))
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.List       as L
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- | Context 'SchFootprint' closes over. 'CatOp' terms carry no source
-- line\/statement identity of their own, so any edge this functor derives
-- is necessarily anchored at procedure granularity ('fcStmtObj'), coarser
-- than Phase 1b's per-line 'StmtId's. 'fcDwColumns' (DW object name ->
-- its known @(table, column)@ targets, lowercase-normalized) and
-- 'fcControlBindings' (@(object, control)@ -> DW object name, all
-- lowercase-normalized) are built by callers via 'dwColumnsFromRows' and
-- 'controlBindingsMap' respectively — empty 'Map.Map's are legal, total
-- inputs.
data FunctorCtx = FunctorCtx
  { fcStmtObj         :: StmtId
  , fcTypeEnv         :: ScopedTypeEnv
  , fcDwColumns       :: Map.Map Text [(TableRef, Text)]
  , fcControlBindings :: Map.Map (Text, Text) Text
  }

-- | Build 'fcControlBindings' from 'PB.Analysis.TypeResolve.extractDwControlBindings'
-- output. All three key parts are lowercased (PB identifiers are
-- case-insensitive).
controlBindingsMap :: [DwControlBinding] -> Map.Map (Text, Text) Text
controlBindingsMap bindings = Map.fromList
  [ ((T.toLower (dcbObject b), T.toLower (dcbControlName b)), T.toLower (dcbDwName b))
  | b <- bindings
  ]

-- | Build 'fcDwColumns' from Phase 1b's existing @dw_retrieve_columns@ rows
-- (e.g. 'PB.Pipeline.DuckDb.queryDwRetrieveColumns'). DW-name key is
-- lowercased.
dwColumnsFromRows :: [DwRetrieveColRow] -> Map.Map Text [(TableRef, Text)]
dwColumnsFromRows rows = Map.fromListWith (<>)
  [ (T.toLower (drcDwName r), [(TableRef (drcNamespace r) (drcTable r), drcColumn r)])
  | r <- rows
  ]

-- | The object a compiled 'CatOp' term belongs to. 'CatOp' only ever
-- compiles from a PowerScript procedure body, so 'fcStmtObj' is always a
-- 'SqlStmtId' in practice — 'DwRetrieveId' has no such notion and is
-- handled totally rather than assumed unreachable.
stmtObject :: StmtId -> Maybe Text
stmtObject (SqlStmtId _ o _ _) = Just o
stmtObject (DwRetrieveId _ _)  = Nothing

-- | Recognize a @receiver.SetItem(row, "col", value)@ call and resolve it
-- to the @(table, column)@ it writes, via 'fcControlBindings' then
-- 'fcDwColumns'. @Nothing@ on any lookup miss (unbound control, dynamic
-- column argument, unknown column) — no guessing.
resolveSetItem :: FunctorCtx -> Text -> [Expr] -> Maybe (TableRef, Text)
resolveSetItem ctx name args = do
  ctrl <- T.stripSuffix ".setitem" (T.toLower name)
  obj  <- stmtObject (fcStmtObj ctx)
  col  <- case args of
            (_ : ExStr c : _) -> Just c
            _                 -> Nothing
  dwName <- Map.lookup (T.toLower obj, ctrl) (fcControlBindings ctx)
  cols   <- Map.lookup dwName (fcDwColumns ctx)
  case L.filter (\(_, c) -> T.toLower c == T.toLower col) cols of
    [(tbl, c)] -> Just (tbl, c)
    _          -> Nothing

-- | The constant-annotation category (Elliott's "compiling to categories"
-- static-analysis move): erase the object-language types @a@\/@b@ entirely
-- and just accumulate the set of 'SchMorphism's a term touches, as a
-- function of 'FunctorCtx'. 'id' is the empty footprint; composition,
-- '(&&&)', and '(|||)' are all pointwise union — the 'Category' laws hold
-- by construction since set union is an associative monoid with 'mempty'
-- as identity.
--
-- __Test-only semantic oracle since Plan 167 Phase 1 (2026-07-13).__ The
-- production path is 'foldSchFootprint' (a direct force-time-memoized
-- fold); this newtype, its four instances, and 'runSchFootprint' are kept
-- ONLY as the spec that direct fold implements — driven by the \"category
-- laws\" test group in SchFootprintTest. Do not add a new production
-- caller through the instance route: it memoizes the fold but not the
-- force (the bug Phase 1 fixed) and will re-force shared 'CatTagged'
-- subtrees O(N) times.
newtype SchFootprint a b = SchFootprint { runSchFootprint :: FunctorCtx -> Set.Set SchMorphism }

instance Category SchFootprint where
  id = SchFootprint (const Set.empty)
  SchFootprint f . SchFootprint g = SchFootprint (\ctx -> f ctx <> g ctx)

instance Cartesian SchFootprint where
  exl = SchFootprint (const Set.empty)
  exr = SchFootprint (const Set.empty)
  SchFootprint f &&& SchFootprint g = SchFootprint (\ctx -> f ctx <> g ctx)

instance Cocartesian SchFootprint where
  inl = SchFootprint (const Set.empty)
  inr = SchFootprint (const Set.empty)
  -- Static over-approximation: a fold has already forgotten which branch a
  -- real execution would take, so the footprint of a branch is the union of
  -- both arms' footprints, not a runtime choice between them.
  SchFootprint f ||| SchFootprint g = SchFootprint (\ctx -> f ctx <> g ctx)

-- | 'callProc' recognizes @SetItem@ with a literal column (see
-- 'resolveSetItem'); every other method remains a constant empty footprint
-- — 'suspend' and the @ExHostVar@ case are not needed this session (see
-- module header). 'loopK' still propagates the loop body's own footprint
-- (not a constant empty one) since a static, iteration-count-oblivious
-- analysis must count whatever the body touches regardless of how many
-- times it would actually run.
instance Effectful SchFootprint where
  eval _      = SchFootprint (const Set.empty)
  assign _    = SchFootprint (const Set.empty)
  lookup _    = SchFootprint (const Set.empty)
  suspend _ _ = SchFootprint (const Set.empty)
  callProc name args = SchFootprint $ \ctx ->
    case resolveSetItem ctx name args of
      Just (tbl, col) -> Set.singleton (SchMorphism (StmtObj (fcStmtObj ctx)) (ColumnObj tbl col) LegWrites SrcCatFootprint)
      Nothing         -> Set.empty
  splitValue = SchFootprint (const Set.empty)
  ret        = SchFootprint (const Set.empty)
  loopK (SchFootprint f) = SchFootprint f

-- | Run a compiled 'CatOp' term through the 'SchFootprint' functor.
--
-- Plan 167 Phase 1: a DIRECT, force-time-memoized fold, NOT the
-- @runSchFootprint (foldCat op) ctx@ route it used through 2026-07-13.
-- That route memoized the FOLD (closure construction, via foldCat's
-- 'CatTagged' cache) but not the FORCE (closure application):
-- 'SchFootprint' is a deferred @(FunctorCtx -> Set)@ constant functor,
-- so a 'CatTagged' subtree embedded at N positions was re-forced N times
-- — O(2^N) on reconvergent control flow (confirmed by scaling probe:
-- ~4x alloc per +2 switches). This fold caches the FORCED 'Set' per
-- blockId, so a shared subtree's footprint is computed once and reused
-- at every embedding — the force-time analogue of LowCat's
-- @bsBlockPcMemo@ ('PB.Analysis.GraphBuilder.compileLowCatToInstr'
-- 'LTagged' case). Simpler than that memo: @ctx@ is fixed for the whole
-- call, so the key is just @blockId@ (no continuation-pc dimension).
--
-- Soundness: 'SchFootprint' is a constant functor (phantom a\/b), so
-- folding directly is semantically equivalent to the instance route BY
-- CONSTRUCTION — the instance equations ARE this fold's spec (kept as a
-- test-only oracle via the \"category laws\" group in SchFootprintTest).
-- The cache holds monomorphic @Set SchMorphism@ (no unsafeCoerce\/Any,
-- unlike 'foldCat'\'s GADT-indexed cache). A @CatTagged bid f@ produces
-- exactly the Set folding @f@ would, so caching under @bid@ and returning
-- on repeat is the identity on the result. 'compileBlock' guarantees a
-- block never contains itself ('PB.Analysis.CatOp.foldCat' headnote), so
-- insert-after-recursion is cycle-safe.
foldSchFootprint :: FunctorCtx -> CatOp a b -> Set.Set SchMorphism
foldSchFootprint ctx op = fst (go op Map.empty)
  where
    -- Threads a blockId -> forced-Set cache through the term exactly as
    -- foldCat threads its (k x y, Map) cache (CatOp.hs:168-179): the
    -- cache flows sequentially through every binary constructor so a
    -- CatTagged discovered in one subterm is visible to its siblings.
    go :: CatOp x y -> Map.Map Text (Set.Set SchMorphism)
       -> (Set.Set SchMorphism, Map.Map Text (Set.Set SchMorphism))
    go CatId                    m = (Set.empty, m)
    go (CatCompose g f)         m = let (rg, m1) = go g m in let (rf, m2) = go f m1 in (rg <> rf, m2)
    go (CatFork l r)            m = let (rl, m1) = go l m in let (rr, m2) = go r m1 in (rl <> rr, m2)
    go CatExl                   m = (Set.empty, m)
    go CatExr                   m = (Set.empty, m)
    go (CatConst _)             m = (Set.empty, m)
    go CatInl                   m = (Set.empty, m)
    go CatInr                   m = (Set.empty, m)
    go CatReturn                m = (Set.empty, m)
    go (CatFanIn t f)           m = let (rt, m1) = go t m in let (rf, m2) = go f m1 in (rt <> rf, m2)
    go (CatAssign _)            m = (Set.empty, m)
    go (CatAssignWithRhs _ _)   m = (Set.empty, m)
    go (CatLookup _)            m = (Set.empty, m)
    go (CatLoop body)           m = go body m
    go (CatEval _)              m = (Set.empty, m)
    go (CatCall name args)      m = (callFootprint name args, m)
    go (CatSuspend _ _)         m = (Set.empty, m)
    go CatSplitValue            m = (Set.empty, m)
    go (CatTry body _handler)   m = go body m
    go (CatTagged bid f)        m = case Map.lookup bid m of
        Just cached -> (cached, m)
        Nothing     -> let (r, m') = go f m in (r, Map.insert bid r m')

    -- CatCall is the sole non-empty leaf: mirrors the 'callProc' instance
    -- (above) verbatim, so the exact-output oracle (SchFootprintTest.hs
    -- ~line 156) is preserved bit-for-bit.
    callFootprint :: Text -> [Expr] -> Set.Set SchMorphism
    callFootprint name args =
      case resolveSetItem ctx name args of
        Just (tbl, col) -> Set.singleton (SchMorphism (StmtObj (fcStmtObj ctx)) (ColumnObj tbl col) LegWrites SrcCatFootprint)
        Nothing         -> Set.empty

-- | Scan one procedure body for the runtime DataWindow-aliasing pattern
-- Plan 164 Phase C\/D3 exists to resolve -- e.g.
-- @idw_epidom = tab1.page1.uo_epidom.dw@ -- a @datawindow@\/@datastore@-typed
-- instance variable assigned from a multi-hop member-chain lvalue, rather
-- than bound via a literal @dataobject=@ declaration on the variable's own
-- control. Resolves each hit via
-- 'PB.Analysis.ControlHierarchy.resolveMemberChainDwBinding' and feeds the
-- same @(object, control) -> dwName@ map 'resolveSetItem' already reads, so
-- a later @SetItem@ call on the aliased variable resolves the same way a
-- directly-declared control binding would.
--
-- Only 'BsAssign' is scanned: 'PB.Grammar.Body.classifyBodyStmt' emits
-- 'BsAssignExpr' only when the LHS does NOT parse as a plain 'Lvalue' (e.g.
-- a method-call-chain LHS) -- a bare single-segment instance variable
-- always parses as a plain 'Lvalue', so 'BsAssignExpr' can never carry this
-- pattern's shape and does not need to be scanned.
--
-- Recurses into if\/for\/do\/choose bodies, mirroring
-- 'PB.Analysis.Taint.extractSqlStmts'. Any lookup miss (non-datawindow\/
-- datastore LHS, single-segment RHS, unresolvable chain) contributes
-- nothing to the result -- no guessing past what the resolver itself can
-- resolve.
runtimeDwAliasBindings
  :: ControlIndex -> Map.Map Text Text -> Text -> ScopedTypeEnv
  -> [Located BodyStmt] -> Map.Map (Text, Text) Text
runtimeDwAliasBindings idx inh obj env stmts = Map.fromList (concatMap go stmts)
  where
    go (Located _ (BsAssign lhs rhs)) = maybe [] pure (tryBind lhs rhs)
    go (Located _ (BsIf (IfStmt _ then_ eis mel))) =
      concatMap go then_
      <> concatMap (\ei -> concatMap go (eifBody ei)) eis
      <> maybe [] (concatMap go) mel
    go (Located _ (BsFor (ForStmt _ _ _ _ body))) = concatMap go body
    go (Located _ (BsDo (DoStmt _ body _)))       = concatMap go body
    go (Located _ (BsChoose (ChooseStmt _ clauses))) =
      concatMap (\c -> concatMap go (ccBody c)) clauses
    go _ = []

    tryBind lhs rhsExpr = case (segments lhs, rhsExpr) of
      ([LvSegment lhsName Nothing], ExLvalue rhsLv)
        | rhsSegs <- map segName (segments rhsLv)
        , length rhsSegs > 1
        , isDwTyped lhsName ->
            (\dwName -> ((T.toLower obj, T.toLower lhsName), T.toLower dwName))
              <$> resolveMemberChainDwBinding idx inh obj rhsSegs
      _ -> Nothing

    isDwTyped lhsName = case lookupScopedVar lhsName env of
      Just ty -> T.toLower (renderPbType ty) `elem` ["datawindow", "datastore"]
      Nothing -> False
