{-# LANGUAGE StrictData #-}
-- | Workspace-wide control/object hierarchy index and multi-hop member-chain
-- resolver (Plan 164 Phase B / D2).
--
-- Pure module — no I/O. Generalizes 'PB.Analysis.TypeResolve.extractDwControlBindings'
-- (per-file) into a workspace-wide index that can walk a dotted member chain
-- (e.g. @tab1.page1.uo_epidom.dw@) across file boundaries, following two
-- distinct PowerBuilder declaration conventions at each hop:
--
--   * __Visual-tree convention__: a control that is part of the /same/
--     object's own inheritance tree (extended via 'PB.AST.SourceFile.splitAncestorRef'\'s
--     backtick same-name override) is redeclared, at every level of the
--     ancestor chain, @within \<literal-instance-name\>@ — the same literal
--     name persists across files. Continuing a chain through such a control
--     uses its own literal name as the next lookup scope.
--   * __Has-a convention__: a control that is an /instance of a separate,
--     independent class/ (a plain @type X from SomeClass within Y@ with no
--     backtick) has its own children declared @within \<ClassName\>@ in that
--     class's own file — never @within \<instance-name\>@. Continuing a
--     chain through such a control requires switching the lookup scope to
--     its resolved ancestor type.
--
-- 'resolveMemberChainType'/'resolveMemberChainDwBinding' try the first
-- convention before falling back to the second at every hop, since a flat
-- per-file inspection can't tell which applies without trying.
module PB.Analysis.ControlHierarchy
  ( ControlDecl (..)
  , ControlIndex
  , buildControlIndex
  , resolveMemberChainType
  , resolveMemberChainDwBinding
  ) where

import PB.Prelude
import PB.AST.SourceFile
import PB.Analysis.TypeResolve (findLiteralDataObject)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- | Every declared control across the workspace: which object it belongs to
-- (owner), what it's declared as (ancestor class, or a same-named override
-- per 'splitAncestorRef'), and its own static DataWindow binding if any.
-- All 'Text' fields except 'cdDwBinding' are lowercased at construction time
-- for case-insensitive lookup (PowerBuilder identifiers are case-insensitive).
data ControlDecl = ControlDecl
  { cdOwner         :: Text          -- ^ lowercased; object/control this control lives within (tdWithin, or its own name when top-level)
  , cdName          :: Text          -- ^ lowercased; this control's own name (tdName), or "this" for a top-level TypeBlock
  , cdAncestorType  :: Text          -- ^ lowercased; split ancestor class (D1)
  , cdOverridesName :: Maybe Text    -- ^ lowercased; D1 backtick override target, if any
  , cdDwBinding     :: Maybe Text    -- ^ verbatim; literal dataobject= value declared directly on this block
  } deriving (Eq, Show)

-- | (owner, name) -> declaration, both components lowercased.
type ControlIndex = Map.Map (Text, Text) ControlDecl

-- | Build the workspace-wide control index from every 'TypeBlock' in every
-- file. When multiple files declare the same (owner, name) pair, the last
-- file in the input list wins (ordinary 'Map.fromList' bias) — callers
-- should pass files in a stable order.
buildControlIndex :: [SrFile] -> ControlIndex
buildControlIndex sfs = Map.fromList
  [ ((T.toLower owner, T.toLower name), decl)
  | sf <- sfs
  , tb <- srTypeBlocks sf
  , let td = tbDecl tb
        (owner, name) = case tdWithin td of
          Just parent -> (parent, tdName td)
          Nothing     -> (tdName td, "this")
        (ancestorClass, overridesName) = splitAncestorRef (tdAncestor td)
        decl = ControlDecl
          { cdOwner         = T.toLower owner
          , cdName          = T.toLower name
          , cdAncestorType  = T.toLower ancestorClass
          , cdOverridesName = T.toLower <$> overridesName
          , cdDwBinding     = findLiteralDataObject (tbBody tb)
          }
  ]

-- | Resolve a dotted member-chain starting from a known object context to
-- its terminal control's effective type (the ancestor type of the final,
-- non-overridden declaration reached after following every D1 override).
-- 'Nothing' when any hop is unresolvable — no guessing past what the
-- workspace actually declares.
resolveMemberChainType :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe Text
resolveMemberChainType idx inh obj segs =
  cdAncestorType . snd <$> resolveChain idx (normalizeInherits inh) obj segs

-- | Resolve a dotted member-chain to its terminal control's static
-- DataWindow binding, walking the same chain as 'resolveMemberChainType'.
-- Unlike the effective /type/ (which fully unwinds to the base declaration),
-- the binding search stops at the closest override that sets a literal
-- @dataobject@ — a more-derived override's own binding must win over
-- whatever its ancestor declares (or doesn't declare) further up the chain.
resolveMemberChainDwBinding :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe Text
resolveMemberChainDwBinding idx inh obj segs =
  case resolveChain idx (normalizeInherits inh) obj segs of
    Nothing              -> Nothing
    Just (dwBinding, _)  -> dwBinding

-- | Lowercase both sides of an externally-supplied inherits map (e.g.
-- 'PB.Analysis.TypeResolve.buildInheritsMap'\'s raw, case-sensitive output)
-- once per top-level call, so every internal lookup can assume normalized keys.
normalizeInherits :: Map.Map Text Text -> Map.Map Text Text
normalizeInherits = Map.fromList . map (\(k, v) -> (T.toLower k, T.toLower v)) . Map.toList

-- | Walk every chain segment, resolving each hop (closest-wins DW binding,
-- fully-unwound terminal decl for its type) and choosing the next lookup
-- scope: first the resolved control's own literal name (visual-tree
-- convention), falling back to its fully-resolved ancestor type (has-a
-- convention) only if the literal-name continuation fails to resolve the
-- rest of the chain. Returns the closest-wins DW binding accumulated over
-- the *terminal* hop only (each hop's own binding is irrelevant once we've
-- moved past it to the next segment).
resolveChain :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe (Maybe Text, ControlDecl)
resolveChain _   _   _   []         = Nothing
resolveChain idx inh obj (seg:rest) = do
  (dwBinding, decl) <- resolveHop idx inh obj seg
  if null rest
    then Just (dwBinding, decl)
    else case resolveChain idx inh (cdName decl) rest of
           Just r  -> Just r
           Nothing -> resolveChain idx inh (cdAncestorType decl) rest

-- | Resolve one segment under one owner scope: direct-or-inherited lookup,
-- then unwind any D1 override chain. Returns the closest-wins DW binding
-- found anywhere along the chain, paired with the fully-unwound terminal
-- (non-overridden) decl, whose 'cdAncestorType' is the control's true base
-- type. Cycle-safe via a visited (scope, name) set on the override walk.
resolveHop :: ControlIndex -> Map.Map Text Text -> Text -> Text -> Maybe (Maybe Text, ControlDecl)
resolveHop idx inh owner name = do
  decl <- lookupWithAncestry idx inh owner name
  Just (unwind Set.empty decl)
  where
    unwind seen decl = case cdOverridesName decl of
      Nothing -> (cdDwBinding decl, decl)
      Just overrideName
        | target `Set.member` seen -> (cdDwBinding decl, decl)
        | otherwise -> case lookupWithAncestry idx inh (cdAncestorType decl) overrideName of
            Nothing -> (cdDwBinding decl, decl)
            Just next ->
              let (dwFromRest, terminal) = unwind (Set.insert target seen) next
              in (cdDwBinding decl <|> dwFromRest, terminal)
        where target = (cdAncestorType decl, overrideName)

-- | Look up (owner, name) directly; if absent, walk owner's class-ancestor
-- chain via inh (cycle-safe via a visited-owner set), retrying at each
-- ancestor. Mirrors 'PB.Analysis.TypeEnv.walkInheritChain'\'s cycle guard.
lookupWithAncestry :: ControlIndex -> Map.Map Text Text -> Text -> Text -> Maybe ControlDecl
lookupWithAncestry idx inh owner0 name = go Set.empty (T.toLower owner0)
  where
    lname = T.toLower name
    go seen owner
      | owner `Set.member` seen                     = Nothing
      | Just decl <- Map.lookup (owner, lname) idx   = Just decl
      | Just parent <- Map.lookup owner inh          = go (Set.insert owner seen) parent
      | otherwise                                    = Nothing
