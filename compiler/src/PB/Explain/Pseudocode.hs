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
import GHC.Generics (Generic)
import PB.AST.Expr (Expr (..))
import PB.AST.Ident (Ident, IdentMap, identOrig)
import PB.AST.SourceFile (FnSig, SubSig)
import PB.AST.Type (PbType)
import PB.Analysis.TypeEnv (ScopedTypeEnv (..))
import PB.Compile.IR (EffTerm)
import PB.Explain.Regions (EffLeaf (..), RegionId, Region (..), RegionOps (..), computeRegionsWith)
import PB.Explain.Signatures (InferredSignature, ResolvedCallSiteMap, lookupDeclaredSig)

data PStmt
  = PAssign Text (Maybe Expr) (Maybe PbType) Expr Int
  | PCall Text (Maybe (Either FnSig SubSig)) [Expr] Int
  | PBranch Expr [PStmt] [PStmt] Int
  | PLoop [PStmt] Int
  | PReturn Expr Int
  | PRegionRef RegionId (Maybe (Int, Int)) (Maybe InferredSignature)
  deriving (Eq, Show, Generic)

data Pseudocode = Pseudocode
  { pcDeclaredSig :: Maybe (Either FnSig SubSig)
  , pcRootRegion  :: RegionId
  , pcRootSig     :: Maybe InferredSignature
  , pcRegions     :: Map.Map RegionId [PStmt]
  } deriving (Eq, Show, Generic)

-- | Resolve a call site's declared signature by keying @(selfObj, selfProc,
-- callLine)@ into @callSiteMap@ ('PB.Explain.Signatures.ResolvedCallSiteMap')
-- to get its real resolved target, then looking that target's declaration up
-- in @sigMap@ via 'PB.Explain.Signatures.lookupDeclaredSig' -- the same
-- corpus-wide resolution 'PB.Explain.Signatures' uses for transitive
-- effect-tag lookup, so a dotted receiver call (@dw_1.Retrieve()@) or a bare
-- call to a global function resolves here too, not just a same-object bare
-- call. An unresolved call site (absent from @callSiteMap@) renders
-- name-only, matching the plan's own Non-Goal that an unresolved call
-- degrades rather than blocks.
resolveCallSite
  :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig))
  -> Text -> ResolvedCallSiteMap -> Int
  -> Maybe (Either FnSig SubSig)
resolveCallSite env sigMap selfProc callSiteMap ln =
  Map.lookup (identOrig (steObject env), selfProc, ln) callSiteMap
    >>= \(tObj, tProc) -> lookupDeclaredSig sigMap tObj tProc

-- | One atomic 'EffLeaf' contribution's own 'PStmt' (a singleton list).
-- 'LBranchCond' is unreachable through this module's own 'opBranch' (which
-- receives the condition directly, not via a leaf) but the pattern match
-- must stay total since 'EffLeaf' is a type shared with
-- 'PB.Explain.Signatures'.
leafToStmt
  :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig))
  -> Text -> ResolvedCallSiteMap -> EffLeaf -> [PStmt]
leafToStmt _env _sigMap _selfProc _callSiteMap (LAssign var ln ty) = [PAssign var Nothing ty (ExRaw []) ln]
leafToStmt _env _sigMap _selfProc _callSiteMap (LAssignWithRhs var lhsE rhsE ln ty) = [PAssign var (Just lhsE) ty rhsE ln]
leafToStmt env sigMap selfProc callSiteMap (LCall name args ln _tags) =
  [PCall name (resolveCallSite env sigMap selfProc callSiteMap ln) args ln]
leafToStmt env sigMap selfProc callSiteMap (LSuspend name args ln _tags) =
  [PCall name (resolveCallSite env sigMap selfProc callSiteMap ln) args ln]
leafToStmt _env _sigMap _selfProc _callSiteMap (LReturn e ln) = [PReturn e ln]
leafToStmt _env _sigMap _selfProc _callSiteMap (LBranchCond _cond _ln) = []

pseudoOps
  :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig))
  -> Text -> ResolvedCallSiteMap -> Map.Map RegionId InferredSignature -> RegionOps [PStmt]
pseudoOps env sigMap selfProc callSiteMap sigs = RegionOps
  { opLeaf   = leafToStmt env sigMap selfProc callSiteMap
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
  -> Text
  -> ResolvedCallSiteMap
  -> Maybe (Either FnSig SubSig)
  -> Map.Map RegionId InferredSignature
  -> EffTerm a b
  -> Pseudocode
buildPseudocode threshold env sigMap selfProc callSiteMap declaredSig sigs term =
  let ops = pseudoOps env sigMap selfProc callSiteMap sigs
      (root, regionsMap) = computeRegionsWith threshold ops term
  in Pseudocode
       { pcDeclaredSig = declaredSig
       , pcRootRegion  = regionId root
       , pcRootSig     = Map.lookup (regionId root) sigs
       , pcRegions     = regionsMap
       }
