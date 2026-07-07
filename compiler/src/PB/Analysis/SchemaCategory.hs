-- | Plan 148 Phase 1b: the database schema as a free category (@Sch@).
--
-- Objects are @(table, column)@ pairs and SQL-statement/DW-retrieve
-- instances; morphisms are the "legs" a statement has into the columns it
-- reads/writes, plus FK morphisms recovered from DataWindow @JOIN@ blocks
-- and DDL foreign keys. See doc/plan/148-db-schema-category.md for the
-- design rationale (span encoding of a hyperedge, free-category structure).
module PB.Analysis.SchemaCategory
  ( -- Core category
    StmtId (..)
  , SchObject (..)
  , FkSource (..)
  , LegKind (..)
  , SchMorphism (..)
  , SchGraph (..)
  , schObjectKey
    -- Free-category path structure
  , SchPath (..)
  , idPath
  , composePath
    -- Column-ref parsing
  , splitColumnRef
    -- Construction
  , DwRetrieveColRow (..)
  , DwJoinLegRow (..)
  , SqlColRow (..)
  , CatColumnRow (..)
  , CatFkRow (..)
  , SchemaInputs (..)
  , buildSchema
  ) where

import PB.Prelude
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Core category

-- | Identity of a SQL statement or DataWindow retrieve — the "apex" of a
-- span/hyperedge. Two constructors, not a concatenated blob, so callers
-- can pattern-match on provenance.
data StmtId
  = SqlStmtId    { siFile :: Text, siObject :: Text, siProc :: Text, siLine :: Int }
  | DwRetrieveId { siFile :: Text, siDwName :: Text }
  deriving (Show, Eq, Ord)

-- | Objects of @Sch@: a column, or a statement instance.
data SchObject
  = ColumnObj TableRef Text
  | StmtObj StmtId
  deriving (Show, Eq, Ord)

-- | Provenance of an FK-derived morphism — kept distinct so a leg's origin
-- (code evidence vs. static DDL) is never lost.
data FkSource = FkDdl | FkDwJoin
  deriving (Show, Eq, Ord)

-- | Generating edges of the free category.
data LegKind
  = LegReads
  | LegWrites
  | LegRetrieve
  | LegFk FkSource
  deriving (Show, Eq, Ord)

data SchMorphism = SchMorphism
  { legFrom :: SchObject
  , legTo   :: SchObject
  , legKind :: LegKind
  } deriving (Show, Eq, Ord)

-- | The materialized graph: objects, the generating edges, and adjacency
-- indexes for traversal (Phase 2 consumes 'sgOut'/'sgIn').
data SchGraph = SchGraph
  { sgObjects :: Set.Set SchObject
  , sgLegs    :: [SchMorphism]
  , sgOut     :: Map.Map SchObject [SchMorphism]
  , sgIn      :: Map.Map SchObject [SchMorphism]
  }

-- | Canonical string key for an object (DB storage: object_key/from_key/to_key).
schObjectKey :: SchObject -> Text
schObjectKey (ColumnObj (TableRef ns tbl) col) =
  "col:" <> maybe "" (<> ".") ns <> tbl <> "." <> col
schObjectKey (StmtObj (SqlStmtId f o p l)) =
  "stmt:sql:" <> f <> ":" <> o <> ":" <> p <> ":" <> T.pack (show l)
schObjectKey (StmtObj (DwRetrieveId f dw)) =
  "stmt:dw:" <> f <> ":" <> dw

-- ---------------------------------------------------------------------------
-- Free-category path structure (composable leg chains)

data SchPath = SchPath
  { spFrom :: SchObject
  , spTo   :: SchObject
  , spLegs :: [SchMorphism]
  } deriving (Show, Eq)

-- | The identity path at an object (the empty leg chain).
idPath :: SchObject -> SchPath
idPath o = SchPath o o []

-- | Path concatenation. Defined iff the first path's codomain is the
-- second's domain — @Nothing@ otherwise (no coercion, no guessing).
composePath :: SchPath -> SchPath -> Maybe SchPath
composePath p q
  | spTo p == spFrom q = Just (SchPath (spFrom p) (spTo q) (spLegs p <> spLegs q))
  | otherwise           = Nothing

-- ---------------------------------------------------------------------------
-- Column-ref parsing

-- | Split a qualified column reference on its *last* dot: the final
-- segment is the column, everything before is the (possibly
-- namespace-qualified) table ref. Lowercase-normalized. @Nothing@ for
-- unqualified text (no dot) or a malformed ref (empty column/table).
splitColumnRef :: Text -> Maybe (TableRef, Text)
splitColumnRef raw =
  case T.breakOnEnd "." (T.toLower raw) of
    (pre, col)
      | T.null pre || T.null col -> Nothing
      | otherwise ->
          let tablePart = T.dropEnd 1 pre
          in case T.breakOnEnd "." tablePart of
               (nsPre, tbl)
                 | T.null tbl   -> Nothing
                 | T.null nsPre -> Just (TableRef Nothing tbl, col)
                 | otherwise    -> Just (TableRef (Just (T.dropEnd 1 nsPre)) tbl, col)

-- ---------------------------------------------------------------------------
-- Construction: read-shapes consumed by buildSchema.
--
-- These mirror (but are distinct from) the DuckDB Phase A write-side row
-- types in PB.Pipeline.DuckDb — same split as TypeResolve.ResolvedCall
-- (write) vs. Taint.ResolvedCallRow (read) for resolved_calls.

-- | One row of dw_retrieve_columns: a DW retrieve's qualified column ref.
data DwRetrieveColRow = DwRetrieveColRow
  { drcFile      :: Text
  , drcDwName    :: Text
  , drcNamespace :: Maybe Text
  , drcTable     :: Text
  , drcColumn    :: Text
  } deriving (Show, Eq)

-- | One row of dw_joins, narrowed to the two qualified refs a JOIN relates
-- (op/outer1/outer2 don't matter for FK-morphism construction).
data DwJoinLegRow = DwJoinLegRow
  { djlFile     :: Text
  , djlDwName   :: Text
  , djlLeftRef  :: Text
  , djlRightRef :: Text
  } deriving (Show, Eq)

-- | One row of sql_statement_columns. 'scTable' is @Nothing@ for an
-- ambiguous unqualified column in an old-style implicit join with no
-- catalog to resolve it against — 'buildSchema' skips these rather than
-- guessing.
data SqlColRow = SqlColRow
  { scStmt      :: StmtId
  , scNamespace :: Maybe Text
  , scTable     :: Maybe Text
  , scColumn    :: Text
  , scIsWrite   :: Bool
  } deriving (Show, Eq)

-- | One row of catalog_columns: a column that exists per the static DDL,
-- regardless of whether any statement touches it.
data CatColumnRow = CatColumnRow
  { cclNamespace :: Maybe Text
  , cclTable     :: Text
  , cclColumn    :: Text
  } deriving (Show, Eq)

-- | One row of catalog_fks, already flattened to a single column pair
-- (composite FKs arrive as multiple rows sharing a constraint — see
-- 'PB.Pipeline.Runner.catalogToRows').
data CatFkRow = CatFkRow
  { cfrFromNamespace :: Maybe Text
  , cfrFromTable     :: Text
  , cfrFromColumn    :: Text
  , cfrToNamespace   :: Maybe Text
  , cfrToTable       :: Text
  , cfrToColumn      :: Text
  } deriving (Show, Eq)

data SchemaInputs = SchemaInputs
  { inDwRetrieveColumns :: [DwRetrieveColRow]
  , inDwJoins           :: [DwJoinLegRow]
  , inSqlColumns        :: [SqlColRow]
  , inCatalogColumns    :: [CatColumnRow]
  , inCatalogFks        :: [CatFkRow]
  } deriving (Show, Eq)

-- | Total, pure: builds the full 'SchGraph' from Phase A/DDL inputs.
-- Columns that only appear in the catalog (no statement or JOIN touches
-- them) still become objects with no legs — a free normalization signal
-- (dead-column candidates).
buildSchema :: SchemaInputs -> SchGraph
buildSchema inputs =
  SchGraph
    { sgObjects = Set.union legObjects catalogOnlyObjects
    , sgLegs    = allLegs
    , sgOut     = Map.fromListWith (<>) [ (legFrom m, [m]) | m <- allLegs ]
    , sgIn      = Map.fromListWith (<>) [ (legTo m,   [m]) | m <- allLegs ]
    }
  where
    dwRetrieveLegs =
      [ SchMorphism (StmtObj (DwRetrieveId (drcFile r) (drcDwName r)))
                     (ColumnObj (TableRef (drcNamespace r) (drcTable r)) (drcColumn r))
                     LegRetrieve
      | r <- inDwRetrieveColumns inputs
      ]

    sqlLegs =
      [ SchMorphism from to kind
      | r <- inSqlColumns inputs
      , Just tbl <- [scTable r]
      , let colObj  = ColumnObj (TableRef (scNamespace r) tbl) (scColumn r)
            stmtObj = StmtObj (scStmt r)
            (from, to, kind)
              | scIsWrite r = (stmtObj, colObj, LegWrites)
              | otherwise   = (colObj, stmtObj, LegReads)
      ]

    dwJoinLegs =
      [ SchMorphism (ColumnObj lt lc) (ColumnObj rt rc) (LegFk FkDwJoin)
      | j <- inDwJoins inputs
      , Just (lt, lc) <- [splitColumnRef (djlLeftRef j)]
      , Just (rt, rc) <- [splitColumnRef (djlRightRef j)]
      ]

    ddlFkLegs =
      [ SchMorphism (ColumnObj (TableRef (cfrFromNamespace f) (cfrFromTable f)) (cfrFromColumn f))
                     (ColumnObj (TableRef (cfrToNamespace f) (cfrToTable f)) (cfrToColumn f))
                     (LegFk FkDdl)
      | f <- inCatalogFks inputs
      ]

    allLegs = dwRetrieveLegs <> sqlLegs <> dwJoinLegs <> ddlFkLegs

    legObjects = Set.fromList (concatMap (\m -> [legFrom m, legTo m]) allLegs)

    catalogOnlyObjects = Set.fromList
      [ ColumnObj (TableRef (cclNamespace c) (cclTable c)) (cclColumn c)
      | c <- inCatalogColumns inputs
      ]
