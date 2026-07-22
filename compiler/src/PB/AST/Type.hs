{-# LANGUAGE StrictData #-}
module PB.AST.Type
  ( PbType (..)
  , renderPbType
  , parseTypeText
  , parseTypeTextAt
  , pbTypeSpan
  ) where

import PB.Prelude
import PB.AST.Ident     (Ident, identOrig, identSpan, mkIdentAt, mkIdentSynthetic, provenanceSpan)
import PB.Lexing.Token  (SourceSpan)
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import qualified Data.Text as T

-- | PowerBuilder type representation.
-- Covers the ~35 types with actual type-system semantics.
-- User-defined types carry the declared name as an 'Ident' -- see
-- 'parseTypeText'/'parseTypeTextAt' for how its provenance is minted.
data PbType
  = PtPrimitive Text      -- "string", "integer", "decimal", etc.
  | PtUserDefined Ident   -- "n_cst_service", "w_main", etc.
  | PtAny                 -- the dynamic catch-all
  | PtDecimalPrec Int     -- "decimal{10}" with explicit precision
  deriving (Eq, Show, Generic)

instance NFData PbType

renderPbType :: PbType -> Text
renderPbType (PtPrimitive t)    = t
renderPbType (PtUserDefined t)  = identOrig t
renderPbType PtAny              = "any"
renderPbType (PtDecimalPrec n)  = "decimal{" <> T.pack (show n) <> "}"

-- | Parse a type text string into a 'PbType' with no source span available
-- (e.g. a value re-read from a DuckDB TEXT column, or a name split out of an
-- already-joined parameter-list string). The user-defined case mints a
-- 'Synthetic' 'Ident' -- honest about the missing provenance rather than
-- inventing one. Prefer 'parseTypeTextAt' whenever a real token is in hand.
parseTypeText :: Text -> PbType
parseTypeText = parseTypeTextWith (mkIdentSynthetic "type name has no source span at this call site")

-- | Parse a type text string into a 'PbType', minting a real-provenance
-- 'Ident' for the user-defined case from the given token span.
parseTypeTextAt :: SourceSpan -> Text -> PbType
parseTypeTextAt sp = parseTypeTextWith (mkIdentAt sp)

parseTypeTextWith :: (Text -> Ident) -> Text -> PbType
parseTypeTextWith mkI t
  | T.toLower t == "any" = PtAny
  | "decimal{" `T.isPrefixOf` T.toLower t =
      case reads (T.unpack (T.drop 8 (T.dropEnd 1 t))) of
        [(n, "")] -> PtDecimalPrec n
        _         -> PtPrimitive "decimal"
  | T.toLower t `elem` primitiveNames = PtPrimitive (T.toLower t)
  | otherwise = PtUserDefined (mkI t)

-- | The real source span backing a 'PtUserDefined' type name, or 'Nothing'
-- for every other case (a primitive/decimal/any type name is a keyword, not
-- an identifier reference -- see @compiler/AGENTS.md@'s identifier-typing
-- carve-out (b)) or for a 'PtUserDefined' minted with no real span at all.
pbTypeSpan :: PbType -> Maybe SourceSpan
pbTypeSpan (PtUserDefined i) = provenanceSpan (identSpan i)
pbTypeSpan _                 = Nothing

primitiveNames :: [Text]
primitiveNames = ["any","blob","boolean","byte","char","character"
  ,"date","datetime","dec","decimal","double"
  ,"int","integer","long","longlong","longptr"
  ,"real","string","time","uint","ulong"
  ,"unsignedint","unsignedinteger","unsignedlong"]
