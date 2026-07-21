module RepoRoot (repoRoot) where

import PB.Prelude
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath  (takeDirectory, (</>))

-- | Locates the pb repo root by walking upward from the current working
-- directory until an ancestor whose @compiler@ subdirectory contains
-- @pb-compiler.cabal@ is found. Needed because Cabal always runs a built
-- test-suite binary with cwd = the package directory (@compiler/@)
-- regardless of which directory @cabal test@ itself was invoked from, but
-- corpus fixtures live in @example/@ at the repo root, one level up.
repoRoot :: IO FilePath
repoRoot = getCurrentDirectory >>= go
  where
    go dir = do
      here <- doesFileExist (dir </> "compiler" </> "pb-compiler.cabal")
      if here
        then pure dir
        else
          let parent = takeDirectory dir
          in if parent == dir
               then error "impossible: repo root not found (no ancestor directory contains compiler/pb-compiler.cabal)"
               else go parent
