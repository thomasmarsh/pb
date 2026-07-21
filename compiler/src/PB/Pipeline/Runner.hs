{-# LANGUAGE StrictData #-}
module PB.Pipeline.Runner
  ( -- re-exports from Emit
    runFile
  , collectStatements
  , wrapSrFile
  , extractWindowLayout
  , reconstructRetrieveSql
    -- own
  , runModeDb
  , compileOne
  , appendToDb
  , catalogToRows
  , parseDdlArg
  , validateDdlNamespaceConfig
  , CompiledFile (..)
  , CompiledPs (..)
  , CompiledDw (..)
  ) where

import PB.Prelude
import PB.AST.BodyStmt   (BodyStmt (..))
import PB.AST.DataWindow
import PB.AST.Ident      (Ident, identCanon, identMapSize, identOrig)
import PB.AST.Located    (Located (..))
import PB.AST.SourceFile
import PB.AST.Type           (parseTypeText)
import PB.Grammar.File       (SrSpans (..))
import PB.Analysis.Cfg    (buildCfg, cyclomaticComplexity)
import PB.Compile.Flatten
  ( compileProcedureToEff
  , buildEffGraphNamed, buildEffGraphWiring )
import PB.Compile.InstrTypes (linearize)
import PB.Analysis.CallClassify (collectBodyLocals)
import PB.Analysis.ControlHierarchy (ControlIndex, buildControlIndex)

import PB.Analysis.TypeEnv     (WorkspaceEnv (..), ScopedTypeEnv (..), buildWorkspaceEnv, procEnv)
import PB.Analysis.Dataflow    qualified as Dataflow
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.SchemaCategory
  ( splitColumnRef, catalogNamespacedTables, resolveTableRef
  , CatColumnRow (..), DwRetrieveColRow (..)
  , StmtId (..), SchObject (..), SchMorphism (..), LegKind (..), LegSource (..)
  )
import PB.Analysis.TaintEdges (foldTaintEdgesEff, TaintIntraEdgeRow (..), TaintReturnRow (..))
import PB.Analysis.SchFootprint
  ( FunctorCtx (..), foldSchFootprintEff, controlBindingsMap, dwColumnsFromRows
  , runtimeDwAliasBindings
  )
import PB.Analysis.DwFootprint
  ( DwFootprintCtx, mkDwFootprintCtx, dwRetrieveFootprint )
import PB.Analysis.TypeResolve
  ( LocalVar (..), CallSite, GlobalVar (..)
  , extractCallSites, extractDwCallSites, extractGlobalVars, extractLocalVars
  , extractDwControlBindings
  , parseParams, paramsToVars
  )
import PB.Analysis.DeadVars (DeadVarFinding, findDeadVars)
import PB.Analysis.TypeCheck
  ( TypeCheckCtx (..), TypeCheckWorkspace (..)
  , buildTypeCheckWorkspace, checkBody
  )
import PB.Analysis.TypeFamily (TypeMismatchFinding)
import PB.Analysis.Builtins (builtinFnNames, builtinMethodNames)
import PB.Pipeline.Emit
  ( runFile, ParsedFile (..), ParseOutcome (..)
  , parseOutcome
  , extractWindowLayout, reconstructRetrieveSql, collectStatements
  , wrapSrFile
  )
import PB.Runtime.StdLib (parseStdlibFiles)
import PB.Pipeline.Passes    (runPhaseB)
import PB.Pipeline.Progress  qualified as Progress
import PB.Pipeline.Serialise ()
import PB.Pipeline.SqlParse
  ( SqlResult (..), ColumnRef (..), RowFilter (..), SqlBridgePool
  , TableRef (..), splitTableRef, CatalogTable (..), CatalogPrimaryKey (..), CatalogForeignKey (..)
  , CatalogCheckConstraint (..), SchemaCatalog (..), DdlStats (..), DdlResponse (..)
  , startSqlBridgePool, shutdownSqlBridgePool, sqlWorkerModuleArgs
  , parseSql, parseDdl, extractBsRawNodes
  )
import PB.Pipeline.FileWalk    (walkAllSrFiles)
import PB.Pipeline.DuckDb
  ( withHandle, Config(..), initSchema
  )
import PB.Pipeline.DuckDb.Appender (AppenderPool, withAppenderPoolTimed)
import PB.Pipeline.DuckDb.PhaseA
  ( ObjectRow (..), ProcRow (..), DwObjectRow (..), DwControlRow (..)
  , DwRetrieveTableRow (..), DwRetrieveColumnRow (..), DwJoinRow (..), SqlStmtRow (..)
  , SqlStmtColumnRow (..), SqlStmtFilterRow (..), SqlStmtTableRow (..)
  , CatalogColumnRow (..), CatalogPkRow (..), CatalogFkRow (..), CatalogCheckRow (..)
  , SourceFileRow (..)
  , appendObjects, appendProcedures
  , appendDwObjects, appendDwControls, appendDwRetrieveTables, appendDwRetrieveColumns
  , appendDwWriteColumns, appendDwWhereColumns, appendDwJoins
  , appendDwRetrieveWhere, DwRetrieveWhereRow (..)
  , appendLocalVars, appendDeadVars, appendTypeMismatches, appendCallSites, appendGlobalVars
  , appendProcDefs, appendProcUses, appendSqlStmts
  , appendSqlStmtColumns, appendSqlStmtFilters, appendSqlStmtTables
  , appendCatFootprintColumns
  , appendTaintIntraEdges
  , appendTaintReturnRows
  , appendCatalogColumns, appendCatalogPks, appendCatalogFks, appendCatalogChecks
  , appendParseErrors, appendSourceFiles
  )

import Data.Aeson          (ToJSON (..), Value (..), encode, object, toJSON, (.=))
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL
import Control.Concurrent.Async (mapConcurrently, mapConcurrently_)
import Control.Concurrent.MVar  (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  ( TQueue, atomically
  , newTQueueIO
  , writeTQueue, isEmptyTQueue, readTQueue
  )
import GHC.Conc   (getNumCapabilities)
import Control.DeepSeq     (force)
import Control.Exception   (finally, evaluate)
import System.Environment  (lookupEnv)
import System.IO           (hFlush, stderr)
import Data.IORef          (IORef, newIORef, readIORef, atomicModifyIORef')
import qualified Data.Set           as Set
import qualified Data.Text          as T
import qualified Data.Text.Encoding as TE
import System.FilePath     (takeBaseName, makeRelative)
import qualified Data.Map.Strict as Map

-- | Emit a single JSON progress event to stderr for the Python reporter,
-- stamped with 'Progress.elapsedSinceStartMs' -- shares its origin with
-- every 'PB.Pipeline.Progress.emitEvent' call in Phase B, so Phase A's
-- concurrent per-file workers (@mapConcurrently_@ over 'workerLoopFiles'
-- below) and Phase B's sequential analysis passes land on one consistent
-- timeline regardless of which one emitted a given event.
emitProgress :: Value -> IO ()
emitProgress v = do
  sinceStartMs <- Progress.elapsedSinceStartMs
  BS.hPut stderr (BSL.toStrict (encode (Progress.stampValue sinceStartMs v)) <> "\n")
  hFlush stderr

-- ---------------------------------------------------------------------------
-- DuckDB streaming mode
--
-- runModeDb srcDir dbPath:
--   Phase A0 — parse all files concurrently → build workspace TypeEnv
--   Phase A  — compile each file with TypeEnv → append rows to DuckDB
--   Phase B  — link analysis (passes 5–8) entirely within DuckDB

data CompiledPs = CompiledPs
  { cpsObjectRow     :: ObjectRow
  , cpsProcRows      :: [ProcRow]
  , cpsLocalVars     :: [LocalVar]
  , cpsDeadVars      :: [DeadVarFinding]
  , cpsTypeMismatches :: [TypeMismatchFinding]
  , cpsCallSites     :: [CallSite]
  , cpsGlobalVars    :: [GlobalVar]
  , cpsProcFlows     :: [(Text, Text, Text, Dataflow.ProcFlow)]
  , cpsSqlStmts      :: [SqlStmtRow]
  , cpsSqlStmtColumns :: [SqlStmtColumnRow]
  , cpsSqlStmtFilters :: [SqlStmtFilterRow]
  , cpsSqlStmtTables :: [SqlStmtTableRow]
  , cpsCatFootprintColumns :: [SqlStmtColumnRow]
  , cpsTaintIntraEdges :: [TaintIntraEdgeRow]
  , cpsTaintReturnRows :: [TaintReturnRow]
  , cpsSourceContent :: Maybe SourceFileRow
  }

data CompiledDw = CompiledDw
  { cdDwObjectRow      :: DwObjectRow
  , cdDwControls       :: [DwControlRow]
  , cdDwRetrieveTables :: [DwRetrieveTableRow]
  , cdDwRetrieveColumns :: [DwRetrieveColumnRow]
  , cdDwWriteColumns   :: [DwRetrieveColumnRow]
    -- ^ Plan 163 Phase 6: 'PB.Analysis.DwFootprint.dwRetrieveFootprint's
    -- @LegWrites@ legs (the DW's update-table columns), persisted to
    -- @dw_write_columns@.
  , cdDwWhereColumns   :: [DwRetrieveColumnRow]
    -- ^ Plan 163 Phase 6: 'dwRetrieveFootprint's @LegReads@ legs (catalog-
    -- gated WHERE-operand columns), persisted to @dw_where_columns@.
  , cdDwJoins          :: [DwJoinRow]
  , cdDwRetrieveWhere  :: [DwRetrieveWhereRow]
  , cdCallSites        :: [CallSite]
  , cdSourceContent    :: Maybe SourceFileRow
  }

data CompiledFile
  = CFPs    CompiledPs
  | CFDw    CompiledDw
  | CFError FilePath Text
  | CFSkip

-- | Convert one 'foldSchFootprintEff'-produced 'SchMorphism' into the same
-- row shape 'appendCatFootprintColumns' persists. 'SchFootprint' only ever
-- emits the @StmtObj -> ColumnObj@/'LegWrites' shape today ('resolveSetItem'
-- is its sole non-trivial producer) — the catch-all 'Nothing' totalizes
-- against any future shape rather than crashing (Plan 163 Phase 3).
morphismToColRow :: SchMorphism -> Maybe SqlStmtColumnRow
morphismToColRow (SchMorphism (StmtObj (SqlStmtId f o p l)) (ColumnObj (TableRef ns tbl) col) LegWrites _) =
  Just (SqlStmtColumnRow f o p l ns (Just tbl) col True)
morphismToColRow _ = Nothing

-- | 'catTables'/'mDefaultNamespace' (Plan 157 Phase 4.5): the DDL catalog's
-- (namespace, table) pairs and the configured @--default-namespace@,
-- applied via 'resolveTableRef' at the point a 'SqlStmtColumnRow'/
-- 'DwRetrieveColumnRow' is built — so the persisted row itself carries a
-- resolved namespace, not just 'PB.Analysis.SchemaCategory.buildSchema''s
-- in-memory 'SchGraph'. Both are already fully known before Phase A starts
-- (every @--ddl@ arg is loaded in 'runModeDb' before any worker launches),
-- so no DB round-trip is needed here — just threading a pure value through.
--
-- 'globalDwColumns' (Plan 163 Phase 3): every DW's resolved @(table,
-- column)@ retrieve targets, keyed by lowercased DW name — 'SchFootprint's
-- 'FunctorCtx' needs this cross-file (a PowerScript file's @SetItem@ call
-- may reference a DW compiled by a different worker), so it is built once
-- in 'runModeDb' from Phase A0's already-parsed 'PsDw' outcomes, not
-- re-derived per file here.
--
-- 'controlIdx' (Plan 164 Phase C): the workspace-wide 'ControlIndex' built
-- once in 'runModeDb' (same input file set as 'wsEnv') from
-- 'PB.Analysis.ControlHierarchy.buildControlIndex'. The 'PsParsed' branch
-- uses it, together with 'wsEnv''s own 'weHierarchy' inherits map, to
-- extend a file's static @fcControlBindings@ with runtime DataWindow-alias
-- assignments found in its own procedure bodies (see
-- 'PB.Analysis.SchFootprint.runtimeDwAliasBindings').
--
-- 'dwfCtx' (Plan 163 Phase 6): the DDL catalog wrapped for
-- 'PB.Analysis.DwFootprint.dwRetrieveFootprint' -- built once in
-- 'runModeDb' from the same DDL catalog rows 'catTables' itself is derived
-- from (empty catalog on the no-bridge path, matching 'catTables' there).
-- The 'PsDw' branch calls @dwRetrieveFootprint@ and keeps only its
-- @LegWrites@\/@LegReads@ legs (the update-table\/WHERE-operand columns) --
-- @LegRetrieve@\/@LegFk@ are dropped here since 'rcols'\/'jrows' already
-- persist those via the pre-existing @dw_retrieve_columns@\/@dw_joins@
-- producers; keeping both would double the corresponding rows in
-- @schema_morphisms@.
compileOne :: Set.Set (Text, Text) -> Maybe Text -> DwFootprintCtx -> WorkspaceEnv -> ControlIndex -> TypeCheckWorkspace -> Map.Map Ident [(TableRef, Text)] -> Maybe (SqlBridgePool, Int) -> Text -> ParseOutcome -> IO CompiledFile
compileOne catTables mDefaultNamespace dwfCtx wsEnv controlIdx tcw globalDwColumns mBridge confidence outcome = case outcome of

  PsParsed pf -> do
    let sf   = pfSrFile pf
        sp   = pfSpans  pf
        fp   = T.pack (pfPath pf)
        (objIdent, anc) = srPrimaryObject sf
        obj = identOrig objIdent
        userFns = Set.fromList
          $  map (identCanon . fnsName . fbSig) (srFunctions  sf)
          <> map (identCanon . ssName  . sbSig) (srSubroutines sf)
        mkProcEnv params = procEnv wsEnv controlIdx obj (parseParams params)
        lvs  = extractLocalVars  fp obj sf
        css  = extractCallSites  fp obj sf
        gvs  = extractGlobalVars fp obj sf
        controlBindings = controlBindingsMap (extractDwControlBindings fp sf)
        -- Shared by both 'aliasBindings' and 'procs' below, so the
        -- (sLine, eLine)/(pName, pType, instrParams, taintParams, retType,
        -- body) zip logic exists exactly once.
        procSpecs =
              zip (spFunctions   sp) [ (identOrig (fnsName (fbSig fb)), "function",   fnsParams (fbSig fb), fnsParams    (fbSig fb), fnsReturnType (fbSig fb), fbBody fb) | fb <- srFunctions   sf ]
              <>
              zip (spSubroutines sp) [ (identOrig (ssName  (sbSig sb)), "subroutine", ssParams  (sbSig sb), ssParams     (sbSig sb), "",                       sbBody sb) | sb <- srSubroutines sf ]
              <>
              zip (spEvents      sp) [ (identOrig (esName  (evSig ev)), "event",      "",                   esRawSig     (evSig ev), "",                       evBody ev) | ev <- srEvents      sf ]
              <>
              zip (spOnBlocks    sp) [ (obEvent ob,         "on",         "",                   "",                      "",                       obBody ob) | ob <- srOnBlocks    sf ]
        -- Plan 164 Phase C / D3: runtime DataWindow-alias assignments
        -- (e.g. idw_epidom = tab1.page1.uo_epidom.dw), scanned across every
        -- procedure body in this file and merged into the static bindings.
        -- steLocal is seeded with the procedure's own body locals
        -- (collectBodyLocals), mirroring GraphBuilder's own seeding, so an
        -- alias assigned to a local (not just an instance) variable still
        -- resolves. On an (object, control) key collision between two
        -- procedures' alias assignments, Map.unions keeps the first result
        -- (procSpecs order) -- an accepted simplification, since a real
        -- alias var is assigned once (constructor/open event) in practice.
        aliasBindings = Map.unions
          [ runtimeDwAliasBindings controlIdx (weHierarchy wsEnv) obj procEnvWithLocals body
          | (_, (_, _, instrParams, _, _, body)) <- procSpecs
          , let baseEnv = mkProcEnv instrParams
                procEnvWithLocals = baseEnv { steLocal = collectBodyLocals body <> steLocal baseEnv }
          ]
        -- Static literal bindings win on key collision -- a directly
        -- declared dataobject= is more trustworthy than an inferred alias.
        controlBindings' = Map.union controlBindings aliasBindings
        procs =
          [ let cfg      = buildCfg body
                cfgJs    = jsonText (toJSON cfg)
                effTerm  = compileProcedureToEff (mkProcEnv instrParams) userFns body
                instrJs    = jsonText (toJSON (linearize (buildEffGraphNamed effTerm)))
                wiringJs = jsonText (toJSON (buildEffGraphWiring effTerm))
                pflow    = Dataflow.analyzeProcedure obj pName cfg
                flow     = (fp, obj, pName, pflow)
                cyclo    = cyclomaticComplexity cfg
                footprintCtx = FunctorCtx
                  { fcStmtObj         = SqlStmtId fp obj pName sLine
                  , fcTypeEnv         = mkProcEnv instrParams
                  , fcDwColumns       = globalDwColumns
                  , fcControlBindings = controlBindings'
                  }
                catFpRows = mapMaybe morphismToColRow
                  (Set.toList (foldSchFootprintEff footprintCtx effTerm))
                -- Plan 182 Move 2 / 182b: the intra-proc taint edge set and
                -- the procedure's returned-var set, folded directly from
                -- the same 'effTerm' 'catFpRows' above already folds -- no
                -- second compile.
                (taintEdgePairs, taintReturnVars) = foldTaintEdgesEff effTerm
                taintEdgeRows =
                  [ TaintIntraEdgeRow obj pName useV defV
                  | (useV, defV) <- Set.toList taintEdgePairs
                  ]
                taintReturnRows =
                  [ TaintReturnRow obj pName v
                  | v <- Set.toList taintReturnVars
                  ]
                -- DeadVars needs this procedure's own params/body-locals,
                -- not the file-wide 'lvs' -- 'lvs' tags every param with
                -- lvScopeLine=0 (extractLocalVars/paramsToVars has no span
                -- info to give a param its own line), which would collapse
                -- every overload of a same-named procedure onto one param
                -- list. Re-deriving params from this comprehension's own
                -- instrParams/sLine sidesteps that; body locals are
                -- span-filtered against this procedure's own (sLine, eLine).
                scopedParams  = paramsToVars fp obj pName instrParams sLine
                scopedBodyLvs =
                  [ lv | lv <- lvs, lvProcName lv == pName, not (lvIsParam lv)
                       , sLine <= lvScopeLine lv, lvScopeLine lv <= eLine ]
                -- Speculative confidence marks a synthetic builtin-class
                -- method stub (PB.Runtime.StdLib) whose params are never
                -- referenced by design -- same exclusion
                -- PB.Pipeline.DuckDb.Relations's procRows/procMetaRows apply
                -- to 'procedures', kept here rather than as a query-time
                -- filter since dead_vars carries no confidence column.
                deadVars
                  | confidence == "speculative" = []
                  | otherwise = findDeadVars (scopedParams <> scopedBodyLvs) pflow
                -- Plan 177 follow-up (TypeCheckCtx/ScopedTypeEnv
                -- unification): tcEnv reuses the same ScopedTypeEnv shape
                -- CallClassify/the SSA pipeline already build for this
                -- procedure (mkProcEnv instrParams -- global > instance >
                -- local var typing, workspace hierarchy/control index),
                -- with body locals folded into steLocal the same way
                -- 'aliasBindings' above already does (collectBodyLocals body
                -- <> steLocal baseEnv -- body locals win on a name
                -- collision with a param, matching that established
                -- precedent). This replaces a hand-rolled
                -- params-and-body-locals-only 'Map Text TypeFamily' that
                -- never covered instance/global vars at all -- a bare
                -- instance/global variable reference is now visible to
                -- 'inferExpr' via 'lookupScopedVar''s existing
                -- global/instance/local lookup, the same way it already is
                -- for call classification. Same "speculative confidence ->
                -- skip" gate as deadVars, for the same stdlib-stub reason.
                typeCheckBaseEnv = mkProcEnv instrParams
                typeCheckEnv = typeCheckBaseEnv
                  { steLocal = collectBodyLocals body <> steLocal typeCheckBaseEnv }
                -- The enclosing procedure's own declared return type comes
                -- straight from this comprehension's own 'retType' text
                -- (empty for a subroutine/event/on-block), never from a
                -- 'tcwParams' lookup that could resolve to a different
                -- overload of the same name.
                ownReturnType = if T.null retType then Nothing else Just (parseTypeText retType)
                typeCheckCtx = TypeCheckCtx
                  { tcEnv = typeCheckEnv
                  , tcProcMap = tcwProcMap tcw
                  , tcParams = tcwParams tcw
                  , tcObjects = tcwObjects tcw
                  , tcUserTypes = tcwUserTypes tcw
                  , tcBuiltinFns = builtinFnNames
                  , tcBuiltinMethods = builtinMethodNames
                  , tcOwnReturnType = ownReturnType
                  }
                typeMismatches
                  | confidence == "speculative" = []
                  | otherwise = checkBody typeCheckCtx pName body
            in ( ProcRow fp obj pName pType sLine eLine cfgJs instrJs wiringJs
                   taintParams retType (Just cyclo) confidence
               , flow
               , catFpRows
               , deadVars
               , typeMismatches
               , taintEdgeRows
               , taintReturnRows )
          | ((sLine, eLine), (pName, pType, instrParams, taintParams, retType, body)) <- procSpecs
          ]
        procBodies =
             [ (identOrig (fnsName (fbSig fb)), fbBody fb) | fb <- srFunctions   sf ]
          <> [ (identOrig (ssName  (sbSig sb)), sbBody sb) | sb <- srSubroutines sf ]
          <> [ (identOrig (esName  (evSig ev)), evBody ev) | ev <- srEvents      sf ]
          <> [ (obEvent ob,         obBody ob) | ob <- srOnBlocks    sf ]
    (sqlRows, sqlColRows, sqlFilterRows, sqlTableRows) <- case mBridge of
      Nothing       ->
        -- No SQL bridge: extract raw SQL from BsRaw nodes (same as extractSqlStmts)
        pure (concatMap (rawSqlRow fp obj) procBodies, [], [], [])
      Just (pool,k) -> do
        quads <- mapM (extractProcSql resolve pool k fp obj) procBodies
        pure ( concatMap (\(a,_,_,_) -> a) quads
             , concatMap (\(_,b,_,_) -> b) quads
             , concatMap (\(_,_,c,_) -> c) quads
             , concatMap (\(_,_,_,d) -> d) quads
             )
    pure $ CFPs $ CompiledPs
      { cpsObjectRow     = ObjectRow fp "powerscript" obj anc
                             (fmap jsonText (extractWindowLayout (srTypeBlocks sf)))
                             (Just (jsonText (toJSON (srTypeBlocks sf))))
                             confidence
      , cpsProcRows      = [ r | (r, _, _, _, _, _, _) <- procs ]
      , cpsLocalVars     = lvs
      , cpsDeadVars      = concat [ dvs | (_, _, _, dvs, _, _, _) <- procs ]
      , cpsTypeMismatches = concat [ tms | (_, _, _, _, tms, _, _) <- procs ]
      , cpsCallSites     = css
      , cpsGlobalVars    = gvs
      , cpsProcFlows     = [ f | (_, f, _, _, _, _, _) <- procs ]
      , cpsSqlStmts      = sqlRows
      , cpsSqlStmtColumns = sqlColRows
      , cpsSqlStmtFilters = sqlFilterRows
      , cpsSqlStmtTables = sqlTableRows
      , cpsCatFootprintColumns = concat [ rs | (_, _, rs, _, _, _, _) <- procs ]
      , cpsTaintIntraEdges = concat [ tes | (_, _, _, _, _, tes, _) <- procs ]
      , cpsTaintReturnRows = concat [ trs | (_, _, _, _, _, _, trs) <- procs ]
      , cpsSourceContent = Just (SourceFileRow fp (pfContents pf))
      }

  PsDw fp contents dw -> do
    let obj        = T.pack (takeBaseName fp)
        fpT        = T.pack fp
        style      = Map.findWithDefault "" "style" (doaAttrs (dwObject dw))
        layoutJson = jsonText (toJSON dw)
        ctls  = [ DwControlRow fpT obj (renderBandKind (dwcBand c))
                    (dwcType c)
                    (fromMaybe "" (dwcName c))
                    (dwcX c) (dwcY c) (dwcWidth c) (dwcHeight c)
                    (dwcExpression c)
                | c <- dwControls dw ]
        css   = extractDwCallSites fpT obj dw
        retrieveSql = fmap reconstructRetrieveSql (dwTable dw >>= dtRetrieve)
        rtbls = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) ->
            [ DwRetrieveTableRow fpT obj (trNamespace resolvedRef) (trTable resolvedRef)
            | t <- drTables r
            , let resolvedRef = resolve (splitTableRef t)
            ]
          _                     -> []
        rcols = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) ->
            [ DwRetrieveColumnRow fpT obj (trNamespace resolvedRef) (trTable resolvedRef) col
            | c <- drColumns r
            , Just (tref, col) <- [splitColumnRef c]
            , let resolvedRef = resolve tref
            ]
          _                     -> []
        jrows = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) ->
            [ DwJoinRow fpT obj (djLeft j) (djOp j) (djRight j) (djOuter1 j) (djOuter2 j)
            | j <- drJoins r ]
          _                     -> []
        wrows = case dwTable dw >>= dtRetrieve of
          Just (DwRetrieveOk r) ->
            [ DwRetrieveWhereRow fpT obj idx (dwcExp1 w) (dwcOp w) (dwcExp2 w) (dwcLogic w)
            | (idx, w) <- zip [0..] (drWhere r) ]
          _                     -> []
        -- Plan 163 Phase 6: LegWrites/LegReads legs from dwRetrieveFootprint,
        -- persisted separately from rcols/jrows above (which already cover
        -- this same Set's LegRetrieve/LegFk legs) -- see compileOne's own
        -- doc comment for why keeping both would double-count.
        dwFpMorphisms = case dwTable dw of
          Just table -> dwRetrieveFootprint dwfCtx fpT obj table
          Nothing    -> Set.empty
        wcols = [ DwRetrieveColumnRow fpT obj ns tbl col
                | SchMorphism (StmtObj _) (ColumnObj (TableRef ns tbl) col) LegWrites SrcDwRetrieve
                    <- Set.toList dwFpMorphisms
                ]
        whcols = [ DwRetrieveColumnRow fpT obj ns tbl col
                 | SchMorphism (ColumnObj (TableRef ns tbl) col) (StmtObj _) LegReads SrcDwWhere
                     <- Set.toList dwFpMorphisms
                 ]
    pure $ CFDw $ CompiledDw
      { cdDwObjectRow      = DwObjectRow fpT obj style layoutJson retrieveSql
      , cdDwControls       = ctls
      , cdDwRetrieveTables = rtbls
      , cdDwRetrieveColumns = rcols
      , cdDwWriteColumns   = wcols
      , cdDwWhereColumns   = whcols
      , cdDwJoins          = jrows
      , cdDwRetrieveWhere  = wrows
      , cdCallSites        = css
      , cdSourceContent    = Just (SourceFileRow fpT contents)
      }

  PsFailed fp err -> pure $ CFError fp err
  OtherFile _     -> pure CFSkip

  where
    resolve :: TableRef -> TableRef
    resolve = resolveTableRef catTables mDefaultNamespace

renderBandKind :: Maybe DwBandKind -> Text
renderBandKind Nothing               = ""
renderBandKind (Just BkHeader)       = "header"
renderBandKind (Just BkDetail)       = "detail"
renderBandKind (Just BkFooter)       = "footer"
renderBandKind (Just BkSummary)      = "summary"
renderBandKind (Just BkBackground)   = "background"
renderBandKind (Just BkForeground)   = "foreground"
renderBandKind (Just (BkGroupHeader n)) = "group_header_" <> T.pack (show n)
renderBandKind (Just (BkGroupTrailer n)) = "group_trailer_" <> T.pack (show n)
renderBandKind (Just (BkTreeLevel n))  = "tree_level_" <> T.pack (show n)

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BSL.toStrict . encode

-- | Build SqlStmtRows from BsRaw nodes without a SQL bridge (no tables/columns).
rawSqlRow :: Text -> Text -> (Text, [Located BodyStmt]) -> [SqlStmtRow]
rawSqlRow fpT obj (pName, body) =
  [ SqlStmtRow fpT obj pName ln (Just op) "" "" rawTxt False
  | (ln, rawTxt) <- extractBsRawNodes body
  , let op = Taint.classifyOperation rawTxt
  , not (T.null op)
  , op `Set.notMember` _skipOps
  ]
  where
    _skipOps = Set.fromList
      ["DECLARE","OPEN","FETCH","CLOSE","COMMIT","ROLLBACK","CONNECT","DISCONNECT"]

extractProcSql
  :: (TableRef -> TableRef) -> SqlBridgePool -> Int -> Text -> Text -> (Text, [Located BodyStmt])
  -> IO ([SqlStmtRow], [SqlStmtColumnRow], [SqlStmtFilterRow], [SqlStmtTableRow])
extractProcSql resolve pool k fp obj (pName, body) = do
  quads <- mapM parseNode (extractBsRawNodes body)
  pure ( map (\(row,_,_,_) -> row) quads
       , concatMap (\(_,cols,_,_) -> cols) quads
       , concatMap (\(_,_,filts,_) -> filts) quads
       , concatMap (\(_,_,_,tbls) -> tbls) quads
       )
  where
    -- | Only a column ref with a known table can be resolved — an
    -- ambiguous unqualified column ('crTable' Nothing, no catalog to
    -- disambiguate against) passes through unchanged, same conservatism
    -- 'PB.Analysis.SchemaCategory.buildSchema' already applies.
    resolveColRef :: Maybe Text -> Maybe Text -> (Maybe Text, Maybe Text)
    resolveColRef _   Nothing    = (Nothing, Nothing)
    resolveColRef mNs (Just tbl) =
      let TableRef mNs' tbl' = resolve (TableRef mNs tbl) in (mNs', Just tbl')

    parseNode (ln, rawTxt) = do
      res <- parseSql pool k rawTxt
      let row = SqlStmtRow fp obj pName ln
                  (srOperation res)
                  (T.intercalate "," (srTables res))
                  (T.intercalate "," (srColumns res))
                  rawTxt
                  (srParseOk res)
          colRows =
            [ SqlStmtColumnRow fp obj pName ln ns tbl (crColumn c) (crIsWrite c)
            | c <- srColumnRefs res
            , let (ns, tbl) = resolveColRef (crNamespace c) (crTable c)
            ]
          filterRows =
            [ SqlStmtFilterRow fp obj pName ln (rfNamespace f) (rfTable f) (rfColumn f) (rfOp f)
                (jsonText (toJSON (rfValues f)))
            | f <- srRowFilters res ]
          tableRows =
            [ SqlStmtTableRow fp obj pName ln (srOperation res) (trNamespace resolvedRef) (trTable resolvedRef)
            | t <- srTableRefs res
            , let resolvedRef = resolve t
            ]
      pure (row, colRows, filterRows, tableRows)

-- | Cross-file DW-retrieve column facts for 'PB.Analysis.SchFootprint's
-- 'FunctorCtx' (Plan 163 Phase 3). Deliberately not the same helper as
-- 'compileOne''s own DW-column extraction (which builds
-- 'PB.Pipeline.DuckDb.DwRetrieveColumnRow', the persistence-side row type)
-- — this builds 'PB.Analysis.SchemaCategory.DwRetrieveColRow', the
-- analysis-side read-shape type 'dwColumnsFromRows' expects, matching the
-- codebase's existing write-side/read-shape type split (see this module's
-- own Code Index note on 'PB.Pipeline.SqlParse'). Applies the same
-- 'resolve' function 'dw_retrieve_columns' persistence itself uses, so a
-- cat-footprint leg's table ref is resolved consistently with the rest of
-- the graph.
dwRetrieveColRowsForFootprint :: (TableRef -> TableRef) -> FilePath -> DataWindowFile -> [DwRetrieveColRow]
dwRetrieveColRowsForFootprint resolve fp dw =
  [ DwRetrieveColRow fpT obj (trNamespace resolvedRef) (trTable resolvedRef) col
  | Just (DwRetrieveOk r) <- [dwTable dw >>= dtRetrieve]
  , c <- drColumns r
  , Just (tref, col) <- [splitColumnRef c]
  , let resolvedRef = resolve tref
  ]
  where
    fpT = T.pack fp
    obj  = T.pack (takeBaseName fp)

-- | Worker thread k: drains FilePaths from workQ, parses and compiles each without a SQL bridge.
-- @root@ is the ingestion root, used to relativize every stored/reported path.
workerLoopFilesNoBridge :: FilePath -> Set.Set (Text, Text) -> Maybe Text -> DwFootprintCtx -> Int -> TQueue FilePath -> WorkspaceEnv -> ControlIndex -> TypeCheckWorkspace -> Map.Map Ident [(TableRef, Text)] -> AppenderPool -> MVar () -> IORef Int -> IO ()
workerLoopFilesNoBridge root catTables mDefaultNamespace dwfCtx k workQ wsEnv controlIdx tcw globalDwColumns appPool mutex errCount = go
  where
    go = do
      mFile <- atomically $ do
        empty <- isEmptyTQueue workQ
        if empty then pure Nothing else Just <$> readTQueue workQ
      case mFile of
        Nothing   -> pure ()
        Just file -> do
          let fp = T.pack (makeRelative root file)
          emitProgress (object ["tag" .= ("worker_start" :: Text), "worker" .= k, "file" .= fp])
          outcome  <- parseOutcome root file
          compiled <- compileOne catTables mDefaultNamespace dwfCtx wsEnv controlIdx tcw globalDwColumns Nothing "confirmed" outcome
          let ok = case compiled of { CFError {} -> False; _ -> True }
          when (not ok) $ atomicModifyIORef' errCount (\n -> (n + 1, ()))
          withMVar mutex $ \_ -> appendToDb appPool compiled
          emitProgress (object ["tag" .= ("worker_done" :: Text), "worker" .= k, "file" .= fp, "ok" .= ok])
          go

-- | Worker thread k: drains FilePaths from workQ, parses and compiles each with bridge slot k,
--   serialises DB writes through a shared mutex (DuckDB connections are not thread-safe).
-- @root@ is the ingestion root, used to relativize every stored/reported path.
workerLoopFiles :: FilePath -> Set.Set (Text, Text) -> Maybe Text -> DwFootprintCtx -> Int -> TQueue FilePath -> SqlBridgePool -> WorkspaceEnv -> ControlIndex -> TypeCheckWorkspace -> Map.Map Ident [(TableRef, Text)] -> AppenderPool -> MVar () -> IORef Int -> IO ()
workerLoopFiles root catTables mDefaultNamespace dwfCtx k workQ pool wsEnv controlIdx tcw globalDwColumns appPool mutex errCount = go
  where
    go = do
      mFile <- atomically $ do
        empty <- isEmptyTQueue workQ
        if empty then pure Nothing else Just <$> readTQueue workQ
      case mFile of
        Nothing   -> pure ()
        Just file -> do
          let fp = T.pack (makeRelative root file)
          emitProgress (object ["tag" .= ("worker_start" :: Text), "worker" .= k, "file" .= fp])
          outcome  <- parseOutcome root file
          compiled <- compileOne catTables mDefaultNamespace dwfCtx wsEnv controlIdx tcw globalDwColumns (Just (pool, k)) "confirmed" outcome
          let ok = case compiled of { CFError {} -> False; _ -> True }
          when (not ok) $ atomicModifyIORef' errCount (\n -> (n + 1, ()))
          withMVar mutex $ \_ -> appendToDb appPool compiled
          emitProgress (object ["tag" .= ("worker_done" :: Text), "worker" .= k, "file" .= fp, "ok" .= ok])
          go

appendToDb :: AppenderPool -> CompiledFile -> IO ()
appendToDb pool (CFPs r) = do
  appendObjects    pool [cpsObjectRow r]
  appendProcedures pool (cpsProcRows r)
  appendLocalVars  pool (cpsLocalVars r)
  appendDeadVars   pool (cpsDeadVars r)
  appendTypeMismatches pool (cpsTypeMismatches r)
  appendCallSites  pool (cpsCallSites r)
  appendGlobalVars pool (cpsGlobalVars r)
  appendProcDefs   pool (cpsProcFlows r)
  appendProcUses   pool (cpsProcFlows r)
  appendSqlStmts   pool (cpsSqlStmts r)
  appendSqlStmtColumns pool (cpsSqlStmtColumns r)
  appendSqlStmtFilters pool (cpsSqlStmtFilters r)
  appendSqlStmtTables  pool (cpsSqlStmtTables r)
  appendCatFootprintColumns pool (cpsCatFootprintColumns r)
  appendTaintIntraEdges pool (cpsTaintIntraEdges r)
  appendTaintReturnRows pool (cpsTaintReturnRows r)
  appendSourceFiles pool (catMaybes [cpsSourceContent r])
appendToDb pool (CFDw r) = do
  appendDwObjects        pool [cdDwObjectRow r]
  appendDwControls       pool (cdDwControls r)
  appendDwRetrieveTables pool (cdDwRetrieveTables r)
  appendDwRetrieveColumns pool (cdDwRetrieveColumns r)
  appendDwWriteColumns   pool (cdDwWriteColumns r)
  appendDwWhereColumns   pool (cdDwWhereColumns r)
  appendDwJoins          pool (cdDwJoins r)
  appendDwRetrieveWhere  pool (cdDwRetrieveWhere r)
  appendCallSites        pool (cdCallSites r)
  appendSourceFiles      pool (catMaybes [cdSourceContent r])
appendToDb pool (CFError fp err) =
  appendParseErrors pool [(fp, err)]
appendToDb _    CFSkip = pure ()

-- | Flatten a 'SchemaCatalog' into DuckDB's row-oriented catalog tables,
-- assigning positional ordinals (0-based) within each table/PK/FK group.
-- Composite FKs pair @fromColumns[i]@ with @toColumns[i]@ by position.
catalogToRows :: SchemaCatalog -> ([CatalogColumnRow], [CatalogPkRow], [CatalogFkRow], [CatalogCheckRow])
catalogToRows cat =
  ( concatMap toColumnRows (scTables cat)
  , concatMap toPkRows (scPrimaryKeys cat)
  , concatMap toFkRows (scForeignKeys cat)
  , map toCheckRow (scChecks cat)
  )
  where
    toColumnRows (CatalogTable ref cols) =
      [ CatalogColumnRow (trNamespace ref) (trTable ref) c i | (i, c) <- zip [0 ..] cols ]
    toPkRows (CatalogPrimaryKey ref cols) =
      [ CatalogPkRow (trNamespace ref) (trTable ref) c i | (i, c) <- zip [0 ..] cols ]
    toFkRows (CatalogForeignKey mName fromRef fromCols toRef toCols) =
      [ CatalogFkRow mName (trNamespace fromRef) (trTable fromRef) fc
                     (trNamespace toRef) (trTable toRef) tc i
      | (i, fc, tc) <- zip3 [0 :: Int ..] fromCols toCols
      ]
    toCheckRow (CatalogCheckConstraint mName ref predicate) =
      CatalogCheckRow mName (trNamespace ref) (trTable ref) predicate

-- | Split a @--ddl@ CLI argument in @[schema:]path@ form. The prefix is
-- treated as a schema name only when it contains no path separator --
-- otherwise (e.g. a bare relative/absolute path with no schema tag) the
-- whole string is the path. Lets a dump file with an implicit schema
-- (e.g. @clims.sql@, exported while connected to CLIMS) be tagged on the
-- command line: @--ddl CLIMS:../clims.sql@.
parseDdlArg :: Text -> (Maybe Text, FilePath)
parseDdlArg arg =
  case T.breakOn ":" arg of
    (prefix, rest)
      | not (T.null rest), not ("/" `T.isInfixOf` prefix) ->
          (Just prefix, T.unpack (T.drop 1 rest))
    _ -> (Nothing, T.unpack arg)

-- | Plan 157 Phase 6: reject an ambiguous launch before any work starts.
-- 'resolveTableRef' (see 'PB.Analysis.SchemaCategory') is a pure no-op
-- whenever the default namespace is 'Nothing' — every unqualified table
-- reference in the corpus then silently fails to resolve against any
-- schema-tagged catalog, with no error anywhere in the run. As soon as
-- even one @--ddl@ arg carries an explicit @SCHEMA:@ tag, a default becomes
-- mandatory: there is no other way for an unqualified reference to pick a
-- schema. 'Left' carries a user-facing message; the caller is expected to
-- 'die' with it.
validateDdlNamespaceConfig :: [Text] -> Maybe Text -> Either Text ()
validateDdlNamespaceConfig ddlArgs mDefaultNamespace
  | Set.null taggedSchemas || isJust mDefaultNamespace = Right ()
  | otherwise = Left $
      "--ddl <SCHEMA:file> was given (schema(s): "
        <> T.intercalate ", " (Set.toList taggedSchemas)
        <> ") but --default-namespace was not. Unqualified table references "
        <> "in the corpus cannot resolve against any of the tagged schemas "
        <> "without one. Pass --default-namespace <schema>."
  where
    taggedSchemas = Set.fromList [s | arg <- ddlArgs, (Just s, _) <- [parseDdlArg arg]]

-- | 'ddlArgs' are raw @--ddl@ CLI values in @[schema:]path@ form (see
-- 'parseDdlArg'), one per DDL dump file -- e.g. multiple per-schema exports
-- (@--ddl CLIMS:clims.sql --ddl CLIMS_COMMON:clims-common.sql@) whose
-- cross-schema FK references resolve against each other once loaded.
-- 'dialect' is the sqlglot dialect for both DDL and regular SQL-statement
-- parsing (see 'PB.Pipeline.SqlParse.SqlBridgePool'). 'mSqlWorkerFlag' is a
-- python interpreter path passed explicitly via @--sql-worker-python@ -- the
-- pb CLI always passes its own @sys.executable@ here unconditionally (no
-- discovery/lookup needed on the Python side at all: a running interpreter's
-- own path is never absent), so bridge availability can't be lost anywhere
-- in a shell -> uv run -> python -> subprocess chain. The bridge worker
-- itself is launched as @pythonExe -m pb.pipeline.bridge.sql_worker@ (see
-- 'sqlWorkerModuleArgs') -- the checked-in module's location within its own
-- distribution is fixed and needs no separate discovery step either. Falls
-- back to the PB_SQL_WORKER env var (lookupEnv, expected to hold a python
-- interpreter path too) when the flag is omitted, for direct/manual
-- `cabal run pbc --` invocations. The final 'Maybe Text' is
-- @--default-namespace@ (Plan 157): threaded into 'runPhaseB' -> 'runPass9'
-- -> 'buildSchema', which resolves an unqualified SQL/DW-retrieve/DW-join
-- table reference against it iff the DDL catalog defines the table under
-- that namespace -- never guessed.
runModeDb :: FilePath -> FilePath -> [Text] -> Text -> Maybe FilePath -> Maybe Text -> IO ()
runModeDb srcDir dbPath ddlArgs dialect mSqlWorkerFlag mDefaultNamespace = do
  files <- Progress.timedStep "Scanning source directory" (walkAllSrFiles srcDir)
  let total = length files
  emitProgress (object ["tag" .= ("total" :: Text), "n" .= total])

  -- Phase A0: parse stdlib + all user files to build workspace TypeEnv.
  stdlibParsed <- parseStdlibFiles
  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("A0" :: Text), "total" .= total])
  -- 'mapConcurrently' only spawns the parse; the parsed tree it returns is
  -- otherwise a lazy thunk chain that nothing forces until the first
  -- single-threaded traversal below (originally 'buildWorkspaceEnv'), which
  -- silently serializes the real megaparsec work onto one core and makes
  -- this concurrency pointless for the CPU-bound cost (doc/plan/187-perf-
  -- hotspots.md §16 -- measured 235x on openpay: forcing here instead of
  -- after the loop dropped "Building workspace type env" from 518ms to
  -- 2.2ms). Forcing each outcome's payload to normal form here, on its own
  -- worker, is what makes the parallelism real. This 'timedStep' also gives
  -- that real cost its own labeled, visible step instead of leaving it to
  -- land wherever the next traversal happens to be.
  outcomes0 <- Progress.timedStep "Parsing files (phase A0)" $ mapConcurrently (\file -> do
    outcome <- parseOutcome srcDir file
    case outcome of
      PsParsed pf -> void (evaluate (force (pfSrFile pf)))
      PsDw _ _ dw -> void (evaluate (force dw))
      _           -> pure ()
    emitProgress (object ["tag" .= ("file_done" :: Text), "phase" .= ("A0" :: Text)])
    pure outcome) files
  let allParsedSrFiles = map pfSrFile stdlibParsed ++ [pfSrFile pf | PsParsed pf <- outcomes0]
  wsEnv <- Progress.timedStep "Building workspace type env" $ do
    let wsEnv' = buildWorkspaceEnv allParsedSrFiles
    _ <- evaluate (Map.size (weGlobals wsEnv') + Map.size (weHierarchy wsEnv'))
    pure wsEnv'

  -- Plan 164 Phase C: workspace-wide control/object hierarchy index, built
  -- once from the same parsed-file set as wsEnv, so a runtime DW-alias
  -- assignment in one file can resolve a member-chain through controls
  -- declared in a different file (see 'runtimeDwAliasBindings' in
  -- 'compileOne' below).
  controlIdx <- Progress.timedStep "Building control index" $ do
    let controlIdx' = buildControlIndex allParsedSrFiles
    _ <- evaluate (Map.size controlIdx')
    pure controlIdx'

  -- Plan 177 Phase 4: workspace-wide type-check context, built once from
  -- the same parsed-file set as wsEnv/controlIdx above -- every field is a
  -- pure function of allParsedSrFiles (see TypeCheckWorkspace's own doc
  -- comment), so no DuckDB round-trip is needed the way resolveTypes/
  -- resolveCalls's Phase-B inputs require.
  tcw <- Progress.timedStep "Building type-check workspace" $ do
    let tcw' = buildTypeCheckWorkspace allParsedSrFiles
    _ <- evaluate (identMapSize (tcwProcMap tcw') + Map.size (tcwParams tcw'))
    pure tcw'

  -- Every DW file, already parsed in Phase A0 above -- Plan 163 Phase 3
  -- needs this cross-file (a PowerScript SetItem call may reference a DW
  -- compiled by a different worker), so it's built once here rather than
  -- re-derived per file inside compileOne.
  let dwOutcomes = [ (fp, dw) | PsDw fp _ dw <- outcomes0 ]

  mBridgeBin <- case mSqlWorkerFlag of
    Just bin -> pure (Just bin)
    Nothing  -> lookupEnv "PB_SQL_WORKER"
  nWorkers   <- getNumCapabilities
  errCount   <- newIORef (0 :: Int)

  emitProgress (object ["tag" .= ("phase" :: Text), "name" .= ("A" :: Text), "workers" .= nWorkers, "total" .= total])

  withHandle (Config dbPath) $ \conn -> do
    initSchema conn
    -- Phase A tables: all tables written during the per-file compile loop
    -- and DDL loading. The pool's scope closes (flushing all appenders)
    -- before runPhaseB starts — this ordering is correctness-critical.
    let phaseATables =
          [ "objects", "procedures", "local_vars", "dead_vars", "type_mismatches", "call_sites", "global_vars"
          , "proc_defs", "proc_uses", "sql_statements", "sql_statement_columns"
          , "sql_statement_filters", "sql_statement_tables", "cat_footprint_columns"
          , "taint_intra_edges", "taint_return_rows"
          , "source_files", "parse_errors"
          , "dw_objects", "dw_controls", "dw_retrieve_tables", "dw_retrieve_columns"
          , "dw_write_columns", "dw_where_columns", "dw_joins", "dw_retrieve_where"
          , "catalog_columns", "catalog_pks", "catalog_fks", "catalog_checks"
          ]
    withAppenderPoolTimed Progress.emitEvent conn phaseATables $ \appPool -> do
      -- Load stdlib first so type lookups in user-code Phase B see the base classes.
      -- Stdlib has no DW files of its own, so an empty map is correct here.
      mapM_ (\pf -> do
        cf <- compileOne Set.empty mDefaultNamespace (mkDwFootprintCtx [] mDefaultNamespace) wsEnv controlIdx tcw Map.empty Nothing "speculative" (PsParsed pf)
        appendToDb appPool cf) stdlibParsed
      case mBridgeBin of
        Nothing -> do
          for_ ddlArgs $ \_ -> emitProgress (object
            [ "tag" .= ("warning" :: Text)
            , "message" .= ("--ddl given but no python interpreter available for the SQL bridge \
                            \(pass --sql-worker-python or set PB_SQL_WORKER); skipping DDL ingestion" :: Text)
            ])
          -- N worker threads drain a shared queue; serialize DB writes through mutex.
          -- No DDL is loaded on this path, so the catalog is empty and
          -- resolveTableRef is a no-op regardless of mDefaultNamespace.
          let globalDwColumns = dwColumnsFromRows
                [ r | (fp, dw) <- dwOutcomes
                , r <- dwRetrieveColRowsForFootprint (resolveTableRef Set.empty mDefaultNamespace) fp dw ]
              dwfCtx = mkDwFootprintCtx [] mDefaultNamespace
          workQ <- newTQueueIO
          atomically (mapM_ (writeTQueue workQ) files)
          mutex <- newMVar ()
          mapConcurrently_
            (\k -> workerLoopFilesNoBridge srcDir Set.empty mDefaultNamespace dwfCtx k workQ wsEnv controlIdx tcw globalDwColumns appPool mutex errCount)
            [0 .. nWorkers - 1]
        Just pythonExe -> do
          sqlPool <- Progress.timedStep "Starting SQL bridge pool"
            (startSqlBridgePool nWorkers pythonExe sqlWorkerModuleArgs dialect)
          allColRows <- mapM (\rawArg -> do
            let (mSchema, ddlPath) = parseDdlArg rawArg
            ddlText <- readFile ddlPath
            resp <- Progress.timedStep ("Loading DDL: " <> T.pack ddlPath) (parseDdl sqlPool mSchema ddlText)
            let stats = ddlStats resp
                (colRows, pkRows, fkRows, checkRows) = catalogToRows (ddlCatalog resp)
            appendCatalogColumns appPool colRows
            appendCatalogPks     appPool pkRows
            appendCatalogFks     appPool fkRows
            appendCatalogChecks  appPool checkRows
            emitProgress (object
              [ "tag" .= ("ddl_loaded" :: Text)
              , "path" .= ddlPath
              , "namespace" .= mSchema
              , "parse_ok" .= ddlParseOk resp
              , "error" .= ddlError resp
              , "statements_total" .= dsStatementsTotal stats
              , "statements_parsed" .= dsStatementsParsed stats
              , "statements_skipped" .= dsStatementsSkipped stats
              , "skipped_previews" .= dsSkippedPreviews stats
              , "tables" .= length (scTables (ddlCatalog resp))
              , "primary_keys" .= length pkRows
              , "foreign_keys" .= length (scForeignKeys (ddlCatalog resp))
              , "checks" .= length checkRows
              ])
            pure colRows) ddlArgs
          -- Every --ddl arg is loaded before any file worker launches, so the
          -- full cross-file catalog is known up front (Plan 157 Phase 4.5:
          -- persistence-time namespace resolution needs the complete set, not
          -- just the file currently being compiled's own DDL tag). 'catCols'
          -- feeds both 'catTables' (namespace resolution) and 'dwfCtx'
          -- (Plan 163 Phase 6: dwRetrieveFootprint's WHERE-leg catalog gate)
          -- from the same DDL rows -- no need to collect it twice.
          let catCols = [ CatColumnRow (cclrNamespace c) (cclrTableName c) (cclrColumnName c)
                        | c <- concat allColRows ]
              catTables = catalogNamespacedTables catCols
              dwfCtx = mkDwFootprintCtx catCols mDefaultNamespace
              globalDwColumns = dwColumnsFromRows
                [ r | (fp, dw) <- dwOutcomes
                , r <- dwRetrieveColRowsForFootprint (resolveTableRef catTables mDefaultNamespace) fp dw ]
          workQ <- newTQueueIO
          atomically (mapM_ (writeTQueue workQ) files)
          mutex <- newMVar ()
          mapConcurrently_
            (\k -> workerLoopFiles srcDir catTables mDefaultNamespace dwfCtx k workQ sqlPool wsEnv controlIdx tcw globalDwColumns appPool mutex errCount)
            [0 .. nWorkers - 1]
            `finally` shutdownSqlBridgePool sqlPool
    -- Pool scope closed here: all Phase A appenders flushed + destroyed.
    -- Phase B SQL queries now see the complete data.
    runPhaseB conn mDefaultNamespace  -- Phase B: link analysis (passes 5–8)

  errors <- readIORef errCount
  emitProgress (object ["tag" .= ("done" :: Text), "parsed" .= (total - errors), "errors" .= errors])
