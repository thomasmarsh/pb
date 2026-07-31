{-# LANGUAGE StrictData #-}
-- | Procedure-level effect closure: a transitive per-procedure effect set
-- over the resolved call graph, mirroring 'PB.Analysis.TaintClosure'\/
-- 'PB.Analysis.SchemaClosure''s shape (intern nodes, build a
-- 'PB.Algebra.Closure.Relation' over a 'PB.Algebra.Semiring' instance, call
-- 'PB.Algebra.Closure.reachFrom') rather than a bespoke recursive walk.
--
-- 'EffectSetLabel' weights each call edge by its DESTINATION node's own
-- direct effect tags, so 'reachFrom''s worklist relaxation accumulates, at
-- each reachable node, the union of every node's tags encountered on any
-- path from the source — an idempotent-union semiring converges to the
-- true union over all paths, not just one shortest path (unlike
-- 'PB.Algebra.Semiring.PathValue''s hop-count tie-break).
--
-- See doc/plan/220-effect-capability-system.md Layer 4.
module PB.Analysis.EffectClosure
  ( EffectSetLabel (..)
  , foldEffectClosureEff
  , computeProcEffectClosure
  , materializeProcEffects
  ) where

import PB.Prelude
import Control.DeepSeq (NFData (..))
import PB.Algebra.Semiring (Semiring (..))
import PB.Algebra.Closure
  ( emptyInterner
  , intern
  , internByVal
  , fromEdges
  , reachFrom
  )
import PB.Analysis.CallClassify (EffectTag)
import PB.Compile.IR (Eff (..), EffTerm (..))
import PB.Pipeline.DuckDb (Handle, recreateTextTable, appendTextRows)

import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap.Strict as IM
import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

-- | Semiring label carrying the union of effect tags accumulated along a
-- call-graph path. Payload is 'Maybe'-wrapped (mirroring
-- 'PB.Algebra.Semiring.MinPlus''s own "unreached vs. reached-with-trivial-
-- payload" shape) so 'zero' (unreached) stays distinguishable from 'one'
-- (reached, no tags yet) even when the accumulated tag set is empty --
-- without this, 'zero' and a genuinely-reached-but-so-far-untagged node
-- would compare equal, and 'PB.Algebra.Closure.reachFrom''s worklist
-- (which only enqueues a node when its relaxed value changes) would never
-- insert or explore that node's own outgoing edges, silently dropping
-- everything reachable only through it. '(.+.)'\/'(.*.)' are otherwise the
-- same associative\/commutative union once both sides are 'Just' --
-- sequencing two calls doesn't change *which* effects are present, only
-- their union.
newtype EffectSetLabel = EffectSetLabel (Maybe (Set.Set EffectTag))
  deriving (Eq, Show)

instance Semiring EffectSetLabel where
  zero = EffectSetLabel Nothing
  one  = EffectSetLabel (Just Set.empty)
  EffectSetLabel Nothing .+. q                     = q
  p                      .+. EffectSetLabel Nothing = p
  EffectSetLabel (Just a) .+. EffectSetLabel (Just b) = EffectSetLabel (Just (Set.union a b))
  EffectSetLabel Nothing .*. _                     = EffectSetLabel Nothing
  _                      .*. EffectSetLabel Nothing = EffectSetLabel Nothing
  EffectSetLabel (Just a) .*. EffectSetLabel (Just b) = EffectSetLabel (Just (Set.union a b))

instance NFData EffectSetLabel where
  rnf (EffectSetLabel s) = rnf s

-- | Unwrap a label to the tag set it carries, treating 'zero' (unreached)
-- as the empty set -- only used once a node is already known-reached (a
-- key present in a 'reachFrom' row), so the 'zero' case never actually
-- arises in 'computeProcEffectClosure' below; total anyway for safety.
effectTagsOf :: EffectSetLabel -> Set.Set EffectTag
effectTagsOf (EffectSetLabel m) = fromMaybe Set.empty m

-- | Direct effect tags for one procedure: the union of every 'ECall'\/
-- 'ESuspend' leaf's own tag set within the compiled 'EffTerm'. Mirrors
-- 'PB.Analysis.SchFootprint.foldSchFootprintEff''s walk\/memo shape (a
-- direct fold, not the generic 'PB.Compile.IR.foldFreyd' instance-dispatch
-- route), minus the 'FunctorCtx' that fold needs for its own
-- 'resolveSetItem' lookup -- this fold only reads the tag already stored on
-- each leaf, no external context required.
foldEffectClosureEff :: EffTerm a b -> Set.Set EffectTag
foldEffectClosureEff (EffTerm spine table) = fst (go spine Map.empty)
  where
    go :: Eff x y -> Map.Map Text (Set.Set EffectTag)
       -> (Set.Set EffectTag, Map.Map Text (Set.Set EffectTag))
    go (J _)                      m = (Set.empty, m)
    go (EComp g f)                m = let (rg, m1) = go g m in let (rf, m2) = go f m1 in (rg <> rf, m2)
    go (EAssign _ _ _)            m = (Set.empty, m)
    go (EAssignWithRhs _ _ _ _ _) m = (Set.empty, m)
    go (ECall _ _ _ tags)         m = (tags, m)
    go (ESuspend _ _ _ tags)      m = (tags, m)
    go ESplitValue                m = (Set.empty, m)
    go (EFanIn t f)                m = let (rt, m1) = go t m in let (rf, m2) = go f m1 in (rt <> rf, m2)
    go (EBranch _ t f _)          m = let (rt, m1) = go t m in let (rf, m2) = go f m1 in (rt <> rf, m2)
    go (ELoop body _)             m = go body m
    go (EReturn _ _)              m = (Set.empty, m)
    go (ELetRef bid)              m = case Map.lookup bid m of
      Just cached -> (cached, m)
      Nothing     -> case Map.lookup bid table of
        Just body -> let (r, m') = go body m in (r, Map.insert bid r m')
        Nothing   -> error ("foldEffectClosureEff: unbound ELetRef " <> show bid)

-- | Transitive per-procedure effect closure over the resolved call graph.
-- @seedRows@ is every procedure's own direct tags (from
-- 'foldEffectClosureEff'); @edges@ is @(callerObj, callerProc, calleeObj,
-- calleeProc)@ resolved call edges, reusing whatever relation
-- 'PB.Analysis.TaintClosure'\/'PB.Analysis.SchemaClosure' already consume
-- (not re-derived here). An edge whose callee has no seed row (an
-- unresolved\/external call) contributes 'Set.empty', not an error.
computeProcEffectClosure
  :: [(Text, Text, Set.Set EffectTag)]
  -> [(Text, Text, Text, Text)]
  -> Map.Map (Text, Text) (Set.Set EffectTag)
computeProcEffectClosure seedRows edges =
  let directMap = Map.fromList [ ((o, p), tags) | (o, p, tags) <- seedRows ]
      directOf n = Map.findWithDefault Set.empty n directMap
      allNodes = Set.toList (Set.fromList
        ([ (o, p) | (o, p, _) <- seedRows ]
          ++ concatMap (\(co, cp, ceo, cep) -> [(co, cp), (ceo, cep)]) edges))
      interner = L.foldl' (\acc n -> snd (intern n acc)) emptyInterner allNodes
      idOf n = HM.lookup n (internByVal interner)
      rawArcs =
        [ (ci, ei, EffectSetLabel (Just (directOf (ceo, cep))))
        | (co, cp, ceo, cep) <- edges
        , Just ci <- [idOf (co, cp)]
        , Just ei <- [idOf (ceo, cep)]
        ]
      rel = fromEdges rawArcs
      seedIds = [ i | n <- allNodes, Just i <- [idOf n] ]
      reachAll = reachFrom rel seedIds
  in Map.fromList
       [ (n, Set.union (directOf n) unionOfReached)
       | n <- allNodes
       , Just nid <- [idOf n]
       , let row = IM.findWithDefault IM.empty nid reachAll
             unionOfReached = Set.unions (map effectTagsOf (IM.elems row))
       ]

-- | Materialize 'computeProcEffectClosure''s result as @proc_effects@: one
-- row per @(object, proc_name, effect_tag)@ -- the normalized shape
-- 'PB.Analysis.TaintEdges''s @taint_intra_edges@\/@taint_return_rows@
-- already use for a set-valued fact, not a comma-joined 'Text' column. A
-- procedure whose closure is genuinely empty gets zero rows (absence is
-- purity, per Plan 220's own framing). Returns the computed 'Map' so a
-- caller doesn't need a second closure computation to use it in-memory.
materializeProcEffects
  :: [(Text, Text, Set.Set EffectTag)]
  -> [(Text, Text, Text, Text)]
  -> Handle
  -> IO (Map.Map (Text, Text) (Set.Set EffectTag))
materializeProcEffects seedRows edges conn = do
  let closure = computeProcEffectClosure seedRows edges
      rows =
        [ [o, p, T.pack (show tag)]
        | ((o, p), tags) <- Map.toList closure
        , tag <- Set.toList tags
        ]
  recreateTextTable conn "proc_effects" ["object", "proc_name", "effect_tag"]
  appendTextRows conn "proc_effects" rows
  pure closure
