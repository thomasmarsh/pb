-- | Simplification passes over 'PB.Explain.Pseudocode.Pseudocode' (Plan 218
-- Layer 3.5): a fixed pipeline of named sub-passes run over every region's
-- own @[PStmt]@, each independently testable and a no-op when its pattern
-- doesn't match. Applied before serialization/rendering, not folded into
-- 'PB.Explain.Render.Text' itself -- every renderer wants the same cleanup,
-- and 'PB.Explain.Render.Text' stays the plainest possible printer.
-- "Semantics-preserving" here means preserving each region's own
-- 'PB.Explain.Signatures.InferredSignature' and observable PowerScript
-- behavior, not a formal proof -- enforced by hand-written tests per pass
-- plus a Hedgehog idempotence property, not a verified equivalence to the
-- original 'PB.Compile.IR.Eff'.
module PB.Explain.Simplify
  ( simplifyPseudocode
  , dropDeadStores
  , collapseBooleanBranch
  , inlineForwardingRegions
  , inlinePureRegions
  ) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import PB.AST.Expr (Expr (..))
import PB.AST.Ident (Ident, IdentSet, identSetDifference, identSetFromList, identSetMember, identSetToList, mkIdentSynthetic)
import PB.AST.SourceFile (FnSig (..), Param (..), SubSig (..))
import PB.Analysis.Dataflow (walkExprIdents)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..), collectRegionRefs)
import PB.Explain.Regions (RegionId)
import PB.Explain.Signatures (InferredSignature (..), RegionKind (..), VarBinding (..))

-- | 'PStmt'\'s own fields carry only a flattened 'Text' var name at this
-- layer -- there is no other in-memory 'Ident' to recover it from here,
-- so a fresh 'Ident' is minted per comparison for PB's case-insensitive
-- identifier equality, never for anything else.
bridgeIdent :: Text -> Ident
bridgeIdent = mkIdentSynthetic "PB.Explain.Simplify: PStmt carries only a flattened Text var name at this layer"

-- | Single backward pass over one straight-line run, mirroring
-- 'PB.Analysis.DeadVars.deadStoresInBlock'\'s own established backward-
-- liveness walk (same reason: a forward "scan to the next redefinition"
-- pass can be fooled by a later read that itself turns out to belong to a
-- statement the very same pass goes on to drop -- verified against a
-- Hedgehog counterexample, @b = a; a = b@ with neither read again,
-- where a forward scan kept @b = a@ only because @a = b@'s RHS reads
-- @b@, then dropped @a = b@ itself as dead, leaving a phantom
-- justification). @live@ threaded in is whatever the enclosing scope
-- needs from this list's own tail onward -- 'Set.empty' for a
-- top-level region call (the caller already excludes anything actually
-- live-out via 'simplifyPseudocode'\'s @eligibleFor@), or whatever the
-- branch\/loop's own enclosing list still needs for a nested arm\/body,
-- threaded through exactly as this same walk computes it, so a var
-- genuinely read later in the same region (even past this arm's own
-- close) is never mistaken for dead. A 'PRegionRef' is opaque at this
-- layer (no access to the referenced region's own reads), so hitting one
-- folds the entire @safe@ universe into "live" rather than guessing.
dropDeadStoresWithLiveOut :: IdentSet -> Set.Set Ident -> [PStmt] -> ([PStmt], Set.Set Ident)
dropDeadStoresWithLiveOut safe liveOut = foldr step ([], liveOut)
  where
    step stmt (acc, live) = case stmt of
      -- The full dotted/indexed LHS Expr (present for a member/indexed
      -- write like @adw.object.kodypal[row]@) is display-only here --
      -- liveness always keys on the assignment's root identifier (@var@),
      -- since that's what @safe@\/@locals@\/@sigOutputs@ are keyed on too.
      PAssign var _ _ rhs _
        | v `identSetMember` safe, not (v `Set.member` live) -> (acc, live)
        | otherwise -> (stmt : acc, Set.delete v live `Set.union` walkExprIdents rhs)
        where v = bridgeIdent var
      PCall _ _ args _ -> (stmt : acc, live `Set.union` foldMap walkExprIdents args)
      PReturn e _       -> (stmt : acc, live `Set.union` walkExprIdents e)
      PBranch cond t f ln ->
        let (t', liveT) = dropDeadStoresWithLiveOut safe live t
            (f', liveF) = dropDeadStoresWithLiveOut safe live f
        in (PBranch cond t' f' ln : acc, liveT `Set.union` liveF `Set.union` walkExprIdents cond)
      PLoop body ln ->
        let (body', liveBody) = dropDeadStoresWithLiveOut safe live body
        in (PLoop body' ln : acc, live `Set.union` liveBody)
      PRegionRef {} -> (stmt : acc, live `Set.union` Set.fromList (identSetToList safe))

-- | Drop a @PAssign@ whose var is in @safe@ (the caller's set of plain,
-- non-ref-parameter, non-live-out local names -- see 'simplifyPseudocode')
-- when it is not live -- read later in the same list, including past a
-- nested 'PBranch'\/'PLoop', per 'dropDeadStoresWithLiveOut'. Top-level
-- entry live is empty: the caller is responsible for excluding anything
-- actually live-out from @safe@ first.
dropDeadStores :: IdentSet -> [PStmt] -> [PStmt]
dropDeadStores safe stmts = fst (dropDeadStoresWithLiveOut safe Set.empty stmts)

-- | @if cond then return true else return false end if@ -> @return cond@
-- (and the mirrored negated-arm form); recurses into nested
-- 'PBranch'\/'PLoop' bodies since the pattern can occur at any nesting
-- depth, not just the top level of the list being simplified.
collapseBooleanBranch :: [PStmt] -> [PStmt]
collapseBooleanBranch = map rewrite
  where
    rewrite (PBranch cond [PReturn (ExBool True) _] [PReturn (ExBool False) _] ln) =
      PReturn cond ln
    rewrite (PBranch cond [PReturn (ExBool False) _] [PReturn (ExBool True) _] ln) =
      PReturn (ExNot cond) ln
    rewrite (PBranch cond t f ln) =
      PBranch cond (collapseBooleanBranch t) (collapseBooleanBranch f) ln
    rewrite (PLoop body ln) = PLoop (collapseBooleanBranch body) ln
    rewrite stmt = stmt

-- | Every 'RegionId' this 'Pseudocode' references, mapped to its own
-- 'InferredSignature' where known -- the root's via 'pcRootSig', every
-- other region's via whichever 'PRegionRef' (anywhere in 'pcRegions')
-- first refers to it. Mirrors 'PB.Explain.Render.Text'\'s own
-- @collectRefs@ walk, kept local since Layer 3.5 runs before Layer 4 and
-- has no reason to depend on it.
regionSignatures :: Pseudocode -> Map.Map RegionId InferredSignature
regionSignatures pc = Map.union rootEntry (Map.fromList (concatMap harvest (Map.elems (pcRegions pc))))
  where
    rootEntry = maybe Map.empty (Map.singleton (pcRootRegion pc)) (pcRootSig pc)
    harvest = concatMap go
    go (PRegionRef rid _ (Just sig)) = (rid, sig) : []
    go (PRegionRef _ _ Nothing)      = []
    go (PBranch _ t f _)             = harvest t <> harvest f
    go (PLoop body _)                = harvest body
    go _                             = []

-- | A declared 'FnSig'\/'SubSig'\'s ref-mode parameter names -- a store to
-- one is observable to the caller after return regardless of any
-- intra-procedure read, so it must never be treated as droppable no
-- matter what the caller passes in 'simplifyPseudocode'\'s own @locals@.
-- Derived here (not left to the caller) because 'Pseudocode' already
-- carries the declared signature via 'pcDeclaredSig' -- nothing else is
-- needed to get this right.
refParamNames :: Maybe (Either FnSig SubSig) -> IdentSet
refParamNames msig = identSetFromList (mapMaybe refName (either fnsParams ssParams =<< maybeToList msig))
  where
    refName p
      | any (\m -> T.toLower m == "ref") (paramMods p) = Just (paramName p)
      | otherwise = Nothing

-- | Names safe to drop a dead store to for one specific region: @locals@
-- (declared locals + params, from the caller) minus that region's own
-- live-out outputs (its 'InferredSignature' may make some of them
-- observable after the region ends with no local read at all) and minus
-- every ref-mode parameter (see 'refParamNames').
eligibleFor :: IdentSet -> IdentSet -> Maybe InferredSignature -> IdentSet
eligibleFor locals refParams msig =
  identSetDifference (identSetDifference locals refParams) (identSetFromList (maybe [] (map vbName . sigOutputs) msig))

-- | Run the fixed simplification pipeline over every region. @locals@ is
-- the set of plain local\/parameter surface names 'dropDeadStores' may
-- ever consider dropping a store to -- sourced by the caller from the
-- procedure's own declared locals\/params (e.g.
-- 'PB.Analysis.TypeResolve.LocalVar', scoped the same way
-- 'PB.Analysis.DeadVars.findDeadVars'\'s own caller already does), never
-- derived here: nothing upstream of 'Pseudocode' threads instance\/global-
-- vs-local variable classification through. A ref-mode parameter is
-- excluded automatically (see 'refParamNames') even if the caller's
-- @locals@ includes it.
simplifyPseudocode :: IdentSet -> Pseudocode -> Pseudocode
simplifyPseudocode locals pc = inlinePureRegions (inlineForwardingRegions pc')
  where
    pc' = pc { pcRegions = Map.mapWithKey simplifyRegion (pcRegions pc) }
    sigs = regionSignatures pc
    refParams = refParamNames (pcDeclaredSig pc)
    simplifyRegion rid stmts =
      collapseBooleanBranch (dropDeadStores (eligibleFor locals refParams (Map.lookup rid sigs)) stmts)

-- | A pure-forwarder region -- one whose entire body is a single
-- 'PRegionRef' and nothing else. The root is never a candidate even when
-- its own body happens to match: it is the procedure's real entry point
-- and must stay independently addressable by its own declared name.
forwardingRegions :: Pseudocode -> Map.Map RegionId (RegionId, Maybe (Int, Int), Maybe InferredSignature)
forwardingRegions pc = Map.fromList
  [ (rid, (target, lns, msig))
  | (rid, [PRegionRef target lns msig]) <- Map.toList (pcRegions pc)
  , rid /= pcRootRegion pc
  ]

-- | Follow a forwarding chain to its real, non-forwarding destination.
-- Each forwarder's own carried @(lns, msig)@ already describes its
-- immediate target's genuine line range and signature (every 'PRegionRef'
-- is built by looking those fields up keyed on the region actually being
-- referenced, never the referrer) -- so resolving one more hop, when the
-- immediate target is itself a forwarder, simply means discarding this
-- hop's own tuple in favor of the deeper one, not merging them.
resolveForwarding
  :: Map.Map RegionId (RegionId, Maybe (Int, Int), Maybe InferredSignature)
  -> RegionId
  -> Maybe (RegionId, Maybe (Int, Int), Maybe InferredSignature)
resolveForwarding forwarders rid = case Map.lookup rid forwarders of
  Nothing -> Nothing
  Just immediate@(target, _, _)
    | Map.member target forwarders -> resolveForwarding forwarders target
    | otherwise                    -> Just immediate

-- | Rewrite every 'PRegionRef' in a statement tree that targets a
-- forwarding region to point directly at its real, fully-resolved
-- destination; every other statement (and non-forwarded refs) is
-- unchanged. Recurses into 'PBranch'\/'PLoop' bodies, the same shape
-- 'dropDeadStoresWithLiveOut'\/'collapseBooleanBranch' already recurse
-- with.
retargetRefs
  :: Map.Map RegionId (RegionId, Maybe (Int, Int), Maybe InferredSignature)
  -> [PStmt] -> [PStmt]
retargetRefs forwarders = map rewrite
  where
    rewrite (PRegionRef rid lns msig) = case resolveForwarding forwarders rid of
      Just (target, lns', msig') -> PRegionRef target lns' msig'
      Nothing                    -> PRegionRef rid lns msig
    rewrite (PBranch cond t f ln) = PBranch cond (retargetRefs forwarders t) (retargetRefs forwarders f) ln
    rewrite (PLoop body ln)       = PLoop (retargetRefs forwarders body) ln
    rewrite stmt                  = stmt

-- | Drop every pure-forwarder region from 'pcRegions' and retarget every
-- remaining reference to point straight at the real destination a
-- forwarding chain ultimately led to. A whole chain collapses in one pass
-- (see 'resolveForwarding'), so this needs no repeated fixpoint
-- iteration of its own.
inlineForwardingRegions :: Pseudocode -> Pseudocode
inlineForwardingRegions pc = pc
  { pcRegions = Map.map (retargetRefs forwarders) (Map.withoutKeys (pcRegions pc) (Map.keysSet forwarders))
  }
  where
    forwarders = forwardingRegions pc

-- | 'RegionId's this 'Pseudocode' can safely fold back into their single
-- call site (Plan 227 Phase 2 Design goal 3): 'PB.Explain.Signatures.PureRegion'
-- kind (per the region's own carried 'InferredSignature'; see 'regionSignatures')
-- and referenced from exactly one 'PRegionRef' anywhere in the tree,
-- counted via 'collectRegionRefs' over every region's own (already
-- per-region-simplified) statement list. A region referenced from more
-- than one site keeps its own name rather than being duplicated into every
-- call site (mirrors the plan's own "surviving PureRegion... multiple call
-- sites" carve-out); a region that (indirectly) references itself is never
-- eligible either, since 'PB.Explain.Regions'' walk can only ever produce
-- a DAG, so a genuine self-reference always counts as a second referrer.
inlinablePureRegions :: Pseudocode -> Map.Map RegionId [PStmt]
inlinablePureRegions pc = Map.filterWithKey eligible (pcRegions pc)
  where
    counts = Map.fromListWith (+)
      [ (rid, 1 :: Int)
      | stmts <- Map.elems (pcRegions pc)
      , (rid, _, _) <- collectRegionRefs stmts
      ]
    sigs = regionSignatures pc
    eligible rid _ =
      rid /= pcRootRegion pc
      && Map.findWithDefault 0 rid counts == 1
      && maybe False ((== PureRegion) . sigKind) (Map.lookup rid sigs)

-- | Recursively substitute every 'PRegionRef' targeting an
-- 'inlinablePureRegions' entry with that region's own body, expanding the
-- same way for any further pure region it references in turn -- so a chain
-- of pure regions collapses in one pass, the same shape 'resolveForwarding'
-- follows for a chain of pure forwarders.
expandPureRefs :: Map.Map RegionId [PStmt] -> [PStmt] -> [PStmt]
expandPureRefs pureBodies = concatMap rewrite
  where
    rewrite (PRegionRef rid _ _)
      | Just body <- Map.lookup rid pureBodies = expandPureRefs pureBodies body
    rewrite (PBranch cond t f ln) = [PBranch cond (expandPureRefs pureBodies t) (expandPureRefs pureBodies f) ln]
    rewrite (PLoop body ln)       = [PLoop (expandPureRefs pureBodies body) ln]
    rewrite stmt                  = [stmt]

-- | Fold every singly-referenced 'PB.Explain.Signatures.PureRegion' cut
-- back into its own call site's statement list and drop it from
-- 'pcRegions' entirely, so a pure region the effect-boundary cutter still
-- produces (Open Question 3 in doc/plan/227-explain-effect-boundary-regions.md:
-- the complexity-threshold fallback can still cut a long pure run with no
-- effect boundary to justify it) never surfaces as its own named block in
-- the rendered output.
inlinePureRegions :: Pseudocode -> Pseudocode
inlinePureRegions pc = pc
  { pcRegions = Map.map (expandPureRefs pureBodies) (Map.withoutKeys (pcRegions pc) (Map.keysSet pureBodies))
  }
  where
    pureBodies = inlinablePureRegions pc
