module PB.AST.Ident
  ( Ident
  , IdentProvenance (..)
  , identOrig
  , identCanon
  , identSpan
  , mkIdentAt
  , mkIdentDerived
  , mkIdentSynthetic
  , mkIdent
  , provenanceSpan
  , IdentSet
  , identSetEmpty
  , identSetSingleton
  , identSetFromList
  , identSetMember
  , identSetLookup
  , identSetToList
  , identSetUnion
  , identSetDifference
  , IdentMap
  , identMapEmpty
  , identMapSize
  , identMapInsertWith
  , identMapFromList
  , identMapFromListWith
  , identMapLookup
  , identMapToList
  ) where

import PB.Prelude
import Control.DeepSeq (NFData (..))
import Data.Aeson     (ToJSON (..))
import Data.Hashable  (Hashable (..))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.String    (IsString (..))
import GHC.Generics   (Generic)
import qualified Data.Map.Strict as Map
import qualified Data.Text       as T
import PB.Lexing.Token (SourceSpan (..))

-- | Where an 'Ident''s identity came from.  'Eq'\/'Ord'\/'Hashable' on
-- 'Ident' compare only 'identCanon', so this field has no effect on
-- those instances.
data IdentProvenance
  = FromSource (NonEmpty SourceSpan)
    -- ^ Real span(s) this Ident's identity traces to: a 1-element list for
    -- an ordinary single-token identifier, 2+ for a compiler-built compound
    -- name assembled from multiple real tokens.
  | Synthetic Text
    -- ^ No source span at all, by design.  The Text names the reason so
    -- this is never confused with a position that was merely lost.
  deriving (Eq, Ord, Show, Generic)

instance NFData IdentProvenance

-- | A PowerBuilder identifier, carrying the originally declared casing
-- (for display\/JSON), a canonicalized lowercase form ('identCanon',
-- 'Eq'\/'Ord' compare only on this field), and source provenance.
data Ident = Ident
  { identOrig  :: Text
  , identCanon :: Text
  , identSpan  :: IdentProvenance
  }

instance Eq Ident where
  a == b = identCanon a == identCanon b

instance Ord Ident where
  compare a b = compare (identCanon a) (identCanon b)

instance Hashable Ident where
  hashWithSalt s = hashWithSalt s . identCanon

instance Show Ident where
  show = show . identOrig

instance IsString Ident where
  fromString = mkIdentSynthetic "IsString" . T.pack

instance ToJSON Ident where
  toJSON = toJSON . identOrig

instance NFData Ident where
  rnf (Ident a b c) = rnf a `seq` rnf b `seq` rnf c

-- | Mint an 'Ident' from a single real source token.
mkIdentAt :: SourceSpan -> Text -> Ident
mkIdentAt sp t = Ident t (T.toLower t) (FromSource (sp :| []))

-- | Mint an 'Ident' assembled from multiple real source tokens
-- (e.g. a @CALL ancestor::event@ super-dispatch name).
mkIdentDerived :: NonEmpty SourceSpan -> Text -> Ident
mkIdentDerived sps t = Ident t (T.toLower t) (FromSource sps)

-- | Mint an 'Ident' with no source span, by design.
mkIdentSynthetic :: Text -> Text -> Ident
mkIdentSynthetic reason t = Ident t (T.toLower t) (Synthetic reason)

-- | Flatten an 'IdentProvenance' to the single overall span it covers -- the
-- start of its first token through the end of its last, or 'Nothing' for a
-- 'Synthetic' ident (no source span to report).
provenanceSpan :: IdentProvenance -> Maybe SourceSpan
provenanceSpan (FromSource sps) = Just (SourceSpan (ssStartLine start_) (ssStartCol start_) (ssEndLine end_) (ssEndCol end_))
  where
    start_ = NE.head sps
    end_   = NE.last sps
provenanceSpan (Synthetic _) = Nothing

-- | Legacy constructor — temporarily kept as a bridge during the
-- Phase E.5 migration.  Every call site must be converted to
-- 'mkIdentAt', 'mkIdentDerived', or 'mkIdentSynthetic' before this
-- is deleted.
mkIdent :: Text -> Ident
mkIdent = mkIdentSynthetic "unconverted mkIdent"

-- | A set of 'Ident's keyed by canonical form, recovering the originally
-- declared casing on lookup -- the shape 'PB.Analysis.TypeCheck''s
-- @findOriginalCase@ used to hand-roll as an O(n) linear scan per query.
newtype IdentSet = IdentSet (Map.Map Text Ident)

instance NFData IdentSet where
  rnf (IdentSet m) = rnf m

identSetEmpty :: IdentSet
identSetEmpty = IdentSet Map.empty

identSetSingleton :: Ident -> IdentSet
identSetSingleton i = IdentSet (Map.singleton (identCanon i) i)

identSetFromList :: [Ident] -> IdentSet
identSetFromList = IdentSet . Map.fromList . map (\i -> (identCanon i, i))

identSetMember :: Ident -> IdentSet -> Bool
identSetMember needle (IdentSet m) = Map.member (identCanon needle) m

-- | Look up an 'Ident' by canonical form, recovering the originally declared
-- casing of the stored match (which may differ from the query's casing).
identSetLookup :: Ident -> IdentSet -> Maybe Ident
identSetLookup needle (IdentSet m) = Map.lookup (identCanon needle) m

identSetToList :: IdentSet -> [Ident]
identSetToList (IdentSet m) = Map.elems m

-- | Union of two 'IdentSet's. On a canonical-form collision, the first
-- set's entry (and its casing) wins -- same left-biased tie-break as
-- 'Data.Map.union'.
identSetUnion :: IdentSet -> IdentSet -> IdentSet
identSetUnion (IdentSet a) (IdentSet b) = IdentSet (Map.union a b)

-- | Entries of the first set whose canonical form does not appear in the
-- second set.
identSetDifference :: IdentSet -> IdentSet -> IdentSet
identSetDifference (IdentSet a) (IdentSet b) = IdentSet (Map.difference a b)

-- | A canonical-keyed map from 'Ident' to a value, recovering the
-- originally declared casing of the key on lookup -- generalizes
-- 'IdentSet' (an @IdentMap@ with no payload) to carry an arbitrary value
-- per key. Used where a consumer needs both a key's own declared casing
-- back (not just membership) and an associated value, e.g.
-- 'PB.Analysis.TypeResolve.buildProcMap''s object-name -> proc-set map.
newtype IdentMap a = IdentMap (Map.Map Text (Ident, a))

instance NFData a => NFData (IdentMap a) where
  rnf (IdentMap m) = rnf m

identMapEmpty :: IdentMap a
identMapEmpty = IdentMap Map.empty

identMapSize :: IdentMap a -> Int
identMapSize (IdentMap m) = Map.size m

-- | Insert, combining with the existing value on a canonical-form
-- collision via @f newValue oldValue@ (matching 'Map.insertWith''s
-- argument order) -- the stored key's casing is left-biased, same
-- precedent as 'identSetUnion'.
identMapInsertWith :: (a -> a -> a) -> Ident -> a -> IdentMap a -> IdentMap a
identMapInsertWith f k v (IdentMap m) =
  IdentMap (Map.insertWith combine (identCanon k) (k, v) m)
  where combine (_, newV) (oldK, oldV) = (oldK, f newV oldV)

-- | Build from a list, last entry winning on a canonical-form collision --
-- same convention as 'Data.Map.fromList'.
identMapFromList :: [(Ident, a)] -> IdentMap a
identMapFromList = identMapFromListWith (\new _old -> new)

identMapFromListWith :: (a -> a -> a) -> [(Ident, a)] -> IdentMap a
identMapFromListWith f = foldl' (\acc (k, v) -> identMapInsertWith f k v acc) identMapEmpty

-- | Look up by canonical form, recovering both the originally declared
-- casing of the stored key and its value.
identMapLookup :: Ident -> IdentMap a -> Maybe (Ident, a)
identMapLookup needle (IdentMap m) = Map.lookup (identCanon needle) m

identMapToList :: IdentMap a -> [(Ident, a)]
identMapToList (IdentMap m) = Map.elems m
