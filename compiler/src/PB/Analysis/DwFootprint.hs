-- | The DW-retrieve-to-'PB.Analysis.SchemaCategory.Sch' producer — the
-- "Fdw" half of the cospan, sibling to 'PB.Analysis.SchFootprint's "Fps"
-- functor. Unlike 'SchFootprint', which folds a compiled @EffTerm@, a DW
-- retrieve has no control flow to fold — this is a plain, total walk over
-- the already-parsed 'DwTable'\/'DwRetrieve' record straight into the same
-- @Set SchMorphism@ codomain.
--
-- Reproduces all four leg categories (column list, update-table, WHERE
-- predicate, joins) directly from the AST, deliberately overlapping with
-- 'PB.Analysis.SchemaCategory.buildSchema's existing row-based
-- @dwRetrieveLegs@\/@dwJoinLegs@ producers (fed via DB-persisted
-- @DwRetrieveColRow@\/@DwJoinLegRow@ rows). Each of the four leg
-- categories already tags its own 'LegSource' so a future wiring session
-- doesn't need to revisit this.
module PB.Analysis.DwFootprint
  ( DwFootprintCtx (..)
  , mkDwFootprintCtx
  , lvalueColumnRef
  , dwRetrieveFootprint
  ) where

import PB.Prelude
import PB.AST.DataWindow
  ( DwTable (..), DwColumn (..), DwRetrieve (..), DwRetrieveOrRaw (..)
  , DwWhereClause (..), DwJoin (..)
  )
import PB.AST.Expr (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Ident (Ident, identCanon)
import PB.Analysis.SchemaCategory
  ( SchMorphism (..), SchObject (..), StmtId (..), LegKind (..), LegSource (..)
  , CatColumnRow (..), splitColumnRef, resolveTableRef, catalogNamespacedTables
  )
import PB.Pipeline.SqlParse (TableRef (..))

import qualified Data.Set  as Set
import qualified Data.Text as T

-- | Context this producer closes over: the DDL catalog (for namespace
-- resolution, and, for WHERE-derived legs specifically, column-existence
-- gating -- see 'dwRetrieveFootprint's WHERE case) and the corpus's
-- configured default namespace.
data DwFootprintCtx = DwFootprintCtx
  { dfcCatalogTables    :: Set.Set (Text, Text)
    -- ^ (namespace, table) pairs the DDL catalog defines -- feeds
    -- 'resolveTableRef' exactly as
    -- 'PB.Analysis.SchemaCategory.buildSchema' already does.
  , dfcCatalogColumns   :: Set.Set (Maybe Text, Text, Text)
    -- ^ (namespace, table, column) triples the DDL catalog defines,
    -- lowercase-normalized. Only consulted by the WHERE-operand case: no
    -- other leg kind here is catalog-gated, matching
    -- 'PB.Analysis.SchemaCategory.buildSchema's existing column\/join
    -- producers, which never check catalog membership either.
  , dfcDefaultNamespace :: Maybe Text
  } deriving (Show, Eq)

-- | Build a 'DwFootprintCtx' from the same @catalog_columns@ rows
-- 'PB.Analysis.SchemaCategory.buildSchema' already consumes.
mkDwFootprintCtx :: [CatColumnRow] -> Maybe Text -> DwFootprintCtx
mkDwFootprintCtx catCols mDefaultNs = DwFootprintCtx
  { dfcCatalogTables  = catalogNamespacedTables catCols
  , dfcCatalogColumns = Set.fromList
      [ (fmap T.toLower (cclNamespace c), T.toLower (cclTable c), T.toLower (cclColumn c))
      | c <- catCols
      ]
  , dfcDefaultNamespace = mDefaultNs
  }

-- | Recognize a plain, unsubscripted dotted lvalue -- @table.column@ or
-- @namespace.table.column@ -- as a column reference. Anything else
-- (a subscript on any segment, 1 segment, 4+ segments, or any non-
-- 'ExLvalue' expression: host vars, literals, calls) is @Nothing@ -- no
-- guessing past what the lvalue shape itself confirms. Segment names are
-- lowercased (PB identifiers are case-insensitive), mirroring
-- 'PB.Analysis.SchemaCategory.splitColumnRef's own normalization.
lvalueColumnRef :: Expr -> Maybe (TableRef, Text)
lvalueColumnRef (ExLvalue (Lvalue segs))
  | all isPlainSegment segs = columnRefFromNames (map (identCanon . segName) segs)
lvalueColumnRef _ = Nothing

isPlainSegment :: LvSegment -> Bool
isPlainSegment (LvSegment _ Nothing) = True
isPlainSegment _                     = False

segName :: LvSegment -> Ident
segName (LvSegment n _) = n

columnRefFromNames :: [Text] -> Maybe (TableRef, Text)
columnRefFromNames names = case names of
  [tbl, col]     -> Just (TableRef Nothing tbl, col)
  [ns, tbl, col] -> Just (TableRef (Just ns) tbl, col)
  _              -> Nothing

-- | The DW-retrieve half of D1's cospan: walks a parsed 'DwTable' directly
-- into a @Set SchMorphism@, covering all four leg categories D1 names.
-- @file@\/@dwName@ identify the retrieve as a @DwRetrieveId@.
dwRetrieveFootprint :: DwFootprintCtx -> Text -> Text -> DwTable -> Set.Set SchMorphism
dwRetrieveFootprint ctx file dwName table =
  Set.unions [retrieveLegs, writeLegs, whereLegs, joinLegs]
  where
    stmtObj = StmtObj (DwRetrieveId file dwName)

    resolve :: TableRef -> TableRef
    resolve = resolveTableRef (dfcCatalogTables ctx) (dfcDefaultNamespace ctx)

    mRetrieve :: Maybe DwRetrieve
    mRetrieve = case dtRetrieve table of
      Just (DwRetrieveOk r) -> Just r
      _                     -> Nothing

    -- Column list -> LegRetrieve.
    retrieveLegs = Set.fromList
      [ SchMorphism stmtObj (ColumnObj (resolve tref) col) LegRetrieve SrcDwRetrieve
      | Just r <- [mRetrieve]
      , c <- drColumns r
      , Just (tref, col) <- [splitColumnRef c]
      ]

    -- Update-table columns (on Save) -> LegWrites. dcDbName is already a
    -- table-qualified ref (e.g. "misth_final.kodfinal"), same shape
    -- splitColumnRef already parses for drColumns -- no separate parse of
    -- dtUpdate's bare table name needed.
    writeLegs = Set.fromList
      [ SchMorphism stmtObj (ColumnObj (resolve tref) col) LegWrites SrcDwRetrieve
      | c <- dtColumns table
      , dcUpdate c
      , Just dbname <- [dcDbName c]
      , Just (tref, col) <- [splitColumnRef dbname]
      ]

    -- WHERE predicate Expr tree -> LegReads, gated on DDL catalog
    -- membership (no guessing past what the catalog confirms).
    whereLegs = Set.fromList
      [ SchMorphism (ColumnObj resolvedRef col) stmtObj LegReads SrcDwWhere
      | Just r <- [mRetrieve]
      , w <- drWhere r
      , me <- [dwcParsedExp1 w, dwcParsedExp2 w]
      , Just e <- [me]
      , Just (tref, col) <- [lvalueColumnRef e]
      , let resolvedRef@(TableRef ns tbl) = resolve tref
      , Set.member (ns, tbl, col) (dfcCatalogColumns ctx)
      ]

    -- Joins -> LegFk, SrcDwJoin.
    joinLegs = Set.fromList
      [ SchMorphism (ColumnObj (resolve lt) lc) (ColumnObj (resolve rt) rc) LegFk SrcDwJoin
      | Just r <- [mRetrieve]
      , j <- drJoins r
      , Just (lt, lc) <- [splitColumnRef (djLeft j)]
      , Just (rt, rc) <- [splitColumnRef (djRight j)]
      ]
