module PB.Pipeline.SqlParse
  ( SqlResult (..)
  , ColumnRef (..)
  , RowFilter (..)
  , TableRef (..)
  , CatalogTable (..)
  , CatalogPrimaryKey (..)
  , CatalogForeignKey (..)
  , CatalogCheckConstraint (..)
  , SchemaCatalog (..)
  , DdlStats (..)
  , DdlResponse (..)
  , WorkerConn (..)
  , SqlBridgePool (..)
  , startSqlBridgePool
  , parseSql
  , parseDdl
  , shutdownSqlBridgePool
  , extractBsRawNodes
  ) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Located  (Located (..))

import Control.Exception          (SomeException, try)
import Data.Aeson                 (FromJSON (..), Value, decode, encode, object, withObject, (.=), (.:), (.:?), (.!=))
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

-- | A table identifier, optionally schema/namespace-qualified. Lowercased by
-- the Python-side extractor.
data TableRef = TableRef
  { trNamespace :: Maybe Text
  , trTable     :: Text
  } deriving (Show, Eq, Ord)

instance FromJSON TableRef where
  parseJSON = withObject "TableRef" $ \o -> TableRef
    <$> o .:? "namespace"
    <*> o .:  "table"

-- | A table's ordered column list, as declared in DDL (Plan 148 Phase 1a-3).
data CatalogTable = CatalogTable
  { ctRef     :: TableRef
  , ctColumns :: [Text]
  } deriving (Show, Eq)

instance FromJSON CatalogTable where
  parseJSON v = CatalogTable <$> parseJSON v <*> withObject "CatalogTable" (.: "columns") v

-- | A table's primary-key column list (composite keys supported).
data CatalogPrimaryKey = CatalogPrimaryKey
  { cpkRef     :: TableRef
  , cpkColumns :: [Text]
  } deriving (Show, Eq)

instance FromJSON CatalogPrimaryKey where
  parseJSON v = CatalogPrimaryKey <$> parseJSON v <*> withObject "CatalogPrimaryKey" (.: "columns") v

-- | A DDL foreign-key constraint: from_columns[i] -> to_columns[i], paired
-- by position (supports composite FKs sharing one constraint name).
data CatalogForeignKey = CatalogForeignKey
  { cfkConstraintName :: Maybe Text
  , cfkFromTable      :: TableRef
  , cfkFromColumns    :: [Text]
  , cfkToTable        :: TableRef
  , cfkToColumns      :: [Text]
  } deriving (Show, Eq)

instance FromJSON CatalogForeignKey where
  parseJSON = withObject "CatalogForeignKey" $ \o -> CatalogForeignKey
    <$> o .:? "constraint_name"
    <*> (TableRef <$> o .:? "from_namespace" <*> o .: "from_table")
    <*> o .: "from_columns"
    <*> (TableRef <$> o .:? "to_namespace" <*> o .: "to_table")
    <*> o .: "to_columns"

-- | A named CHECK constraint's raw predicate (e.g. @STATUS IN ('T', 'TG')@),
-- captured as sqlglot's normalized-SQL rendering rather than re-parsed --
-- this tool models column *structure* (tables/PK/FK), not full SQL semantics,
-- but the allowed-value information a CHECK predicate encodes is too
-- valuable to discard just because we're not writing a CHECK-expression AST.
data CatalogCheckConstraint = CatalogCheckConstraint
  { cckConstraintName :: Maybe Text
  , cckTable          :: TableRef
  , cckPredicate      :: Text
  } deriving (Show, Eq)

instance FromJSON CatalogCheckConstraint where
  parseJSON = withObject "CatalogCheckConstraint" $ \o -> CatalogCheckConstraint
    <$> o .:? "constraint_name"
    <*> (TableRef <$> o .:? "namespace" <*> o .: "table")
    <*> o .: "predicate"

-- | A static schema catalog parsed from a DDL dump (Plan 148 Phase 1a-3).
-- Flat/row-oriented (not @Map TableRef [Text]@) to match the JSON wire
-- shape and DuckDB's row-oriented appenders directly.
data SchemaCatalog = SchemaCatalog
  { scTables      :: [CatalogTable]
  , scPrimaryKeys :: [CatalogPrimaryKey]
  , scForeignKeys :: [CatalogForeignKey]
  , scChecks      :: [CatalogCheckConstraint]
  } deriving (Show, Eq)

instance FromJSON SchemaCatalog where
  parseJSON = withObject "SchemaCatalog" $ \o -> SchemaCatalog
    <$> o .: "tables"
    <*> o .: "primary_keys"
    <*> o .: "foreign_keys"
    <*> o .:? "checks" .!= []

emptySchemaCatalog :: SchemaCatalog
emptySchemaCatalog = SchemaCatalog [] [] [] []

-- | Per-request statement bookkeeping (Oracle DDL hardening follow-up):
-- 'dsStatementsSkipped' counts statements sqlglot could not structurally
-- parse (fell back to an inert Command) even at WARN error level -- surfaced
-- so a silently-empty catalog is never mistaken for "the DDL loaded fine."
data DdlStats = DdlStats
  { dsStatementsTotal   :: Int
  , dsStatementsParsed  :: Int
  , dsStatementsSkipped :: Int
  } deriving (Show, Eq)

instance FromJSON DdlStats where
  parseJSON = withObject "DdlStats" $ \o -> DdlStats
    <$> o .: "statements_total"
    <*> o .: "statements_parsed"
    <*> o .: "statements_skipped"

emptyDdlStats :: DdlStats
emptyDdlStats = DdlStats 0 0 0

-- | Full response envelope for a "ddl"-kind bridge request. 'ddlParseOk' is
-- false only for a hard failure outside sqlglot's own per-statement WARN-level
-- recovery (e.g. an unknown dialect name) -- 'ddlError' then carries the
-- exception message instead of being silently swallowed.
data DdlResponse = DdlResponse
  { ddlCatalog :: SchemaCatalog
  , ddlStats   :: DdlStats
  , ddlParseOk :: Bool
  , ddlError   :: Maybe Text
  } deriving (Show, Eq)

instance FromJSON DdlResponse where
  parseJSON = withObject "DdlResponse" $ \o -> DdlResponse
    <$> o .: "catalog"
    <*> o .: "stats"
    <*> o .: "parse_ok"
    <*> o .:? "error"

emptyDdlResponse :: Text -> DdlResponse
emptyDdlResponse err = DdlResponse emptySchemaCatalog emptyDdlStats False (Just err)

data WorkerConn = WorkerConn
  { wcStdin   :: Handle
  , wcStdout  :: Handle
  , wcProcess :: ProcessHandle
  }

data SqlBridgePool = SqlBridgePool
  { sbpSlots   :: V.Vector (IORef WorkerConn)
  , sbpBinary  :: FilePath
  , sbpDialect :: Text
  }


-- ---------------------------------------------------------------------------
-- Pool lifecycle
-- ---------------------------------------------------------------------------

-- | 'dialect' governs both regular SQL-statement parsing ('parseSql') and DDL
-- parsing ('parseDdl') -- set once here rather than threaded separately
-- through each, so the two can never structurally drift apart.
startSqlBridgePool :: Int -> FilePath -> Text -> IO SqlBridgePool
startSqlBridgePool n bin dialect = do
  slots <- mapM (\_ -> startWorker bin >>= newIORef) [0 .. n - 1]
  pure $ SqlBridgePool { sbpSlots = V.fromList slots, sbpBinary = bin, sbpDialect = dialect }

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
      r <- try @SomeException (timeout 30_000_000 (sendReceive conn (sbpDialect pool) sqlText))
      pure $ case r of
        Right (Just (Just res)) -> Just res
        _                       -> Nothing

-- | Parse a DDL dump into a 'DdlResponse' via the bridge's "ddl" request
-- kind. Always uses slot 0 -- this is a one-shot, once-per-run call (unlike
-- 'parseSql', which is called once per SQL statement across all worker
-- slots), so there is no need to thread a slot index through the caller.
-- 'dialect' comes from the pool ('sbpDialect'), the same value 'parseSql'
-- uses for regular SQL statements, so the two can't disagree.
-- 'defaultNamespace' fills in the schema for a table (or FK reference) left
-- unqualified in the DDL text -- the common per-schema-dump export
-- convention (e.g. a file named clims.sql implicitly belongs to CLIMS).
parseDdl :: SqlBridgePool -> Maybe Text -> Text -> IO DdlResponse
parseDdl pool defaultNamespace ddlText = do
  let ref = sbpSlots pool V.! 0
  conn <- readIORef ref
  mres <- safeRequest conn
  case mres of
    Just resp -> pure resp
    Nothing -> do
      restartWorker pool ref conn
      conn' <- readIORef ref
      mres2 <- safeRequest conn'
      pure $ fromMaybe (emptyDdlResponse "ddl request failed (bridge worker crashed or timed out)") mres2
  where
    safeRequest conn = do
      r <- try @SomeException (timeout 30_000_000 (ddlSendReceive conn (sbpDialect pool) defaultNamespace ddlText))
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

sendReceive :: WorkerConn -> Text -> Text -> IO (Maybe SqlResult)
sendReceive conn dialect sqlText =
  requestResponse conn (object ["sql" .= sqlText, "dialect" .= dialect])

ddlSendReceive :: WorkerConn -> Text -> Maybe Text -> Text -> IO (Maybe DdlResponse)
ddlSendReceive conn dialect defaultNamespace ddlText =
  requestResponse conn (object
    [ "kind" .= ("ddl" :: Text), "ddl" .= ddlText, "dialect" .= dialect
    , "namespace" .= defaultNamespace
    ])

requestResponse :: FromJSON a => WorkerConn -> Value -> IO (Maybe a)
requestResponse conn payload = do
  let body = encode payload
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
