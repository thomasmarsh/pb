{-# LANGUAGE StrictData #-}
module PB.AST.Located
  ( Located (..)
  ) where

import PB.Prelude
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

-- | Annotate any AST node with the source line it started on.
data Located a = Located
  { locLine :: Int
  , locNode :: a
  } deriving (Eq, Show, Generic)

instance NFData a => NFData (Located a)
