module PB.AST.Type
  ( PbType (..)
  , renderPbType
  , parseTypeText
  ) where

import PB.Prelude
import GHC.Generics (Generic)
import qualified Data.Text as T

-- | PowerBuilder type representation.
-- Covers the ~35 types with actual type-system semantics.
-- User-defined types are stored as their name text.
data PbType
  = PtPrimitive Text      -- "string", "integer", "decimal", etc.
  | PtUserDefined Text    -- "n_cst_service", "w_main", etc.
  | PtAny                 -- the dynamic catch-all
  | PtDecimalPrec Int     -- "decimal{10}" with explicit precision
  deriving (Eq, Show, Generic)

renderPbType :: PbType -> Text
renderPbType (PtPrimitive t)    = t
renderPbType (PtUserDefined t)  = t
renderPbType PtAny              = "any"
renderPbType (PtDecimalPrec n)  = "decimal{" <> T.pack (show n) <> "}"

-- | Parse a type text string into a PbType.
parseTypeText :: Text -> PbType
parseTypeText t
  | T.toLower t == "any" = PtAny
  | "decimal{" `T.isPrefixOf` T.toLower t =
      case reads (T.unpack (T.drop 8 (T.dropEnd 1 t))) of
        [(n, "")] -> PtDecimalPrec n
        _         -> PtPrimitive "decimal"
  | T.toLower t `elem` primitiveNames = PtPrimitive (T.toLower t)
  | otherwise = PtUserDefined t

primitiveNames :: [Text]
primitiveNames = ["any","blob","boolean","byte","char","character"
  ,"date","datetime","dec","decimal","double"
  ,"int","integer","long","longlong","longptr"
  ,"real","string","time","uint","ulong"
  ,"unsignedint","unsignedinteger","unsignedlong"]
