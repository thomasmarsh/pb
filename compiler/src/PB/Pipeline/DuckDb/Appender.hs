module PB.Pipeline.DuckDb.Appender
  ( AppenderPool
  , withAppenderPool
  , withAppenderPoolTimed
  , appendRow
  , forEachRow
  ) where

import PB.Prelude
import PB.Pipeline.DuckDb (Handle, withHandleConnection, checkSt, checkAppenderSt)
import PB.Pipeline.Progress    qualified as Progress

import Database.DuckDB.FFI
  ( c_duckdb_appender_create
  , c_duckdb_appender_flush
  , c_duckdb_appender_destroy
  , c_duckdb_appender_end_row
  , DuckDBAppender
  )

import qualified Data.ByteString         as BS
import qualified Data.Map.Strict         as Map
import qualified Data.Text               as T
import qualified Data.Text.Encoding      as TE
import           Control.Exception       (bracket, bracket_)
import           Foreign                 (alloca, nullPtr, peek, poke)

-- | A set of long-lived DuckDB appenders, one per table. Created once after
-- 'PB.Pipeline.DuckDb.initSchema' and destroyed (flush + destroy) once at the
-- Phase A/B boundary. This avoids the ~13K create/flush/destroy FFI cycles
-- that per-file appenders would otherwise require (Plan 169 Finding 1+2).
newtype AppenderPool = AppenderPool (Map.Map Text DuckDBAppender)

-- | Create one appender per table name, then run @action@. All appenders are
-- flushed and destroyed when the scope exits (even on exception).
withAppenderPool :: Handle -> [Text] -> (AppenderPool -> IO a) -> IO a
withAppenderPool = withAppenderPoolTimed (\_ -> pure ())

-- | Like 'withAppenderPool', but times the flush+destroy teardown via
-- @sink@ (typically 'Progress.emitEvent') -- the only potentially slow part
-- of this scope's exit (on a large corpus, flushing every buffered
-- appender is real I/O), and a span a 'bracket' cleanup can't otherwise be
-- timed from outside its own scope: by the time control returns to the
-- caller of 'withAppenderPool', the flush has already silently happened.
withAppenderPoolTimed
  :: (Progress.ProgressEvent -> IO ()) -> Handle -> [Text] -> (AppenderPool -> IO a) -> IO a
withAppenderPoolTimed sink conn tables action =
  withHandleConnection conn $ \rawConn ->
    bracket
      (createAll rawConn tables)
      (\pool -> Progress.timedStepTo sink "Flushing Phase A appender pool" (destroyAll pool))
      (\pool -> action (AppenderPool pool))
  where
    createAll _ [] = pure Map.empty
    createAll rawConn (t:ts) = do
      app <- alloca $ \appPtr -> do
        checkSt "appender_create" =<<
          BS.useAsCString (TE.encodeUtf8 t) (\tn ->
            c_duckdb_appender_create rawConn nullPtr tn appPtr)
        peek appPtr
      rest <- createAll rawConn ts
      pure (Map.insert t app rest)

    destroyAll pool = for_ (Map.toList pool) $ \(tbl, app) -> do
      st <- c_duckdb_appender_flush app
      checkAppenderSt ("appender_flush:" <> T.unpack tbl) app st
      alloca $ \appPtrPtr -> do
        poke appPtrPtr app
        void $ c_duckdb_appender_destroy appPtrPtr

-- | Append rows to a pooled table. Errors if the table is not in the pool
-- (programmer error — all table names are compile-time literals).
-- Flush happens once in 'withAppenderPool' teardown, not per call.
appendRow :: AppenderPool -> Text -> (DuckDBAppender -> IO ()) -> IO ()
appendRow (AppenderPool pool) tbl action =
  case Map.lookup tbl pool of
    Nothing -> error ("impossible: appender pool missing table " <> T.unpack tbl)
    Just app -> action app

-- | Write each row via @writeRow app row@, guaranteeing 'endRow' is called
-- exactly once after each row (bracketed). A forgotten 'endRow' can never
-- leave an un-finalized appender row — this is what made the 182b
-- 'appender_flush' bug impossible to repeat. Every 'append*' function routes
-- its per-row column marshalling through this helper instead of calling
-- 'endRow' directly. See compiler/AGENTS.md's "Appender-pool failure modes"
-- subsection.
forEachRow :: DuckDBAppender -> [row] -> (DuckDBAppender -> row -> IO ()) -> IO ()
forEachRow app rows writeRow = for_ rows $ \r -> bracket_ (pure ()) (endRow app) (writeRow app r)

endRow :: DuckDBAppender -> IO ()
endRow app = checkSt "appender_end_row" =<< c_duckdb_appender_end_row app
