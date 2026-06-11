module PB.Pipeline.Walk
  ( walkFiles
  , walkPsFiles
  , walkDwFiles
  , walkAllSrFiles
  ) where

import PB.Prelude

import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath  (takeExtension, (</>))

-- | Recursively collect files matching a predicate under a root directory.
walkFiles :: (FilePath -> Bool) -> FilePath -> IO [FilePath]
walkFiles keep root = do
  entries <- listDirectory root
  fmap concat $ mapM step entries
  where
    step entry = do
      let path = root </> entry
      isDir <- doesDirectoryExist path
      if isDir
        then walkFiles keep path
        else pure [path | keep path]

-- | All PowerScript source files (.srf .srw .sru .srm .sra .srx).
walkPsFiles :: FilePath -> IO [FilePath]
walkPsFiles = walkFiles isPsExt

-- | DataWindow source files (.srd).
walkDwFiles :: FilePath -> IO [FilePath]
walkDwFiles = walkFiles ((== ".srd") . takeExtension)

-- | Any PowerBuilder export file (.sr<single-char>).
walkAllSrFiles :: FilePath -> IO [FilePath]
walkAllSrFiles = walkFiles isSrExt

isPsExt :: FilePath -> Bool
isPsExt fp = takeExtension fp `elem` [".srf", ".srw", ".sru", ".srm", ".sra", ".srx"]

isSrExt :: FilePath -> Bool
isSrExt fp = case splitAt 3 (takeExtension fp) of
  (".sr", [_]) -> True
  _            -> False
