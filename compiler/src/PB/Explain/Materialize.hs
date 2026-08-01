-- | Orchestrates 'PB.Explain.Regions'\/'PB.Explain.Signatures'\/
-- 'PB.Explain.Pseudocode' over every retained procedure and materializes
-- the result as @proc_pseudocode@ (Plan 221 Phase 2), the same
-- compute-then-materialize shape 'PB.Analysis.EffectClosure.materializeProcEffects'
-- already uses for @proc_effects@ -- lives beside the analysis it
-- materializes rather than in 'PB.Pipeline.DuckDb.Materialize' (that module
-- is pure-SQL-projection territory; this is a Haskell fold over retained
-- 'EffTerm's, not a SQL @SELECT@).
module PB.Explain.Materialize
  ( ExplainSeedRow (..)
  , materializeProcPseudocode
  ) where

import PB.Prelude
import Data.Aeson (ToJSON, encode)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text.Encoding as TE
import PB.AST.Ident (Ident, IdentMap, identSetFromList)
import PB.AST.SourceFile (FnSig, SubSig)
import PB.Analysis.CallClassify (EffectTag)
import PB.Analysis.Taint qualified as Taint
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR (EffTerm)
import PB.Explain.Regions (defaultComplexityThreshold)
import PB.Explain.Signatures (buildResolvedCallSiteMap, computeSignatures, lookupDeclaredSig)
import PB.Explain.Pseudocode (buildPseudocode)
import PB.Explain.Simplify (simplifyPseudocode)
import PB.Pipeline.DuckDb (Handle, recreateTextTable, appendTextRows)
import PB.Pipeline.Serialise ()

import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | One procedure's retained compilation state (Plan 221 Phase 2), carried
-- corpus-wide from 'PB.Pipeline.Runner.compileOne' through to this
-- module's own fold in 'PB.Pipeline.Passes.runPhaseB', once the effect
-- closure exists. 'Eq'\/'Show' compare\/display only @(esrObject,
-- esrProcName)@ -- 'EffTerm'\/'Eff' has no 'Eq'\/'Show' of its own (its
-- 'EComp' constructor existentially hides an intermediate composition type
-- a generic derived instance cannot compare type-safely), and every real
-- use of 'PhaseAData''s own derived 'Eq' (the "did anything get added"
-- checks in @RunnerTest.hs@) only ever compares against a genuinely empty
-- accumulator, so identity-only comparison is exact for every case that
-- matters.
data ExplainSeedRow = ExplainSeedRow
  { esrObject   :: Text
  , esrProcName :: Text
  , esrEffTerm  :: EffTerm () ()
  , esrEnv      :: ScopedTypeEnv
  }

instance Eq ExplainSeedRow where
  a == b = esrObject a == esrObject b && esrProcName a == esrProcName b

instance Show ExplainSeedRow where
  show r = "ExplainSeedRow " <> show (esrObject r, esrProcName r)

jsonText :: ToJSON a => a -> Text
jsonText = TE.decodeUtf8 . BSL.toStrict . encode

-- | Fold 'PB.Explain.Regions.computeRegionsWith'\/'PB.Explain.Signatures.computeSignatures'\/
-- 'PB.Explain.Pseudocode.buildPseudocode' over every retained procedure and
-- write one @(object, proc_name, pseudocode_json)@ row per procedure to
-- @proc_pseudocode@. @sigMap@\/@procEffects@ are threaded straight through
-- to 'computeSignatures'\/'buildPseudocode' with no lossy collapsing step.
-- @callRows@ (the same corpus-wide 'Taint.ResolvedCallRow's already used to
-- build @proc_effects@ itself) is reshaped once, outside the per-procedure
-- loop, into a 'PB.Explain.Signatures.ResolvedCallSiteMap' so every call
-- leaf -- dotted or bare, same-object or not -- resolves against the real
-- corpus-wide resolution instead of a caller-local search.
materializeProcPseudocode
  :: IdentMap (Map.Map Ident (Either FnSig SubSig))
  -> Map.Map (Text, Text) (Set.Set EffectTag)
  -> [Taint.ResolvedCallRow]
  -> [ExplainSeedRow]
  -> Handle
  -> IO ()
materializeProcPseudocode sigMap procEffects callRows seedRows conn = do
  let callSiteMap = buildResolvedCallSiteMap callRows
      rows =
        [ [obj, pName, jsonText pc]
        | ExplainSeedRow obj pName effTerm env <- seedRows
        , let declaredSig = lookupDeclaredSig sigMap obj pName
              sigs = computeSignatures defaultComplexityThreshold env pName callSiteMap procEffects effTerm
              locals = identSetFromList (Map.keys (steLocal env))
              pc = simplifyPseudocode locals
                     (buildPseudocode defaultComplexityThreshold env sigMap pName callSiteMap declaredSig sigs effTerm)
        ]
  recreateTextTable conn "proc_pseudocode" ["object", "proc_name", "pseudocode_json"]
  appendTextRows conn "proc_pseudocode" rows
