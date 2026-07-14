-- | The database schema as a free category (@Sch@).
--
-- Objects are @(table, column)@ pairs and SQL-statement/DW-retrieve
-- instances; morphisms are the "legs" a statement has into the columns it
-- reads/writes, plus FK morphisms recovered from DataWindow @JOIN@ blocks
-- and DDL foreign keys.
module PB.Analysis.SchemaCategory
  ( -- Core category
    StmtId (..)
  , SchObject (..)
  , LegKind (..)
  , LegSource (..)
  , renderLegSource
  , SchMorphism (..)
  , SchGraph (..)
  , schObjectKey
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
    -- Namespace resolution (shared by buildSchema and any other write site
    -- that needs to resolve an unqualified TableRef, e.g. persistence-time
    -- resolution in PB.Pipeline.Runner)
  , catalogNamespacedTables
  , resolveTableRef
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

-- | Generating edges of the free category.
data LegKind
  = LegReads
  | LegWrites
  | LegRetrieve
  | LegFk
  deriving (Show, Eq, Ord)

-- | Which analysis technique produced a given leg — orthogonal to 'LegKind'
-- (the leg's direction/role) and to 'StmtId' (which front-end produced the
-- statement). Supersedes the old 'FkSource' type,
-- which covered only 'LegFk' rows ('FkDdl'/'FkDwJoin') via a second field;
-- every leg now carries provenance, not just FK ones.
data LegSource
  = SrcSqlText      -- ^ sqlglot text extraction of an embedded SQL statement.
  | SrcCatFootprint -- ^ 'PB.Analysis.SchFootprint's @EffTerm -> Sch@ functor (dynamic-dispatch writes, e.g. @SetItem@).
  | SrcDwRetrieve   -- ^ A DW retrieve's column list or update-table columns.
  | SrcDwJoin       -- ^ A DataWindow @JOIN@ block.
  | SrcDwWhere       -- ^ A DW retrieve's WHERE-clause predicate operand.
  | SrcDdlFk        -- ^ A DDL-declared foreign key.
  deriving (Show, Eq, Ord)

renderLegSource :: LegSource -> Text
renderLegSource SrcSqlText      = "sql_text"
renderLegSource SrcCatFootprint = "cat_footprint"
renderLegSource SrcDwRetrieve   = "dw_retrieve"
renderLegSource SrcDwJoin       = "dw_join"
renderLegSource SrcDwWhere      = "dw_where"
renderLegSource SrcDdlFk        = "ddl_fk"

data SchMorphism = SchMorphism
  { legFrom   :: SchObject
  , legTo     :: SchObject
  , legKind   :: LegKind
  , legSource :: LegSource
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
-- Identifiers are drawn raw from the PB extraction tables and may carry stray
-- control characters (notably newlines inside object/proc names). Such a
-- character would later break Soufflé fact-file parsing (one physical line is
-- one tuple; no escape syntax) and otherwise corrupt the @:@/@.@-delimited
-- key structure, so each segment is sanitized here at the source.
schObjectKey :: SchObject -> Text
schObjectKey (ColumnObj (TableRef ns tbl) col) =
  "col:" <> maybe "" (\n -> sanitizeIdent n <> ".") ns
            <> sanitizeIdent tbl <> "." <> sanitizeIdent col
schObjectKey (StmtObj (SqlStmtId f o p l)) =
  -- 'l' is an 'Int' line number, never user-controlled, so it is not cleaned.
  "stmt:sql:" <> sanitizeIdent f <> ":" <> sanitizeIdent o <> ":"
                <> sanitizeIdent p <> ":" <> T.pack (show l)
schObjectKey (StmtObj (DwRetrieveId f dw)) =
  "stmt:dw:" <> sanitizeIdent f <> ":" <> sanitizeIdent dw

-- | Collapse any character that would break a Soufflé fact field or the
-- @:@/@.@-delimited key grammar into a single space. A space (rather than
-- empty) keeps keys round-trip stable across the DuckDB -> Soufflé -> DuckDB
-- pipeline and avoids producing empty key segments.
sanitizeIdent :: Text -> Text
sanitizeIdent =
  T.replace "\t" " " . T.replace "\n" " " . T.replace "\r" " "

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
  { inDwRetrieveColumns   :: [DwRetrieveColRow]
  , inDwJoins             :: [DwJoinLegRow]
  , inDwWriteColumns      :: [DwRetrieveColRow]
    -- ^ A DW's update-table columns (@DwColumn@'s @dcUpdate@) -> 'LegWrites'.
    -- Same row shape as 'inDwRetrieveColumns' (each row is (file, dwName,
    -- namespace, table, column)) -- a write leg and a retrieve leg are both
    -- keyed to a single 'DwRetrieveId', no per-row "kind" needed since the
    -- two never share a table.
  , inDwWhereColumns      :: [DwRetrieveColRow]
    -- ^ A DW retrieve's WHERE-operand columns (gated on
    -- DDL catalog membership by the producer, same as
    -- 'PB.Analysis.DwFootprint.dwRetrieveFootprint's own @whereLegs@) ->
    -- 'LegReads'.
  , inSqlColumns          :: [SqlColRow]
  , inCatFootprintColumns :: [SqlColRow]
    -- ^ Same shape and resolution treatment as 'inSqlColumns', but sourced
    -- from 'PB.Analysis.SchFootprint's @EffTerm -> Sch@ functor (dynamic-
    -- dispatch writes, e.g. a DataWindow @SetItem@ call, invisible to
    -- sqlglot's text-based extraction) rather than parsed SQL text. Kept as
    -- a separate field, not merged into 'inSqlColumns', so each row's
    -- producing technique stays distinguishable — the @leg_source@ column
    -- tags rows by which physical ingestion table (and therefore which
    -- producer) they
    -- came from.
  , inCatalogColumns      :: [CatColumnRow]
  , inCatalogFks          :: [CatFkRow]
  , inDefaultNamespace    :: Maybe Text
    -- ^ The corpus's configured default schema (@--default-namespace@). An
    -- unqualified 'TableRef' in 'inSqlColumns'/'inCatFootprintColumns'/
    -- 'inDwRetrieveColumns'/'inDwJoins' resolves to this namespace only when
    -- the DDL catalog
    -- ('inCatalogColumns') actually defines the table under it — never
    -- guessed.
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
-- resolved nothing.
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
                     LegRetrieve SrcDwRetrieve
      | r <- inDwRetrieveColumns inputs
      ]

    -- DW update-table columns -> LegWrites, same shape as 'dwRetrieveLegs'
    -- but stmt -> column (a write), not column -> stmt.
    dwWriteLegs =
      [ SchMorphism (StmtObj (DwRetrieveId (drcFile r) (drcDwName r)))
                     (ColumnObj (resolve (TableRef (drcNamespace r) (drcTable r))) (drcColumn r))
                     LegWrites SrcDwRetrieve
      | r <- inDwWriteColumns inputs
      ]

    -- DW WHERE-operand columns -> LegReads (already catalog-gated by the
    -- producer, see 'PB.Analysis.DwFootprint').
    dwWhereLegs =
      [ SchMorphism (ColumnObj (resolve (TableRef (drcNamespace r) (drcTable r))) (drcColumn r))
                     (StmtObj (DwRetrieveId (drcFile r) (drcDwName r)))
                     LegReads SrcDwWhere
      | r <- inDwWhereColumns inputs
      ]

    -- Shared by 'sqlLegs' and 'catFootprintLegs': both are lists of
    -- 'SqlColRow' (a statement touching a resolved-or-unresolved column),
    -- differing only in which ingestion table/producer they came from —
    -- 'src' names that producer for the 'legSource' column (D3).
    mkSqlLegs :: LegSource -> [SqlColRow] -> [SchMorphism]
    mkSqlLegs src rows =
      [ SchMorphism from to kind src
      | r <- rows
      , Just tbl <- [scTable r]
      , let colObj  = ColumnObj (resolve (TableRef (scNamespace r) tbl)) (scColumn r)
            stmtObj = StmtObj (scStmt r)
            (from, to, kind)
              | scIsWrite r = (stmtObj, colObj, LegWrites)
              | otherwise   = (colObj, stmtObj, LegReads)
      ]

    sqlLegs = mkSqlLegs SrcSqlText (inSqlColumns inputs)

    catFootprintLegs = mkSqlLegs SrcCatFootprint (inCatFootprintColumns inputs)

    dwJoinLegs =
      [ SchMorphism (ColumnObj (resolve lt) lc) (ColumnObj (resolve rt) rc) LegFk SrcDwJoin
      | j <- inDwJoins inputs
      , Just (lt, lc) <- [splitColumnRef (djlLeftRef j)]
      , Just (rt, rc) <- [splitColumnRef (djlRightRef j)]
      ]

    ddlFkLegs =
      [ SchMorphism (ColumnObj (TableRef (cfrFromNamespace f) (cfrFromTable f)) (cfrFromColumn f))
                     (ColumnObj (TableRef (cfrToNamespace f) (cfrToTable f)) (cfrToColumn f))
                     LegFk SrcDdlFk
      | f <- inCatalogFks inputs
      ]

    allLegs = dwRetrieveLegs <> dwWriteLegs <> dwWhereLegs <> sqlLegs <> catFootprintLegs <> dwJoinLegs <> ddlFkLegs

    legObjects = Set.fromList (concatMap (\m -> [legFrom m, legTo m]) allLegs)

    catalogOnlyObjects = Set.fromList
      [ ColumnObj (TableRef (cclNamespace c) (cclTable c)) (cclColumn c)
      | c <- inCatalogColumns inputs
      ]

