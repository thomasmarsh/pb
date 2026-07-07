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
  ) where

import PB.Prelude hiding (id, (.), lookup)
import PB.Analysis.CatOp (Category (..), Cartesian (..), Cocartesian (..), Effectful (..), CatOp, foldCat)
import PB.Analysis.SchemaCategory (SchMorphism (..), SchObject (..), StmtId (..), LegKind (..), DwRetrieveColRow (..))
import PB.Analysis.TypeEnv (ScopedTypeEnv)
import PB.Analysis.TypeResolve (DwControlBinding (..))
import PB.AST.Expr (Expr (..))
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
      Just (tbl, col) -> Set.singleton (SchMorphism (StmtObj (fcStmtObj ctx)) (ColumnObj tbl col) LegWrites)
      Nothing         -> Set.empty
  splitValue = SchFootprint (const Set.empty)
  ret        = SchFootprint (const Set.empty)
  loopK (SchFootprint f) = SchFootprint f

-- | Run a compiled 'CatOp' term through the 'SchFootprint' functor.
foldSchFootprint :: FunctorCtx -> CatOp a b -> Set.Set SchMorphism
foldSchFootprint ctx op = runSchFootprint (foldCat op) ctx
