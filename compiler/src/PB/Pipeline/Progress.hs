-- | Structured pipeline progress events: a typed replacement for hand-built
-- @Data.Aeson.object@ literals at every 'PB.Pipeline.Passes' emission site,
-- plus the generic timing/heartbeat helpers that let a caller wrap any
-- long-running step without inventing a bespoke callback each time.
module PB.Pipeline.Progress
  ( ProgressEvent (..)
  , RowCounts
  , emitEvent
  , stampEvent
  , stampValue
  , elapsedSinceStartMs
  , timedStepTo
  , timedStep
  , timedStepRowsTo
  , timedStepRows
  , withHeartbeat
  , residencySnapshot
  , msBetween
  ) where

import PB.Prelude

import Control.Concurrent       (threadDelay)
import Control.Concurrent.Async (race)
import Control.Monad            (forever)
import Data.Aeson               (ToJSON (..), Value (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef                (IORef, newIORef, readIORef, writeIORef)
import Data.Time.Clock           (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import GHC.Stats
  (RTSStats (gc), getRTSStats, getRTSStatsEnabled, GCDetails (gcdetails_live_bytes))
import System.IO                (hFlush, stderr)
import System.IO.Unsafe          (unsafePerformIO)
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BSL

-- | Row counts keyed by relation/table name, in emission order.
type RowCounts = [(Text, Int)]

-- | One progress event emitted to stderr as a single JSON object for the
-- Python reporter to consume. 'EvStep' carries every optional field a
-- caller might have on hand (elapsed time, input/derived row counts, live-heap
-- residency) rather than composing them into 'evLabel' prose by hand.
data ProgressEvent
  = EvPhase
      { evName :: Text
      }
  | EvStep
      { evLabel       :: Text
      , evElapsedMs   :: Maybe Double
      , evInputRows   :: RowCounts
      , evDerivedRows :: RowCounts
      , evResidencyMb :: Maybe Double
      }
  | EvWarning
      { evMessage :: Text
      }
  deriving (Eq, Show)

-- | Wire shape: @"tag"@/@"label"@ always present on 'EvStep'; every optional
-- field (@elapsed_ms@/@input_rows@/@derived_rows@/@residency_mb@) is omitted, not
-- rendered @null@, when unset -- keeps the common-case payload identical to
-- the bare @{"tag":"step","label":...}@ shape the Python reporter already
-- parses (it reads @event["label"]@ only), so this is a pure wire-format
-- addition, not a breaking change.
instance ToJSON ProgressEvent where
  toJSON (EvPhase name) = object [ "tag" .= ("phase" :: Text), "name" .= name ]
  toJSON (EvWarning msg) = object [ "tag" .= ("warning" :: Text), "message" .= msg ]
  toJSON (EvStep label mElapsed inputRows derivedRows mResidency) = object
    ( [ "tag" .= ("step" :: Text), "label" .= label ]
      <> optField "elapsed_ms"   mElapsed
      <> rowsField "input_rows"    inputRows
      <> rowsField "derived_rows"  derivedRows
      <> optField "residency_mb" mResidency
    )
    where
      optField _ Nothing    = []
      optField k (Just v)   = [ Key.fromText k .= (v :: Double) ]
      rowsField _ []        = []
      rowsField k rows      = [ Key.fromText k .= rowsObject rows ]
      rowsObject rows       = object [ Key.fromText k .= (v :: Int) | (k, v) <- rows ]

-- | Origin every event's 'elapsedSinceStartMs' is measured from -- the
-- moment the first progress event was emitted, not literally process
-- start (nothing before the first event needs a timestamp). A top-level
-- mutable cell is the only way to give 'emitEvent' (the single choke point
-- every event flows through) implicit access to this origin without
-- threading it as an explicit parameter through every existing
-- 'timedStep'\/'timedStepRows'\/report-function call site.
processStartRef :: IORef (Maybe UTCTime)
{-# NOINLINE processStartRef #-}
processStartRef = unsafePerformIO (newIORef Nothing)

-- | Milliseconds since the first progress event was emitted (0 on that
-- first call itself). Absolute, not "since the previous event" -- stays
-- correct regardless of how many threads\/workers emit events, unlike a
-- since-last-checkpoint delta (which silently assumes a single sequential
-- emitter, the assumption 'PB.Pipeline.Passes.reportTaintCounts' relies
-- on today for Phase B specifically).
elapsedSinceStartMs :: IO Double
elapsedSinceStartMs = do
  now <- getCurrentTime
  mStart <- readIORef processStartRef
  case mStart of
    Just start -> pure (msBetween start now)
    Nothing    -> do
      writeIORef processStartRef (Just now)
      pure 0

-- | Insert @since_start_ms@ into a JSON object value -- the shared
-- primitive behind 'stampEvent' (typed 'ProgressEvent's) and
-- 'PB.Pipeline.Runner.emitProgress' (Phase A's own hand-built 'Value'
-- literals, predating 'ProgressEvent' and not worth re-typing wholesale
-- just for this). Every progress event on either path encodes to a JSON
-- object, so the wildcard branch is unreached in practice but kept as a
-- harmless no-op rather than a partial pattern match.
stampValue :: Double -> Value -> Value
stampValue sinceStartMs v = case v of
  Object o -> Object (KeyMap.insert "since_start_ms" (toJSON sinceStartMs) o)
  _        -> v

-- | Insert @since_start_ms@ into an already-encoded 'ProgressEvent'.
stampEvent :: Double -> ProgressEvent -> Value
stampEvent sinceStartMs ev = stampValue sinceStartMs (toJSON ev)

-- | Write one 'ProgressEvent' to stderr as a single line of JSON, stamped
-- with 'elapsedSinceStartMs'.
emitEvent :: ProgressEvent -> IO ()
emitEvent ev = do
  sinceStartMs <- elapsedSinceStartMs
  BS.hPut stderr (BSL.toStrict (encode (stampEvent sinceStartMs ev)) <> "\n")
  hFlush stderr

-- | Wrap an 'IO' action with a start 'EvStep' (no timing yet) and an end
-- 'EvStep' (elapsed time since the start event), sent to the given sink
-- rather than hardcoded to 'emitEvent' -- the seam a test injects a
-- recording sink through.
timedStepTo :: (ProgressEvent -> IO ()) -> Text -> IO a -> IO a
timedStepTo sink label action = do
  sink (EvStep label Nothing [] [] Nothing)
  t0 <- getCurrentTime
  result <- action
  t1 <- getCurrentTime
  mResidency <- residencySnapshot
  sink (EvStep label (Just (msBetween t0 t1)) [] [] mResidency)
  pure result

-- | 'timedStepTo' specialized to 'emitEvent'.
timedStep :: Text -> IO a -> IO a
timedStep = timedStepTo emitEvent

-- | Like 'timedStepTo', but the wrapped action also produces its own
-- 'RowCounts' (e.g. a relation-materialization step), attached to the end
-- event's 'evDerivedRows'.
timedStepRowsTo :: (ProgressEvent -> IO ()) -> Text -> IO (a, RowCounts) -> IO a
timedStepRowsTo sink label action = do
  sink (EvStep label Nothing [] [] Nothing)
  t0 <- getCurrentTime
  (result, rows) <- action
  t1 <- getCurrentTime
  mResidency <- residencySnapshot
  sink (EvStep label (Just (msBetween t0 t1)) [] rows mResidency)
  pure result

-- | 'timedStepRowsTo' specialized to 'emitEvent'.
timedStepRows :: Text -> IO (a, RowCounts) -> IO a
timedStepRows = timedStepRowsTo emitEvent

-- | Milliseconds elapsed between two timestamps.
msBetween :: UTCTime -> UTCTime -> Double
msBetween t0 t1 = realToFrac (diffUTCTime t1 t0 :: NominalDiffTime) * 1000

-- | Run @action@, firing @onTick elapsedSeconds@ roughly every
-- @intervalSec@ seconds until @action@ completes. Ticking stops as soon as
-- @action@ returns -- no heartbeat fires after that point. 'race' cancels
-- the ticker thread the instant @action@ finishes; the ticker itself never
-- returns (a 'forever' loop), so the 'Left' branch is unreachable.
withHeartbeat :: Double -> (Double -> IO ()) -> IO a -> IO a
withHeartbeat intervalSec onTick action = do
  start <- getCurrentTime
  outcome <- race (heartbeatLoop start) action
  case outcome of
    Left ()       -> error "impossible: withHeartbeat's ticker loop never terminates"
    Right result  -> pure result
  where
    heartbeatLoop start = forever $ do
      threadDelay (round (intervalSec * 1000000))
      now <- getCurrentTime
      onTick (realToFrac (diffUTCTime now start :: NominalDiffTime))

-- | 'Just' the current live-heap size in megabytes when the RTS was started
-- with @+RTS -T@ (or @-s@); 'Nothing' otherwise (no external @ps@/@top@
-- call needed to answer "still climbing or plateaued").
residencySnapshot :: IO (Maybe Double)
residencySnapshot = do
  enabled <- getRTSStatsEnabled
  if enabled
    then do
      stats <- getRTSStats
      pure (Just (fromIntegral (gcdetails_live_bytes (gc stats)) / 1e6))
    else pure Nothing
