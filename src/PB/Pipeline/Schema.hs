module PB.Pipeline.Schema
  ( astSchemaJSON
  , srFileSchemaJSON
  ) where

import Autodocodec.Schema (JSONSchema, jsonSchemaViaCodec)
import Data.Aeson         (Value, toJSON)
import PB.AST.BodyStmt    (BodyStmt)
import PB.AST.SourceFile  (SrFile)
import PB.Pipeline.Codec  ()   -- HasCodec instances

srFileSchemaJSON :: Value
srFileSchemaJSON = toJSON (jsonSchemaViaCodec @SrFile :: JSONSchema)

-- Array-of-BodyStmt schema kept for backwards compatibility.
astSchemaJSON :: Value
astSchemaJSON = toJSON (jsonSchemaViaCodec @[BodyStmt] :: JSONSchema)
