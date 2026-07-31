-- | Pseudocode AST over 'PB.Explain.Regions.Region'/'PB.Explain.Signatures.InferredSignature'
-- (Plan 218 Layer 3): a target-agnostic tree reconstructing one compiled
-- procedure's real control-flow shape, cut at the same threshold points
-- 'PB.Explain.Regions.computeRegionsWith' decides, with each cut point
-- denormalized to a 'PRegionRef' carrying its own line range and candidate
-- signature so a Layer 4 renderer never needs to look either back up.
--
-- Deviates from the plan's literal @buildPseudocode :: Region ->
-- Map.Map RegionId InferredSignature -> EffTerm a b -> Pseudocode@ signature
-- for the same reason 'PB.Explain.Signatures.computeSignatures' took a
-- threshold directly rather than a pre-built 'Region': matching cut points
-- requires the same walk that built any passed-in 'Region', not a
-- reconstruction from its finished shape. Two more parameters are needed
-- because neither channel exists anywhere upstream yet: the enclosing
-- procedure's own declared signature (no 'EffTerm' field carries it) and a
-- callee-signature map plus 'ScopedTypeEnv' (an 'Eff' 'ECall'\/'ESuspend'
-- carries only a flattened 'Text' callee name, not a resolved target).
module PB.Explain.Pseudocode
  ( PStmt (..)
  , Pseudocode (..)
  , buildPseudocode
  ) where

import PB.Prelude hiding (id, (.))
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import PB.AST.Expr (Expr (..))
import PB.AST.Ident (Ident, IdentMap, identMapLookup, mkIdentSynthetic)
import PB.AST.SourceFile (FnSig, SubSig)
import PB.AST.Type (PbType)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..), ancestorChain)
import PB.Compile.IR (EffTerm)
import PB.Explain.Regions (EffLeaf (..), RegionId, Region (..), RegionOps (..), computeRegionsWith)
import PB.Explain.Signatures (InferredSignature)

data PStmt
  = PAssign Text (Maybe PbType) Expr Int
  | PCall Text (Maybe (Either FnSig SubSig)) [Expr] Int
  | PBranch Expr [PStmt] [PStmt] Int
  | PLoop [PStmt] Int
  | PReturn Expr Int
  | PRegionRef RegionId (Maybe (Int, Int)) (Maybe InferredSignature)
  deriving (Eq, Show)

data Pseudocode = Pseudocode
  { pcDeclaredSig :: Maybe (Either FnSig SubSig)
  , pcRootRegion  :: RegionId
  , pcRootSig     :: Maybe InferredSignature
  , pcRegions     :: Map.Map RegionId [PStmt]
  } deriving (Eq, Show)

-- | Resolve a bare (dot-free) call name to its declaring object's own
-- ancestor chain in @sigMap@ ('PB.Analysis.TypeEnv.buildCallableSigMap').
-- Any dotted name (@this.foo@, @recv.method@) renders name-only: real
-- receiver-type resolution needs 'PB.Analysis.TypeResolve''s heavier
-- 'CallSite'\/'ResolvedCall' machinery, sourced from token-level extraction
-- this pure 'EffTerm'-only walk has no access to -- matches the plan's own
-- Non-Goal that an unresolved call degrades to name-only rather than
-- blocking. 'mkIdentSynthetic': 'Eff'\'s 'ECall'\/'ESuspend' carry only a
-- flattened 'Text' callee name (ident-minting skill verdict, Plan 218 Phase
-- 4 Stage 0b: the real per-segment 'Ident's are discarded by
-- 'PB.Analysis.CallClassify.calleeName' before 'Eff' construction, and
-- widening 'ECall'\/'ESuspend' to carry one is blocked by the shared
-- 'PB.Compile.IR.Effectful' 'callProc' method signature across 4+ other
-- instances -- logged to 'BACKLOG.md' as its own follow-on gap, not fixed
-- here).
resolveCallee :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig)) -> Text -> Maybe (Either FnSig SubSig)
resolveCallee env sigMap name
  | T.any (== '.') name = Nothing
  | otherwise =
      let nameIdent = mkIdentSynthetic
            "PB.Explain.Pseudocode: PCall callee name has no in-memory Ident at this layer (see resolveCallee's own doc comment)"
            name
          chain = ancestorChain (steObject env) (steHierarchy env)
          lookupIn obj = case identMapLookup obj sigMap of
            Just (_, procs) -> Map.lookup nameIdent procs
            Nothing         -> Nothing
      in listToMaybe (mapMaybe lookupIn chain)

-- | One atomic 'EffLeaf' contribution's own 'PStmt' (a singleton list).
-- 'LBranchCond' is unreachable through this module's own 'opBranch' (which
-- receives the condition directly, not via a leaf) but the pattern match
-- must stay total since 'EffLeaf' is a type shared with
-- 'PB.Explain.Signatures'.
leafToStmt :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig)) -> EffLeaf -> [PStmt]
leafToStmt _env _sigMap (LAssign var ln ty) = [PAssign var ty (ExRaw []) ln]
leafToStmt _env _sigMap (LAssignWithRhs var _lhsE rhsE ln ty) = [PAssign var ty rhsE ln]
leafToStmt env sigMap (LCall name args ln _tags) = [PCall name (resolveCallee env sigMap name) args ln]
leafToStmt env sigMap (LSuspend name args ln _tags) = [PCall name (resolveCallee env sigMap name) args ln]
leafToStmt _env _sigMap (LReturn e ln) = [PReturn e ln]
leafToStmt _env _sigMap (LBranchCond _cond _ln) = []

pseudoOps :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig)) -> Map.Map RegionId InferredSignature -> RegionOps [PStmt]
pseudoOps env sigMap sigs = RegionOps
  { opLeaf   = leafToStmt env sigMap
  , opFanIn  = (<>)
  , opBranch = \cond ln t f -> [PBranch cond t f ln]
  , opLoop   = \ln body -> [PLoop body ln]
  , opRef    = \rid lns -> [PRegionRef rid lns (Map.lookup rid sigs)]
  , opSeq    = (<>)
  , opEmpty  = []
  }

buildPseudocode
  :: Int
  -> ScopedTypeEnv
  -> IdentMap (Map.Map Ident (Either FnSig SubSig))
  -> Maybe (Either FnSig SubSig)
  -> Map.Map RegionId InferredSignature
  -> EffTerm a b
  -> Pseudocode
buildPseudocode threshold env sigMap declaredSig sigs term =
  let ops = pseudoOps env sigMap sigs
      (root, regionsMap) = computeRegionsWith threshold ops term
  in Pseudocode
       { pcDeclaredSig = declaredSig
       , pcRootRegion  = regionId root
       , pcRootSig     = Map.lookup (regionId root) sigs
       , pcRegions     = regionsMap
       }
