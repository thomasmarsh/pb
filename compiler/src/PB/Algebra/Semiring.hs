-- | Semiring algebra for fixed-point / graph-closure computations.
--
-- A semiring @(s, 'zero', 'one', ('.+.'), ('.*.))@ lets us express transitive
-- closure (Kleene star) uniformly: 'PB.Algebra.Closure.star' is the
-- fixpoint of @r ↣ r '.+.' (r '.*.' r)@.  Picking the semiring
-- picks the analysis:
--
--   * 'Boolean'    — reachability (idempotent union).
--   * 'PathValue' — shortest path + witness edge, for path reconstruction.
--   * 'MinPlus'   — shortest path with an arbitrary payload.
--
-- See doc/plan/182-algebraic-analysis.md.
module PB.Algebra.Semiring
  ( Semiring (..)
  , Boolean (..)
  , PathValue (..)
  , MinPlus (..)
  , addS
  , mulS
  ) where

import PB.Prelude
import Data.Semigroup (Sum (..))

infixr 6 .+.
infixr 7 .*.

-- | A semiring: a commutative monoid under '.+.' (additive) and a monoid
-- under '.*.' (multiplicative), with '.*.' distributing over '.+.'.
-- Distributivity holds by construction for every instance below.
class Semiring s where
  zero :: s
  one  :: s
  (.+.) :: s -> s -> s   -- ^ additive: choice / union
  (.*.) :: s -> s -> s   -- ^ multiplicative: sequence / compose

-- | Named wrappers around the class operators, so call sites (notably
-- qualified use across modules) can avoid operator syntax entirely.
addS :: Semiring s => s -> s -> s
addS = (.+.)

mulS :: Semiring s => s -> s -> s
mulS = (.*.)

-- | Boolean semiring: reachability.  Additive is idempotent OR.
newtype Boolean = Boolean { getBoolean :: Bool }
  deriving (Eq, Show)

instance Semiring Boolean where
  zero                     = Boolean False
  one                      = Boolean True
  Boolean a .+. Boolean b = Boolean (a || b)
  Boolean a .*. Boolean b = Boolean (a && b)

-- | Shortest-path semiring carrying a witness for reconstruction.
--
-- A 'PathValue' for arc (i → j) stores the minimum hop count and, for
-- the last step of the path, the edge label and the predecessor node — enough
-- to backtrack a concrete witness via 'PB.Algebra.Closure.reconstructPath'.
--
-- Invariant for a /direct/ arc i→j: @pvPred == i@ and 'pvLastEdge'
-- is the label of i→j.  For a composed arc i→…→j, 'pvPred' is the
-- node immediately before j, and 'pvLastEdge' is j's incoming edge.
--
-- 'Unreachable' is 'zero'; the 0-hop identity (i → i) is
-- 'Reachable 0 Nothing (-1)' (no last edge, predecessor is self).
data PathValue e
  = Unreachable
  | Reachable
      { pvHops     :: Int        -- ^ hop count i → j
      , pvLastEdge :: Maybe e   -- ^ label of the final edge (pred → j); Nothing only for the 0-hop identity
      , pvPred     :: Int        -- ^ predecessor of j on the min path (the split node)
      }
  deriving (Eq, Show)

instance Semiring (PathValue e) where
  zero = Unreachable
  one  = Reachable 0 Nothing (-1)
  Unreachable .+. q = q
  p .+. Unreachable = p
  p@(Reachable hp _ _) .+. q@(Reachable hq _ _) =
    if hp < hq then p else if hq < hp then q else p   -- deterministic tie-break
  Unreachable .*. _ = Unreachable
  _ .*. Unreachable = Unreachable
  Reachable hp _ _ .*. Reachable hq eq kq = Reachable (hp + hq) eq kq

-- | Tropical / min-plus semiring with an arbitrary payload 'a'.
--
-- 'zero' is unreachable; 'one' is the 0-distance identity carrying 'mempty'.
-- The payload of a composed path takes the SECOND factor's payload, so a
-- composed value carries the sink-side payload (e.g. a taint sink type).
newtype MinPlus a = MinPlus { getMinPlus :: Maybe (Sum Int, a) }
  deriving (Eq, Show)

instance Monoid a => Semiring (MinPlus a) where
  zero = MinPlus Nothing
  one  = MinPlus (Just (Sum 0, mempty))
  MinPlus Nothing .+. q = q
  p .+. MinPlus Nothing = p
  p@(MinPlus (Just (d1, _))) .+. q@(MinPlus (Just (d2, _))) =
    if d1 <= d2 then p else q
  MinPlus Nothing .*. _ = MinPlus Nothing
  _ .*. MinPlus Nothing = MinPlus Nothing
  MinPlus (Just (d1, _)) .*. MinPlus (Just (d2, a2)) =
    MinPlus (Just (d1 <> d2, a2))
