{-# LANGUAGE StrictData #-}
module PB.AST.Located
  ( Located (..)
  ) where

import PB.Prelude
import GHC.Generics (Generic)

-- | Annotate any AST node with the source line it started on.
data Located a = Located
  { locLine :: Int
  , locNode :: a
  } deriving (Eq, Show, Generic)
