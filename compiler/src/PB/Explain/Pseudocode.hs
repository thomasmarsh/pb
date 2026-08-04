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
  , RegionEntry (..)
  , pseudocodeRegions
  , collectRegionRefs
  , buildPseudocode
  ) where

import PB.Prelude hiding (id, (.))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
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

-- | One region block in root-first, encounter-order, de-duplicated display
-- order -- the same enumeration every consumer walking 'Pseudocode' needs:
-- walk 'PStmt' lists recursively (including nested 'PBranch'\/'PLoop' bodies), find
-- every referenced 'RegionId', and emit each one once. A region's own
-- label\/line-range\/signature always comes from the denormalized fields
-- already carried on the 'PRegionRef' that first refers to it (the root
-- entry's 'reLines' is 'Nothing' since 'Pseudocode' carries no line range
-- for its own root region).
data RegionEntry = RegionEntry
  { reId    :: RegionId
  , reStmts :: [PStmt]
  , reLines :: Maybe (Int, Int)
  , reSig   :: Maybe InferredSignature
  } deriving (Eq, Show, Generic)

pseudocodeRegions :: Pseudocode -> [RegionEntry]
pseudocodeRegions pc = rootEntry : go (Set.singleton rootId) (collectRegionRefs rootStmts)
  where
    rootId = pcRootRegion pc
    rootStmts = Map.findWithDefault [] rootId (pcRegions pc)
    rootEntry = RegionEntry rootId rootStmts Nothing (pcRootSig pc)
    go _seen [] = []
    go seen ((rid, lns, msig) : rest)
      | rid `Set.member` seen = go seen rest
      | otherwise =
          let stmts = Map.findWithDefault [] rid (pcRegions pc)
          in RegionEntry rid stmts lns msig : go (Set.insert rid seen) (rest <> collectRegionRefs stmts)

-- | Every 'PRegionRef' reachable from a statement list, recursing into
-- 'PBranch'\/'PLoop' bodies (a cut can happen inside either arm\/body, its
-- own independent straight-line run). Does not recurse into a referenced
-- region's own body -- 'pseudocodeRegions' does that once, from
-- 'pcRegions', after checking the dedup set.
collectRegionRefs :: [PStmt] -> [(RegionId, Maybe (Int, Int), Maybe InferredSignature)]
collectRegionRefs = concatMap go
  where
    go (PRegionRef rid lns msig) = [(rid, lns, msig)]
    go (PBranch _ t f _)         = collectRegionRefs t <> collectRegionRefs f
    go (PLoop body _)            = collectRegionRefs body
    go _                         = []

-- | Resolve a call site's declared signature by keying @(selfObj, selfProc,
-- callLine, calleeNameLower)@ into @callSiteMap@
-- ('PB.Explain.Signatures.ResolvedCallSiteMap') to get its real resolved
-- target, then looking that target's declaration up in @sigMap@ via
-- 'PB.Explain.Signatures.lookupDeclaredSig' -- the same corpus-wide
-- resolution 'PB.Explain.Signatures' uses for transitive effect-tag lookup,
-- so a dotted receiver call (@dw_1.Retrieve()@) or a bare call to a global
-- function resolves here too, not just a same-object bare call. The trailing
-- callee-name component (matching 'PB.Explain.Signatures.sigAccLeaf's own
-- lookup key) disambiguates two distinct calls sharing one line, e.g.
-- @MessageBox(trn(68), trn(161))@ -- without it, @MessageBox@'s own lookup
-- could return @trn@'s resolved target. An unresolved call site (absent from
-- @callSiteMap@) renders name-only, matching the plan's own Non-Goal that an
-- unresolved call degrades rather than blocks.
resolveCallSite
  :: ScopedTypeEnv -> IdentMap (Map.Map Ident (Either FnSig SubSig))
  -> Text -> ResolvedCallSiteMap -> Int -> Text
  -> Maybe (Either FnSig SubSig)
resolveCallSite env sigMap selfProc callSiteMap ln name =
  Map.lookup (identOrig (steObject env), selfProc, ln, T.toLower name) callSiteMap
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
leafToStmt _env _sigMap _selfProc _callSiteMap (LAssignWithRhs var lhsE rhsE ln ty _tags) = [PAssign var (Just lhsE) ty rhsE ln]
leafToStmt env sigMap selfProc callSiteMap (LCall name args ln _tags) =
  [PCall name (resolveCallSite env sigMap selfProc callSiteMap ln name) args ln]
leafToStmt env sigMap selfProc callSiteMap (LSuspend name args ln _tags) =
  [PCall name (resolveCallSite env sigMap selfProc callSiteMap ln name) args ln]
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
