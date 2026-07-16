-- | Semantic clone-family grouping over canonical instruction-graph shapes
-- ('PB.Compile.InstrTypes.canonicalize'). Two procedures with 'Eq'-equal
-- canonical shapes are exact structural clones of each other.
module PB.Analysis.CloneDetect
  ( CloneFamily (..)
  , cloneFamilies
  ) where

import PB.Prelude
import PB.Compile.InstrTypes (ShapeNode)

import qualified Data.Map.Strict as Map

data CloneFamily = CloneFamily
  { cfShape   :: [ShapeNode]
  , cfMembers :: [(Text, Text)]
  } deriving (Eq, Show)

-- | Groups (object, procedure, canonical shape) triples by exact shape
-- equality. Families of size 1 are included -- filtering to size >= 2 (the
-- "interesting" clones) is the report/consumer's judgment call, not this
-- primitive's. Families are ordered by 'Ord ShapeNode' on their shape (not
-- input order); 'cfMembers' preserves input order within a family.
cloneFamilies :: [(Text, Text, [ShapeNode])] -> [CloneFamily]
cloneFamilies triples =
  [ CloneFamily shape members
  | (shape, members) <- Map.toList grouped
  ]
  where
    grouped = Map.fromListWith (flip (<>))
      [ (shape, [(obj, proc)]) | (obj, proc, shape) <- triples ]
