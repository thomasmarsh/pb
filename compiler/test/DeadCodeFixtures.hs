-- | Shared dead-code test fixtures, relocated from a deleted test module
-- that previously held them.
-- These build the same Phase A-shaped @procedures@\/@resolved_calls@\/
-- @objects@\/@dw_objects@ tables the production pipeline populates, so the
-- EDB-reshaping and materializer tests in "RulesTest" can exercise the
-- SQL-backed dead-code analysis against hand-verified expected sets.
module DeadCodeFixtures
  ( ProcInfo (..)
  , seedDeadCodeFixture
  , mkResolvedCall
  , phaseATables
  ) where

import PB.Prelude
import PB.Pipeline.DuckDb
  ( Handle, AppenderPool
  , appendProcedures, ProcRow (..)
  , appendDwObjects, DwObjectRow (..)
  , appendResolvedCalls
  , appendObjects, ObjectRow (..)
  )
import PB.Analysis.TypeResolve (ResolvedCall (..))
import PB.Analysis.Taint qualified as Taint

import qualified Data.Set as Set

-- | Terse fixture-builder shorthand for a procedure: 'seedDeadCodeFixture'
-- expands each one into a full 'ProcRow' with placeholder values for every
-- field these tests don't vary.
data ProcInfo = ProcInfo
  { piObject      :: Text
  , piName        :: Text
  , piProcType    :: Text   -- "function" | "subroutine" | "event" | "on"
  , piCyclomatic  :: Maybe Int
  } deriving (Eq, Show)

phaseATables :: [Text]
phaseATables =
  [ "objects", "procedures", "local_vars", "call_sites", "global_vars"
  , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
  , "sql_statement_filters", "sql_statement_tables", "cat_footprint_columns"
  , "source_files", "parse_errors"
  , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
  , "dw_write_columns", "dw_where_columns", "dw_joins", "dw_retrieve_where"
  , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
  ]

-- ---------------------------------------------------------------------------
-- Plan 161 Phase 2b fixtures: seed procedures/resolved_calls/dw_objects/
-- objects the way 'PB.Pipeline.Passes.runPass8' populates them in
-- production, from the same (procs, rawCalls, resolvedCalls, inherits,
-- dwObjects) shape the old Haskell BFS used to take before it was deleted
-- (Plan 161 Phase 2b cutover) -- so each fixture below exercises the
-- SQL-view EDB layer ('PB.Pipeline.DuckDb.Relations.initDeadCodeRelations')
-- against a hand-verified expected dead set (each one cross-checked against
-- the old Haskell BFS before it was deleted, and against the real openpay
-- corpus -- see BACKLOG's Phase 2b session entry).
--
-- Plan 166 Stage 2: inheritance is seeded via @objects.ancestor@ (read by
-- the faithful @inherits@ EDB view), not via the deleted
-- @procedure_overrides@ table. The @inherits@ (child, parent) tuples below
-- become @objects@ rows whose @ancestor@ is the parent.

seedDeadCodeFixture
  :: Handle
  -> AppenderPool
  -> [ProcInfo]
  -> [(Text, Text, Text)]           -- ^ raw calls (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)]     -- ^ resolved calls (object, from_proc, target_object, target_proc)
  -> [(Text, Text)]                 -- ^ inherits (child, parent)
  -> Set.Set Text                   -- ^ DW object names
  -> IO ()
seedDeadCodeFixture conn pool procs calls resolved inherits dwObjs = do
  appendProcedures pool
    [ ProcRow "f.srf" (piObject p) (piName p) (piProcType p)
              1 1 "" "" "" "" "" (piCyclomatic p) "confirmed"
    | p <- procs
    ]
  appendDwObjects pool
    [ DwObjectRow "f.srd" o "" "" Nothing | o <- Set.toList dwObjs ]
  appendResolvedCalls conn $
    [ ResolvedCall "f.srf" obj fromProc toName "call" (Just 1) Nothing Nothing "call" "high"
    | (obj, fromProc, toName) <- calls
    ]
    <> [ ResolvedCall "f.srf" obj fromProc (tgtObj <> "." <> tgtProc) "call" (Just 1)
           (Just tgtObj) (Just tgtProc) "call" "high"
       | (obj, fromProc, tgtObj, tgtProc) <- resolved
       ]
  -- Plan 166 Stage 2: seed inheritance as objects.ancestor rows; the
  -- faithful `inherits` EDB view (initDeadCodeRelations) reads these, and
  -- the `descendant`/`override_edge` IDB rules derive the closure.
  appendObjects pool
    [ ObjectRow "f.sru" "object" child (Just parent) Nothing Nothing "confirmed"
    | (child, parent) <- inherits
    ]

-- | A resolved_calls row builder for the 'EdbRelations' pure-function tests
-- below -- fields these functions never read (file, call_type, resolution
-- kind, confidence, return_type) get fixed placeholder values.
mkResolvedCall :: Text -> Text -> Text -> Maybe (Text, Text) -> Maybe Int -> Taint.ResolvedCallRow
mkResolvedCall obj fromProc toName mTarget mLine = Taint.ResolvedCallRow
  { Taint.rcrFile           = "f.srf"
  , Taint.rcrObject         = obj
  , Taint.rcrFromProc       = fromProc
  , Taint.rcrToName         = toName
  , Taint.rcrCallType       = "call"
  , Taint.rcrCallLine       = mLine
  , Taint.rcrTargetObject   = fst <$> mTarget
  , Taint.rcrTargetProc     = snd <$> mTarget
  , Taint.rcrResolutionKind = "call"
  , Taint.rcrConfidence     = "high"
  , Taint.rcrReturnType     = Nothing
  }
