{-# LANGUAGE StrictData #-}
-- | Taint analysis: source/sink classification, BFS propagation, path tracing.
--
-- Pure module — no I/O.  Public API:
--
--   taintAnalysis :: TaintEnv -> (sources, sinks, paths, annotations)
--
-- Classifies taint sources (SELECT INTO host vars, event/on handler params)
-- and sinks (INSERT/UPDATE/DELETE bind vars, EXECUTE IMMEDIATE) directly from
-- the AST.  Propagates taint forward through intra-procedural def-use chains
-- and inter-procedural arg/return/global edges.  Reconstructs paths via
-- provenance back-trace.
module PB.Pipeline.Taint
  ( -- * Types
    SqlStmt (..)
  , ProcMeta (..)
  , TaintFileInputs (..)
  , InterprocEdge (..)
  , ProcedureSummary (..)
  , ProcSummaryReturnFlow (..)
  , TaintSource (..)
  , TaintSink (..)
  , TaintStep (..)
  , TaintPath (..)
  , TaintAnnotation (..)
  , TaintResult (..)
  , DefRow (..)
  , UseRow (..)
  , ResolvedCallRow (..)
  , GlobalVarRow (..)
    -- * Classification
  , classifySources
  , classifySinks
  , buildInterprocEdges
  , buildProcedureSummaries
  , propagateTaint
  , traceTaintPath
  , buildTaintAnnotations
    -- * Pre-extraction (for streaming pipelines)
  , extractTaintInputs
    -- * Corpus-wide path building (used by runPhaseB)
  , buildTaintPaths
    -- * Entry point
  , taintAnalysis
    -- * Helpers used by Phase B DuckDB reconstruction
  , classifyOperation
  , hasIntoClause
  ) where

import PB.Prelude
import PB.AST.BodyStmt
  ( BodyStmt (..)
  , IfStmt (..), ElseIf (..), ForStmt (..), DoStmt (..)
  , ChooseStmt (..), CaseClause (..)
  )
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile
import PB.Pipeline.TypeResolve (parseParams)

import Data.Aeson
  ( FromJSON (..), ToJSON (..), (.:), (.:?), (.!=)
  , object, withObject, (.=)
  )
import Data.Char            (isAlpha)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict     as Map
import qualified Data.Sequence       as Seq
import qualified Data.Set            as Set
import qualified Data.Text           as T

-- ---------------------------------------------------------------------------
-- Input row types (from JSON files produced by Pass 5/6)
-- ---------------------------------------------------------------------------

data DefRow = DefRow
  { drFile     :: Text
  , drObject   :: Text
  , drProcName :: Text
  , drVarName  :: Text
  , drBlockId  :: Text
  , drStmtIdx  :: Int
  , drLine     :: Maybe Int
  , drKind     :: Text
  } deriving (Eq, Show)

instance FromJSON DefRow where
  parseJSON = withObject "DefRow" $ \o ->
    DefRow <$> o .: "file" <*> o .: "object" <*> o .: "proc_name"
           <*> o .: "var_name" <*> o .: "block_id" <*> o .: "stmt_index"
           <*> o .:? "line" .!= Nothing <*> o .: "kind"

data UseRow = UseRow
  { urFile     :: Text
  , urObject   :: Text
  , urProcName :: Text
  , urVarName  :: Text
  , urBlockId  :: Text
  , urStmtIdx  :: Int
  , urLine     :: Maybe Int
  , urKind     :: Text
  } deriving (Eq, Show)

instance FromJSON UseRow where
  parseJSON = withObject "UseRow" $ \o ->
    UseRow <$> o .: "file" <*> o .: "object" <*> o .: "proc_name"
           <*> o .: "var_name" <*> o .: "block_id" <*> o .: "stmt_index"
           <*> o .:? "line" .!= Nothing <*> o .: "kind"

data ResolvedCallRow = ResolvedCallRow
  { rcrFile           :: Text
  , rcrObject         :: Text
  , rcrFromProc       :: Text
  , rcrToName         :: Text
  , rcrCallType       :: Text
  , rcrCallLine       :: Maybe Int
  , rcrTargetObject   :: Maybe Text
  , rcrTargetProc     :: Maybe Text
  , rcrResolutionKind :: Text
  , rcrConfidence     :: Text
  , rcrReturnType     :: Maybe Text
  } deriving (Eq, Show)

instance FromJSON ResolvedCallRow where
  parseJSON = withObject "ResolvedCallRow" $ \o ->
    ResolvedCallRow <$> o .: "file" <*> o .: "object" <*> o .: "fromProc"
                    <*> o .: "toName" <*> o .: "callType"
                    <*> o .:? "line" .!= Nothing
                    <*> o .:? "targetObject" .!= Nothing
                    <*> o .:? "targetProc" .!= Nothing
                    <*> o .: "kind" <*> o .: "confidence"
                    <*> o .:? "return_type" .!= Nothing

data GlobalVarRow = GlobalVarRow
  { gvrVarName :: Text
  } deriving (Eq, Show)

instance FromJSON GlobalVarRow where
  parseJSON = withObject "GlobalVarRow" $ \o ->
    GlobalVarRow <$> o .: "name"

-- ---------------------------------------------------------------------------
-- AST-derived types
-- ---------------------------------------------------------------------------

data SqlStmt = SqlStmt
  { ssFile     :: Text
  , ssObject   :: Text
  , ssProcName :: Text
  , ssLine     :: Maybe Int
  , ssOperation :: Text
  , ssRawSql   :: Text
  , ssHasInto  :: Bool
  } deriving (Eq, Show)

data ProcMeta = ProcMeta
  { pmFile     :: Text
  , pmObject   :: Text
  , pmName     :: Text
  , pmProcType :: Text
  , pmParams   :: Text
  , pmReturnType :: Text
  , pmStartLine :: Maybe Int
  } deriving (Eq, Show)

-- | Pre-extracted per-file inputs for taint analysis.
-- Produced during the streaming per-file pass so that taintAnalysis can run
-- in Phase B without needing the SrFile AST.
data TaintFileInputs = TaintFileInputs
  { tfiFile      :: Text
  , tfiObjName   :: Text
  , tfiSqlStmts  :: [SqlStmt]
  , tfiProcMetas :: [ProcMeta]
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Taint types
-- ---------------------------------------------------------------------------

data TaintSource = TaintSource
  { tsFile      :: Text
  , tsObject    :: Text
  , tsProcName  :: Text
  , tsVarName   :: Text
  , tsSourceType :: Text
  , tsLine      :: Maybe Int
  } deriving (Eq, Show)

instance ToJSON TaintSource where
  toJSON s = object
    [ "file"        .= tsFile s
    , "object"      .= tsObject s
    , "proc_name"   .= tsProcName s
    , "var_name"    .= tsVarName s
    , "source_type" .= tsSourceType s
    , "line"        .= tsLine s
    ]

data TaintSink = TaintSink
  { tskFile     :: Text
  , tskObject   :: Text
  , tskProcName :: Text
  , tskVarName  :: Text
  , tskSinkType :: Text
  , tskSeverity :: Text
  , tskLine     :: Maybe Int
  } deriving (Eq, Show)

instance ToJSON TaintSink where
  toJSON s = object
    [ "file"      .= tskFile s
    , "object"    .= tskObject s
    , "proc_name" .= tskProcName s
    , "var_name"  .= tskVarName s
    , "sink_type" .= tskSinkType s
    , "severity"  .= tskSeverity s
    , "line"      .= tskLine s
    ]

data TaintStep = TaintStep
  { tstObject    :: Text
  , tstProcName  :: Text
  , tstVarName   :: Text
  , tstLine      :: Maybe Int
  , tstStepKind  :: Text
  , tstDescription :: Text
  } deriving (Eq, Show)

instance ToJSON TaintStep where
  toJSON s = object
    [ "object"      .= tstObject s
    , "proc_name"   .= tstProcName s
    , "var_name"    .= tstVarName s
    , "line"        .= tstLine s
    , "step_kind"   .= tstStepKind s
    , "description" .= tstDescription s
    ]

data TaintPath = TaintPath
  { tpSource   :: TaintSource
  , tpSink     :: TaintSink
  , tpSteps    :: [TaintStep]
  , tpSeverity :: Text
  , tpCategory :: Text
  } deriving (Eq, Show)

instance ToJSON TaintPath where
  toJSON p = object
    [ "source"   .= tpSource p
    , "sink"     .= tpSink p
    , "steps"    .= tpSteps p
    , "severity" .= tpSeverity p
    , "category" .= tpCategory p
    ]

data TaintAnnotation = TaintAnnotation
  { taFile           :: Text
  , taObject         :: Text
  , taProcName       :: Text
  , taBlockId        :: Text
  , taIsTaintEntry   :: Bool
  , taIsTaintSink    :: Bool
  , taTaintedVars    :: [Text]
  } deriving (Eq, Show)

instance ToJSON TaintAnnotation where
  toJSON a = object
    [ "file"           .= taFile a
    , "object"         .= taObject a
    , "proc_name"      .= taProcName a
    , "block_id"       .= taBlockId a
    , "is_taint_entry" .= taIsTaintEntry a
    , "is_taint_sink"  .= taIsTaintSink a
    , "tainted_vars"   .= taTaintedVars a
    ]

data TaintResult = TaintResult
  { trSources     :: [TaintSource]
  , trSinks       :: [TaintSink]
  , trPaths       :: [TaintPath]
  , trAnnotations :: [TaintAnnotation]
  , trEdges       :: [InterprocEdge]
  , trProcedureSummaries :: [ProcedureSummary]
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Inter-procedural edges (computed from resolved_calls + def/use rows)
-- ---------------------------------------------------------------------------

data InterprocEdge = InterprocEdge
  { ieCallerObject   :: Text
  , ieCallerProc     :: Text
  , ieCallerLine     :: Maybe Int
  , ieCalleeObject   :: Text
  , ieCalleeProc     :: Text
  , ieEdgeKind       :: Text
  , ieVarName        :: Text
  , ieCallerContext  :: Text
  , ieCalleeContext  :: Text
  } deriving (Eq, Show)

data ProcSummaryReturnFlow = ProcSummaryReturnFlow
  { psrfObject  :: Text
  , psrfProc    :: Text
  , psrfLhsVar  :: Text
  } deriving (Eq, Show)

data ProcedureSummary = ProcedureSummary
  { psFile            :: Text
  , psObject          :: Text
  , psProcName        :: Text
  , psParamsIn        :: [Text]
  , psGlobalsRead     :: [Text]
  , psGlobalsWritten  :: [Text]
  , psReturnFlowsTo   :: [ProcSummaryReturnFlow]
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

type Triple = (Text, Text, Text)
type Provenance = HM.HashMap Triple (Text, Text, Maybe Text, Text, Text)

_sqlKeywords :: Set.Set Text
_sqlKeywords = Set.fromList
  [ "SELECT", "INSERT", "UPDATE", "DELETE", "DECLARE"
  , "OPEN", "FETCH", "CLOSE", "COMMIT", "ROLLBACK"
  , "EXECUTE", "CONNECT", "DISCONNECT"
  ]

_writeOps :: Set.Set Text
_writeOps = Set.fromList ["INSERT", "UPDATE", "DELETE"]

_execOps :: Set.Set Text
_execOps = Set.fromList ["EXECUTE"]

_eventProcTypes :: Set.Set Text
_eventProcTypes = Set.fromList ["event", "on"]

_severity :: Map.Map Text Text
_severity = Map.fromList [("db_write", "high"), ("exec_immediate", "critical")]

_category :: Map.Map Text Text
_category = Map.fromList [("db_write", "sql_injection"), ("exec_immediate", "exec_immediate")]

-- ---------------------------------------------------------------------------
-- AST extraction
-- ---------------------------------------------------------------------------

-- | Determine the SQL operation type from raw SQL text.
classifyOperation :: Text -> Text
classifyOperation txt =
  let first = case T.words (T.strip txt) of
        (w:_) -> T.toUpper w
        []    -> ""
  in if first `Set.member` _sqlKeywords then first else ""

-- | Check if raw SQL contains an INTO clause (SELECT ... INTO :var FROM ...).
hasIntoClause :: Text -> Bool
hasIntoClause txt =
  let upper = T.toUpper txt
      hasInto = "INTO" `T.isInfixOf` upper
      -- Must not be "INSERT INTO" — only "SELECT ... INTO" counts
      isInsert = "INSERT" `T.isPrefixOf` T.toUpper (T.strip txt)
  in hasInto && not isInsert

-- | Extract :identifier host variable names from text.
extractHostVars :: Text -> [Text]
extractHostVars txt = go txt
  where
    go t = case T.breakOn ":" t of
      ("", rest) | T.null rest -> []
                 | otherwise   -> go (T.drop 1 rest)
      (_, rest) ->
        let afterColon = T.drop 1 rest
            (var, remaining) = T.span isIdentChar afterColon
        in if T.null var
           then go remaining
           else var : go remaining

    isIdentChar c = isAlpha c || c == '_' || (c >= '0' && c <= '9')

-- | Walk AST body statements to extract SQL statements.
extractSqlStmts :: Text -> Text -> Text -> [Located BodyStmt] -> [SqlStmt]
extractSqlStmts file obj procName = concatMap go
  where
    go (Located line (BsRaw txt)) =
      let op = classifyOperation txt
      in if T.null op || op == "DECLARE" || op == "OPEN"
            || op == "FETCH" || op == "CLOSE" || op == "COMMIT"
            || op == "ROLLBACK" || op == "CONNECT" || op == "DISCONNECT"
         then []
         else [SqlStmt file obj procName (Just line) op txt (hasIntoClause txt)]
    go (Located _ (BsIf (IfStmt _ then_ eis mel))) =
      concatMap go then_
      <> concatMap (concatMap go . eifBody) eis
      <> maybe [] (concatMap go) mel
    go (Located _ (BsFor (ForStmt _ _ _ _ body)))   = concatMap go body
    go (Located _ (BsDo (DoStmt _ body _)))          = concatMap go body
    go (Located _ (BsChoose (ChooseStmt _ clauses))) =
      concatMap (concatMap go . ccBody) clauses
    go _ = []

-- | Extract procedure metadata from AST blocks.
extractProcMeta :: Text -> SrFile -> [ProcMeta]
extractProcMeta file sf =
  map fnMeta (srFunctions sf)
  <> map subMeta (srSubroutines sf)
  <> map evMeta (srEvents sf)
  <> map obMeta (srOnBlocks sf)
  where
    objName = case srTypeBlocks sf of
      (tb:_) -> tdName (tbDecl tb)
      []     -> ""
    fnMeta fb = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = fnsName (fbSig fb), pmProcType = "function"
      , pmParams = fnsParams (fbSig fb)
      , pmReturnType = fnsReturnType (fbSig fb)
      , pmStartLine = Nothing }
    subMeta sb = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = ssName (sbSig sb), pmProcType = "subroutine"
      , pmParams = ssParams (sbSig sb)
      , pmReturnType = ""
      , pmStartLine = Nothing }
    evMeta ev = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = esName (evSig ev), pmProcType = "event"
      , pmParams = esRawSig (evSig ev)
      , pmReturnType = ""
      , pmStartLine = Nothing }
    obMeta ob = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = obEvent ob, pmProcType = "on"
      , pmParams = ""
      , pmReturnType = ""
      , pmStartLine = Nothing }

-- | Extract all taint analysis inputs from one SrFile in a single pass.
-- Call this during the streaming per-file loop; the returned TaintFileInputs
-- can be held cheaply and passed to taintAnalysis after the SrFile is released.
extractTaintInputs :: Text -> SrFile -> TaintFileInputs
extractTaintInputs file sf =
  let objName  = case srTypeBlocks sf of
                   (tb:_) -> tdName (tbDecl tb)
                   []     -> ""
      bodies   = [ (objName, fnsName (fbSig fb), fbBody fb) | fb <- srFunctions   sf ]
              <> [ (objName, ssName  (sbSig sb), sbBody sb) | sb <- srSubroutines sf ]
              <> [ (objName, esName  (evSig ev), evBody ev) | ev <- srEvents      sf ]
              <> [ (objName, obEvent ob,          obBody ob) | ob <- srOnBlocks    sf ]
      sqlStmts = concatMap (\(obj, proc, body) -> extractSqlStmts file obj proc body) bodies
      procMetas = extractProcMeta file sf
  in TaintFileInputs file objName sqlStmts procMetas

-- ---------------------------------------------------------------------------
-- Source classification
-- ---------------------------------------------------------------------------

-- | Classify taint sources from SQL statements and procedure metadata.
classifySources :: [SqlStmt] -> [ProcMeta] -> [TaintSource]
classifySources sqlStmts procs =
  concatMap sqlSources sqlStmts <> concatMap procSources procs
  where
    sqlSources s
      | ssOperation s /= "SELECT" || not (ssHasInto s) = []
      | otherwise =
          [ TaintSource (ssFile s) (ssObject s) (ssProcName s)
              var "db_read" (ssLine s)
          | var <- extractHostVars (ssRawSql s)
          ]

    procSources p
      | pmProcType p `Set.notMember` _eventProcTypes = []
      | T.null (T.strip (pmParams p)) = []
      | otherwise =
          [ TaintSource (pmFile p) (pmObject p) (pmName p)
              paramName "request_param" (pmStartLine p)
          | (paramName, _) <- parseParams (pmParams p)
          , not (T.null paramName)
          ]

-- ---------------------------------------------------------------------------
-- Sink classification
-- ---------------------------------------------------------------------------

-- | Classify taint sinks from SQL statements.
classifySinks :: [SqlStmt] -> [TaintSink]
classifySinks = concatMap go
  where
    go s
      | op `Set.notMember` _writeOps && op `Set.notMember` _execOps = []
      | otherwise =
          let sinkType = if op `Set.member` _execOps
                         then "exec_immediate" else "db_write"
              sev = Map.findWithDefault "high" sinkType _severity
              vars = extractHostVars (ssRawSql s)
          in if null vars
             then [TaintSink (ssFile s) (ssObject s) (ssProcName s)
                     "*exec" sinkType sev (ssLine s)]
             else [TaintSink (ssFile s) (ssObject s) (ssProcName s)
                     v sinkType sev (ssLine s) | v <- vars]
      where op = T.toUpper (ssOperation s)

-- ---------------------------------------------------------------------------
-- Inter-procedural edge computation
-- ---------------------------------------------------------------------------

-- | Match caller arg vars to callee param names by position.
matchArgsToParams :: [Text] -> [Text] -> [(Text, Text)]
matchArgsToParams args params =
  zip args (params ++ repeat "*extra")

-- | Build inter-procedural edges from resolved calls, def/use rows, and global vars.
buildInterprocEdges
  :: [ResolvedCallRow]
  -> [DefRow] -> [UseRow]
  -> Set.Set Text
  -> [ProcMeta]
  -> [InterprocEdge]
buildInterprocEdges resolvedCalls defs uses globalVarNames procMetas =
  concatMap callEdges resolvedCalls
  <> concatMap builtinReturnEdges resolvedCalls
  <> concatMap builtinArgEdges resolvedCalls
  <> globalEdges
  where
    usesByProc :: HM.HashMap (Text, Text) [UseRow]
    usesByProc = HM.fromListWith (++)
      [ ((urObject u, urProcName u), [u]) | u <- uses ]

    defsByProc :: HM.HashMap (Text, Text) [DefRow]
    defsByProc = HM.fromListWith (++)
      [ ((drObject d, drProcName d), [d]) | d <- defs ]

    paramsByProc :: HM.HashMap (Text, Text) [Text]
    paramsByProc = HM.fromList
      [ ((pmObject p, pmName p), map fst (parseParams (pmParams p)))
      | p <- procMetas
      ]

    returnTypeByProc :: HM.HashMap (Text, Text) Text
    returnTypeByProc = HM.fromList
      [ ((pmObject p, pmName p), T.toLower (pmReturnType p))
      | p <- procMetas
      , pmProcType p == "function"
      ]

    callEdges rc
      | rcrResolutionKind rc `Set.notMember` Set.fromList ["virtual", "inherited"] = []
      | isNothing (rcrTargetObject rc) || isNothing (rcrTargetProc rc) = []
      | otherwise =
          let callerKey = (rcrObject rc, rcrFromProc rc)
              calleeObj = fromMaybe "" (rcrTargetObject rc)
              calleeProc = fromMaybe "" (rcrTargetProc rc)
              calleeKey = (calleeObj, calleeProc)
              calleeNameLower = T.toLower (rcrToName rc)
              calleeParams = HM.findWithDefault [] calleeKey paramsByProc
              -- Collect arg vars: uses at call line, excluding callee name
              argVars = nubOrd
                [ urVarName u
                | u <- HM.findWithDefault [] callerKey usesByProc
                , urLine u == rcrCallLine rc
                , T.toLower (urVarName u) /= calleeNameLower
                ]
              argEdges = [ InterprocEdge (rcrObject rc) (rcrFromProc rc) (rcrCallLine rc)
                              calleeObj calleeProc "arg" argVar argVar param
                         | (argVar, param) <- matchArgsToParams argVars calleeParams
                         ]
              retType = HM.findWithDefault "" calleeKey returnTypeByProc
              retEdges = if T.null retType || retType `Set.member` Set.fromList ["none", ""]
                         then []
                         else [ InterprocEdge (rcrObject rc) (rcrFromProc rc) (rcrCallLine rc)
                                   calleeObj calleeProc "return"
                                   (drVarName d) (drVarName d) "return"
                               | d <- HM.findWithDefault [] callerKey defsByProc
                               , drLine d == rcrCallLine rc
                               , drKind d == "assign"
                               ]
          in argEdges ++ retEdges

    -- Synthetic return edges for builtin calls with non-void return
    builtinReturnEdges rc
      | rcrResolutionKind rc /= "builtin" = []
      | isNothing (rcrReturnType rc) = []
      | T.toLower (fromMaybe "" (rcrReturnType rc)) `Set.member` Set.fromList ["void", "none", ""] = []
      | otherwise =
          let callerKey = (rcrObject rc, rcrFromProc rc)
              calleeName = if "." `T.isInfixOf` rcrToName rc
                           then T.toLower (snd (T.breakOnEnd "." (rcrToName rc)))
                           else T.toLower (rcrToName rc)
          in [ InterprocEdge (rcrObject rc) (rcrFromProc rc) (rcrCallLine rc)
                   "__builtin__" calleeName "return"
                   (drVarName d) (drVarName d) "return"
              | d <- HM.findWithDefault [] callerKey defsByProc
              , drLine d == rcrCallLine rc
              , drKind d == "assign"
              ]

    -- Synthetic arg edges for builtin calls (free functions only — class method params not available)
    builtinArgEdges rc
      | rcrResolutionKind rc /= "builtin" = []
      | isNothing (rcrReturnType rc) = []
      | T.toLower (fromMaybe "" (rcrReturnType rc)) `Set.member` Set.fromList ["void", "none", ""] = []
      | otherwise = []  -- No callee param info for builtins in this pass

    globalEdges =
      let writers = HM.fromListWith Set.union
            [ (drVarName d, Set.singleton (drObject d, drProcName d))
            | d <- defs, drVarName d `Set.member` globalVarNames
            ]
          readers = HM.fromListWith Set.union
            [ (urVarName u, Set.singleton (urObject u, urProcName u))
            | u <- uses, urVarName u `Set.member` globalVarNames
            ]
          allGlobals = nubOrd (HM.keys writers ++ HM.keys readers)
      in [ InterprocEdge writerObj writerProc Nothing
              readerObj readerProc "global_write" gvar gvar gvar
         | gvar <- allGlobals
         , writerKey <- Set.toList (HM.findWithDefault Set.empty gvar writers)
         , readerKey <- Set.toList (HM.findWithDefault Set.empty gvar readers)
         , writerKey /= readerKey
          , let (writerObj, writerProc) = writerKey
                (readerObj, readerProc) = readerKey
         ]

-- ---------------------------------------------------------------------------
-- Procedure summaries
-- ---------------------------------------------------------------------------

-- | Build per-procedure summaries: params, globals read/written, return flows.
buildProcedureSummaries
  :: [InterprocEdge]
  -> [DefRow] -> [UseRow]
  -> Set.Set Text
  -> [ProcMeta]
  -> [ProcedureSummary]
buildProcedureSummaries edges defs uses globalVarNames procMetas =
  map mkSummary procMetas
  where
    defsByProc :: HM.HashMap (Text, Text) [DefRow]
    defsByProc = HM.fromListWith (++)
      [ ((drObject d, drProcName d), [d]) | d <- defs ]

    usesByProc :: HM.HashMap (Text, Text) [UseRow]
    usesByProc = HM.fromListWith (++)
      [ ((urObject u, urProcName u), [u]) | u <- uses ]

    returnFlowsByCallee :: HM.HashMap (Text, Text) [ProcSummaryReturnFlow]
    returnFlowsByCallee = HM.fromListWith (++)
      [ ((ieCalleeObject e, ieCalleeProc e),
         [ProcSummaryReturnFlow (ieCallerObject e) (ieCallerProc e) (ieVarName e)])
      | e <- edges, ieEdgeKind e == "return"
      ]

    mkSummary :: ProcMeta -> ProcedureSummary
    mkSummary pm =
      let key = (pmObject pm, pmName pm)
          paramsIn = map fst (parseParams (pmParams pm))
          gRead = Set.toAscList $ Set.fromList
            [ urVarName u | u <- HM.findWithDefault [] key usesByProc
            , urVarName u `Set.member` globalVarNames ]
          gWritten = Set.toAscList $ Set.fromList
            [ drVarName d | d <- HM.findWithDefault [] key defsByProc
            , drVarName d `Set.member` globalVarNames ]
          retFlows = HM.findWithDefault [] key returnFlowsByCallee
      in ProcedureSummary (pmFile pm) (pmObject pm) (pmName pm)
           paramsIn gRead gWritten retFlows

-- ---------------------------------------------------------------------------
-- BFS taint propagation
-- ---------------------------------------------------------------------------

-- | Forward BFS taint propagation through def-use chains and inter-proc edges.
-- Returns the set of tainted triples and provenance for path reconstruction.
propagateTaint
  :: [TaintSource]
  -> [DefRow] -> [UseRow]
  -> [InterprocEdge]
  -> (Set.Set Triple, Provenance)
propagateTaint sources defs uses edges =
  fixpoint Set.empty HM.empty (Seq.fromList initialSeeds)
  where
    -- Index uses by (object, proc, var)
    usesByTriple :: HM.HashMap Triple [UseRow]
    usesByTriple = HM.fromListWith (++)
      [ ((urObject u, urProcName u, urVarName u), [u]) | u <- uses ]

    -- Index defs by (object, proc, line)
    defsByLine :: HM.HashMap (Text, Text, Int) [Text]
    defsByLine = HM.fromListWith (++)
      [ ((drObject d, drProcName d, line), [drVarName d])
      | d <- defs
      , Just line <- [drLine d]
      ]

    -- Index interproc edges
    argEdgesByCaller :: HM.HashMap Triple [InterprocEdge]
    argEdgesByCaller = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieCallerContext e), [e])
      | e <- edges, ieEdgeKind e == "arg"
      ]

    returnEdgesByCallee :: HM.HashMap (Text, Text) [InterprocEdge]
    returnEdgesByCallee = HM.fromListWith (++)
      [ ((ieCalleeObject e, ieCalleeProc e), [e])
      | e <- edges, ieEdgeKind e == "return"
      ]

    globalWriteEdges :: HM.HashMap Triple [InterprocEdge]
    globalWriteEdges = HM.fromListWith (++)
      [ ((ieCallerObject e, ieCallerProc e, ieVarName e), [e])
      | e <- edges, ieEdgeKind e == "global_write"
      ]

    initialSeeds :: [(Triple, Text, Text)]
    initialSeeds =
      [ ((tsObject s, tsProcName s, tsVarName s), "source",
          "taint source: " <> tsSourceType s)
      | s <- sources
      ]

    fixpoint
      :: Set.Set Triple
      -> Provenance
      -> Seq.Seq (Triple, Text, Text)
      -> (Set.Set Triple, Provenance)
    fixpoint tainted prov queue = case Seq.viewl queue of
      Seq.EmptyL -> (tainted, prov)
      (t, sk, desc) Seq.:< rest
        | t `Set.member` tainted -> fixpoint tainted prov rest
        | otherwise ->
            let tainted' = Set.insert t tainted
                prov'    = HM.insert t ("", "", Nothing, sk, desc) prov
                newSeeds = propagateOne t tainted'
            in  fixpoint tainted' prov' (rest Seq.>< Seq.fromList newSeeds)

    propagateOne :: Triple -> Set.Set Triple -> [(Triple, Text, Text)]
    propagateOne (obj, proc, var) tainted =
      concatMap snd
        [ (True, intraProcSeeds)
        , (True, argSeeds)
        , (True, returnSeeds)
        , (True, globalSeeds)
        ]
      where
        -- 1. Intra-proc: tainted var used on line with def → def is tainted
        intraProcSeeds =
          [ ((obj, proc, newVar), "def",
              var <> " used in expression that defines " <> newVar)
          | u <- HM.findWithDefault [] (obj, proc, var) usesByTriple
          , Just line <- [urLine u]
          , newVar <- HM.findWithDefault [] (obj, proc, line) defsByLine
          , newVar /= var
          , (obj, proc, newVar) `Set.notMember` tainted
          ]

        -- 2. Arg edges: tainted caller_context → callee_context
        argSeeds =
          [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "arg",
              "passed as argument from " <> obj <> "." <> proc)
          | e <- HM.findWithDefault [] (obj, proc, var) argEdgesByCaller
          , (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) `Set.notMember` tainted
          ]

        -- 3. Return edges: tainted var returned from callee → caller lhs tainted
        returnSeeds =
          [ ((ieCallerObject e, ieCallerProc e, ieCallerContext e), "return",
              "return value of " <> obj <> "." <> proc <> " received by caller")
          | u <- HM.findWithDefault [] (obj, proc, var) usesByTriple
          , urKind u == "return"
          , e <- HM.findWithDefault [] (obj, proc) returnEdgesByCallee
          , (ieCallerObject e, ieCallerProc e, ieCallerContext e) `Set.notMember` tainted
          ]

        -- 4. Global write edges: tainted global propagates to readers
        globalSeeds =
          [ ((ieCalleeObject e, ieCalleeProc e, ieCalleeContext e), "global",
              "global variable " <> var <> " written in " <> obj <> "." <> proc)
          | e <- HM.findWithDefault [] (obj, proc, var) globalWriteEdges
          , (ieCalleeObject e, ieCalleeProc e, ieCalleeContext e) `Set.notMember` tainted
          ]

-- ---------------------------------------------------------------------------
-- Path reconstruction
-- ---------------------------------------------------------------------------

-- | Reconstruct taint path from source to sink using provenance back-trace.
traceTaintPath
  :: TaintSource
  -> TaintSink
  -> Provenance
  -> [TaintStep]
traceTaintPath source sink prov =
  let sourceTriple = (tsObject source, tsProcName source, tsVarName source)
      sinkTriple   = (tskObject sink, tskProcName sink, tskVarName sink)
      -- Walk backwards from sink to source, collecting the chain
      chain = buildChain sinkTriple sourceTriple prov []
      -- Reverse to get source→sink order
      ordered = reverse chain
  in map makeStep ordered
  where
    buildChain :: Triple -> Triple -> Provenance -> [Triple] -> [Triple]
    buildChain current target _ acc | current == target = current : acc
    buildChain _ _ _ acc | length acc > 50 = acc
    buildChain current target p acc =
      case HM.lookup current p of
        Nothing -> acc
        Just (_, _, Nothing, _, _) -> current : acc  -- source node
        Just (po, pp, Just pv, _, _) ->
          buildChain (po, pp, pv) target p (current : acc)

    makeStep :: Triple -> TaintStep
    makeStep (o, p, v) =
      let isSource = (o, p, v) == (tsObject source, tsProcName source, tsVarName source)
          isSink   = (o, p, v) == (tskObject sink, tskProcName sink, tskVarName sink)
          line | isSource  = tsLine source
               | isSink    = tskLine sink
               | otherwise = Nothing
          sk   | isSource  = "source"
               | isSink    = "sink"
               | otherwise = maybe "def" (\(_, _, _, k, _) -> k) (HM.lookup (o, p, v) prov)
          desc | isSource  = "taint source: " <> tsSourceType source
               | isSink    = "taint sink: " <> tskSinkType sink
               | otherwise = maybe ("tainted variable " <> v)
                                    (\(_, _, _, _, d) -> d)
                                    (HM.lookup (o, p, v) prov)
      in TaintStep o p v line sk desc

-- ---------------------------------------------------------------------------
-- Taint annotations
-- ---------------------------------------------------------------------------

-- | Build per-block taint annotations.
buildTaintAnnotations
  :: Set.Set Triple
  -> [TaintSource] -> [TaintSink]
  -> [DefRow] -> [UseRow]
  -> [TaintAnnotation]
buildTaintAnnotations tainted sources sinks defs uses =
  HM.elems $ HM.fromListWith mergeAnnotations
    (concatMap defAnnotations defs ++ concatMap useAnnotations uses)
  where
    defAnnotations d =
      let triple = (drObject d, drProcName d, drVarName d)
          isEntry = any (\s -> (tsObject s, tsProcName s, tsVarName s) == triple) sources
          isSnk   = any (\s -> (tskObject s, tskProcName s, tskVarName s) == triple) sinks
          key = (drFile d, drObject d, drProcName d, drBlockId d, isEntry, isSnk)
      in if triple `Set.member` tainted
         then [(key, TaintAnnotation (drFile d) (drObject d) (drProcName d)
                   (drBlockId d) isEntry isSnk [drVarName d])]
         else []

    useAnnotations u =
      let triple = (urObject u, urProcName u, urVarName u)
          isEntry = any (\s -> (tsObject s, tsProcName s, tsVarName s) == triple) sources
          isSnk   = any (\s -> (tskObject s, tskProcName s, tskVarName s) == triple) sinks
          key = (urFile u, urObject u, urProcName u, urBlockId u, isEntry, isSnk)
      in if triple `Set.member` tainted
         then [(key, TaintAnnotation (urFile u) (urObject u) (urProcName u)
                   (urBlockId u) isEntry isSnk [urVarName u])]
         else []

    mergeAnnotations a b = a
      { taTaintedVars = nubOrd (taTaintedVars a ++ taTaintedVars b) }

-- ---------------------------------------------------------------------------
-- Full pipeline
-- ---------------------------------------------------------------------------

-- | Run the full taint analysis from pre-extracted per-file inputs.
-- Use extractTaintInputs to produce TaintFileInputs during the streaming
-- per-file pass, then call this after all files are processed.
taintAnalysis
  :: [ResolvedCallRow]    -- ^ resolved_calls.json
  -> [DefRow]             -- ^ proc_defs.json
  -> [UseRow]             -- ^ proc_uses.json
  -> Set.Set Text         -- ^ global variable names
  -> TaintFileInputs      -- ^ pre-extracted per-file data
  -> TaintResult
taintAnalysis resolvedCalls defs uses globalVarNames tfi =
  let sqlStmts  = tfiSqlStmts  tfi
      procMetas = tfiProcMetas tfi
      sources   = classifySources sqlStmts procMetas
      sinks     = classifySinks sqlStmts
      edges     = buildInterprocEdges resolvedCalls defs uses globalVarNames procMetas
      summaries = buildProcedureSummaries edges defs uses globalVarNames procMetas
      (tainted, prov) = propagateTaint sources defs uses edges
      paths       = buildTaintPaths sources sinks prov
      annotations = buildTaintAnnotations tainted sources sinks defs uses
  in TaintResult sources sinks paths annotations edges summaries

buildTaintPaths :: [TaintSource] -> [TaintSink] -> Provenance -> [TaintPath]
buildTaintPaths srcs snks prov =
  [ TaintPath src sink steps (tskSeverity sink)
      (Map.findWithDefault "general" (tskSinkType sink) _category)
  | sink <- snks
  , let sinkTriple = (tskObject sink, tskProcName sink, tskVarName sink)
  , HM.member sinkTriple prov
  , src <- findSourceRoot sinkTriple prov srcs
  , let steps = traceTaintPath src sink prov
  , not (null steps)
  ]

findSourceRoot :: Triple -> Provenance -> [TaintSource] -> [TaintSource]
findSourceRoot triple prov srcs =
  let rootTriple = walkProvBack triple prov
  in filter (\s -> (tsObject s, tsProcName s, tsVarName s) == rootTriple) srcs

walkProvBack :: Triple -> Provenance -> Triple
walkProvBack t p = case HM.lookup t p of
  Nothing    -> t
  Just (_, _, Nothing, _, _) -> t
  Just (po, pp, Just pv, _, _) -> walkProvBack (po, pp, pv) p

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

nubOrd :: Ord a => [a] -> [a]
nubOrd = Set.toAscList . Set.fromList
