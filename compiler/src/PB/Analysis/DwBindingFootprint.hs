-- | The DW property\/expression-binding-to-column-dependency-edge producer
-- -- a sibling to 'PB.Analysis.SchFootprint's @Fps@ and
-- 'PB.Analysis.DwFootprint's @Fdw@ functors, but targeting a third,
-- independent category: not the DB schema, but which column's data a
-- control's rendering (or a column's own validation) reactively depends
-- on. Like 'PB.Analysis.DwFootprint', this is a plain, total walk over an
-- already-parsed 'PB.AST.DataWindow.DataWindowFile' -- these are
-- declarative bindings the DataWindow engine re-evaluates whenever the
-- referenced column's data changes, not sequential PowerScript with
-- control flow to fold.
module PB.Analysis.DwBindingFootprint
  ( DwBindKind (..)
  , DwBindEdge (..)
  , columnNameRef
  , dwBindingFootprint
  ) where

import PB.Prelude
import PB.AST.DataWindow (DataWindowFile (..), DwTable (..), DwColumn (..), DwControl (..))
import PB.AST.Expr        (Expr (..), Lvalue (..), LvSegment (..), foldExprs)
import PB.AST.Ident        (identCanon)

import qualified Data.Set  as Set
import qualified Data.Text as T

-- | Which expression-valued property a dependency edge's target slot is.
data DwBindKind
  = BindExpression    -- ^ 'PB.AST.DataWindow.dwcParsedExpression' (a control's compute formula).
  | BindFormat        -- ^ 'PB.AST.DataWindow.dwcParsedFormat'.
  | BindColor         -- ^ 'PB.AST.DataWindow.dwcParsedColor'.
  | BindValidation    -- ^ 'PB.AST.DataWindow.dcParsedValidation'.
  | BindValidationMsg -- ^ 'PB.AST.DataWindow.dcParsedValidationMsg'.
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | One dependency edge: the binding named by @dbeToKind@\/@dbeToName@
-- (a control or column, identified by name within this DW) reactively
-- depends on @dbeFromColumn@'s data.
data DwBindEdge = DwBindEdge
  { dbeFile       :: Text
  , dbeDwName     :: Text
  , dbeFromColumn :: Text
  , dbeToKind     :: DwBindKind
  , dbeToName     :: Text
  } deriving (Show, Eq, Ord)

-- | Recognize a plain, unsubscripted single-segment lvalue as a bare
-- reference to one of this DataWindow's own data columns. Deliberately
-- narrower than 'PB.Analysis.DwFootprint.lvalueColumnRef' (which matches
-- 2-3 segment @table.column@\/@namespace.table.column@ lvalues for
-- cross-table SQL operands): a binding expression like @color=@ or
-- @validation=@ names a sibling column of the *same* DataWindow by its
-- bare, single-segment name (e.g. @if(salary < 12000, ...)@), never a
-- table-qualified one. Anything else -- a subscript, 2+ segments, or any
-- non-'ExLvalue' expression -- is @Nothing@, and a bare name not present
-- in @cols@ is also @Nothing@ -- no guessing past what the DW's own
-- column list confirms.
columnNameRef :: Set.Set Text -> Expr -> Maybe Text
columnNameRef cols (ExLvalue (Lvalue [LvSegment nm Nothing]))
  | Set.member canon cols = Just canon
  where canon = identCanon nm
columnNameRef _ _ = Nothing

-- | Walk every column-dependency-bearing expression in a
-- 'DataWindowFile' -- controls' @expression=@\/@format=@\/@color=@ and
-- columns' @validation=@\/@validationmsg=@ -- into a 'Set' of dependency
-- edges. @file@\/@dwName@ identify the DataWindow the edges belong to.
dwBindingFootprint :: Text -> Text -> DataWindowFile -> Set.Set DwBindEdge
dwBindingFootprint file dwName dw = Set.unions [controlEdges, columnEdges]
  where
    colNames :: Set.Set Text
    colNames = Set.fromList
      [ T.toLower (dcName c) | Just t <- [dwTable dw], c <- dtColumns t ]

    -- Every column reference anywhere in the expression tree, not just at
    -- the root -- a binding expression is frequently a call or a binary
    -- op wrapping the actual column reference (e.g. the corpus-confirmed
    -- @'...' + dept_id + '...'@ string-concat shape), so a root-only check
    -- would miss real dependencies. 'foldExprs' walks every subterm via
    -- 'PB.AST.Expr.exprChildren'.
    refsOf :: Maybe Expr -> [Text]
    refsOf mExpr =
      [ col | Just e <- [mExpr], col <- foldExprs (maybeToList . columnNameRef colNames) e ]

    mkEdges :: Text -> [(DwBindKind, Maybe Expr)] -> Set.Set DwBindEdge
    mkEdges target bindings = Set.fromList
      [ DwBindEdge file dwName col kind target
      | (kind, mExpr) <- bindings
      , col <- refsOf mExpr
      ]

    controlEdges = Set.unions
      [ mkEdges target
          [ (BindExpression, dwcParsedExpression ctl)
          , (BindFormat,     dwcParsedFormat ctl)
          , (BindColor,      dwcParsedColor ctl)
          ]
      | ctl <- dwControls dw
      , Just target <- [dwcName ctl]
      ]

    columnEdges = Set.unions
      [ mkEdges (dcName col)
          [ (BindValidation,    dcParsedValidation col)
          , (BindValidationMsg, dcParsedValidationMsg col)
          ]
      | Just t <- [dwTable dw]
      , col <- dtColumns t
      ]
