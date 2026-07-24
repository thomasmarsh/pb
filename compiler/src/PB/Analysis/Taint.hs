{-# LANGUAGE StrictData #-}
-- | Taint analysis: source/sink classification and per-block annotations.
--
-- Pure module — no I/O. Classifies taint sources (SELECT INTO host vars,
-- event/on handler params) and sinks (INSERT/UPDATE/DELETE bind vars,
-- EXECUTE IMMEDIATE) directly from the AST, and builds inter-procedural
-- arg/return/global edges. The taint closure itself (reachability,
-- confirmed source-sink pairs, witness paths) is
-- 'PB.Analysis.TaintClosure' — an algebraic closure, not BFS.
module PB.Analysis.Taint
  ( -- * Types
    SqlStmt (..)
  , ProcMeta (..)
  , TaintFileInputs (..)
  , InterprocEdge (..)
  , ProcedureSummary (..)
  , ProcSummaryReturnFlow (..)
  , TaintSource (..)
  , TaintSink (..)
  , TaintAnnotation (..)
  , DefRow (..)
  , UseRow (..)
  , ResolvedCallRow (..)
  , GlobalVarRow (..)
    -- * Classification
  , classifySources
  , classifySinks
  , buildInterprocEdges
  , buildProcedureSummaries
  , buildTaintAnnotations
    -- * Pre-extraction (for streaming pipelines)
  , extractTaintInputs
    -- * Helpers used by Phase B DuckDB reconstruction
  , classifyOperation
  , hasIntoClause
  ) where

import PB.Prelude
import PB.AST.BodyStmt     (BodyStmt (..), foldStmts)
import PB.AST.Ident        (Ident, identOrig, mkIdent)
import PB.AST.Located      (Located (..))
import PB.AST.SourceFile
import PB.Lexing.Token     (SourceSpan)
import PB.Analysis.Dataflow (extractSqlHostVars)

import Data.Aeson
  ( FromJSON (..), ToJSON (..), (.:)
  , object, withObject, (.=)
  )
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict     as Map
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
  , drSpan     :: Maybe SourceSpan
    -- ^ The def variable's own token span -- distinct from 'drLine' (the
    -- enclosing statement's line, which 'buildInterprocEdges' matches
    -- against 'ResolvedCallRow.rcrCallLine' and so must stay untouched).
  } deriving (Eq, Show)

data UseRow = UseRow
  { urFile     :: Text
  , urObject   :: Text
  , urProcName :: Text
  , urVarName  :: Text
  , urBlockId  :: Text
  , urStmtIdx  :: Int
  , urLine     :: Maybe Int
  , urKind     :: Text
  , urSpan     :: Maybe SourceSpan  -- ^ see 'DefRow.drSpan'
  } deriving (Eq, Show)

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
  , rcrSpan           :: Maybe SourceSpan  -- ^ see 'DefRow.drSpan'
  } deriving (Eq, Show)

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
  , pmParams   :: [Text]  -- ^ ordered declared parameter names only -- every
                          -- consumer (taint source classification,
                          -- positional arg\/param matching) only ever needs
                          -- the name, never the declared type
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

sqlKeywords :: Set.Set Text
sqlKeywords = Set.fromList
  [ "SELECT", "INSERT", "UPDATE", "DELETE", "DECLARE"
  , "OPEN", "FETCH", "CLOSE", "COMMIT", "ROLLBACK"
  , "EXECUTE", "CONNECT", "DISCONNECT"
  ]

writeOps :: Set.Set Text
writeOps = Set.fromList ["INSERT", "UPDATE", "DELETE"]

execOps :: Set.Set Text
execOps = Set.fromList ["EXECUTE"]

eventProcTypes :: Set.Set Text
eventProcTypes = Set.fromList ["event", "on"]

severityMap :: Map.Map Text Text
severityMap = Map.fromList [("db_write", "high"), ("exec_immediate", "critical")]

-- ---------------------------------------------------------------------------
-- AST extraction
-- ---------------------------------------------------------------------------

-- | Determine the SQL operation type from raw SQL text.
classifyOperation :: Text -> Text
classifyOperation txt =
  let first = case T.words (T.strip txt) of
        (w:_) -> T.toUpper w
        []    -> ""
  in if first `Set.member` sqlKeywords then first else ""

-- | Check if raw SQL contains an INTO clause (SELECT ... INTO :var FROM ...).
hasIntoClause :: Text -> Bool
hasIntoClause txt =
  let upper = T.toUpper txt
      hasInto = "INTO" `T.isInfixOf` upper
      -- Must not be "INSERT INTO" — only "SELECT ... INTO" counts
      isInsert = "INSERT" `T.isPrefixOf` T.toUpper (T.strip txt)
  in hasInto && not isInsert

-- | Walk AST body statements to extract SQL statements.
extractSqlStmts :: Text -> Text -> Text -> [Located BodyStmt] -> [SqlStmt]
extractSqlStmts file obj procName = foldStmts classify
  where
    classify (Located line (BsRaw txt)) =
      let op = classifyOperation txt
      in if T.null op || op `elem` ignoredSqlOps
         then [] else [SqlStmt file obj procName (Just line) op txt (hasIntoClause txt)]
    classify _ = []

ignoredSqlOps :: [Text]
ignoredSqlOps =
  ["DECLARE", "OPEN", "FETCH", "CLOSE", "COMMIT", "ROLLBACK", "CONNECT", "DISCONNECT"]

-- | Extract procedure metadata from AST blocks.
extractProcMeta :: Text -> SrFile -> [ProcMeta]
extractProcMeta file sf =
  map fnMeta (srFunctions sf)
  <> map subMeta (srSubroutines sf)
  <> map evMeta (srEvents sf)
  <> map obMeta (srOnBlocks sf)
  where
    objName = identOrig (fst (srPrimaryObject sf))
    fnMeta fb = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = identOrig (fnsName (fbSig fb)), pmProcType = "function"
      , pmParams = map (identOrig . paramName) (fnsParams (fbSig fb))
      , pmReturnType = fnsReturnType (fbSig fb)
      , pmStartLine = Nothing }
    subMeta sb = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = identOrig (ssName (sbSig sb)), pmProcType = "subroutine"
      , pmParams = map (identOrig . paramName) (ssParams (sbSig sb))
      , pmReturnType = ""
      , pmStartLine = Nothing }
    evMeta ev = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = identOrig (esName (evSig ev)), pmProcType = "event"
      , pmParams = map (identOrig . paramName) (esParams (evSig ev))
      , pmReturnType = ""
      , pmStartLine = Nothing }
    obMeta ob = ProcMeta
      { pmFile = file, pmObject = objName
      , pmName = identOrig (obEvent ob), pmProcType = "on"
      , pmParams = []
      , pmReturnType = ""
      , pmStartLine = Nothing }

-- | Extract all taint analysis inputs from one SrFile in a single pass.
-- Call this during the streaming per-file loop; the returned TaintFileInputs
-- can be held cheaply and passed to taintAnalysis after the SrFile is released.
extractTaintInputs :: Text -> SrFile -> TaintFileInputs
extractTaintInputs file sf =
  let objName  = identOrig (fst (srPrimaryObject sf))
      bodies   = [ (objName, identOrig (fnsName (fbSig fb)), fbBody fb) | fb <- srFunctions   sf ]
              <> [ (objName, identOrig (ssName  (sbSig sb)), sbBody sb) | sb <- srSubroutines sf ]
              <> [ (objName, identOrig (esName  (evSig ev)), evBody ev) | ev <- srEvents      sf ]
              <> [ (objName, identOrig (obEvent ob), obBody ob) | ob <- srOnBlocks    sf ]
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
          | var <- extractSqlHostVars (ssRawSql s)
          ]

    procSources p
      | pmProcType p `Set.notMember` eventProcTypes = []
      | null (pmParams p) = []
      | otherwise =
          [ TaintSource (pmFile p) (pmObject p) (pmName p)
              paramN "request_param" (pmStartLine p)
          | paramN <- pmParams p
          ]

-- ---------------------------------------------------------------------------
-- Sink classification
-- ---------------------------------------------------------------------------

-- | Classify taint sinks from SQL statements.
classifySinks :: [SqlStmt] -> [TaintSink]
classifySinks = concatMap go
  where
    go s
      | op `Set.notMember` writeOps && op `Set.notMember` execOps = []
      | otherwise =
          let sinkType = if op `Set.member` execOps
                         then "exec_immediate" else "db_write"
              sev = Map.findWithDefault "high" sinkType severityMap
              vars = extractSqlHostVars (ssRawSql s)
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
  -> Set.Set Ident
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
      [ ((pmObject p, pmName p), pmParams p)
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

    -- Fans every writer and reader of a global through one synthetic
    -- per-global "hub" node (object "", proc @"global::<name>"@) instead of
    -- a direct writer x reader cartesian product: O(writers+readers) edges
    -- per global instead of O(writers*readers). A widely-shared global (a
    -- transaction object referenced from most DB-touching procedures, say)
    -- can have writer/reader counts in the thousands each -- the direct
    -- product of those is the dominant cost of this whole function on a
    -- large real corpus. taint_reaches' transitive closure makes the hub
    -- reachability-equivalent to the direct edges it replaces (any writer
    -- that reached a reader directly still reaches it via the hub, one hop
    -- longer), so taint_confirmed output is unaffected; the one visible
    -- difference is that a global-mediated witness path
    -- (PB.Analysis.TaintClosure.materializeTaintStepKind) now shows two
    -- "global_write" hops through the hub instead of one direct hop.
    --
    -- A proc that is both a writer AND a reader of the same global now gets
    -- a harmless writer-\>hub-\>itself-as-reader self-loop, where the old
    -- direct cartesian product explicitly excluded that one pair (there is
    -- no way to keep a per-pair exclusion once every writer shares one
    -- hub). This adds no reachability beyond what the proc's own real
    -- outgoing edges already provide, and taint_confirmed's own separate
    -- 0-hop rule (@taint_confirmed(s, s) :- taint_source(s),
    -- taint_sink(s)@, see PB.Analysis.TaintClosure.materializeTaintClosure) already
    -- covers a proc confirmed against itself without this self-loop's help.
    --
    -- Keyed/probed by 'Ident' (canonical Eq/Ord) -- globalVarNames is
    -- already Ident-typed (PB.Pipeline.Passes.buildCallGraphAndTaint mints it once), and
    -- PB variable names are case-insensitive, so a writer/reader pair
    -- spelling the same global with different casing must still collapse
    -- onto one hub here (else they'd never be connected at all).
    globalEdges =
      let writers = HM.fromListWith Set.union
            [ (mkIdent (drVarName d), Set.singleton (drObject d, drProcName d))
            | d <- defs, mkIdent (drVarName d) `Set.member` globalVarNames
            ]
          readers = HM.fromListWith Set.union
            [ (mkIdent (urVarName u), Set.singleton (urObject u, urProcName u))
            | u <- uses, mkIdent (urVarName u) `Set.member` globalVarNames
            ]
          allGlobals = nubOrd (HM.keys writers ++ HM.keys readers)
      in concat
           [ writerToHub ++ hubToReader
           | gvar <- allGlobals
           , let gvarText = identOrig gvar
                 hubProc  = "global::" <> gvarText
                 writerToHub =
                   [ InterprocEdge writerObj writerProc Nothing "" hubProc
                       "global_write" gvarText gvarText gvarText
                   | (writerObj, writerProc) <- Set.toList (HM.findWithDefault Set.empty gvar writers)
                   ]
                 hubToReader =
                   [ InterprocEdge "" hubProc Nothing readerObj readerProc
                       "global_write" gvarText gvarText gvarText
                   | (readerObj, readerProc) <- Set.toList (HM.findWithDefault Set.empty gvar readers)
                   ]
           ]

-- ---------------------------------------------------------------------------
-- Procedure summaries
-- ---------------------------------------------------------------------------

-- | Build per-procedure summaries: params, globals read/written, return flows.
buildProcedureSummaries
  :: [InterprocEdge]
  -> [DefRow] -> [UseRow]
  -> Set.Set Ident
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
          paramsIn = pmParams pm
          -- Membership probed via a freshly-minted Ident against
          -- globalVarNames (already Ident-typed); the reported value keeps
          -- this occurrence's own casing, same display/identity split as
          -- Dataflow's dsVar/usVar.
          gRead = Set.toAscList $ Set.fromList
            [ urVarName u | u <- HM.findWithDefault [] key usesByProc
            , mkIdent (urVarName u) `Set.member` globalVarNames ]
          gWritten = Set.toAscList $ Set.fromList
            [ drVarName d | d <- HM.findWithDefault [] key defsByProc
            , mkIdent (drVarName d) `Set.member` globalVarNames ]
          retFlows = HM.findWithDefault [] key returnFlowsByCallee
      in ProcedureSummary (pmFile pm) (pmObject pm) (pmName pm)
           paramsIn gRead gWritten retFlows

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

