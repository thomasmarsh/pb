module PB.Prelude
  ( module X
  , Text
  ) where

import Prelude as X hiding
  ( head, tail, init, last
  , (!!)
  , maximum, minimum
  , foldl1, foldr1
  , scanl1, scanr1
  , cycle
  , read
  , undefined
  , putStr, putStrLn, print
  , getLine, getContents, interact
  , readFile, writeFile, appendFile
  , lines, unlines, words, unwords
  )

import Control.Arrow as X ((>>>))
import Data.Maybe    as X ( fromMaybe, catMaybes, mapMaybe
                          , listToMaybe, maybeToList
                          , isJust, isNothing )
import Data.Either   as X ( fromLeft, fromRight, partitionEithers
                          , isLeft, isRight )
import Data.Void     as X ( Void, absurd )
import Data.Function as X ( on )
import Data.Text.IO  as X ( putStr, putStrLn
                          , readFile, writeFile, appendFile
                          , getLine )

import Data.Text (Text)
