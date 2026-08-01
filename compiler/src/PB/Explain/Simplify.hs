-- | Simplification passes over 'PB.Explain.Pseudocode.Pseudocode' (Plan 218
-- Layer 3.5): a fixed pipeline of named sub-passes run over every region's
-- own @[PStmt]@, each independently testable and a no-op when its pattern
-- doesn't match. Applied between Layer 3 and Layer 4
-- (@renderText (simplifyPseudocode locals pc)@), not folded into
-- 'PB.Explain.Render.Text' itself -- every future renderer wants the same
-- cleanup, and 'PB.Explain.Render.Text' stays the plainest possible
-- printer. "Semantics-preserving" here means preserving each region's own
-- 'PB.Explain.Signatures.InferredSignature' and observable PowerScript
-- behavior, not a formal proof -- enforced by hand-written tests per pass
-- plus a Hedgehog idempotence property, not a verified equivalence to the
-- original 'PB.Compile.IR.Eff'.
module PB.Explain.Simplify
  ( simplifyPseudocode
  , dropDeadStores
  , collapseBooleanBranch
  ) where

import PB.Prelude
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import PB.AST.Expr (Expr (..))
import PB.AST.Ident (Ident, IdentSet, identSetDifference, identSetFromList, identSetMember, identSetToList, mkIdentSynthetic)
import PB.AST.SourceFile (FnSig (..), Param (..), SubSig (..))
import PB.Analysis.Dataflow (walkExprIdents)
import PB.Explain.Pseudocode (PStmt (..), Pseudocode (..))
import PB.Explain.Regions (RegionId)
import PB.Explain.Signatures (InferredSignature (..), VarBinding (..))

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
      PAssign var _ rhs _
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
simplifyPseudocode locals pc = pc { pcRegions = Map.mapWithKey simplifyRegion (pcRegions pc) }
  where
    sigs = regionSignatures pc
    refParams = refParamNames (pcDeclaredSig pc)
    simplifyRegion rid stmts =
      collapseBooleanBranch (dropDeadStores (eligibleFor locals refParams (Map.lookup rid sigs)) stmts)
