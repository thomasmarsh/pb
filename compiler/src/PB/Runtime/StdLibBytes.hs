{-# LANGUAGE TemplateHaskell #-}
module PB.Runtime.StdLibBytes (stdlibBytes) where

import PB.Prelude
import Data.FileEmbed (embedDir)
import qualified Data.ByteString as BS

-- Embedded at compile time from runtime/ at the repo root (../runtime
-- relative to compiler/). 'embedDir' only registers a GHC recompilation
-- dependency on files present at the time it last spliced -- adding a new
-- runtime/*.sru file requires forcing this module to actually recompile
-- (not just relink) once, e.g. via 'cabal clean' or touching this file's
-- content, or the new file silently never reaches a consumer.
--
-- Kept as its own leaf module (no 'PB.Pipeline.*'/'PB.Analysis.*' imports)
-- so both 'PB.Runtime.StdLib' (full parse pipeline) and
-- 'PB.Runtime.EffectAnnotations' (raw-text annotation scan, consumed by
-- 'PB.Analysis.CallClassify') can depend on the same embedded bytes
-- without 'PB.Analysis.CallClassify' importing 'PB.Runtime.StdLib' itself
-- -- that would cycle back through 'PB.Pipeline.Emit' /
-- 'PB.Compile.Flatten', which already imports 'PB.Analysis.CallClassify'.
stdlibBytes :: [(FilePath, BS.ByteString)]
stdlibBytes = $(embedDir "../runtime")
