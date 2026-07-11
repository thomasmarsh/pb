-- | Plan 166 Stage 1 -- the schema-category Datalog program, split out of
-- 'PB.Pipeline.Souffle' so the engine adapter stays free of domain
-- knowledge. Holds 'reachesRules' and the @leg@\/@stmt@ EDB-view
-- projections that ruleset (and 'PB.Analysis.Rules.DeadCode.liveProcRules')
-- assume already exist over @schema_morphisms@\/@schema_objects@.
module PB.Analysis.Rules.Schema
  ( initEdbViews
  , reachesRules
  ) where

import PB.Prelude

import PB.Pipeline.Souffle (Relation (..), Literal (..), Rule (..), RuleSet (..))
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
-- ordering coupling entirely. @dead_code@ itself is unchanged and still
-- Haskell-computed: it carries confidence/cyclomatic/caller-count fields
-- ('PB.Analysis.DeadCode.DeadProcedure') with no Datalog equivalent, and is
-- still the sole source for the Dead Code Explorer API (@get_dead_code@).
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
      ]

-- ---------------------------------------------------------------------------
-- Concrete program

legRel, reachesRel :: Relation
legRel     = Relation "leg" ["x", "y", "leg_kind"]
reachesRel = Relation "reaches" ["x", "y"]

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
      [ Rule (Literal reachesRel ["x", "y"] False)
             [ Literal legRel ["x", "y", "_"] False ]
      , Rule (Literal reachesRel ["x", "z"] False)
             [ Literal reachesRel ["x", "y"] False
             , Literal legRel ["y", "z", "_"] False
             ]
      ]
  }
