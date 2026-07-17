module PB.AST.Ident
  ( Ident
  , mkIdent
  , identOrig
  , identCanon
  , IdentSet
  , identSetEmpty
  , identSetSingleton
  , identSetFromList
  , identSetMember
  , identSetLookup
  , identSetToList
  , identSetUnion
  ) where

import PB.Prelude
import Data.Aeson     (ToJSON (..))
import Data.Hashable  (Hashable (..))
import Data.String    (IsString (..))
import qualified Data.Map.Strict as Map
import qualified Data.Text       as T

-- | A PowerBuilder identifier, carrying both the originally declared casing
-- (for display\/JSON) and a canonicalized lowercase form ('identCanon',
-- 'Eq'\/'Ord' compare only on this field). PB identifiers are
-- case-insensitive; every previous consumer that needed case-insensitive
-- comparison re-derived @T.toLower@ locally instead of relying on a
-- canonical form computed once at parse time.
data Ident = Ident
  { identOrig  :: Text
  , identCanon :: Text
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
  fromString = mkIdent . T.pack

instance ToJSON Ident where
  toJSON = toJSON . identOrig

mkIdent :: Text -> Ident
mkIdent t = Ident t (T.toLower t)

-- | A set of 'Ident's keyed by canonical form, recovering the originally
-- declared casing on lookup -- the shape 'PB.Analysis.TypeCheck''s
-- @findOriginalCase@ used to hand-roll as an O(n) linear scan per query.
newtype IdentSet = IdentSet (Map.Map Text Ident)

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
