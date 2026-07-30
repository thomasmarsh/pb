{-# LANGUAGE StrictData #-}
-- | SQL lint: detect common anti-patterns in embedded SQL statements.
--
-- Pure module — no I/O. Two independent, bounded per-procedure checks:
-- 'lintStmt' (SELECT * / write-without-WHERE, driven off one already-
-- classified SQL statement's raw text and operation, the same shape
-- 'PB.Analysis.Taint.extractSqlStmts' produces) and 'lintLoopSql' (a DML
-- statement issued inside a loop body — a distinct AST-shape check that
-- needs the un-flattened body, since 'SqlStmt' carries no loop-nesting
-- context).
module PB.Analysis.SqlLint
  ( LintIssue (..)
  , lintStmt
  , sqlInLoopLines
  , lintLoopSql
  ) where

import PB.Prelude
import PB.AST.BodyStmt   (BodyStmt (..), stmtChildren)
import PB.AST.Located    (Located (..))
import PB.Analysis.Taint (classifyOperation)
import qualified Data.Text as T
import qualified Data.Set  as Set
import GHC.Generics (Generic)

data LintIssue = LintIssue
  { liLine      :: Int
  , liIssueCode :: Text
  , liSeverity  :: Text
  } deriving (Eq, Show, Generic)

-- | select_star / write_no_where, from one already-extracted SQL statement's
-- line, classified operation, and raw text.
lintStmt :: Int -> Maybe Text -> Text -> [LintIssue]
lintStmt line operation rawSql =
  [ LintIssue line "select_star" "warning"
  | operation == Just "SELECT", isSelectStar rawSql ]
  <> [ LintIssue line "write_no_where" "error"
     | operation `elem` [Just "UPDATE", Just "DELETE"], not (hasWhereClause rawSql) ]

-- | The token immediately after SELECT (or SELECT DISTINCT) is a bare '*'
-- or a qualified 'alias.*' — covers "SELECT *", "SELECT DISTINCT *",
-- "SELECT *, foo", "SELECT t.*". Deliberately word-boundary-based, not a
-- bare substring scan: "SELECT quantity*price FROM t" (no space around an
-- arithmetic '*') tokenizes as one word and never matches.
isSelectStar :: Text -> Bool
isSelectStar = afterSelect . T.words . T.toUpper
  where
    afterSelect ("SELECT":rest)   = afterDistinct rest
    afterSelect (_:rest)          = afterSelect rest
    afterSelect []                 = False
    afterDistinct ("DISTINCT":rest) = afterDistinct rest
    afterDistinct (tok:_)           =
      let stripped = T.takeWhile (/= ',') tok
      in stripped == "*" || ".*" `T.isSuffixOf` stripped
    afterDistinct []                 = False

-- | Same raw-text heuristic 'PB.Analysis.Taint.hasIntoClause' uses for its
-- own SELECT...INTO check: a WHERE clause is looked for anywhere in the
-- statement text, not parsed structurally (no sqlglot AST is available to
-- this module — 'PB.Pipeline.SqlParse' output isn't threaded this deep).
hasWhereClause :: Text -> Bool
hasWhereClause = T.isInfixOf "WHERE" . T.toUpper

-- | DML operations worth flagging inside a loop. Deliberately excludes
-- DECLARE/OPEN/FETCH/CLOSE (the standard PB cursor-loop idiom —
-- @do ... fetch cursor into :var ... loop@ — issues those every iteration
-- by design) and COMMIT/ROLLBACK/CONNECT/DISCONNECT (transaction/connection
-- management, not a data-access anti-pattern).
dmlOps :: Set.Set Text
dmlOps = Set.fromList ["SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE"]

isLoopStmt :: BodyStmt -> Bool
isLoopStmt (BsFor _) = True
isLoopStmt (BsDo _)  = True
isLoopStmt _         = False

isDmlRaw :: BodyStmt -> Bool
isDmlRaw (BsRaw txt) = classifyOperation txt `Set.member` dmlOps
isDmlRaw _           = False

-- | Lines of DML 'BsRaw' statements reachable inside a 'BsFor'/'BsDo' body,
-- at any nesting depth (through 'BsIf'/'BsChoose'/'BsTry' branches, which
-- don't themselves start or end loop context — 'stmtChildren' recurses
-- generically so a new compound 'BodyStmt' can't silently fall outside this
-- walk, the same structural guarantee 'PB.AST.BodyStmt.foldStmts' gives its
-- callers).
sqlInLoopLines :: [Located BodyStmt] -> [Int]
sqlInLoopLines = go False
  where
    go :: Bool -> [Located BodyStmt] -> [Int]
    go inLoop = concatMap step
      where
        step (Located line s) =
          [ line | inLoop, isDmlRaw s ]
          <> concatMap (go (inLoop || isLoopStmt s)) (stmtChildren s)

lintLoopSql :: [Located BodyStmt] -> [LintIssue]
lintLoopSql body = [ LintIssue line "sql_in_loop" "warning" | line <- sqlInLoopLines body ]
