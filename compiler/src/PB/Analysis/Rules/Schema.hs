-- | Plan 166 Stage 1 -- the schema-category Datalog program, split out of
-- 'PB.Pipeline.Souffle' so the engine adapter stays free of domain
-- knowledge. Holds 'reachesRules' and the @leg@\/@stmt@ EDB-view
-- projections that ruleset (and 'PB.Analysis.Rules.DeadCode.liveProcRules')
-- assume already exist over @schema_morphisms@\/@schema_objects@.
module PB.Analysis.Rules.Schema
  ( initEdbViews
  , reachesRules
  , cosliceRules
  , legRules
  , LegSourceFanout (..)
  , legSourceFanout
  -- Plan 175 Phase 1: pure EDB-reshaping functions (exported for unit tests)
  , legSourceRows
  , stmtRows
  , seedRows
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb
  ( DuckConn, SchMorphismRow (..)
  , querySchemaObjects, querySchemaMorphismRows
  , recreateTextTable, appendTextRows
  )
import PB.Analysis.SchemaCategory (SchObject (..), StmtId (..), schObjectKey)
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
-- 'schema_objects'\/'schema_morphisms' have been populated (the read here is
-- eager, not a lazily-evaluated SQL view -- unlike the old @CREATE VIEW@
-- form, calling this before 'PB.Pipeline.DuckDb.appendSchemaObjects'\/
-- 'appendSchemaMorphisms' materializes empty relations).
--
-- __Plan 175 Phase 1 pilot exception__ -- not yet a Plan 170 rule-3
-- amendment; see doc/plan/175-haskell-edb-reshaping-layer.md. This is the
-- one @initXEdbViews@ in @PB.Analysis.Rules.*@ that materializes its EDB
-- relations via a typed Haskell read + 'recreateTextTable'\/'appendTextRows'
-- instead of @CREATE VIEW@ SQL -- 'PB.Analysis.Rules.DeadCode'\/'Taint'
-- still use SQL views, pending this pilot's real-corpus gate.
--
-- No @dead@ relation here (Plan 161 Phase 2b cutover, 2026-07-11): 'liveProcRules'
-- used to read a @dead@ view over the Haskell-computed @dead_code@ table;
-- once real-corpus parity between @proc_dead@ (Datalog, 'deadReachRules')
-- and @dead_code@ (Haskell BFS) was confirmed exact (104/104 rows, openpay
-- corpus), it was switched to read the @proc_dead@ table directly --
-- closing the half-Haskell/half-Datalog gap Phase 1 left. @dead_code@
-- itself (Plan 166 Stage 6) is now populated purely from Datalog's
-- @dead_code_rows@ relation via 'PB.Pipeline.DuckDb.materializeDeadCode' --
-- no Haskell classification step remains -- and is still the sole source
-- for the Dead Code Explorer API (@get_dead_code@).
initEdbViews :: DuckConn -> IO ()
initEdbViews conn = do
  morphisms <- querySchemaMorphismRows conn
  objects   <- querySchemaObjects conn
  materialize "leg_source" ["x", "y", "kind"]                  (legSourceRows morphisms)
  materialize "stmt"       ["file", "object", "proc", "line"]  (stmtRows objects)
  materialize "seed"       ["x"]                                (seedRows objects)
  where
    materialize name cols rows = do
      recreateTextTable conn name cols
      appendTextRows conn name rows

-- | Plan 175 Phase 1 pilot exception -- not yet a Plan 170 rule-3 amendment;
-- see doc/plan/175-haskell-edb-reshaping-layer.md. 'leg_source''s Haskell
-- replacement for the old @CREATE VIEW@: a pure rename of
-- ('smrFromKey', 'smrToKey', 'smrLegKind') to (x, y, kind).
-- 'smrLegSource' is unused here, mirroring the old view's own projection.
legSourceRows :: [SchMorphismRow] -> [[Text]]
legSourceRows = map (\r -> [smrFromKey r, smrToKey r, smrLegKind r])

-- | Plan 175 Phase 1 pilot exception. 'stmt''s Haskell replacement: filter
-- to 'SqlStmtId' rows only (kind = 'stmt') and rename to (file, object,
-- proc, line). 'DwRetrieveId' rows are deliberately excluded -- a DW
-- retrieve's stmt_proc is always NULL, which would make @dead(Object,Proc)@
-- vacuously never match and every DW retrieve unconditionally "live".
stmtRows :: [SchObject] -> [[Text]]
stmtRows objs = [ [f, o, p, T.pack (show l)] | StmtObj (SqlStmtId f o p l) <- objs ]

-- | Plan 175 Phase 1 pilot exception. 'seed''s Haskell replacement: filter
-- to 'ColumnObj' rows only (kind = 'column') and project to their
-- 'schObjectKey'.
seedRows :: [SchObject] -> [[Text]]
seedRows objs = [ [schObjectKey o] | o@(ColumnObj _ _) <- objs ]

-- ---------------------------------------------------------------------------
-- Concrete program

legRel, reachesRel :: Relation
legRel     = symRelation "leg" ["x", "y", "leg_kind"]
reachesRel = symRelation "reaches" ["x", "y"]

legSourceRel :: Relation
legSourceRel = symRelation "leg_source" ["x", "y", "kind"]

legRawRel :: Relation
legRawRel = Relation "leg_raw"
  [("x", "symbol"), ("y", "symbol"), ("kind", "symbol"), ("priority", "number")]

legP0Rel, legP0KeyRel, legP1Rel, legP1KeyRel, legP2Rel :: Relation
legP0Rel    = symRelation "leg_p0"     ["x", "y", "kind"]
legP0KeyRel = symRelation "leg_p0_key" ["x", "y"]
legP1Rel    = symRelation "leg_p1"     ["x", "y", "kind"]
legP1KeyRel = symRelation "leg_p1_key" ["x", "y"]
legP2Rel    = symRelation "leg_p2"     ["x", "y", "kind"]

-- | Plan 171a: the writes-vs-retrieve tie-break for @leg@, moved out of
-- 'initEdbViews' SQL (a ROW_NUMBER/CASE pair -- a house-rule violation, see
-- 'leg_source''s own comment above) into Datalog. 'leg_raw' tags each raw
-- @leg_source@ row with an explicit priority FACT via rule specialization
-- (three mutually exclusive rules on a literal @kind@ guard -- not a
-- positional SQL @CASE@): @writes@ -> 0, @retrieve@ -> 1, everything else
-- tied at 2 (matches the old CASE's precedence exactly; only (x, y) pairs
-- with >1 distinct kind ever compete -- real corpus: 559 pairs, all
-- writes-vs-retrieve).
--
-- Performance rewrite (found on a 1763-file\/300KLOC production corpus, not
-- the smaller openpay\/PowerBuilder-Example dev corpora 171a was gated
-- against): the original @leg@ rule computed the tie-break with an inline
-- correlated aggregate, @leg(x, y, kind) :- leg_raw(x, y, kind, p), p = min
-- p2 : { leg_raw(x, y, _, p2) }@. Verified directly against the real
-- @souffle@ 2.5 CLI on synthetic fixtures: Souffle re-evaluates that
-- aggregate once per MATCHING ROW of the first body literal, not once per
-- distinct (x, y) key, so its cost is O(group_size^2) per key -- 200,000
-- rows spread over 200,000 near-unique keys ran in 0.34s, but the exact
-- same row count concentrated into 200 keys (1,000 duplicate rows/key) took
-- 4.4s (13x), and concentrating further to 40 keys x 5,000 rows/key scaled
-- the instruction count by another ~4.9x -- textbook quadratic-in-group-size
-- blowup. 'leg_source' is deliberately undeduped by design (see its own
-- comment above), so this is purely a function of how much duplicate\/
-- near-duplicate fan-in a real corpus has on one (x, y) edge (e.g. a
-- widely-shared FK edge, or the same statement\/column touch found
-- independently by both @inSqlColumns@ and @inCatFootprintColumns@) --
-- absent from the small dev corpora, plausible at 12x+ scale. Materializing
-- the aggregate into its own relation before joining (the usual Souffle
-- "aggregate-then-join" fix) does NOT help -- verified empirically
-- identical instruction count, since Souffle still fires the aggregate once
-- per row, not once per key.
--
-- Fix: a priority cascade via stratified negation + per-tier
-- @choice-domain@ (the same negation mechanism
-- 'PB.Analysis.Rules.DeadCode.liveProcRules' already uses, not a new
-- technique) -- no aggregate at all. @leg_p0@\/@leg_p1@\/@leg_p2@ each pick
-- (via their own @choice-domain@) one tuple per key at their own priority
-- tier, gated by the NEGATED existence of any higher-priority tuple for
-- that key (@leg_p1_key@\/@leg_p2@'s @!leg_p0_key@\/@!leg_p1_key@ guards);
-- @leg@ unions the three tiers. An existence check is a plain indexed
-- semi-join, not a full-group rescan, so cost is linear in 'leg_raw' size
-- regardless of key fan-in. Verified byte-identical @leg@ output against
-- the old aggregate rule on a 5%-collision fixture and an adversarial
-- battery (writes\/retrieve collision, retrieve\/fk collision, a
-- same-priority tie between two distinct \"other\" kinds, a 0-hop self-loop,
-- a 3-way collision) -- and a ~220x instruction-count reduction on the
-- pathological 40x5,000 fixture above, with no regression on the
-- near-unique-key case (0.60s -> 0.32s).
legRules :: RuleSet
legRules = RuleSet
  { rsRelations = [legRawRel, legP0Rel, legP0KeyRel, legP1Rel, legP1KeyRel, legP2Rel, legRel]
  , rsRules =
      [ Rule "leg_raw(x, y, kind, 0) :- leg_source(x, y, kind), kind = \"writes\""
             [legRawRel, legSourceRel]
      , Rule "leg_raw(x, y, kind, 1) :- leg_source(x, y, kind), kind = \"retrieve\""
             [legRawRel, legSourceRel]
      , Rule "leg_raw(x, y, kind, 2) :- leg_source(x, y, kind), kind != \"writes\", kind != \"retrieve\""
             [legRawRel, legSourceRel]

      , Rule "leg_p0(x, y, kind) :- leg_raw(x, y, kind, 0)"
             [legP0Rel, legRawRel]
      , Rule "leg_p0_key(x, y) :- leg_p0(x, y, _)"
             [legP0KeyRel, legP0Rel]

      , Rule "leg_p1(x, y, kind) :- leg_raw(x, y, kind, 1), !leg_p0_key(x, y)"
             [legP1Rel, legRawRel, legP0KeyRel]
      , Rule "leg_p1_key(x, y) :- leg_p1(x, y, _)"
             [legP1KeyRel, legP1Rel]

      , Rule "leg_p2(x, y, kind) :- leg_raw(x, y, kind, 2), !leg_p0_key(x, y), !leg_p1_key(x, y)"
             [legP2Rel, legRawRel, legP0KeyRel, legP1KeyRel]

      , Rule "leg(x, y, kind) :- leg_p0(x, y, kind)" [legRel, legP0Rel]
      , Rule "leg(x, y, kind) :- leg_p1(x, y, kind)" [legRel, legP1Rel]
      , Rule "leg(x, y, kind) :- leg_p2(x, y, kind)" [legRel, legP2Rel]
      ]
  , rsChoiceDomains =
      [ ("leg_p0", ["x", "y"])
      , ("leg_p1", ["x", "y"])
      , ("leg_p2", ["x", "y"])
      , ("leg", ["x", "y"])
      ]
  }

-- | Fan-in characterization for 'leg_source': total row count, distinct
-- (x, y) key count, and the largest number of rows sharing one key. A
-- single cheap DuckDB @GROUP BY@ pass (milliseconds even at production
-- scale) -- logged before 'legRules' runs so a corpus with pathological
-- duplicate fan-in on one schema edge is visible immediately, rather than
-- discovered only via a slow\/memory-hungry Souffle run. Kept even after
-- the O(group_size^2) 'legRules' fix above: a large 'lsfMaxGroupSize' is
-- still worth an operator's attention on its own terms -- 'leg_source' has
-- only ~3 distinct @kind@ buckets, so hundreds/thousands of rows sharing
-- one exact (x, y) pair signals real duplication in the upstream extractors
-- (e.g. the same statement\/column touch double-counted by two independent
-- extraction techniques), not legitimate diversity.
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

-- | @reaches(X,Y) :- leg(X,Y,_).@
-- @reaches(X,Z) :- reaches(X,Y), leg(Y,Z,_).@
--
-- The Phase 0-validated port of 'PB.Analysis.SchemaCategory.blastRadius'/
-- 'validationWalkBack''s existence-only core: both functions' reachable-set
-- reprojects off this single relation (see Plan 161's Design section).
reachesRules :: RuleSet
reachesRules = RuleSet
  { rsRelations = [reachesRel]
  , rsRules =
      [ Rule "reaches(x, y) :- leg(x, y, _)" [reachesRel, legRel]
      , Rule "reaches(x, z) :- reaches(x, y), leg(y, z, _)" [reachesRel, legRel]
      ]
  , rsChoiceDomains = []
  }

-- ---------------------------------------------------------------------------
-- Plan 161 Phase 2c: coslice path-witness reconstruction.
--
-- 'columnCoslice' = blastRadius (forward walk) ∪ validationWalkBack
-- (backward walk), deduped to one shortest path per StmtObj target. The
-- existence-only core is 'reaches' above (already shipped). This program
-- reconstructs the leg-chain *witness* — the per-leg rows the
-- @decomposition_coslice@ table carries for the Python/UI blast-radius and
-- decomposition-candidate surfaces.
--
-- Encoding (verified against the real @souffle@ binary on a 15-diamond
-- stress fixture matching 'SchemaCategoryTest.hs''s exponential-blowup
-- regression case — see the plan's Step 1 spike notes):
--
--   * @min_dist@/@min_dist_back@ compute shortest forward/backward
--     distance via a native Souffle recursive fixpoint.
--   * @path_leg_fwd@/@path_leg_back@ emit every shortest leg on a path
--     from seed to target. The disjunction (leg ends at target, OR leg
--     ends at an intermediate that reaches target) is expressed as two
--     unioned rules — the same pattern 'reachesRules' uses, avoiding any
--     IR extension for disjunction.
--   * Through a diamond, multiple legs tie at one ordinal (bounded by
--     the diamond's width, NOT exponential in path count — verified 2x,
--     not 2^n). The deterministic single-witness tie-break is deferred to
--     SQL materialization ('materializeDecompositionCoslice'), which
--     picks one via ROW_NUMBER(). This keeps the IR free of
--     inequality/comparison operators (the Souffle aggregate witness
--     problem forbids exporting the min leg_from from inside an
--     aggregate body anyway).
--
-- All four path_leg relations are IDB outputs; 'seed' is the new EDB view
-- ('initEdbViews' above); 'leg' and 'reaches' are reused.

seedRel, minDistRel, minDistBackRel, pathLegFwdRel, pathLegBackRel :: Relation
seedRel        = symRelation "seed" ["x"]
minDistRel     = Relation "min_dist"     [("s", "symbol"), ("node", "symbol"), ("dist", "number")]
minDistBackRel = Relation "min_dist_back" [("s", "symbol"), ("node", "symbol"), ("dist", "number")]
pathLegFwdRel  = Relation "path_leg_fwd"  [("s","symbol"),("target","symbol"),("leg_ord","number"),("lf","symbol"),("lt","symbol"),("kind","symbol")]
pathLegBackRel = Relation "path_leg_back" [("s","symbol"),("target","symbol"),("leg_ord","number"),("lf","symbol"),("lt","symbol"),("kind","symbol")]

cosliceRules :: RuleSet
cosliceRules = RuleSet
  { rsRelations = [minDistRel, minDistBackRel, pathLegFwdRel, pathLegBackRel]
  , rsRules =
      -- reaches is consumed as EDB (not defined here): runRuleSets orders
      -- cosliceRules after reachesRules, which materializes the reaches
      -- table cosliceRules then reads as input. This keeps each ruleset
      -- single-purpose and matches the Plan 166 shared-predicate discipline
      -- (reaches is written once, reused by every consumer).

      [ -- Forward shortest distance: seed -> node (follows leg direction).
        -- @choice-domain (s, node)@ on minDistRel (see rsChoiceDomains below)
        -- is what makes this terminate on cyclic graphs: Souffle locks each
        -- (s, node) key to the FIRST distance derived for it and silently
        -- drops any later tuple sharing that key. Semi-naive evaluation only
        -- derives distance d+1 from already-established distance-d tuples,
        -- so distances are produced in non-decreasing order and the first
        -- (hence locked-in) value for any key is always the shortest. The
        -- @n != s@ guard alone is NOT sufficient: it only blocks the seed
        -- itself from being revisited, but a cycle among non-seed nodes
        -- (e.g. a<->b, neither equal to the seed) still makes min_dist
        -- derive ever-larger distances for a and b forever -- reproduced
        -- directly against the real souffle binary (2-node cycle not
        -- through the seed hangs without choice-domain; terminates with the
        -- correct minimum once it's added). @n != s@ is kept anyway (now
        -- redundant with choice-domain, but harmless) since it also blocks
        -- the seed's own distance-0 tuple from being overwritten before
        -- choice-domain would otherwise lock it in on iteration 0.
        -- Arithmetic @dprev + 1@ is inline in the head (Souffle accepts this).
        Rule "min_dist(s, s, 0) :- seed(s)" [minDistRel, seedRel]
      , Rule "min_dist(s, n, dprev + 1) :- min_dist(s, p, dprev), leg(p, n, _), n != s"
             [minDistRel, legRel]

      -- Backward shortest distance: seed -> node (follows legs REVERSED:
      -- an in-edge TO p is FROM n, hence leg(n, p, _) not leg(p, n, _)).
      , Rule "min_dist_back(s, s, 0) :- seed(s)" [minDistBackRel, seedRel]
      , Rule "min_dist_back(s, n, dprev + 1) :- min_dist_back(s, p, dprev), leg(n, p, _), n != s"
             [minDistBackRel, legRel]

      -- Forward path legs: two unioned rules express the disjunction
      -- (LT = T ; reaches(LT, T)) -- the same unioned-rules pattern
      -- 'reachesRules' uses, avoiding any IR extension for disjunction.
      -- Rule 2 unifies LT with T via the shared variable name in head+body.
      -- @o + 1@ is inline in the min_dist body arg (verified: Souffle
      -- accepts inline arithmetic in body literal arguments).
      --
      -- Rule 1's @reaches(lt, t)@ guard alone is NOT sufficient on a cyclic
      -- graph: 'reaches' is pure existence (no distance bound), so on a
      -- corpus with real graph cycles it admits legs from far outside t's
      -- own shortest-path envelope (confirmed against a real corpus: a
      -- target whose own min_dist is 2 picked up witness legs at ordinals
      -- up to 7, none of them lying on any actual shortest path to it).
      -- @min_dist(s, t, td), o + 1 < td@ bounds the intermediate hop to
      -- strictly within t's own distance -- rule 2 already supplies the
      -- final hop (ordinal td - 1) directly, so rule 1 only needs to cover
      -- ordinals before that.
      , Rule "path_leg_fwd(s, t, o, lf, lt, kind) :- min_dist(s, lf, o), leg(lf, lt, kind), min_dist(s, lt, o + 1), min_dist(s, t, td), o + 1 < td, reaches(lt, t)"
             [pathLegFwdRel, minDistRel, legRel, reachesRel]
      , Rule "path_leg_fwd(s, t, o, lf, t, kind) :- min_dist(s, lf, o), leg(lf, t, kind), min_dist(s, t, o + 1)"
             [pathLegFwdRel, minDistRel, legRel]

      -- Backward path legs (legs oriented in real morphism direction; seed
      -- is the path's TO endpoint, so we look up min_dist_back at lt and lf).
      -- Same min_dist_back-bounded guard as the forward rule above, same
      -- reason (a real cyclic graph otherwise admits legs from outside t's
      -- own shortest-path envelope).
      , Rule "path_leg_back(s, t, o, lf, lt, kind) :- min_dist_back(s, lt, o), leg(lf, lt, kind), min_dist_back(s, lf, o + 1), min_dist_back(s, t, td), o + 1 < td, reaches(t, lf)"
             [pathLegBackRel, minDistBackRel, legRel, reachesRel]
      , Rule "path_leg_back(s, t, o, t, lt, kind) :- min_dist_back(s, lt, o), leg(t, lt, kind), min_dist_back(s, t, o + 1)"
             [pathLegBackRel, minDistBackRel, legRel]
      ]
  , rsChoiceDomains =
      [ ("min_dist", ["s", "node"])
      , ("min_dist_back", ["s", "node"])
      ]
  }
