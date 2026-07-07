module PB.Pipeline.SqlParse
  ( SqlResult (..)
  , ColumnRef (..)
  , RowFilter (..)
  , WorkerConn (..)
  , SqlBridgePool (..)
  , startSqlBridgePool
  , parseSql
  , shutdownSqlBridgePool
  , extractBsRawNodes
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Located  (Located (..))

import Control.Exception          (SomeException, try)
import Data.Aeson                 (FromJSON (..), decode, encode, object, withObject, (.=), (.:), (.:?), (.!=))
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BL
import Data.Bits                  (shiftL, shiftR, (.&.))
import Data.IORef
import qualified Data.Vector          as V
import System.IO                  (Handle, hClose, hFlush, hSetBinaryMode)
import System.Process             ( CreateProcess (..), ProcessHandle, StdStream (..)
                                  , createProcess, proc, terminateProcess, waitForProcess )
import System.Timeout             (timeout)


-- ---------------------------------------------------------------------------
-- Public types
-- ---------------------------------------------------------------------------

-- | A single column reference, scoped to the table it was actually read
-- from or written to (unlike the flat, table-less 'srColumns' list).
data ColumnRef = ColumnRef
  { crNamespace :: Maybe Text
  , crTable     :: Maybe Text
  , crColumn    :: Text
  , crIsWrite   :: Bool
  } deriving (Show, Eq)

instance FromJSON ColumnRef where
  parseJSON = withObject "ColumnRef" $ \o -> ColumnRef
    <$> o .:? "namespace"
    <*> o .:? "table"
    <*> o .:  "column"
    <*> o .:  "is_write"

-- | A shallow WHERE-clause predicate: @col = <literal>@ or @col IN (...)@
-- only (Plan 148 Phase 1a-2's rider).
data RowFilter = RowFilter
  { rfNamespace :: Maybe Text
  , rfTable     :: Maybe Text
  , rfColumn    :: Text
  , rfOp        :: Text
  , rfValues    :: [Text]
  } deriving (Show, Eq)

instance FromJSON RowFilter where
  parseJSON = withObject "RowFilter" $ \o -> RowFilter
    <$> o .:? "namespace"
    <*> o .:? "table"
    <*> o .:  "column"
    <*> o .:  "op"
    <*> o .:  "values"

data SqlResult = SqlResult
  { srTables     :: [Text]
  , srColumns    :: [Text]
  , srOperation  :: Maybe Text
  , srParseOk    :: Bool
  , srColumnRefs :: [ColumnRef]
  , srRowFilters :: [RowFilter]
  } deriving (Show, Eq)

instance FromJSON SqlResult where
  parseJSON = withObject "SqlResult" $ \o -> SqlResult
    <$> o .:  "tables"
    <*> o .:  "columns"
    <*> o .:? "operation"
    <*> o .:  "parse_ok"
    <*> o .:? "column_refs" .!= []
    <*> o .:? "row_filters" .!= []

data WorkerConn = WorkerConn
  { wcStdin   :: Handle
  , wcStdout  :: Handle
  , wcProcess :: ProcessHandle
  }

data SqlBridgePool = SqlBridgePool
  { sbpSlots  :: V.Vector (IORef WorkerConn)
  , sbpBinary :: FilePath
  }


-- ---------------------------------------------------------------------------
-- Pool lifecycle
-- ---------------------------------------------------------------------------

startSqlBridgePool :: Int -> FilePath -> IO SqlBridgePool
startSqlBridgePool n bin = do
  slots <- mapM (\_ -> startWorker bin >>= newIORef) [0 .. n - 1]
  pure $ SqlBridgePool { sbpSlots = V.fromList slots, sbpBinary = bin }

shutdownSqlBridgePool :: SqlBridgePool -> IO ()
shutdownSqlBridgePool pool =
  V.forM_ (sbpSlots pool) $ \ref -> do
    conn <- readIORef ref
    _ <- try @SomeException (hClose (wcStdin conn))
    _ <- try @SomeException (waitForProcess (wcProcess conn))
    pure ()


-- ---------------------------------------------------------------------------
-- Per-request entry point
-- ---------------------------------------------------------------------------

parseSql :: SqlBridgePool -> Int -> Text -> IO SqlResult
parseSql pool idx sqlText = do
  let ref = sbpSlots pool V.! idx
  conn <- readIORef ref
  mres <- safeRequest conn
  case mres of
    Just r  -> pure r
    Nothing -> do
      restartWorker pool ref conn
      conn' <- readIORef ref
      mres2 <- safeRequest conn'
      pure $ fromMaybe (SqlResult [] [] Nothing False [] []) mres2
  where
    safeRequest conn = do
      r <- try @SomeException (timeout 30_000_000 (sendReceive conn sqlText))
      pure $ case r of
        Right (Just (Just res)) -> Just res
        _                       -> Nothing


-- ---------------------------------------------------------------------------
-- Wire protocol helpers
-- ---------------------------------------------------------------------------

startWorker :: FilePath -> IO WorkerConn
startWorker bin = do
  (Just hIn, Just hOut, _, ph) <- createProcess
    (proc bin []) { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit }
  hSetBinaryMode hIn  True
  hSetBinaryMode hOut True
  pure $ WorkerConn { wcStdin = hIn, wcStdout = hOut, wcProcess = ph }

restartWorker :: SqlBridgePool -> IORef WorkerConn -> WorkerConn -> IO ()
restartWorker pool ref old = do
  _ <- try @SomeException (terminateProcess (wcProcess old))
  _ <- try @SomeException (waitForProcess (wcProcess old))
  conn' <- startWorker (sbpBinary pool)
  writeIORef ref conn'

sendReceive :: WorkerConn -> Text -> IO (Maybe SqlResult)
sendReceive conn sqlText = do
  let body = encode (object ["sql" .= sqlText, "dialect" .= ("oracle" :: Text)])
      len  = fromIntegral (BL.length body) :: Int
  BS.hPut (wcStdin conn) (encodeLen len)
  BL.hPut (wcStdin conn) body
  hFlush  (wcStdin conn)
  hdr <- BS.hGet (wcStdout conn) 4
  if BS.length hdr < 4
    then pure Nothing
    else do
      let n = decodeLen hdr
      resp <- BS.hGet (wcStdout conn) n
      if BS.length resp < n
        then pure Nothing
        else pure $ decode (BL.fromStrict resp)

encodeLen :: Int -> BS.ByteString
encodeLen n = BS.pack
  [ fromIntegral (n `shiftR` 24 .&. 0xFF)
  , fromIntegral (n `shiftR` 16 .&. 0xFF)
  , fromIntegral (n `shiftR` 8  .&. 0xFF)
  , fromIntegral (n             .&. 0xFF)
  ]

decodeLen :: BS.ByteString -> Int
decodeLen bs =
  (fromIntegral (BS.index bs 0) `shiftL` 24)
  + (fromIntegral (BS.index bs 1) `shiftL` 16)
  + (fromIntegral (BS.index bs 2) `shiftL` 8)
  + fromIntegral (BS.index bs 3)


-- ---------------------------------------------------------------------------
-- AST helper
-- ---------------------------------------------------------------------------

-- | Collect (line, rawText) for every BsRaw node, recursing into compound stmts.
extractBsRawNodes :: [Located BodyStmt] -> [(Int, Text)]
extractBsRawNodes = concatMap extract
  where
    extract (Located ln stmt) = case stmt of
      BsRaw txt ->
        [(ln, txt)]
      BsIf (IfStmt { ifThen = body, ifElseIfs = eis, ifElse = mel }) ->
        extractBsRawNodes body
        ++ concatMap (\ei -> extractBsRawNodes (eifBody ei)) eis
        ++ maybe [] extractBsRawNodes mel
      BsFor (ForStmt { forBody = body }) ->
        extractBsRawNodes body
      BsDo (DoStmt { doBody = body }) ->
        extractBsRawNodes body
      BsChoose (ChooseStmt { chooseClauses = clauses }) ->
        concatMap (\c -> extractBsRawNodes (ccBody c)) clauses
      _ ->
        []
