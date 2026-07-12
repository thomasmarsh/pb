-- | Plan 166 Stage 1 -- the schema-category Datalog program, split out of
-- 'PB.Pipeline.Souffle' so the engine adapter stays free of domain
-- knowledge. Holds 'reachesRules' and the @leg@\/@stmt@ EDB-view
-- projections that ruleset (and 'PB.Analysis.Rules.DeadCode.liveProcRules')
-- assume already exist over @schema_morphisms@\/@schema_objects@.
module PB.Analysis.Rules.Schema
  ( initEdbViews
  , reachesRules
  , cosliceRules
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), symRelation, Literal (..), Rule (..), RuleSet (..))
import PB.Pipeline.DuckDb (DuckConn)
import Database.DuckDB.Simple (Query (..), execute_)

-- ---------------------------------------------------------------------------
-- EDB views over existing DuckDB tables (no fact marshalling in DuckDB
-- itself -- 'PB.Pipeline.Souffle.queryTextRows' reads these directly)

-- | (Re)create the EDB views every 'RuleSet' below assumes already exist:
-- @leg@ over 'schema_morphisms', @stmt@ over the 'StmtObj' rows of
-- 'schema_objects'. Must run after 'PB.Pipeline.DuckDb.initSchema'.
--
-- No @dead@ view here (Plan 161 Phase 2b cutover, 2026-07-11): 'liveProcRules'
-- used to read a @dead@ view over the Haskell-computed @dead_code@ table;
-- once real-corpus parity between @proc_dead@ (Datalog, 'deadReachRules')
-- and @dead_code@ (Haskell BFS) was confirmed exact (104/104 rows, openpay
-- corpus), it was switched to read the @proc_dead@ table directly --
-- closing the half-Haskell/half-Datalog gap Phase 1 left. A passthrough
-- view here would have to be created eagerly (DuckDB validates a view's
-- referenced table at @CREATE VIEW@ time, not lazily at query time) even
-- in tests\/passes that only run 'reachesRules' and never touch dead-code
-- at all -- reading @proc_dead@ straight from 'liveProcRules' avoids that
-- ordering coupling entirely. @dead_code@ itself (Plan 166 Stage 6) is now
-- populated purely from Datalog's @dead_code_rows@ relation via
-- 'PB.Pipeline.DuckDb.materializeDeadCode' -- no Haskell classification
-- step remains -- and is still the sole source for the Dead Code Explorer
-- API (@get_dead_code@).
initEdbViews :: DuckConn -> IO ()
initEdbViews conn = for_ views (void . execute_ conn)
  where
    views :: [Query]
    views =
      [ "CREATE OR REPLACE VIEW leg AS \
        \SELECT from_key AS x, to_key AS y, leg_kind FROM schema_morphisms"
      , -- 'dw_retrieve'-kind schema_objects rows are deliberately excluded: their
        -- stmt_proc is always NULL (a DW retrieve isn't a procedure), which would
        -- make `dead(Object,Proc)` vacuously never match and every DW retrieve
        -- unconditionally "live" -- confirmed against the real openpay corpus
        -- (114/115 stmt rows were dw_retrieve noise before this restriction).
        "CREATE OR REPLACE VIEW stmt AS \
        \SELECT stmt_file AS file, stmt_object AS object, stmt_proc AS proc, stmt_line AS line \
        \FROM schema_objects WHERE kind = 'stmt'"
      , -- Plan 161 Phase 2c: the seed relation for cosliceRules — every column
        -- object (the coslice is computed per-column; stmt/dw_retrieve objects
        -- are reached as targets, never seeded). A faithful thin projection of
        -- schema_objects, no closure.
        "CREATE OR REPLACE VIEW seed AS \
        \SELECT object_key AS x FROM schema_objects WHERE kind = 'column'"
      ]

-- ---------------------------------------------------------------------------
-- Concrete program

legRel, reachesRel :: Relation
legRel     = symRelation "leg" ["x", "y", "leg_kind"]
reachesRel = symRelation "reaches" ["x", "y"]

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
      [ Rule (Literal reachesRel ["x", "y"] False Nothing)
             [ Literal legRel ["x", "y", "_"] False Nothing ]
      , Rule (Literal reachesRel ["x", "z"] False Nothing)
             [ Literal reachesRel ["x", "y"] False Nothing
             , Literal legRel ["y", "z", "_"] False Nothing
             ]
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
        Rule (Literal minDistRel ["s", "s", "0"] False Nothing)
               [ Literal seedRel ["s"] False Nothing ]
      , Rule (Literal minDistRel ["s", "n", "dprev + 1"] False Nothing)
               [ Literal minDistRel ["s", "p", "dprev"] False Nothing
               , Literal legRel ["p", "n", "_"] False Nothing
               , LitBare "n != s"
               ]

      -- Backward shortest distance: seed -> node (follows legs REVERSED:
      -- an in-edge TO p is FROM n, hence leg(n, p, _) not leg(p, n, _)).
      , Rule (Literal minDistBackRel ["s", "s", "0"] False Nothing)
               [ Literal seedRel ["s"] False Nothing ]
      , Rule (Literal minDistBackRel ["s", "n", "dprev + 1"] False Nothing)
               [ Literal minDistBackRel ["s", "p", "dprev"] False Nothing
               , Literal legRel ["n", "p", "_"] False Nothing
               , LitBare "n != s"
               ]

      -- Forward path legs: two unioned rules express the disjunction
      -- (LT = T ; reaches(LT, T)) -- the same unioned-rules pattern
      -- 'reachesRules' uses, avoiding any IR extension for disjunction.
      -- Rule 2 unifies LT with T via the shared variable name in head+body.
      -- @o + 1@ is inline in the min_dist body arg (verified: Souffle
      -- accepts inline arithmetic in body literal arguments).
      , Rule (Literal pathLegFwdRel ["s", "t", "o", "lf", "lt", "kind"] False Nothing)
               [ Literal minDistRel ["s", "lf", "o"] False Nothing
               , Literal legRel ["lf", "lt", "kind"] False Nothing
               , Literal minDistRel ["s", "lt", "o + 1"] False Nothing
               , Literal reachesRel ["lt", "t"] False Nothing
               ]
      , Rule (Literal pathLegFwdRel ["s", "t", "o", "lf", "t", "kind"] False Nothing)
               [ Literal minDistRel ["s", "lf", "o"] False Nothing
               , Literal legRel ["lf", "t", "kind"] False Nothing
               , Literal minDistRel ["s", "t", "o + 1"] False Nothing
               ]

      -- Backward path legs (legs oriented in real morphism direction; seed
      -- is the path's TO endpoint, so we look up min_dist_back at lt and lf).
      , Rule (Literal pathLegBackRel ["s", "t", "o", "lf", "lt", "kind"] False Nothing)
               [ Literal minDistBackRel ["s", "lt", "o"] False Nothing
               , Literal legRel ["lf", "lt", "kind"] False Nothing
               , Literal minDistBackRel ["s", "lf", "o + 1"] False Nothing
               , Literal reachesRel ["t", "lf"] False Nothing
               ]
      , Rule (Literal pathLegBackRel ["s", "t", "o", "t", "lt", "kind"] False Nothing)
               [ Literal minDistBackRel ["s", "lt", "o"] False Nothing
               , Literal legRel ["t", "lt", "kind"] False Nothing
               , Literal minDistBackRel ["s", "t", "o + 1"] False Nothing
               ]
      ]
  , rsChoiceDomains =
      [ ("min_dist", ["s", "node"])
      , ("min_dist_back", ["s", "node"])
      ]
  }
