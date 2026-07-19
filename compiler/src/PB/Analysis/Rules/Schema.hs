-- | The schema-category EDB reshaping for Phase B link analysis. Holds the
-- @leg@\/@stmt@ EDB-view projections ('initEdbViews') and the
-- 'legSourceFanout' diagnostic. The implied-FK and risk relations
-- (@implied_fk_pairs@, @risk_count@) are materialized directly in DuckDB by
-- 'PB.Pipeline.DuckDb.materializeImpliedFkPairs' \/
-- 'PB.Pipeline.DuckDb.materializeRiskCount'; the @reaches@ \/ @path_leg_fwd@
-- \/ @path_leg_back@ relations are produced algebraically by
-- 'PB.Analysis.SchemaAlgebra.materializeSchemaClosure'.
module PB.Analysis.Rules.Schema
  ( initEdbViews
  , LegSourceFanout (..)
  , legSourceFanout
  -- pure EDB-reshaping functions (exported for unit tests)
  , legSourceRows
  , stmtRows
  , seedRows
  , joinLegRows
  , fkRows
  ) where

import PB.Prelude

import PB.Pipeline.DuckDb
  ( DuckConn, SchMorphismRow (..)
  , querySchemaObjects, querySchemaMorphismRows, queryCatFks
  , recreateTextTable, appendTextRows
  )
import PB.Analysis.SchemaCategory
  (SchObject (..), StmtId (..), CatFkRow (..), schObjectKey)
import PB.Pipeline.SqlParse (TableRef (..))
import Database.DuckDB.Simple (query_)
import Database.DuckDB.Simple.FromRow (FromRow (..), field)

import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- EDB relations materialized from existing DuckDB tables (no fact
-- marshalling in DuckDB itself -- 'queryTextRows' reads these directly)

-- | (Re)materialize the EDB relations every 'RuleSet' below assumes already
-- exist: @leg_source@ over 'schema_morphisms', @stmt@\/@seed@ over
-- 'schema_objects'. Must run after 'PB.Pipeline.DuckDb.initSchema' AND after
-- 'schema_objects'\/'schema_morphisms' have been populated: the read here is
-- eager (a typed Haskell query materialized via 'recreateTextTable'\/
-- 'appendTextRows'), not a lazily-evaluated SQL view, so calling this before
-- 'PB.Pipeline.DuckDb.appendSchemaObjects'\/'appendSchemaMorphisms' populate
-- their source tables materializes empty relations.
--
-- No @dead@ relation is materialized here: @proc_dead@ is computed
-- algebraically by 'PB.Analysis.DeadCodeAlgebra.materializeDeadCodeClosure'
-- and read directly. @dead_code@ is
-- populated from @dead_code_rows@ via
-- 'PB.Pipeline.DuckDb.materializeDeadCode' and is the sole source for the
-- Dead Code Explorer API (@get_dead_code@).
initEdbViews :: DuckConn -> IO ()
initEdbViews conn = do
  morphisms <- querySchemaMorphismRows conn
  objects   <- querySchemaObjects conn
  fks       <- queryCatFks conn
  materialize "leg_source" ["x", "y", "kind"]                  (legSourceRows morphisms)
  materialize "stmt"       ["file", "object", "proc", "line"]  (stmtRows objects)
  materialize "seed"       ["x"]                                (seedRows objects)
  materialize "join_leg"   ["x", "y"]                           (joinLegRows morphisms)
  materialize "fk"         ["x", "y"]                           (fkRows fks)
  where
    materialize name cols rows = do
      recreateTextTable conn name cols
      appendTextRows conn name rows

-- | Projects 'SchMorphismRow' into @leg_source@'s (x, y, kind) shape: a
-- pure rename of ('smrFromKey', 'smrToKey', 'smrLegKind'). 'smrLegSource'
-- is deliberately unused -- @leg_source@ carries no provenance column.
legSourceRows :: [SchMorphismRow] -> [[Text]]
legSourceRows = map (\r -> [smrFromKey r, smrToKey r, smrLegKind r])

-- | Projects 'SchObject' into @stmt@'s (file, object, proc, line) shape,
-- keeping only 'SqlStmtId' rows. 'DwRetrieveId' rows are excluded: a DW
-- retrieve's proc is always NULL, which would make @dead(Object,Proc)@
-- vacuously never match and every DW retrieve unconditionally "live".
stmtRows :: [SchObject] -> [[Text]]
stmtRows objs = [ [f, o, p, T.pack (show l)] | StmtObj (SqlStmtId f o p l) <- objs ]

-- | Projects 'SchObject' into @seed@'s single-column shape: keeps only
-- 'ColumnObj' rows, projected to their 'schObjectKey'.
seedRows :: [SchObject] -> [[Text]]
seedRows objs = [ [schObjectKey o] | o@(ColumnObj _ _) <- objs ]

-- | Projects 'SchMorphismRow' into @join_leg@'s (x, y) shape: DW-join-derived
-- edges only (@leg_source = "dw_join"@) -- the only 'PB.Analysis.
-- SchemaCategory.LegSource' that expresses a genuine two-table join
-- relationship distinct from a DDL-declared FK ('SrcDdlFk', already fully
-- captured by 'catalog_fks') or a statement's read\/write touch. Embedded
-- SQL @JOIN@s are not modeled as legs at all today (SQL-text legs are
-- single-table read\/write), so implied-FK discovery is scoped to
-- DataWindow joins only.
joinLegRows :: [SchMorphismRow] -> [[Text]]
joinLegRows rows = [ [smrFromKey r, smrToKey r] | r <- rows, smrLegSource r == "dw_join" ]

-- | Projects 'CatFkRow' into @fk@'s (x, y) shape, using the identical
-- 'schObjectKey' encoding 'PB.Analysis.SchemaCategory.buildSchema' applies
-- to the same 'catalog_fks' rows for its own 'SrcDdlFk' legs -- so a
-- declared FK's key here always matches the leg it produces there.
fkRows :: [CatFkRow] -> [[Text]]
fkRows = map $ \f ->
  [ schObjectKey (ColumnObj (TableRef (cfrFromNamespace f) (cfrFromTable f)) (cfrFromColumn f))
  , schObjectKey (ColumnObj (TableRef (cfrToNamespace f) (cfrToTable f)) (cfrToColumn f))
  ]

-- ---------------------------------------------------------------------------
-- Concrete program

-- | Fan-in characterization for 'leg_source': total row count, distinct
-- (x, y) key count, and the largest number of rows sharing one key. A
-- single cheap DuckDB @GROUP BY@ pass, logged before 'SchemaAlgebra.materializeSchemaClosure' runs so a
-- corpus with pathological duplicate fan-in on one schema edge is visible
-- immediately rather than discovered only via a slow\/memory-hungry
-- recomputation. A large 'lsfMaxGroupSize' is worth an operator's attention on its
-- own terms: 'leg_source' has only ~3 distinct @kind@ buckets, so
-- hundreds\/thousands of rows sharing one exact (x, y) pair signals real
-- duplication in the upstream extractors (e.g. the same statement\/column
-- touch double-counted by two independent extraction techniques), not
-- legitimate diversity.
data LegSourceFanout = LegSourceFanout
  { lsfTotalRows    :: !Int
  , lsfDistinctKeys :: !Int
  , lsfMaxGroupSize :: !Int
  } deriving (Eq, Show)

newtype FanoutRow = FanoutRow LegSourceFanout

instance FromRow FanoutRow where
  fromRow = (\t k m -> FanoutRow (LegSourceFanout t k m)) <$> field <*> field <*> field

legSourceFanout :: DuckConn -> IO LegSourceFanout
legSourceFanout conn = do
  rows <- query_ conn
    "WITH g AS (SELECT x, y, COUNT(*) AS cnt FROM leg_source GROUP BY x, y) \
    \SELECT (SELECT COUNT(*) FROM leg_source), COUNT(*), COALESCE(MAX(cnt), 0) FROM g"
  pure $ case rows of
    [FanoutRow f] -> f
    _             -> LegSourceFanout 0 0 0

-- ---------------------------------------------------------------------------
-- Implied-FK discovery + composed risk scoring.
--
-- 'PB.Pipeline.DuckDb.materializeImpliedFkPairs' \/ 'materializeRiskCount'
-- populate the raw IDB tables (@implied_fk_pairs@ \/ @risk_count@) the
-- downstream 'materializeImpliedFk' \/ 'materializeColumnRisk' consumers
-- read. The EDB inputs (@join_leg@, @fk@, algebraic @reaches@) are
-- materialized earlier in 'PB.Pipeline.Passes.materializeAllEdbViews'.
