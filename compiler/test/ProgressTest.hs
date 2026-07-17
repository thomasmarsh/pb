module ProgressTest (tests) where

import PB.Prelude
import PB.Pipeline.Progress

import Control.Concurrent (threadDelay)
import Data.Aeson         (ToJSON (..), object, (.=))
import Data.IORef         (modifyIORef, newIORef, readIORef)

import Test.Tasty         (TestTree, testGroup)
import Test.Tasty.HUnit    (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "Progress"
  [ testGroup "ProgressEvent ToJSON"
      [ testCase "EvPhase renders {tag,name} only" $
          toJSON (EvPhase "B") @?= object ["tag" .= ("phase" :: Text), "name" .= ("B" :: Text)]

      , testCase "EvWarning renders {tag,message} only" $
          toJSON (EvWarning "careful") @?=
            object ["tag" .= ("warning" :: Text), "message" .= ("careful" :: Text)]

      , testCase "EvStep with no optional fields renders bare {tag,label}" $
          toJSON (EvStep "leg_source" Nothing [] [] Nothing) @?=
            object ["tag" .= ("step" :: Text), "label" .= ("leg_source" :: Text)]

      , testCase "EvStep with elapsed_ms/edb_rows/idb_rows/residency_mb populates every field" $
          toJSON (EvStep "risk_count" (Just 12345.6) [("reaches", 900000)]
                    [("risk_count", 22756)] (Just 14800.0))
            @?= object
                  [ "tag"          .= ("step" :: Text)
                  , "label"        .= ("risk_count" :: Text)
                  , "elapsed_ms"   .= (12345.6 :: Double)
                  , "edb_rows"     .= object ["reaches" .= (900000 :: Int)]
                  , "idb_rows"     .= object ["risk_count" .= (22756 :: Int)]
                  , "residency_mb" .= (14800.0 :: Double)
                  ]
      ]

  , testGroup "stampEvent"
      [ testCase "inserts since_start_ms alongside EvStep's existing fields" $
          stampEvent 123.4 (EvStep "leg_source" Nothing [] [] Nothing) @?=
            object
              [ "tag"            .= ("step" :: Text)
              , "label"          .= ("leg_source" :: Text)
              , "since_start_ms" .= (123.4 :: Double)
              ]

      , testCase "inserts since_start_ms alongside EvPhase's existing fields" $
          stampEvent 0 (EvPhase "B") @?=
            object
              [ "tag"            .= ("phase" :: Text)
              , "name"           .= ("B" :: Text)
              , "since_start_ms" .= (0 :: Double)
              ]
      ]

  , testGroup "elapsedSinceStartMs"
      [ testCase "is non-negative and monotonically non-decreasing across calls" $ do
          a <- elapsedSinceStartMs
          threadDelay 1000
          b <- elapsedSinceStartMs
          assertBool ("first call should be non-negative, got " <> show a) (a >= 0)
          assertBool ("second call should not precede the first (a=" <> show a <> ", b=" <> show b <> ")")
            (b >= a)
      ]

  , testGroup "timedStepTo"
      [ testCase "emits a start event then an end event with elapsed_ms set" $ do
          ref <- newIORef []
          let sink ev = modifyIORef ref (++ [ev])
          result <- timedStepTo sink "resolving types" (pure (42 :: Int))
          result @?= 42
          events <- readIORef ref
          case events of
            [ EvStep l1 Nothing [] [] Nothing
              , EvStep l2 (Just ms) [] [] Nothing
              ] -> do
                l1 @?= "resolving types"
                l2 @?= "resolving types"
                assertBool "elapsed_ms is non-negative" (ms >= 0)
            other -> assertFailure ("expected exactly 2 EvStep events, got: " <> show other)
      ]

  , testGroup "timedStepRowsTo"
      [ testCase "end event's idb_rows carries the action's own row counts" $ do
          ref <- newIORef []
          let sink ev = modifyIORef ref (++ [ev])
          _ <- timedStepRowsTo sink "taint edb views" (pure ((), [("taint_edge", 3), ("taint_source", 5)]))
          events <- readIORef ref
          case events of
            [ EvStep _ Nothing [] [] Nothing
              , EvStep _ (Just _) [] rows Nothing
              ] -> rows @?= [("taint_edge", 3), ("taint_source", 5)]
            other -> assertFailure ("expected exactly 2 EvStep events, got: " <> show other)
      ]

  , testGroup "withHeartbeat"
      [ testCase "ticks at least once during a slow action given a short interval" $ do
          ref <- newIORef (0 :: Int)
          _ <- withHeartbeat 0.05 (\_ -> modifyIORef ref (+ 1)) (threadDelay 300000)
          n <- readIORef ref
          assertBool ("expected at least 1 tick, got " <> show n) (n >= 1)

      , testCase "stops ticking once the action completes" $ do
          ref <- newIORef (0 :: Int)
          _ <- withHeartbeat 0.05 (\_ -> modifyIORef ref (+ 1)) (threadDelay 150000)
          nAfterAction <- readIORef ref
          threadDelay 300000
          nAfterGrace <- readIORef ref
          nAfterGrace @?= nAfterAction
      ]
  ]
