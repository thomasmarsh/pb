-- | The schema-category Datalog program, split out of 'PB.Pipeline.Souffle'
-- so the engine adapter stays free of domain knowledge. Now holds only the
-- @leg@\/@stmt@ EDB-view projections ('initEdbViews') and the remaining
-- 'impliedFkRules'\/'riskRules' rule sets; the former 'legRules' /
-- 'reachesRules' / 'cosliceRules' (which derived @reaches@ \/ @path_leg_fwd@
-- \/ @path_leg_back@) were deleted in the Plan 182 schema-coslice cutover
-- (2026-07-18) — those three relations are now produced algebraically by
-- 'PB.Analysis.SchemaAlgebra.materializeSchemaClosure', per §12 item 7's
-- CORRECTION (no on-demand oracle retained). 'riskRules' reads the algebraic
-- @reaches@ as an ordinary external EDB table.
module PB.Analysis.Rules.Schema
  ( initEdbViews
  , impliedFkRules
  , riskRules
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

import PB.Pipeline.Souffle (Relation (..), symRelation, Rule (..), RuleSet (..))
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
-- marshalling in DuckDB itself -- 'PB.Pipeline.Souffle.queryTextRows' reads
-- these directly)

-- | (Re)materialize the EDB relations every 'RuleSet' below assumes already
-- exist: @leg_source@ over 'schema_morphisms', @stmt@\/@seed@ over
-- 'schema_objects'. Must run after 'PB.Pipeline.DuckDb.initSchema' AND after
-- 'schema_objects'\/'schema_morphisms' have been populated: the read here is
-- eager (a typed Haskell query materialized via 'recreateTextTable'\/
-- 'appendTextRows'), not a lazily-evaluated SQL view, so calling this before
-- 'PB.Pipeline.DuckDb.appendSchemaObjects'\/'appendSchemaMorphisms' populate
-- their source tables materializes empty relations.
--
-- No @dead@ relation is materialized here: 'liveProcRules' reads
-- @proc_dead@ (algebraic, 'PB.Analysis.DeadCodeAlgebra.materializeDeadCodeClosure')
-- directly. @dead_code@ is
-- populated purely from Datalog's @dead_code_rows@ relation via
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

reachesRel :: Relation
reachesRel = symRelation "reaches" ["x", "y"]

-- | Fan-in characterization for 'leg_source': total row count, distinct
-- (x, y) key count, and the largest number of rows sharing one key. A
-- single cheap DuckDB @GROUP BY@ pass, logged before 'SchemaAlgebra.materializeSchemaClosure' runs so a
-- corpus with pathological duplicate fan-in on one schema edge is visible
-- immediately rather than discovered only via a slow\/memory-hungry Souffle
-- run. A large 'lsfMaxGroupSize' is worth an operator's attention on its
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
-- Plan 161 Phase 3a: implied-FK discovery + composed risk scoring.

joinLegRel, fkRel, impliedFkRel :: Relation
joinLegRel   = symRelation "join_leg" ["x", "y"]
fkRel        = symRelation "fk" ["x", "y"]
impliedFkRel = symRelation "implied_fk_pairs" ["x", "y"]

-- | @implied_fk_pairs(X, Y) :- join_leg(X, Y), !fk(X, Y), !fk(Y, X).@
--
-- A DataWindow join edge with no matching declared foreign key in EITHER
-- direction -- a DW join's column order need not match the FK's declared
-- from\/to side, so both orientations of 'fk' are negated. 'fk' contains
-- only DDL-declared pairs, keyed identically to the 'SrcDdlFk' legs
-- 'PB.Analysis.SchemaCategory.buildSchema' derives from the same
-- 'catalog_fks' rows, so a real declared FK always negates out here; only a
-- join with no backing declaration survives.
--
-- Materializes to 'implied_fk_pairs', a raw two-column ColKey table --
-- deliberately NOT named @implied_fk@, so
-- 'PB.Pipeline.DuckDb.materializeImpliedFk''s structured, human-readable
-- @implied_fk@ consumer table (namespace\/table\/column pairs) is never
-- clobbered by the generic-arity @recreateTextTable@ every IDB relation
-- goes through -- the same raw-vs-consumer name separation 'SchemaAlgebra.materializeSchemaClosure'
-- keeps between @path_leg_fwd@\/@path_leg_back@ and @decomposition_coslice@.
impliedFkRules :: RuleSet
impliedFkRules = RuleSet
  { rsRelations = [impliedFkRel]
  , rsRules =
      [ Rule "implied_fk_pairs(x, y) :- join_leg(x, y), !fk(x, y), !fk(y, x)"
             [impliedFkRel, joinLegRel, fkRel]
      ]
  , rsChoiceDomains = []
  }

hasReachesRel, riskCountRel :: Relation
hasReachesRel = symRelation "has_reaches" ["x"]
riskCountRel  = Relation "risk_count" [("x", "symbol"), ("n", "number")]

-- | Migration blast-radius \/ risk scoring: counts each node's downstream
-- footprint by aggregating directly over the algebraic 'reaches' table (materialized by 'SchemaAlgebra.materializeSchemaClosure')
-- relation, via the same @count :@ idiom
-- 'PB.Analysis.Rules.DeadCode.callerCountRules' already uses for caller
-- fan-in (the @has_reaches@ seeding relation plays the same grounding role
-- that rule's @has_naive_caller@ does).
--
-- Deliberately NOT a second traversal unioning 'leg' with
-- 'impliedFkRules''s undeclared-join edges: every 'LegFk' edge -- DDL-declared
-- ('SrcDdlFk') or DW-join-derived ('SrcDwJoin') -- already renders as a
-- @kind = "fk"@ row in 'leg_source', hence in @leg@, regardless of which
-- 'PB.Analysis.SchemaCategory.LegSource' produced it (see 'legSourceRows'
-- above -- it drops provenance entirely). So the algebraic 'reaches' table's
-- @reaches@ already walks through every undeclared join edge 'implied_fk'
-- flags; re-deriving a parallel @risk_reach@ over the identical edge set
-- would be a second, wasted fixpoint computation of the same relation, not
-- a genuinely new traversal. 'implied_fk' stays a standalone
-- data-quality/schema-hygiene finding (Phase 4 can later join a hop's
-- @implied_fk@ membership into a risk-scored evidence path without this
-- ruleset needing to know about it).
riskRules :: RuleSet
riskRules = RuleSet
  { rsRelations = [hasReachesRel, riskCountRel]
  , rsRules =
      [ Rule "has_reaches(x) :- reaches(x, _)" [hasReachesRel, reachesRel]
      , Rule "risk_count(x, n) :- has_reaches(x), n = count : { reaches(x, _) }"
             [riskCountRel, hasReachesRel, reachesRel]
      ]
  , rsChoiceDomains = []
  }
