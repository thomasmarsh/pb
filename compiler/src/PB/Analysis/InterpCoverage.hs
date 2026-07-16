-- | Static coverage measurement over a procedure's parsed body: classifies
-- every 'Expr' 'PB.Compile.ValueModel.evalExprMocked' will ever see, by
-- whether it can resolve to a concrete value (with or without a mock) or
-- always falls through to that evaluator's 'PB.Compile.ValueModel.VNull'
-- catch-all. This is the "unmodeled-call-site density" number Tier 2's
-- symbolic/path-forking execution bet should be sized against, not a
-- nice-to-have.
--
-- Walks the pre-compiled AST ('[Located BodyStmt]'), not the compiled
-- 'PB.Compile.IR.EffTerm' -- the AST is a tree, so every branch/call/assign
-- site is visited exactly once by construction. A compiled 'EffTerm' is a
-- graph: a CFG merge point shared by N branch predecessors is reached via N
-- separate 'PB.Compile.IR.EFanIn' references to one 'PB.Compile.IR.ELetRef'
-- body, so a first attempt at this module that folded the compiled term
-- instead counted that body's sites once per predecessor -- one real-corpus
-- procedure (a giant case-style dispatch, openpay's
-- @afxlib.pbl\/fn_dateolografos.srf@) alone produced 10.1M of 10.2M sites
-- in that corpus, swamping the density signal from the other 286 files.
module PB.Analysis.InterpCoverage
  ( SiteKind (..)
  , ExprCoverage (..)
  , CoverageSite (..)
  , CoverageSummary (..)
  , classifyExprCoverage
  , collectCoverage
  , summarizeCoverage
  , summarizeCoverageByKind
  ) where

import PB.Prelude
import PB.AST.Expr (Expr (..), Lvalue (..), LvSegment (..))
import PB.AST.Located (Located (..))
import PB.AST.BodyStmt
  ( BodyStmt (..), IfStmt (..), ElseIf (..), ForStmt (..), DoStmt (..)
  , DoCondition (..), ChooseStmt (..), CaseClause (..), TryStmt (..), CatchClause (..)
  )
import PB.Analysis.CallClassify (parseArgList)

import qualified Data.Map.Strict as Map

-- | Where in the source a classified 'Expr' occurs.
data SiteKind = BranchCond | CallArg | AssignRhs
  deriving (Eq, Ord, Show)

-- | Whether 'PB.Compile.ValueModel.evalExprMocked' can resolve this
-- expression shape.
data ExprCoverage
  = FullyModeled          -- ^ literal or variable read: resolvable with no mock.
  | NeedsMock              -- ^ call-shaped: resolvable only if a mock table entry hits.
  | StructurallyUnmodeled  -- ^ always falls to VNull, mocked or not.
  deriving (Eq, Ord, Show)

data CoverageSite = CoverageSite { csKind :: SiteKind, csCoverage :: ExprCoverage }
  deriving (Eq, Show)

-- | Mirrors 'PB.Compile.ValueModel.evalExprMocked's own pattern match: every
-- shape that evaluator resolves without needing 'PB.Compile.ValueModel.MockResponses'
-- is 'FullyModeled'; 'ExCall'\/'ExMethodCall' are 'NeedsMock' (resolvable
-- only given a mock-table hit); everything else falls through to that
-- evaluator's 'VNull' catch-all regardless of mocking, hence
-- 'StructurallyUnmodeled'.
classifyExprCoverage :: Expr -> ExprCoverage
classifyExprCoverage (ExBool _) = FullyModeled
classifyExprCoverage (ExInt _)  = FullyModeled
classifyExprCoverage (ExReal _) = FullyModeled
classifyExprCoverage (ExStr _)  = FullyModeled
classifyExprCoverage ExNull     = FullyModeled
classifyExprCoverage (ExLvalue (Lvalue [LvSegment _ Nothing])) = FullyModeled
classifyExprCoverage (ExBinOp l _ r) = combineCoverage (classifyExprCoverage l) (classifyExprCoverage r)
classifyExprCoverage (ExNot e) = classifyExprCoverage e
classifyExprCoverage (ExNeg e) = classifyExprCoverage e
classifyExprCoverage (ExCall {}) = NeedsMock
classifyExprCoverage (ExMethodCall {}) = NeedsMock
classifyExprCoverage _ = StructurallyUnmodeled

-- | Combine two subexpressions' coverage: the weaker guarantee wins --
-- 'StructurallyUnmodeled' beats 'NeedsMock' beats 'FullyModeled', matching
-- 'evalExprMocked's own strict left-to-right evaluation of both operands.
combineCoverage :: ExprCoverage -> ExprCoverage -> ExprCoverage
combineCoverage StructurallyUnmodeled _ = StructurallyUnmodeled
combineCoverage _ StructurallyUnmodeled = StructurallyUnmodeled
combineCoverage NeedsMock _ = NeedsMock
combineCoverage _ NeedsMock = NeedsMock
combineCoverage FullyModeled FullyModeled = FullyModeled

-- | Every call/branch/assign-rhs site in a procedure body, one entry per
-- syntactic occurrence. Recurses into every nested body ('BsIf'\/'BsFor'\/
-- 'BsDo'\/'BsChoose'\/'BsTry'), mirroring 'PB.Analysis.Taint.extractSqlStmts's
-- recursion shape.
collectCoverage :: [Located BodyStmt] -> [CoverageSite]
collectCoverage = concatMap (stmtSites . locNode)

stmtSites :: BodyStmt -> [CoverageSite]
stmtSites (BsLocalVar _ _ _ mInit) = maybe [] assignRhsSite mInit
stmtSites (BsAssign _ rhs) = assignRhsSite rhs
stmtSites (BsAssignExpr _ rhs) = assignRhsSite rhs
stmtSites (BsCall e) = callArgSites e
stmtSites (BsIf (IfStmt cond thenB elseIfs elseB)) =
  branchCondSite cond <> collectCoverage thenB
    <> concatMap (\(ElseIf c b) -> branchCondSite c <> collectCoverage b) elseIfs
    <> maybe [] collectCoverage elseB
stmtSites (BsFor (ForStmt _ from to step body)) =
  assignRhsSite from <> assignRhsSite to <> maybe [] assignRhsSite step <> collectCoverage body
stmtSites (BsDo (DoStmt cond body loopCond)) =
  maybe [] doCondSite cond <> collectCoverage body <> maybe [] doCondSite loopCond
stmtSites (BsChoose (ChooseStmt switchExpr clauses)) =
  branchCondSite switchExpr <> concatMap (collectCoverage . ccBody) clauses
stmtSites (BsTry (TryStmt tryBody catches)) =
  collectCoverage tryBody <> concatMap (collectCoverage . catchBody) catches
stmtSites (BsReturn (Just e)) = assignRhsSite e
stmtSites (BsThrow e) = assignRhsSite e
stmtSites _ = []

doCondSite :: DoCondition -> [CoverageSite]
doCondSite (DoWhile e) = branchCondSite e
doCondSite (DoUntil e) = branchCondSite e

branchCondSite :: Expr -> [CoverageSite]
branchCondSite e = [CoverageSite BranchCond (classifyExprCoverage e)]

assignRhsSite :: Expr -> [CoverageSite]
assignRhsSite e = [CoverageSite AssignRhs (classifyExprCoverage e)]

-- | One 'CallArg' site per argument, parsed via the same 'parseArgList'
-- 'PB.Compile.ValueModel.evalExprMocked' itself uses to resolve a real
-- call's raw token-list arguments -- so a site here is classified exactly
-- as that evaluator would classify it. Any 'Expr' shape other than
-- 'ExCall'\/'ExMethodCall' standing alone as a statement (rare; classifyBodyStmt
-- normally only produces those two here) contributes nothing.
callArgSites :: Expr -> [CoverageSite]
callArgSites (ExCall _ rawArgs) = map (argSite . parseArgList) rawArgs
callArgSites (ExMethodCall _ _ rawArgs) = map (argSite . parseArgList) rawArgs
callArgSites _ = []

argSite :: Expr -> CoverageSite
argSite = CoverageSite CallArg . classifyExprCoverage

data CoverageSummary = CoverageSummary
  { csvTotal, csvFullyModeled, csvNeedsMock, csvStructurallyUnmodeled :: Int }
  deriving (Eq, Show)

summarizeCoverage :: [CoverageSite] -> CoverageSummary
summarizeCoverage sites = CoverageSummary
  { csvTotal = length sites
  , csvFullyModeled = countCoverage FullyModeled
  , csvNeedsMock = countCoverage NeedsMock
  , csvStructurallyUnmodeled = countCoverage StructurallyUnmodeled
  }
  where countCoverage c = length (filter ((== c) . csCoverage) sites)

summarizeCoverageByKind :: [CoverageSite] -> Map.Map SiteKind CoverageSummary
summarizeCoverageByKind sites =
  Map.map summarizeCoverage (Map.fromListWith (<>) [ (csKind s, [s]) | s <- sites ])
