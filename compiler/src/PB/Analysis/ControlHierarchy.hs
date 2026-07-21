{-# LANGUAGE StrictData #-}
-- | Workspace-wide control/object hierarchy index and multi-hop member-chain
-- resolver.
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
--
-- __Phase E key qualification.__ PowerBuilder codegen re-declares every
-- nested visual control at every level of an ancestor chain via the
-- backtick override, using the /same/ literal names each time (e.g. a
-- generic tab-container child is almost always named @tab1@/@page1@
-- regardless of which window it lives on). A flat @(owner, name)@ key
-- therefore collides across unrelated windows that share this generic
-- naming (confirmed against the real corpus: 11 windows built on the
-- @w_form_tab2@\/@w_singleform_tab@ ancestor family all redeclare
-- @tab1@\/@page1@). The index key is qualified by a third component,
-- @root@ — the top-level object ('PB.AST.SourceFile.srPrimaryObject') of
-- the file that declared this particular 'TypeBlock' — so each window's
-- own redeclaration gets its own entry. Resolution threads @root@
-- alongside @owner@ through every hop, distinguishing two lookup modes:
--
--   * __Coupled__ (@root == owner@ at the start of a hop): true at the very
--     first hop, and again immediately after a has-a jump. Means "does this
--     class directly declare a control called @name@." On a miss, the
--     ancestor-chain fallback (via the caller-supplied inherits map) walks
--     @root@, updating @owner@ in lock-step.
--   * __Decoupled__ (@root \/= owner@): nested visual-tree hops, where
--     @owner@ is a literal parent-control name distinct from @root@. On a
--     miss, only @root@ climbs its own ancestor chain; @owner@ stays fixed
--     — a nested override not redeclared by the current window may still
--     be inherited from an ancestor's file, but always under the same
--     literal parent name.
--
-- The same coupled\/decoupled distinction governs D1 override-unwinding
-- ('resolveHop'\'s @unwind@): whether the override target's @owner@ tracks
-- its new @root@ (coupled: the overridden decl was itself a top-level
-- declaration) or stays fixed (decoupled: the overridden decl was nested
-- under a literal parent name, e.g. @page1@\'s override target is still
-- scoped to @tab1@ in the ancestor's own file, not to the ancestor class
-- itself). Coupled-ness is derived for free from @foundRoot == cdOwner
-- decl@ — no separate flag needs threading.
module PB.Analysis.ControlHierarchy
  ( ControlDecl (..)
  , ControlIndex
  , buildControlIndex
  , resolveMemberChainType
  , resolveMemberChainDwBinding
  , findLiteralDataObject
  ) where

import PB.Prelude
import PB.AST.BodyStmt    (BodyStmt (..))
import PB.AST.Expr        (Expr (..))
import PB.AST.Ident       (Ident, mkIdent, identOrig, identCanon)
import PB.AST.Located     (Located (..))
import PB.AST.SourceFile
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set

-- | Every declared control across the workspace: which object it belongs to
-- (owner), what it's declared as (ancestor class, or a same-named override
-- per 'splitAncestorRef'), and its own static DataWindow binding if any.
-- Every 'Ident' field compares case-insensitively via 'Ident''s own 'Eq'\/
-- 'Ord' (PowerBuilder identifiers are case-insensitive); 'cdDwBinding' is
-- the only field that isn't a PB identifier, so it stays verbatim 'Text'.
data ControlDecl = ControlDecl
  { cdOwner         :: Ident         -- ^ object/control this control lives within (tdWithin, or its own name when top-level)
  , cdName          :: Ident         -- ^ this control's own name (tdName), or "this" for a top-level TypeBlock
  , cdAncestorType  :: Ident         -- ^ split ancestor class (D1)
  , cdOverridesName :: Maybe Ident   -- ^ D1 backtick override target, if any
  , cdDwBinding     :: Maybe Text    -- ^ verbatim; literal dataobject= value declared directly on this block
  } deriving (Eq, Show)

-- | (root, owner, name) -> declaration, all three components 'Ident'-keyed
-- for case-insensitive lookup. @root@ is the top-level object of the file
-- that declared this control (Phase E) — see the module haddock for why
-- @owner@ alone is ambiguous.
type ControlIndex = Map.Map (Ident, Ident, Ident) ControlDecl

-- | Build the workspace-wide control index from every 'TypeBlock' in every
-- file, keyed by (that file's own primary object, the block's literal
-- owner, the block's own name). When multiple files declare the exact same
-- (root, owner, name) triple — i.e. the same file re-declares a block, not
-- two different windows sharing a generic name — the last one in the input
-- list wins (ordinary 'Map.fromList' bias); callers should pass files in a
-- stable order.
buildControlIndex :: [SrFile] -> ControlIndex
buildControlIndex sfs = Map.fromList
  [ ((mkIdent root, mkIdent owner, mkIdent name), decl)
  | sf <- sfs
  , let root = identOrig (fst (srPrimaryObject sf))
  , tb <- srTypeBlocks sf
  , let td = tbDecl tb
        (owner, name) = case tdWithin td of
          Just parent -> (parent, identOrig (tdName td))
          Nothing     -> (identOrig (tdName td), "this")
        decl = ControlDecl
          { cdOwner         = mkIdent owner
          , cdName          = mkIdent name
          , cdAncestorType  = tdAncestorClass td
          , cdOverridesName = tdAncestorOverride td
          , cdDwBinding     = findLiteralDataObject (tbBody tb)
          }
  ]

-- | Resolve a dotted member-chain starting from a known object context to
-- its terminal control's effective type (the ancestor type of the final,
-- non-overridden declaration reached after following every D1 override).
-- 'Nothing' when any hop is unresolvable — no guessing past what the
-- workspace actually declares.
resolveMemberChainType :: ControlIndex -> Map.Map Ident Ident -> Text -> [Text] -> Maybe Text
resolveMemberChainType idx inh obj segs =
  identCanon . cdAncestorType . snd <$> resolveChain idx inh (mkIdent obj) (mkIdent obj) (map mkIdent segs)

-- | Resolve a dotted member-chain to its terminal control's static
-- DataWindow binding, walking the same chain as 'resolveMemberChainType'.
-- Unlike the effective /type/ (which fully unwinds to the base declaration),
-- the binding search stops at the closest override that sets a literal
-- @dataobject@ — a more-derived override's own binding must win over
-- whatever its ancestor declares (or doesn't declare) further up the chain.
resolveMemberChainDwBinding :: ControlIndex -> Map.Map Ident Ident -> Text -> [Text] -> Maybe Text
resolveMemberChainDwBinding idx inh obj segs =
  case resolveChain idx inh (mkIdent obj) (mkIdent obj) (map mkIdent segs) of
    Nothing              -> Nothing
    Just (dwBinding, _)  -> dwBinding

-- | Walk every chain segment, threading @root@ (Phase E) alongside @owner@.
-- Each hop resolves via 'resolveHop', then the next lookup scope is chosen:
-- first the resolved control's own literal name with @root@ held fixed
-- (visual-tree convention — still the same window's own declaration space),
-- falling back to switching /both/ @root@ and @owner@ to the fully-resolved
-- ancestor type (has-a convention) only if the literal-name continuation
-- fails to resolve the rest of the chain. Returns the closest-wins DW
-- binding accumulated over the *terminal* hop only (each hop's own binding
-- is irrelevant once we've moved past it to the next segment).
resolveChain :: ControlIndex -> Map.Map Ident Ident -> Ident -> Ident -> [Ident] -> Maybe (Maybe Text, ControlDecl)
resolveChain _   _   _    _     []         = Nothing
resolveChain idx inh root owner (seg:rest) = do
  (dwBinding, decl) <- resolveHop idx inh root owner seg
  if null rest
    then Just (dwBinding, decl)
    else case resolveChain idx inh root (nextOwner decl) rest of
           Just r  -> Just r
           Nothing -> resolveChain idx inh (cdAncestorType decl) (cdAncestorType decl) rest
  where
    -- A resolved hop whose own name is the "this" sentinel (the enclosing
    -- object's own top-level 'TypeBlock', per 'buildControlIndex') has no
    -- real control named "this" for the next hop to be declared @within@ --
    -- continuing the visual-tree lookup must use the object's own identity
    -- ('cdOwner', which 'buildControlIndex' sets to the object name itself
    -- for a top-level block), not the literal placeholder. Without this,
    -- a 2+-hop chain rooted at @this@ (e.g. @this.dw_1.Retrieve()@) always
    -- missed the visual-tree lookup and fell through to the has-a branch,
    -- which jumps straight to the object's ancestor and skips its own
    -- direct declarations.
    nextOwner decl
      | identCanon (cdName decl) == "this" = cdOwner decl
      | otherwise                          = cdName decl

-- | Resolve one segment under one (root, owner) scope: direct-or-inherited
-- lookup, then unwind any D1 override chain. Returns the closest-wins DW
-- binding found anywhere along the chain, paired with the fully-unwound
-- terminal (non-overridden) decl, whose 'cdAncestorType' is the control's
-- true base type. Cycle-safe via a visited (root, owner, name) set on the
-- override walk.
resolveHop :: ControlIndex -> Map.Map Ident Ident -> Ident -> Ident -> Ident -> Maybe (Maybe Text, ControlDecl)
resolveHop idx inh root owner name = do
  (foundRoot, decl) <- lookupScoped idx inh root owner name
  Just (unwind Set.empty foundRoot decl)
  where
    unwind seen curRoot decl = case cdOverridesName decl of
      Nothing -> (cdDwBinding decl, decl)
      Just overrideName
        | target `Set.member` seen -> (cdDwBinding decl, decl)
        | otherwise -> case lookupScoped idx inh targetRoot targetOwner overrideName of
            Nothing -> (cdDwBinding decl, decl)
            Just (nextRoot, next) ->
              let (dwFromRest, terminal) = unwind (Set.insert target seen) nextRoot next
              in (cdDwBinding decl <|> dwFromRest, terminal)
        where
          -- Coupled iff the decl being overridden was itself a top-level
          -- declaration (root == owner at the point it was found) — then
          -- the override target's owner tracks its new root too. Decoupled
          -- (a nested literal parent, e.g. page1 within tab1) keeps owner
          -- fixed: the override target is still scoped to the same literal
          -- parent name, just in the ancestor class's own file.
          coupled     = curRoot == cdOwner decl
          targetRoot  = cdAncestorType decl
          targetOwner = if coupled then cdAncestorType decl else cdOwner decl
          target      = (targetRoot, targetOwner, overrideName)

-- | Look up (root, owner, name) directly; if absent, walk root's own
-- class-ancestor chain via inh (cycle-safe via a visited-root set), retrying
-- at each ancestor. When @root == owner@ at the start (a "coupled" lookup —
-- this class's own direct declaration), @owner@ tracks @root@ through the
-- walk. Otherwise (a "decoupled" nested lookup — @owner@ is a literal
-- parent-control name distinct from @root@) @owner@ stays fixed and only
-- @root@ climbs. Returns the root at which the entry was actually found,
-- alongside the decl. Mirrors 'PB.Analysis.TypeEnv.walkInheritChain'\'s
-- cycle guard.
lookupScoped :: ControlIndex -> Map.Map Ident Ident -> Ident -> Ident -> Ident -> Maybe (Ident, ControlDecl)
lookupScoped idx inh root0 owner0 name = go Set.empty root0 owner0
  where
    coupled = root0 == owner0
    go seen root owner
      | root `Set.member` seen                         = Nothing
      | Just decl <- Map.lookup (root, owner, name) idx = Just (root, decl)
      | Just parent <- Map.lookup root inh              =
          go (Set.insert root seen) parent (if coupled then parent else owner)
      | otherwise                                       = Nothing

-- | The literal string value of a @dataobject@ property set directly in a
-- 'TypeBlock's body (via a 'BsLocalVar' with a string-literal initializer),
-- if any. Shared by 'PB.Analysis.TypeResolve.extractDwControlBindings'
-- (per-file) and 'buildControlIndex' (workspace-wide).
findLiteralDataObject :: [Located BodyStmt] -> Maybe Text
findLiteralDataObject stmts = case
  [ s
  | Located _ BsLocalVar { varName = n, varInit = Just (ExStr s) } <- stmts
  , identCanon n == "dataobject"
  ] of
    (s:_) -> Just s
    []    -> Nothing
