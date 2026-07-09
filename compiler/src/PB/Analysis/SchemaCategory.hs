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
    -- Namespace resolution (Plan 157 Phase 4.5: shared by buildSchema and
    -- any other write site that needs to resolve an unqualified TableRef,
    -- e.g. persistence-time resolution in PB.Pipeline.Runner)
  , catalogNamespacedTables
  , resolveTableRef
    -- Traversal (Plan 148 Phase 2)
  , blastRadius
  , validationWalkBack
  , ValidationConstraint (..)
  , constraintWriters
  , columnCoslice
  ) where

import PB.Prelude
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Map.Strict as Map
import qualified Data.Sequence   as Seq
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
  , inDefaultNamespace  :: Maybe Text
    -- ^ Plan 157 Phase 1: the corpus's configured default schema
    -- (@--default-namespace@). An unqualified 'TableRef' in
    -- 'inSqlColumns'/'inDwRetrieveColumns'/'inDwJoins' resolves to this
    -- namespace only when the DDL catalog ('inCatalogColumns') actually
    -- defines the table under it — never guessed.
  } deriving (Show, Eq)

-- | (namespace, table) pairs the DDL catalog actually defines, restricted
-- to Just-namespace rows — "is this table real under the default schema."
catalogNamespacedTables :: [CatColumnRow] -> Set.Set (Text, Text)
catalogNamespacedTables catCols = Set.fromList
  [ (ns, cclTable c) | c <- catCols, Just ns <- [cclNamespace c] ]

-- | Resolve a Nothing-namespace 'TableRef' against the configured default
-- namespace, iff the DDL catalog defines that table under it. Already-
-- qualified refs and refs with no matching catalog entry pass through
-- unchanged — never guessed. The default namespace is lowercased here, at
-- the point of comparison — matches the "namespaces are always lowercase"
-- invariant every DDL-derived 'TableRef' already follows (see
-- 'PB.Pipeline.SqlParse.TableRef' and @ddl.py@'s @_table_ident@).
-- @--default-namespace@ is a raw CLI value with no such normalization
-- applied anywhere upstream of here — a case mismatch (e.g.
-- @--default-namespace CLIMS@ against a catalog-derived @"clims"@) silently
-- resolved nothing, confirmed via a real multi-schema reindex (Plan 157
-- Phase 4/5 fixture).
resolveTableRef :: Set.Set (Text, Text) -> Maybe Text -> TableRef -> TableRef
resolveTableRef _ _ tr@(TableRef (Just _) _) = tr
resolveTableRef catTables mDefaultNs tr@(TableRef Nothing tbl) =
  case T.toLower <$> mDefaultNs of
    Just ns | Set.member (ns, tbl) catTables -> TableRef (Just ns) tbl
    _ -> tr

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
    catTables :: Set.Set (Text, Text)
    catTables = catalogNamespacedTables (inCatalogColumns inputs)

    resolve :: TableRef -> TableRef
    resolve = resolveTableRef catTables (inDefaultNamespace inputs)

    dwRetrieveLegs =
      [ SchMorphism (StmtObj (DwRetrieveId (drcFile r) (drcDwName r)))
                     (ColumnObj (resolve (TableRef (drcNamespace r) (drcTable r))) (drcColumn r))
                     LegRetrieve
      | r <- inDwRetrieveColumns inputs
      ]

    sqlLegs =
      [ SchMorphism from to kind
      | r <- inSqlColumns inputs
      , Just tbl <- [scTable r]
      , let colObj  = ColumnObj (resolve (TableRef (scNamespace r) tbl)) (scColumn r)
            stmtObj = StmtObj (scStmt r)
            (from, to, kind)
              | scIsWrite r = (stmtObj, colObj, LegWrites)
              | otherwise   = (colObj, stmtObj, LegReads)
      ]

    dwJoinLegs =
      [ SchMorphism (ColumnObj (resolve lt) lc) (ColumnObj (resolve rt) rc) (LegFk FkDwJoin)
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

-- ---------------------------------------------------------------------------
-- Traversal (Plan 148 Phase 2)

-- | Shared BFS path finder. Returns at most one entry per distinct
-- reachable object (including the identity path at the seed) — the
-- shortest (fewest-hop) path to it, via a graph-global visited set (an
-- object is marked visited the moment it is first discovered, at any
-- distance from the seed, and is never expanded again). Cycle-safe by
-- construction: the visited set guarantees each object is enqueued at
-- most once, so termination and O(V+E) work don't depend on the graph
-- being acyclic.
--
-- This intentionally does NOT enumerate every simple path to every object.
-- An earlier DFS-with-path-local-visited version did that, and on a DAG
-- with repeated diamond shapes (ordinary in a real FK/SQL-touch schema —
-- several tables joining back through a shared hub table) path count grows
-- multiplicatively per diamond layer even though the reachable-object count
-- stays linear: real corpus-scale schema graphs made this an exponential
-- blowup. No consumer (columnCoslice, constraintWriters) needs more than
-- one path per object — both already collapse to shortest-path-per-target.
walkPaths
  :: (SchGraph -> Map.Map SchObject [SchMorphism])  -- ^ adjacency map to follow
  -> (SchPath -> SchMorphism -> SchPath)             -- ^ extend a path with one leg
  -> (SchPath -> SchObject)                          -- ^ frontier object to look up next
  -> (SchMorphism -> SchObject)                      -- ^ the object a leg discovers
  -> SchGraph -> SchObject -> [SchPath]
walkPaths adj step frontier discovered g seed =
  reverse (go (Set.singleton seed) [idPath seed] (Seq.singleton (idPath seed)))
  where
    go visited acc queue = case Seq.viewl queue of
      Seq.EmptyL -> acc
      path Seq.:< queue' ->
        let legs = Map.findWithDefault [] (frontier path) (adj g)
            (visited', acc', extra) = foldl' consider (visited, acc, []) legs
            consider (vis, a, ex) leg =
              let obj = discovered leg
              in if Set.member obj vis
                 then (vis, a, ex)
                 else let p' = step path leg
                      in (Set.insert obj vis, p' : a, p' : ex)
        in go visited' acc' (queue' Seq.>< Seq.fromList (reverse extra))

-- | All paths reachable forward from the seed (sgOut). North-star Q1 ("if
-- this column mutates, what else is affected") — the coslice under a
-- ColumnObj/StmtObj. Every returned path's 'spFrom' is the seed.
blastRadius :: SchGraph -> SchObject -> [SchPath]
blastRadius = walkPaths sgOut extendForward spTo legTo
  where
    extendForward path leg = SchPath (spFrom path) (legTo leg) (spLegs path <> [leg])

-- | All paths that feed into the seed (sgIn), oriented in genuine morphism
-- direction (ancestor -> seed). North-star Q2 ("what can write to this
-- column") — the slice over a ColumnObj (the "validation walk-back").
-- Every returned path's 'spTo' is the seed.
validationWalkBack :: SchGraph -> SchObject -> [SchPath]
validationWalkBack = walkPaths sgIn extendBackward spFrom legFrom
  where
    extendBackward path leg = SchPath (legFrom leg) (spTo path) (leg : spLegs path)

-- | Hand-seeded validation constraint (Phase 2 does not infer constraints —
-- see doc/plan/148-db-schema-category.md's Non-goals). 'vcColumn' is
-- expected to be a 'ColumnObj'.
data ValidationConstraint = ValidationConstraint
  { vcColumn      :: SchObject
  , vcDescription :: Text
  } deriving (Show, Eq)

-- | Every StmtId (SQL statement or DW retrieve) that can write into the
-- constraint's column, directly or transitively via an FK chain — the
-- checklist of code sites to inspect for that constraint.
constraintWriters :: SchGraph -> ValidationConstraint -> [StmtId]
constraintWriters g c =
  Set.toList (Set.fromList
    [ sid | p <- validationWalkBack g (vcColumn c), StmtObj sid <- [spFrom p] ])

-- | The "rewrite cost" of moving a column (Plan 153 D5): every distinct
-- statement reachable either forward (this column is read, possibly via an
-- FK chain, by something downstream) or backward (this column is written or
-- retrieved into, possibly via an FK chain) — one path per distinct
-- statement, since a bare count would discard the explanation of *why* a
-- site is affected.
columnCoslice :: SchGraph -> SchObject -> [SchPath]
columnCoslice g seed =
  Map.elems (Map.fromListWith shorter
    [ (endpoint p, p)
    | p <- blastRadius g seed <> validationWalkBack g seed
    , StmtObj _ <- [endpoint p]
    ])
  where
    endpoint p
      | spFrom p == seed = spTo p
      | otherwise         = spFrom p
    shorter a b
      | length (spLegs a) <= length (spLegs b) = a
      | otherwise                              = b
