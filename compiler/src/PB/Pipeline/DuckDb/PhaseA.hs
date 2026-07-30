module PB.Pipeline.DuckDb.PhaseA
  ( -- Row types
    ObjectRow (..)
  , TypeAncestorRow (..)
  , StructureRow (..)
  , ProcRow (..)
  , DwObjectRow (..)
  , DwControlRow (..)
  , DwRetrieveTableRow (..)
  , DwRetrieveColumnRow (..)
  , DwJoinRow (..)
  , DwRetrieveWhereRow (..)
  , DwArgumentRow (..)
  , SqlStmtRow (..)
  , SqlStmtColumnRow (..)
  , SqlStmtFilterRow (..)
  , SqlStmtTableRow (..)
  , SqlLintIssueRow (..)
  , CatalogColumnRow (..)
  , CatalogPkRow (..)
  , CatalogFkRow (..)
  , CatalogCheckRow (..)
  , SourceFileRow (..)
  , IdentifierTokenRow (..)
  , identifierTokenRows
  -- Phase A appenders
  , appendObjects
  , appendTypeAncestors
  , appendStructures
  , appendProcedures
  , appendDwObjects
  , appendDwControls
  , appendDwRetrieveTables
  , appendDwRetrieveColumns
  , appendDwJoins
  , appendDwRetrieveWhere
  , appendDwArguments
  , appendDeadVars
  , appendTypeMismatches
  , appendCallSites
  , appendVarRefs
  , appendGlobalVars
  , appendProcDefs
  , appendProcUses
  , appendSqlStmts
  , appendSqlLintIssues
  , appendSqlStmtColumns
  , appendSqlStmtFilters
  , appendSqlStmtTables
  , appendCatalogColumns
  , appendCatalogPks
  , appendCatalogFks
  , appendCatalogChecks
  , appendParseErrors
  , appendSourceFiles
  , flowsToDefRows
  , flowsToUseRows
  , appendIdentifierTokens
  , appendWindowOpens
  , appendObjectCreates
  , appendWindowMenuBindings
  , appendDwBindings
  ) where

import PB.Prelude
import PB.AST.Ident             (identOrig, identSpan, provenanceSpan)
import PB.AST.SourceFile        (ParseError (..))
import PB.AST.Type              (pbTypeSpan)
import PB.Grammar.Body          (isSegmentName)
import PB.Lexing.Token          (Token (..), SourceSpan (..))
import PB.Analysis.TypeResolve  (CallSite (..), GlobalVar (..), ResolvedVarRef (..),
                                  WindowOpenRef (..), ObjectCreateRef (..),
                                  WindowMenuBinding (..), DwControlBinding (..))
import PB.Analysis.Dataflow     qualified as Dataflow
import PB.Analysis.Taint        qualified as Taint
import PB.Analysis.DeadVars     (DeadVarFinding (..), deadVarKindText)
import PB.Analysis.TypeFamily   (TypeMismatchFinding (..), mismatchKindText)
import PB.Pipeline.DuckDb       (aText, aMaybeText, aInt, aMaybeInt, aMaybeSpan, aBool)
import PB.Pipeline.DuckDb.Appender (AppenderPool, appendRow, forEachRow)

import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Row types

data ObjectRow = ObjectRow
  { orFile           :: Text
  , orKind           :: Text
  , orObject         :: Text
  , orAncestor       :: Maybe Text
  , orLayoutJson     :: Maybe Text
  , orTypeBlocksJson :: Maybe Text
  , orConfidence     :: Text
  , orCategory       :: Text
  } deriving (Eq, Show)

-- | One row per nested (@within@-qualified) control 'TypeBlock' across the
-- whole workspace -- e.g. @type mdi_1 from mdiclient within w_main@ yields
-- @TypeAncestorRow "mdi_1" "mdiclient"@. Additive to @objects@'s own
-- @object@\/@ancestor@ columns (one row per *file*, so a nested control
-- declared @within@ another object never appears there): computed once from
-- 'PB.Analysis.TypeEnv.extractNestedTypeDecls' over every parsed file, not
-- accumulated per-'CompiledFile' the way most Phase A rows are, since it
-- doesn't depend on per-file compilation output. See the @type_ancestors@
-- table's doc comment in 'PB.Pipeline.DuckDb.initSchema'.
data TypeAncestorRow = TypeAncestorRow
  { tarChild  :: Text
  , tarParent :: Text
  } deriving (Eq, Show)

-- | One row per 'PB.AST.SourceFile.StructureBlock' -- see the @structures@
-- table's doc comment in 'PB.Pipeline.DuckDb.initSchema' for the
-- 'srOwner' nesting convention.
data StructureRow = StructureRow
  { srFile   :: Text
  , srObject :: Text
  , srOwner  :: Maybe Text
  } deriving (Eq, Show)

data ProcRow = ProcRow
  { prFile       :: Text
  , prObject     :: Text
  , prProcName   :: Text
  , prProcType   :: Text
  , prStartLine  :: Int
  , prEndLine    :: Int
  , prCfgJson    :: Text
  , prInstrJson    :: Text
  , prWiringJson :: Text
  , prParams     :: Text
  , prReturnType :: Text
  , prCyclomatic :: Maybe Int
  , prConfidence :: Text
  , prParamNames :: [Text]  -- ^ ordered declared parameter names, see 'procedures.param_names'
  , prOwner      :: Text    -- ^ owning control name for a control-owned event, else the
                             -- procedure's own object name; see 'procedures.owner'
  } deriving (Eq, Show)

data DwObjectRow = DwObjectRow
  { dorFile        :: Text
  , dorObject      :: Text
  , dorStyle       :: Text
  , dorLayoutJson  :: Text
  , dorRetrieveSql :: Maybe Text
  }

data DwControlRow = DwControlRow
  { dcrFile        :: Text
  , dcrObject      :: Text
  , dcrBand        :: Text
  , dcrControlType :: Text
  , dcrName        :: Text
  , dcrX           :: Maybe Int
  , dcrY           :: Maybe Int
  , dcrWidth       :: Maybe Int
  , dcrHeight      :: Maybe Int
  , dcrExpression  :: Maybe Text
  }

data DwRetrieveTableRow = DwRetrieveTableRow
  { drtrFile      :: Text
  , drtrObject    :: Text
  , drtrNamespace :: Maybe Text
  , drtrTableName :: Text
  }

data DwRetrieveColumnRow = DwRetrieveColumnRow
  { drcrFile       :: Text
  , drcrObject     :: Text
  , drcrNamespace  :: Maybe Text
  , drcrTableName  :: Text
  , drcrColumnName :: Text
  }

data DwJoinRow = DwJoinRow
  { djrFile     :: Text
  , djrObject   :: Text
  , djrLeftRef  :: Text
  , djrOp       :: Text
  , djrRightRef :: Text
  , djrOuter1   :: Maybe Text
  , djrOuter2   :: Maybe Text
  }

data DwRetrieveWhereRow = DwRetrieveWhereRow
  { drwrFile   :: Text
  , drwrObject :: Text
  , drwrIdx    :: Int
  , drwrExp1   :: Text
  , drwrOp     :: Text
  , drwrExp2   :: Text
  , drwrLogic  :: Maybe Text
  }

data DwArgumentRow = DwArgumentRow
  { darFile    :: Text
  , darObject  :: Text
  , darArgName :: Text
  , darArgType :: Text
  , darOrdinal :: Int
  }

data SqlStmtRow = SqlStmtRow
  { ssrFile      :: Text
  , ssrObject    :: Text
  , ssrProcName  :: Text
  , ssrLine      :: Int
  , ssrOperation :: Maybe Text
  , ssrTables    :: Text
  , ssrColumns   :: Text
  , ssrRawSql    :: Text
  , ssrParseOk   :: Bool
  , ssrError     :: Maybe Text
  }

data SqlStmtColumnRow = SqlStmtColumnRow
  { sscrFile       :: Text
  , sscrObject     :: Text
  , sscrProcName   :: Text
  , sscrLine       :: Int
  , sscrNamespace  :: Maybe Text
  , sscrTableName  :: Maybe Text
  , sscrColumnName :: Text
  , sscrIsWrite    :: Bool
  }

data SqlStmtFilterRow = SqlStmtFilterRow
  { ssfrFile       :: Text
  , ssfrObject     :: Text
  , ssfrProcName   :: Text
  , ssfrLine       :: Int
  , ssfrNamespace  :: Maybe Text
  , ssfrTableName  :: Maybe Text
  , ssfrColumnName :: Text
  , ssfrOp         :: Text
  , ssfrValuesJson :: Text
  }

-- | One row of sql_statement_tables (Plan 157 Phase 4.5): a namespace-aware
-- sibling of sql_statements.tables, one row per (statement, table) pair.
data SqlStmtTableRow = SqlStmtTableRow
  { sstrFile      :: Text
  , sstrObject    :: Text
  , sstrProcName  :: Text
  , sstrLine      :: Int
  , sstrOperation :: Maybe Text
  , sstrNamespace :: Maybe Text
  , sstrTableName :: Text
  }

-- | One row of sql_lint_issues, one per 'PB.Analysis.SqlLint.LintIssue'
-- found in a procedure.
data SqlLintIssueRow = SqlLintIssueRow
  { slirFile      :: Text
  , slirObject    :: Text
  , slirProcName  :: Text
  , slirLine      :: Int
  , slirIssueCode :: Text
  , slirSeverity  :: Text
  }

data CatalogColumnRow = CatalogColumnRow
  { cclrNamespace  :: Maybe Text
  , cclrTableName  :: Text
  , cclrColumnName :: Text
  , cclrOrdinal    :: Int
  }

data CatalogPkRow = CatalogPkRow
  { cpkrNamespace  :: Maybe Text
  , cpkrTableName  :: Text
  , cpkrColumnName :: Text
  , cpkrOrdinal    :: Int
  }

data CatalogFkRow = CatalogFkRow
  { cfkrConstraintName :: Maybe Text
  , cfkrFromNamespace  :: Maybe Text
  , cfkrFromTable      :: Text
  , cfkrFromColumn     :: Text
  , cfkrToNamespace    :: Maybe Text
  , cfkrToTable        :: Text
  , cfkrToColumn       :: Text
  , cfkrOrdinal        :: Int
  }

data CatalogCheckRow = CatalogCheckRow
  { cckrConstraintName :: Maybe Text
  , cckrNamespace      :: Maybe Text
  , cckrTableName      :: Text
  , cckrPredicate      :: Text
  }

data SourceFileRow = SourceFileRow
  { sfrFile :: Text
  , sfrLines :: Text
  }

-- | One lexed token whose kind is identifier-shaped ('isSegmentName'),
--   the raw denominator for Plan 201 Phase 5a's type-resolution coverage
--   metric.
data IdentifierTokenRow = IdentifierTokenRow
  { itrFile :: Text
  , itrText :: Text
  , itrKind :: Text
  , itrSpan :: SourceSpan
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Phase A appenders

appendObjects :: AppenderPool -> [ObjectRow] -> IO ()
appendObjects _    [] = pure ()
appendObjects pool rows = appendRow pool "objects" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (orFile           r)
    aText      app (orKind           r)
    aText      app (orObject         r)
    aMaybeText app (orAncestor       r)
    aMaybeText app (orLayoutJson     r)
    aMaybeText app (orTypeBlocksJson r)
    aText      app (orConfidence     r)
    aText      app (orCategory       r)

appendTypeAncestors :: AppenderPool -> [TypeAncestorRow] -> IO ()
appendTypeAncestors _    [] = pure ()
appendTypeAncestors pool rows = appendRow pool "type_ancestors" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (tarChild  r)
    aText app (tarParent r)

appendStructures :: AppenderPool -> [StructureRow] -> IO ()
appendStructures _    [] = pure ()
appendStructures pool rows = appendRow pool "structures" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (srFile   r)
    aText      app (srObject r)
    aMaybeText app (srOwner  r)

appendProcedures :: AppenderPool -> [ProcRow] -> IO ()
appendProcedures _    [] = pure ()
appendProcedures pool rows = appendRow pool "procedures" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText     app (prFile       r)
    aText     app (prObject     r)
    aText     app (prProcName   r)
    aText     app (prProcType   r)
    aInt      app (prStartLine  r)
    aInt      app (prEndLine    r)
    aText     app (prCfgJson    r)
    aText     app (prInstrJson    r)
    aText     app (prWiringJson r)
    aText     app (prParams     r)
    aText     app (prReturnType r)
    aMaybeInt app (prCyclomatic r)
    aText     app (prConfidence r)
    aText     app (T.intercalate "|" (prParamNames r))
    aText     app (prOwner      r)

appendDwObjects :: AppenderPool -> [DwObjectRow] -> IO ()
appendDwObjects _    [] = pure ()
appendDwObjects pool rows = appendRow pool "dw_objects" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText     app (dorFile        r)
    aText     app (dorObject      r)
    aText     app (dorStyle       r)
    aText     app (dorLayoutJson  r)
    aMaybeText app (dorRetrieveSql r)

appendDwControls :: AppenderPool -> [DwControlRow] -> IO ()
appendDwControls _    [] = pure ()
appendDwControls pool rows = appendRow pool "dw_controls" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (dcrFile r)
    aText      app (dcrObject r)
    aText      app (dcrBand r)
    aText      app (dcrControlType r)
    aText      app (dcrName r)
    aMaybeInt  app (dcrX r)
    aMaybeInt  app (dcrY r)
    aMaybeInt  app (dcrWidth r)
    aMaybeInt  app (dcrHeight r)
    aMaybeText app (dcrExpression r)

appendDwRetrieveTables :: AppenderPool -> [DwRetrieveTableRow] -> IO ()
appendDwRetrieveTables _    [] = pure ()
appendDwRetrieveTables pool rows = appendRow pool "dw_retrieve_tables" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (drtrFile r)
    aText app (drtrObject r)
    aMaybeText app (drtrNamespace r)
    aText app (drtrTableName r)

appendDwRetrieveColumns :: AppenderPool -> [DwRetrieveColumnRow] -> IO ()
appendDwRetrieveColumns _    [] = pure ()
appendDwRetrieveColumns pool rows = appendRow pool "dw_retrieve_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (drcrFile r)
    aText      app (drcrObject r)
    aMaybeText app (drcrNamespace r)
    aText      app (drcrTableName r)
    aText      app (drcrColumnName r)

-- | Plan 163 Phase 6: a DW's update-table columns (@DwColumn@'s @dcUpdate@),
-- computed via 'PB.Analysis.DwFootprint.dwRetrieveFootprint' at compile
-- time -- same row shape as 'appendDwRetrieveColumns', a separate table so
-- the leg_kind (LegWrites, not LegRetrieve) stays evident from which table
appendDwJoins :: AppenderPool -> [DwJoinRow] -> IO ()
appendDwJoins _    [] = pure ()
appendDwJoins pool rows = appendRow pool "dw_joins" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (djrFile r)
    aText      app (djrObject r)
    aText      app (djrLeftRef r)
    aText      app (djrOp r)
    aText      app (djrRightRef r)
    aMaybeText app (djrOuter1 r)
    aMaybeText app (djrOuter2 r)

appendDwRetrieveWhere :: AppenderPool -> [DwRetrieveWhereRow] -> IO ()
appendDwRetrieveWhere _    [] = pure ()
appendDwRetrieveWhere pool rows = appendRow pool "dw_retrieve_where" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (drwrFile r)
    aText      app (drwrObject r)
    aInt       app (drwrIdx r)
    aText      app (drwrExp1 r)
    aText      app (drwrOp r)
    aText      app (drwrExp2 r)
    aMaybeText app (drwrLogic r)

appendDwArguments :: AppenderPool -> [DwArgumentRow] -> IO ()
appendDwArguments _    [] = pure ()
appendDwArguments pool rows = appendRow pool "dw_arguments" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (darFile r)
    aText app (darObject r)
    aText app (darArgName r)
    aText app (darArgType r)
    aInt  app (darOrdinal r)

appendDeadVars :: AppenderPool -> [DeadVarFinding] -> IO ()
appendDeadVars _    [] = pure ()
appendDeadVars pool rows = appendRow pool "dead_vars" $ \app ->
  forEachRow app rows $ \_ f -> do
    aText     app (dvfObject f)
    aText     app (dvfProc f)
    aText     app (dvfVar f)
    aMaybeInt app (dvfLine f)
    aText     app (deadVarKindText (dvfKind f))

appendTypeMismatches :: AppenderPool -> [TypeMismatchFinding] -> IO ()
appendTypeMismatches _    [] = pure ()
appendTypeMismatches pool rows = appendRow pool "type_mismatches" $ \app ->
  forEachRow app rows $ \_ f -> do
    aText app (tmfObject f)
    aText app (tmfProc f)
    aInt  app (tmfLine f)
    aText app (tmfTarget f)
    aText app (tmfLhsType f)
    aText app (tmfRhsDesc f)
    aText app (mismatchKindText (tmfKind f))

appendCallSites :: AppenderPool -> [CallSite] -> IO ()
appendCallSites _    [] = pure ()
appendCallSites pool css = appendRow pool "call_sites" $ \app ->
  forEachRow app css $ \_ cs -> do
    aText     app (csFile cs)
    aText     app (csObject cs)
    aText     app (csFromProc cs)
    aText     app (csToName cs)
    aText     app (csCallType cs)
    aMaybeInt app (csLine cs)
    aMaybeText app (csReceiverObject cs)
    aMaybeSpan app (csToNameSpan cs)

appendVarRefs :: AppenderPool -> [ResolvedVarRef] -> IO ()
appendVarRefs _    [] = pure ()
appendVarRefs pool rvrs = appendRow pool "resolved_var_refs" $ \app ->
  forEachRow app rvrs $ \_ rvr -> do
    aText      app (rvrFile         rvr)
    aText      app (rvrObject       rvr)
    aText      app (rvrFromProc     rvr)
    aMaybeInt  app (rvrLine         rvr)
    aText      app (rvrName         rvr)
    aText      app (rvrAccess       rvr)
    aMaybeText app (rvrTargetObject rvr)
    aText      app (rvrKind         rvr)
    aText      app (rvrConfidence   rvr)
    aMaybeSpan app (rvrSpan         rvr)
    aMaybeText app (rvrDeclaredType rvr)

appendGlobalVars :: AppenderPool -> [GlobalVar] -> IO ()
appendGlobalVars _    [] = pure ()
appendGlobalVars pool gvs = appendRow pool "global_vars" $ \app ->
  forEachRow app gvs $ \_ gv -> do
    aText app (gvFile gv)
    aText app (gvObject gv)
    aText app (gvName gv)
    aText app (gvType gv)
    aText app (T.intercalate "|" (gvMods gv))
    aMaybeSpan app (pbTypeSpan (gvPbType gv))

-- | Convert a list of (file, object, proc_name, ProcFlow) tuples to
-- 'Taint.DefRow' list, extracting 'DefSite' entries from every block's
-- 'bfDefs'. Shared primitive used by both 'appendProcDefs' (DuckDB write)
-- and 'accumulatePhaseAData' (in-memory threading).
flowsToDefRows :: [(Text, Text, Text, Dataflow.ProcFlow)] -> [Taint.DefRow]
flowsToDefRows = concatMap $ \(file, obj, proc_, pf) ->
  [ Taint.DefRow
    { Taint.drFile     = file
    , Taint.drObject   = obj
    , Taint.drProcName = proc_
    , Taint.drVarName  = identOrig (Dataflow.dsVar d)
    , Taint.drBlockId  = Dataflow.dsBlock d
    , Taint.drStmtIdx  = Dataflow.dsStmtIdx d
    , Taint.drLine     = Dataflow.dsLine d
    , Taint.drKind     = Dataflow.dsKind d
    , Taint.drSpan     = provenanceSpan (identSpan (Dataflow.dsVar d))
    }
  | bf <- Map.elems (Dataflow.pfBlocks pf)
  , d  <- Dataflow.bfDefs bf
  ]

-- | Convert a list of (file, object, proc_name, ProcFlow) tuples to
-- 'Taint.UseRow' list, extracting 'UseSite' entries from every block's
-- 'bfUses'. Shared primitive used by both 'appendProcUses' (DuckDB write)
-- and 'accumulatePhaseAData' (in-memory threading).
flowsToUseRows :: [(Text, Text, Text, Dataflow.ProcFlow)] -> [Taint.UseRow]
flowsToUseRows = concatMap $ \(file, obj, proc_, pf) ->
  [ Taint.UseRow
    { Taint.urFile     = file
    , Taint.urObject   = obj
    , Taint.urProcName = proc_
    , Taint.urVarName  = identOrig (Dataflow.usVar u)
    , Taint.urBlockId  = Dataflow.usBlock u
    , Taint.urStmtIdx  = Dataflow.usStmtIdx u
    , Taint.urLine     = Dataflow.usLine u
    , Taint.urKind     = Dataflow.usKind u
    , Taint.urSpan     = provenanceSpan (identSpan (Dataflow.usVar u))
    }
  | bf <- Map.elems (Dataflow.pfBlocks pf)
  , u  <- Dataflow.bfUses bf
  ]

appendProcDefs :: AppenderPool -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
appendProcDefs _    [] = pure ()
appendProcDefs pool flows = appendRow pool "proc_defs" $ \app ->
  forEachRow app (flowsToDefRows flows) $ \_ d -> do
    aText     app (Taint.drFile d)
    aText     app (Taint.drObject d)
    aText     app (Taint.drProcName d)
    aText     app (Taint.drVarName d)
    aText     app (Taint.drBlockId d)
    aInt      app (Taint.drStmtIdx d)
    aMaybeInt app (Taint.drLine d)
    aText     app (Taint.drKind d)
    aMaybeSpan app (Taint.drSpan d)

appendProcUses :: AppenderPool -> [(Text, Text, Text, Dataflow.ProcFlow)] -> IO ()
appendProcUses _    [] = pure ()
appendProcUses pool flows = appendRow pool "proc_uses" $ \app ->
  forEachRow app (flowsToUseRows flows) $ \_ u -> do
    aText     app (Taint.urFile u)
    aText     app (Taint.urObject u)
    aText     app (Taint.urProcName u)
    aText     app (Taint.urVarName u)
    aText     app (Taint.urBlockId u)
    aInt      app (Taint.urStmtIdx u)
    aMaybeInt app (Taint.urLine u)
    aText     app (Taint.urKind u)
    aMaybeSpan app (Taint.urSpan u)

appendSqlStmts :: AppenderPool -> [SqlStmtRow] -> IO ()
appendSqlStmts _    [] = pure ()
appendSqlStmts pool rows = appendRow pool "sql_statements" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (ssrFile r)
    aText      app (ssrObject r)
    aText      app (ssrProcName r)
    aInt       app (ssrLine r)
    aMaybeText app (ssrOperation r)
    aText      app (ssrTables r)
    aText      app (ssrColumns r)
    aText      app (ssrRawSql r)
    aBool      app (ssrParseOk r)
    aMaybeText app (ssrError r)

appendSqlLintIssues :: AppenderPool -> [SqlLintIssueRow] -> IO ()
appendSqlLintIssues _    [] = pure ()
appendSqlLintIssues pool rows = appendRow pool "sql_lint_issues" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (slirFile r)
    aText app (slirObject r)
    aText app (slirProcName r)
    aInt  app (slirLine r)
    aText app (slirIssueCode r)
    aText app (slirSeverity r)

appendSqlStmtColumns :: AppenderPool -> [SqlStmtColumnRow] -> IO ()
appendSqlStmtColumns _    [] = pure ()
appendSqlStmtColumns pool rows = appendRow pool "sql_statement_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (sscrFile r)
    aText      app (sscrObject r)
    aText      app (sscrProcName r)
    aInt       app (sscrLine r)
    aMaybeText app (sscrNamespace r)
    aMaybeText app (sscrTableName r)
    aText      app (sscrColumnName r)
    aBool      app (sscrIsWrite r)

-- | Plan 163 Phase 3: same row shape/append pattern as
-- 'appendSqlStmtColumns' (reuses 'SqlStmtColumnRow' rather than a bespoke
-- type), writing to 'cat_footprint_columns' instead.
appendSqlStmtFilters :: AppenderPool -> [SqlStmtFilterRow] -> IO ()
appendSqlStmtFilters _    [] = pure ()
appendSqlStmtFilters pool rows = appendRow pool "sql_statement_filters" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (ssfrFile r)
    aText      app (ssfrObject r)
    aText      app (ssfrProcName r)
    aInt       app (ssfrLine r)
    aMaybeText app (ssfrNamespace r)
    aMaybeText app (ssfrTableName r)
    aText      app (ssfrColumnName r)
    aText      app (ssfrOp r)
    aText      app (ssfrValuesJson r)

appendSqlStmtTables :: AppenderPool -> [SqlStmtTableRow] -> IO ()
appendSqlStmtTables _    [] = pure ()
appendSqlStmtTables pool rows = appendRow pool "sql_statement_tables" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (sstrFile r)
    aText      app (sstrObject r)
    aText      app (sstrProcName r)
    aInt       app (sstrLine r)
    aMaybeText app (sstrOperation r)
    aMaybeText app (sstrNamespace r)
    aText      app (sstrTableName r)

appendCatalogColumns :: AppenderPool -> [CatalogColumnRow] -> IO ()
appendCatalogColumns _    [] = pure ()
appendCatalogColumns pool rows = appendRow pool "catalog_columns" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cclrNamespace  r)
    aText      app (cclrTableName  r)
    aText      app (cclrColumnName r)
    aInt       app (cclrOrdinal    r)

appendCatalogPks :: AppenderPool -> [CatalogPkRow] -> IO ()
appendCatalogPks _    [] = pure ()
appendCatalogPks pool rows = appendRow pool "catalog_pks" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cpkrNamespace  r)
    aText      app (cpkrTableName  r)
    aText      app (cpkrColumnName r)
    aInt       app (cpkrOrdinal    r)

appendCatalogFks :: AppenderPool -> [CatalogFkRow] -> IO ()
appendCatalogFks _    [] = pure ()
appendCatalogFks pool rows = appendRow pool "catalog_fks" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cfkrConstraintName r)
    aMaybeText app (cfkrFromNamespace  r)
    aText      app (cfkrFromTable      r)
    aText      app (cfkrFromColumn     r)
    aMaybeText app (cfkrToNamespace    r)
    aText      app (cfkrToTable        r)
    aText      app (cfkrToColumn       r)
    aInt       app (cfkrOrdinal        r)

appendCatalogChecks :: AppenderPool -> [CatalogCheckRow] -> IO ()
appendCatalogChecks _    [] = pure ()
appendCatalogChecks pool rows = appendRow pool "catalog_checks" $ \app ->
  forEachRow app rows $ \_ r -> do
    aMaybeText app (cckrConstraintName r)
    aMaybeText app (cckrNamespace      r)
    aText      app (cckrTableName      r)
    aText      app (cckrPredicate      r)

appendParseErrors :: AppenderPool -> [(FilePath, ParseError)] -> IO ()
appendParseErrors _    [] = pure ()
appendParseErrors pool errs = appendRow pool "parse_errors" $ \app ->
  forEachRow app errs $ \_ (path, pe) -> do
    aText app (T.pack path)
    aText app (peMessage pe)
    aMaybeInt app (peLine pe)

appendSourceFiles :: AppenderPool -> [SourceFileRow] -> IO ()
appendSourceFiles _    [] = pure ()
appendSourceFiles pool rows = appendRow pool "source_files" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (sfrFile r)
    aText app (sfrLines r)

-- | Filter a file's raw lexed token stream down to identifier-shaped rows
--   ('isSegmentName', "PB.Grammar.Body") -- the token-level denominator for
--   Plan 201 Phase 5a's coverage metric. A straight cast/filter over an
--   already-computed token list, no decision logic.
identifierTokenRows :: Text -> [Token] -> [IdentifierTokenRow]
identifierTokenRows file toks =
  [ IdentifierTokenRow file (tkText t) (T.pack (show (tkKind t))) (tkSpan t)
  | t <- toks, isSegmentName t
  ]

appendIdentifierTokens :: AppenderPool -> [IdentifierTokenRow] -> IO ()
appendIdentifierTokens _    [] = pure ()
appendIdentifierTokens pool rows = appendRow pool "identifier_tokens" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (itrFile r)
    aText app (itrText r)
    aText app (itrKind r)
    aInt  app (ssStartLine (itrSpan r))
    aInt  app (ssStartCol  (itrSpan r))
    aInt  app (ssEndLine   (itrSpan r))
    aInt  app (ssEndCol    (itrSpan r))

-- ---------------------------------------------------------------------------
-- "Uses" facts (Plan 210 Phase 4) -- straight appends of
-- 'PB.Analysis.TypeResolve''s already-resolved fact types, no separate Row
-- wrapper needed (mirrors 'appendCallSites'/'appendVarRefs' taking
-- 'CallSite'/'ResolvedVarRef' directly).

appendWindowOpens :: AppenderPool -> [WindowOpenRef] -> IO ()
appendWindowOpens _    [] = pure ()
appendWindowOpens pool rows = appendRow pool "window_opens" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (worFile r)
    aText app (worObject r)
    aText app (worFromProc r)
    aInt  app (worLine r)
    aText app (worTargetObject r)

appendObjectCreates :: AppenderPool -> [ObjectCreateRef] -> IO ()
appendObjectCreates _    [] = pure ()
appendObjectCreates pool rows = appendRow pool "object_creates" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (ocrFile r)
    aText app (ocrObject r)
    aText app (ocrFromProc r)
    aInt  app (ocrLine r)
    aText app (ocrTargetObject r)

appendWindowMenuBindings :: AppenderPool -> [WindowMenuBinding] -> IO ()
appendWindowMenuBindings _    [] = pure ()
appendWindowMenuBindings pool rows = appendRow pool "window_menu_bindings" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (wmbFile r)
    aText app (wmbObject r)
    aText app (wmbMenuName r)

appendDwBindings :: AppenderPool -> [DwControlBinding] -> IO ()
appendDwBindings _    [] = pure ()
appendDwBindings pool rows = appendRow pool "dw_bindings" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText app (dcbFile r)
    aText app (identOrig (dcbObject r))
    aText app (identOrig (dcbControlName r))
    aText app (identOrig (dcbDwName r))
