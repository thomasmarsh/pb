module PB.Pipeline.DuckDb.PhaseB.Append
  ( appendResolvedTypes
  , appendResolvedCalls
  , appendInterprocEdges
  , appendProcSummaries
  , appendTaintSources
  , appendTaintSinks
  , appendTaintAnnotations
  , appendSchemaObjects
  , appendSchemaMorphisms
  , renderLegKind
  ) where

import PB.Prelude
import PB.Analysis.TypeResolve (ResolvedType (..), ResolvedCall (..))
import PB.Analysis.Taint       qualified as Taint
import PB.Analysis.SchemaCategory
  ( StmtId (..), SchObject (..), LegKind (..), renderLegSource
  , SchMorphism (..)
  , schObjectKey
  )
import PB.Pipeline.SqlParse    (TableRef (..))
import PB.Pipeline.Serialise   ()
import PB.Pipeline.DuckDb      (Handle, withRaw, aText, aMaybeText, aInt, aMaybeInt, aMaybeSpan, aBool, jsonList)
import PB.Pipeline.DuckDb.Appender (forEachRow)

import qualified Data.Text as T

appendResolvedTypes :: Handle -> [ResolvedType] -> IO ()
appendResolvedTypes _    [] = pure ()
appendResolvedTypes conn rows = withRaw conn "resolved_types" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (rtFile      r)
    aText      app (rtObject    r)
    aText      app (rtProcName  r)
    aText      app (rtVarName   r)
    aText      app (rtRawType   r)
    aText      app (rtKind      r)
    aMaybeText app (rtTarget    r)
    aText      app (rtScope     r)
    aInt       app (rtScopeLine r)

appendResolvedCalls :: Handle -> [ResolvedCall] -> IO ()
appendResolvedCalls _    [] = pure ()
appendResolvedCalls conn rows = withRaw conn "resolved_calls" $ \app ->
  forEachRow app rows $ \_ r -> do
    aText      app (rcFile         r)
    aText      app (rcObject       r)
    aText      app (rcFromProc     r)
    aText      app (rcToName       r)
    aText      app (rcCallType     r)
    aMaybeInt  app (rcLine         r)
    aMaybeText app (rcTargetObject r)
    aMaybeText app (rcTargetProc   r)
    aText      app (rcKind         r)
    aText      app (rcConfidence   r)
    aMaybeSpan app (rcSpan         r)

appendInterprocEdges :: Handle -> [Taint.InterprocEdge] -> IO ()
appendInterprocEdges _    [] = pure ()
appendInterprocEdges conn rows = withRaw conn "interproc_edges" $ \app ->
  forEachRow app rows $ \_ e -> do
    aText     app (Taint.ieCallerObject  e)
    aText     app (Taint.ieCallerProc    e)
    aMaybeInt app (Taint.ieCallerLine    e)
    aText     app (Taint.ieCalleeObject  e)
    aText     app (Taint.ieCalleeProc    e)
    aText     app (Taint.ieEdgeKind      e)
    aText     app (Taint.ieVarName       e)
    aText     app (Taint.ieCallerContext e)
    aText     app (Taint.ieCalleeContext e)

appendProcSummaries :: Handle -> [Taint.ProcedureSummary] -> IO ()
appendProcSummaries _    [] = pure ()
appendProcSummaries conn rows = withRaw conn "procedure_summaries" $ \app ->
  forEachRow app rows $ \_ s -> do
    aText app (Taint.psFile              s)
    aText app (Taint.psObject            s)
    aText app (Taint.psProcName          s)
    aText app (jsonList (Taint.psParamsIn       s))
    aText app (jsonList (Taint.psGlobalsRead    s))
    aText app (jsonList (Taint.psGlobalsWritten s))
    aText app (jsonList (Taint.psReturnFlowsTo  s))

appendTaintSources :: Handle -> [Taint.TaintSource] -> IO ()
appendTaintSources _    [] = pure ()
appendTaintSources conn rows = withRaw conn "taint_sources" $ \app ->
  forEachRow app rows $ \_ s -> do
    aText     app (Taint.tsFile       s)
    aText     app (Taint.tsObject     s)
    aText     app (Taint.tsProcName   s)
    aText     app (Taint.tsVarName    s)
    aText     app (Taint.tsSourceType s)
    aMaybeInt app (Taint.tsLine       s)

appendTaintSinks :: Handle -> [Taint.TaintSink] -> IO ()
appendTaintSinks _    [] = pure ()
appendTaintSinks conn rows = withRaw conn "taint_sinks" $ \app ->
  forEachRow app rows $ \_ s -> do
    aText     app (Taint.tskFile     s)
    aText     app (Taint.tskObject   s)
    aText     app (Taint.tskProcName s)
    aText     app (Taint.tskVarName  s)
    aText     app (Taint.tskSinkType s)
    aText     app (Taint.tskSeverity s)
    aMaybeInt app (Taint.tskLine     s)

appendTaintAnnotations :: Handle -> [Taint.TaintAnnotation] -> IO ()
appendTaintAnnotations _    [] = pure ()
appendTaintAnnotations conn rows = withRaw conn "taint_annotations" $ \app ->
  forEachRow app rows $ \_ a -> do
    aText app (Taint.taFile         a)
    aText app (Taint.taObject       a)
    aText app (Taint.taProcName     a)
    aText app (Taint.taBlockId      a)
    aBool app (Taint.taIsTaintEntry a)
    aBool app (Taint.taIsTaintSink  a)
    aText app (T.intercalate "|" (Taint.taTaintedVars a))

-- | Kind text for a 'LegKind'. Provenance (formerly a second, FK-only
-- @fk_source@ column derived here) is now the general 'legSource' field on
-- every 'SchMorphism' row -- see 'renderLegSource' (Plan 163 Phase 4, D3).
renderLegKind :: LegKind -> Text
renderLegKind LegReads    = "reads"
renderLegKind LegWrites   = "writes"
renderLegKind LegRetrieve = "retrieve"
renderLegKind LegFk       = "fk"

appendSchemaObjects :: Handle -> [SchObject] -> IO ()
appendSchemaObjects _    [] = pure ()
appendSchemaObjects conn objs = withRaw conn "schema_objects" $ \app ->
  forEachRow app objs $ \_ o -> do
    aText app (schObjectKey o)
    case o of
      ColumnObj (TableRef ns tbl) col -> do
        aText      app "column"
        aMaybeText app ns
        aMaybeText app (Just tbl)
        aMaybeText app (Just col)
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeInt  app Nothing
      StmtObj (SqlStmtId f obj_ p l) -> do
        aText      app "stmt"
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app (Just f)
        aMaybeText app (Just obj_)
        aMaybeText app (Just p)
        aMaybeInt  app (Just l)
      StmtObj (DwRetrieveId f dw) -> do
        aText      app "dw_retrieve"
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app Nothing
        aMaybeText app (Just f)
        aMaybeText app (Just dw)
        aMaybeText app Nothing
        aMaybeInt  app Nothing

appendSchemaMorphisms :: Handle -> [SchMorphism] -> IO ()
appendSchemaMorphisms _    [] = pure ()
appendSchemaMorphisms conn ms = withRaw conn "schema_morphisms" $ \app ->
  forEachRow app ms $ \_ m -> do
    aText      app (schObjectKey (legFrom m))
    aText      app (schObjectKey (legTo m))
    aText      app (renderLegKind (legKind m))
    aText      app (renderLegSource (legSource m))
