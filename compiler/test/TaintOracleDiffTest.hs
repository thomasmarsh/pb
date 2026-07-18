module TaintOracleDiffTest (tests) where

-- | Phase 2 gate (doc/plan/182-algebraic-analysis.md, "Oracle-diff test"):
-- the algebraic 'taintConfirmed' (Kleene star over a semiring relation)
-- must agree with the Souffle 'taintRules' fixpoint -- the trusted oracle
-- for fixed-point taint analysis -- on 'taint_confirmed', not merely with
-- the Haskell BFS ('TaintAlgebraTest' covers that agreement separately).
--
-- Fixtures mirror 'SouffleTaintTest''s four edge-kind cases plus the
-- shared-hub fan-in shape (regression guard for the production incident
-- referenced in SouffleTaintTest.hs's "hub sharing" test).
import PB.Prelude
import PB.Analysis.Taint
  ( DefRow (..)
  , UseRow (..)
  , InterprocEdge (..)
  , TaintSource (..)
  , TaintSink (..)
  )
import PB.Analysis.TaintAlgebra (taintConfirmed)
import TaintAlgebraTest (defRow, useRow, edge, src, snk)
import PB.Pipeline.Souffle (runRuleSet)
import PB.Analysis.Rules.Taint (initTaintEdbViews, taintRules)
import PB.Pipeline.DuckDb (DuckConn, withWriteConn, initSchema)

import qualified Data.Set as Set
import qualified Data.Text as T
import Database.DuckDB.Simple (Query (..), execute_, query_)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

data Fixture = Fixture
  { fxSources :: [TaintSource]
  , fxSinks   :: [TaintSink]
  , fxDefs    :: [DefRow]
  , fxUses    :: [UseRow]
  , fxEdges   :: [InterprocEdge]
  }

taintKey :: Text -> Text -> Text -> Text
taintKey o p v = o <> "::" <> p <> "::" <> v

-- ---------------------------------------------------------------------------
-- Souffle-side row insertion (mirrors SouffleTaintTest.hs's literal-SQL helpers)
-- ---------------------------------------------------------------------------

insDef :: DuckConn -> DefRow -> IO ()
insDef conn d = case drLine d of
  Nothing -> pure ()
  Just line -> void $ execute_ conn
    (Query ("INSERT INTO proc_defs VALUES ('" <> drFile d <> "','" <> drObject d <> "','"
      <> drProcName d <> "','" <> drVarName d <> "','b0',0," <> T.pack (show line) <> ",'assign')") :: Query)

insUse :: DuckConn -> UseRow -> IO ()
insUse conn u = case urLine u of
  Nothing -> pure ()
  Just line -> void $ execute_ conn
    (Query ("INSERT INTO proc_uses VALUES ('" <> urFile u <> "','" <> urObject u <> "','"
      <> urProcName u <> "','" <> urVarName u <> "','b0',0," <> T.pack (show line) <> ",'" <> urKind u <> "')") :: Query)

insEdge :: DuckConn -> InterprocEdge -> IO ()
insEdge conn e = void $ execute_ conn
  (Query ("INSERT INTO interproc_edges VALUES ('" <> ieCallerObject e <> "','" <> ieCallerProc e
    <> "',NULL,'" <> ieCalleeObject e <> "','" <> ieCalleeProc e <> "','" <> ieEdgeKind e <> "','"
    <> ieVarName e <> "','" <> ieCallerContext e <> "','" <> ieCalleeContext e <> "')") :: Query)

insSource :: DuckConn -> TaintSource -> IO ()
insSource conn s = void $ execute_ conn
  (Query ("INSERT INTO taint_sources VALUES ('" <> tsFile s <> "','" <> tsObject s <> "','"
    <> tsProcName s <> "','" <> tsVarName s <> "','" <> tsSourceType s <> "',NULL)") :: Query)

insSink :: DuckConn -> TaintSink -> IO ()
insSink conn k = void $ execute_ conn
  (Query ("INSERT INTO taint_sinks VALUES ('" <> tskFile k <> "','" <> tskObject k <> "','"
    <> tskProcName k <> "','" <> tskVarName k <> "','" <> tskSinkType k <> "','" <> tskSeverity k <> "',NULL)") :: Query)

souffleConfirmed :: DuckConn -> Fixture -> IO (Set.Set (Text, Text))
souffleConfirmed conn fx = do
  initSchema conn
  mapM_ (insDef conn) (fxDefs fx)
  mapM_ (insUse conn) (fxUses fx)
  mapM_ (insEdge conn) (fxEdges fx)
  mapM_ (insSource conn) (fxSources fx)
  mapM_ (insSink conn) (fxSinks fx)
  initTaintEdbViews conn
  runRuleSet conn taintRules
  rows <- query_ conn "SELECT s, t FROM taint_confirmed" :: IO [(Text, Text)]
  pure (Set.fromList rows)

algConfirmed :: Fixture -> Set.Set (Text, Text)
algConfirmed fx = Set.fromList
  [ (taintKey (tsObject s) (tsProcName s) (tsVarName s), taintKey (tskObject k) (tskProcName k) (tskVarName k))
  | (s, k) <- taintConfirmed (fxSources fx) (fxSinks fx) (fxDefs fx) (fxUses fx) (fxEdges fx)
  ]

oracleDiffCase :: String -> Fixture -> TestTree
oracleDiffCase name fx = testCase name $ withWriteConn ":memory:" $ \conn -> do
  souffleRows <- souffleConfirmed conn fx
  assertEqual "algebraic taint_confirmed matches the Souffle oracle"
    souffleRows (algConfirmed fx)

-- ---------------------------------------------------------------------------
-- Fixtures: one per edge kind (mirrors SouffleTaintTest's taintRules cases),
-- plus the shared-hub fan-in shape.
-- ---------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "TaintOracleDiff"
  [ oracleDiffCase "intra-proc def-use chain" Fixture
      { fxSources = [ src "f.srw" "obj" "proc_a" "ls_x" (Just 10) ]
      , fxSinks   = [ snk "f.srw" "obj" "proc_a" "ls_b" (Just 10) ]
      , fxDefs    = [ defRow "f.srw" "obj" "proc_a" "ls_b" 10 0 ]
      , fxUses    = [ useRow "f.srw" "obj" "proc_a" "ls_x" 10 "assign" ]
      , fxEdges   = []
      }

  , oracleDiffCase "arg edge: caller passes tainted var to callee" Fixture
      { fxSources = [ src "f.srw" "obj_a" "proc_x" "ls_arg" (Just 1) ]
      , fxSinks   = [ snk "f.srw" "obj_b" "proc_y" "ls_param" (Just 1) ]
      , fxDefs    = []
      , fxUses    = []
      , fxEdges   = [ edge "obj_a" "proc_x" (Just 1) "obj_b" "proc_y" "arg" "ls_arg" "ls_arg" "ls_param" ]
      }

  , oracleDiffCase "return edge: callee return-var tainted, caller lhs tainted" Fixture
      { fxSources = [ src "f.srw" "obj" "proc_y" "ls_ret" (Just 5) ]
      , fxSinks   = [ snk "f.srw" "obj" "proc_x" "ls_lhs" (Just 5) ]
      , fxDefs    = [ defRow "f.srw" "obj" "proc_x" "ls_lhs" 5 0 ]
      , fxUses    = [ useRow "f.srw" "obj" "proc_y" "ls_ret" 5 "return" ]
      , fxEdges   = [ edge "obj" "proc_x" (Just 5) "obj" "proc_y" "return" "ls_ret" "ls_lhs" "return" ]
      }

  , oracleDiffCase "global write edge: writer global -> reader global" Fixture
      { fxSources = [ src "f.srw" "obj_w" "proc_w" "gv_shared" (Just 1) ]
      , fxSinks   = [ snk "f.srw" "obj_r" "proc_r" "gv_shared" (Just 1) ]
      , fxDefs    = []
      , fxUses    = []
      , fxEdges   = [ edge "obj_w" "proc_w" (Just 1) "obj_r" "proc_r" "global_write" "gv_shared" "gv_shared" "gv_shared" ]
      }

  , oracleDiffCase "shared-hub fan-in: 2 sources x 1 hub x 2 sinks" Fixture
      { fxSources = [ src "f.srw" "obj" "proc_a" "ls_s1" (Just 1), src "f.srw" "obj" "proc_a" "ls_s2" (Just 1) ]
      , fxSinks   = [ snk "f.srw" "obj" "proc_a" "ls_t1" (Just 1), snk "f.srw" "obj" "proc_a" "ls_t2" (Just 1) ]
      , fxDefs    = []
      , fxUses    = []
      , fxEdges   =
          [ edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_s1" "ls_s1" "ls_h"
          , edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_s2" "ls_s2" "ls_h"
          , edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_h"  "ls_h"  "ls_t1"
          , edge "obj" "proc_a" (Just 1) "obj" "proc_a" "global_write" "ls_h"  "ls_h"  "ls_t2"
          ]
      }
  ]
