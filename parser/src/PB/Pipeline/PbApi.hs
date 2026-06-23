{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
-- | Compile-time embedding of pb_api.json for builtin function/method detection.
module PB.Pipeline.PbApi
  ( builtinFnNames
  , builtinMethodNames
  ) where

import PB.Prelude

import Data.Aeson         (FromJSON (..), eitherDecodeStrict, withObject, (.:))
import Data.FileEmbed     (embedFile)

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

pbApiBytes :: BS.ByteString
pbApiBytes = $(embedFile "../cli/pb_cli/data/pb_api.json")

data PbApiJson = PbApiJson
  { pbjFreeFunctions :: [Text]
  , pbjClassMethods  :: Map.Map Text [Text]
  }

instance FromJSON PbApiJson where
  parseJSON = withObject "PbApiJson" $ \o -> PbApiJson
    <$> o .: "free_function_names"
    <*> o .: "class_methods"

builtinFnNames :: Set.Set Text
builtinFnNames = case eitherDecodeStrict pbApiBytes of
  Left  _ -> Set.empty
  Right j -> Set.fromList (pbjFreeFunctions j)

builtinMethodNames :: Set.Set Text
builtinMethodNames = case eitherDecodeStrict pbApiBytes of
  Left  _ -> Set.empty
  Right j -> Set.unions (map Set.fromList (Map.elems (pbjClassMethods j)))
