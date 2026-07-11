-- | Plan 161 Phase 1 -- the DuckDB-native rule-set-to-SQL compiler. Every
-- derived (IDB) relation is a small set of Datalog-style rules over
-- existing DuckDB tables/views (EDB relations); 'runRuleSet' materializes
-- each derived relation into its own table, in dependency ("stratum")
-- order, so a rule that negates another derived relation always sees that
-- relation fully computed first (see Plan 161's Open Question 4).
--
-- Scope (Phase 1): join + equality + stratified negation + single-relation
-- self-recursion (the 'reachesRules' shape). No aggregates, no mutual
-- recursion across two or more distinct relations -- 'stratify' rejects
-- any cross-relation cycle (positive or negative) as unstratifiable rather
-- than guessing an evaluation order for it; extend when a real rule needs
-- it (see Plan 161 Phase 3).
module PB.Pipeline.Datalog
  ( Relation (..)
  , Literal (..)
  , Rule (..)
  , RuleSet (..)
  , stratify
  , compileRelation
  , runRuleSet
  , runRuleSetWith
  , initEdbViews
  , reachesRules
  , liveProcRules
  ) where

import PB.Prelude

import Database.DuckDB.Simple (Connection, Query (..), execute_)

import Data.List         (partition)
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import qualified Data.Text       as T

-- ---------------------------------------------------------------------------
-- Rule IR

-- | A named relation with its column names, in positional order. For a
-- derived relation this also names the DuckDB table 'runRuleSet' creates;
-- for an EDB relation it names an existing table or a view 'initEdbViews'
-- creates over one.
data Relation = Relation
  { relName :: Text
  , relCols :: [Text]
  } deriving (Eq, Ord, Show)

-- | One literal in a rule body (or the head). 'litArgs' are variable names
-- or the wildcard @"_"@, positionally aligned to 'relCols' of 'litRelation'
-- (same arity -- mismatched lengths are a malformed 'Rule').
data Literal = Literal
  { litRelation :: Relation
  , litArgs     :: [Text]
  , litNegated  :: Bool
  } deriving (Eq, Show)

-- | One Horn clause: @ruleHead :- ruleBody@. 'litNegated' on 'ruleHead' is
-- always 'False'.
data Rule = Rule
  { ruleHead :: Literal
  , ruleBody :: [Literal]
  } deriving (Eq, Show)

-- | A whole program: every derived relation it defines, and every rule
-- (a relation may have several alternative rules, unioned together).
data RuleSet = RuleSet
  { rsRelations :: [Relation]
  , rsRules     :: [Rule]
  } deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Stratification

-- | Order 'rsRelations' so that every relation a rule depends on (whether
-- negated or not) is materialized before that rule runs. A relation
-- depending on itself (direct self-reference, the recursive-relation
-- shape) is not an ordering dependency -- it is compiled to a single
-- @WITH RECURSIVE@ statement in 'compileRelation' instead. Any other cycle
-- among 2+ distinct derived relations is rejected as unstratifiable
-- (Phase 1 scope does not support cross-relation mutual recursion).
stratify :: RuleSet -> Either Text [Relation]
stratify rs = do
  ordered <- topoSort names dependsOn
  pure [ byName Map.! n | n <- ordered ]
  where
    byName = Map.fromList [ (relName r, r) | r <- rsRelations rs ]
    names  = map relName (rsRelations rs)

    dependsOn :: Text -> Set.Set Text
    dependsOn headName = Set.fromList
      [ relName (litRelation b)
      | r <- rsRules rs
      , relName (litRelation (ruleHead r)) == headName
      , b <- ruleBody r
      , relName (litRelation b) /= headName
      , relName (litRelation b) `Map.member` byName
      ]

-- | Kahn's algorithm: repeatedly place any not-yet-placed name whose
-- dependencies are all already placed. 'Left' if some names never become
-- placeable (a cycle).
topoSort :: [Text] -> (Text -> Set.Set Text) -> Either Text [Text]
topoSort names deps = go names Set.empty []
  where
    go [] _ acc = Right (reverse acc)
    go remaining placed acc = case filter ready remaining of
      []    -> Left ("unstratifiable: cyclic dependency among relations: "
                        <> T.intercalate ", " remaining)
      (n:_) -> go (filter (/= n) remaining) (Set.insert n placed) (n : acc)
      where
        ready n = deps n `Set.isSubsetOf` placed

-- ---------------------------------------------------------------------------
-- Compiler

-- | Every occurrence of a bound variable resolves to its first occurrence's
-- @alias.column@ reference.
type Bindings = Map.Map Text Text

lookupBound :: Bindings -> Text -> Text
lookupBound bindings var = Map.findWithDefault
  (error ("PB.Pipeline.Datalog: unbound variable " <> T.unpack var
            <> " (every head/negated-literal variable must be bound by an earlier positive body literal)"))
  var bindings

-- | Compile one rule's body to @(fromClause, whereConds)@ and return the
-- variable bindings established, so the head can look variables up.
compileBody :: [Literal] -> (Text, [Text], Bindings)
compileBody body =
  let aliased               = zip body [0 :: Int ..]
      (negatives, positives) = partitionNeg aliased
      bindings = foldl' bindLiteral Map.empty positives
      fromClause = T.intercalate ", "
        [ relName (litRelation l) <> " AS " <> aliasOf i | (l, i) <- positives ]
      eqConds = concat
        [ [ aliasOf i <> "." <> col <> " = " <> ref
          | (col, arg) <- zip (relCols (litRelation l)) (litArgs l)
          , arg /= "_"
          , let ref = lookupBound bindings arg
          , ref /= aliasOf i <> "." <> col
          ]
        | (l, i) <- positives
        ]
      negConds =
        [ "NOT EXISTS (SELECT 1 FROM " <> relName (litRelation l) <> " WHERE "
            <> T.intercalate " AND "
                 [ col <> " = " <> lookupBound bindings arg
                 | (col, arg) <- zip (relCols (litRelation l)) (litArgs l)
                 , arg /= "_"
                 ]
            <> ")"
        | (l, _) <- negatives
        ]
  in (fromClause, eqConds <> negConds, bindings) `seq` (fromClause, eqConds <> negConds, bindings)
  where
    aliasOf i = "b" <> T.pack (show i)
    partitionNeg xs = (filter (litNegated . fst) xs, filter (not . litNegated . fst) xs)
    bindLiteral m (l, i) =
      foldl'
        (\m' (col, arg) ->
           if arg == "_" || Map.member arg m'
             then m'
             else Map.insert arg (aliasOf i <> "." <> col) m'
        )
        m
        (zip (relCols (litRelation l)) (litArgs l))

-- | Compile one full rule (head + body) to a single @SELECT DISTINCT ...@.
compileRule :: Rule -> Text
compileRule (Rule headLit body) =
  let (fromClause, whereConds, bindings) = compileBody body
      whereClause = if null whereConds then "" else " WHERE " <> T.intercalate " AND " whereConds
      selectList = T.intercalate ", "
        [ lookupBound bindings arg <> " AS " <> col
        | (col, arg) <- zip (relCols (litRelation headLit)) (litArgs headLit)
        ]
  in "SELECT DISTINCT " <> selectList <> " FROM " <> fromClause <> whereClause

-- | A relation with no rules at all compiles to a well-typed empty result.
emptyRelationQuery :: Relation -> Text
emptyRelationQuery rel =
  "SELECT " <> T.intercalate ", "
    [ "CAST(NULL AS VARCHAR) AS " <> c | c <- relCols rel ]
    <> " WHERE FALSE"

-- | Compile every rule whose head is this relation into one SQL query
-- producing that relation's rows. A rule whose body positively references
-- its own head relation (direct self-reference) compiles to a
-- @WITH RECURSIVE@ statement; the union of every other ("base") rule for
-- the relation is the non-recursive term.
compileRelation :: RuleSet -> Relation -> Query
compileRelation rs rel =
  let rules = [ r | r <- rsRules rs, litRelation (ruleHead r) == rel ]
      isSelfRecursive r =
        any (\b -> not (litNegated b) && litRelation b == rel) (ruleBody r)
      (recRules, baseRules) = partition isSelfRecursive rules
  in Query $ case rules of
       [] -> emptyRelationQuery rel
       _ | null recRules -> unionOf (map compileRule baseRules)
         | otherwise ->
             "WITH RECURSIVE " <> relName rel
               <> "(" <> T.intercalate ", " (relCols rel) <> ") AS ("
               <> unionOf (map compileRule baseRules)
               <> " UNION "
               <> unionOf (map compileRule recRules)
               <> ") SELECT DISTINCT * FROM " <> relName rel
  where
    unionOf [q] = q
    unionOf qs  = T.intercalate " UNION " [ "(" <> q <> ")" | q <- qs ]

-- | Materialize every relation in 'rsRelations', in 'stratify' order, as a
-- DuckDB table (dropping any previous table of the same name first).
runRuleSet :: Connection -> RuleSet -> IO ()
runRuleSet = runRuleSetWith (\_ -> pure ())

-- | Like 'runRuleSet', but calls the given action just before materializing
-- each relation. A pipeline pass wires this to its own progress-reporting
-- protocol so a caller-visible reporter gets one update per relation
-- instead of a single opaque step spanning the whole ruleset (a real
-- (though currently minor) UX gap this project's Python reporter already
-- has for other multi-relation passes -- see Plan 161 Phase 1's Status
-- note and Plan 161's own "Phase 3" section: as more/larger rule sets are
-- added there, this per-relation granularity is what keeps that step from
-- becoming a long silent pause).
runRuleSetWith :: (Relation -> IO ()) -> Connection -> RuleSet -> IO ()
runRuleSetWith onRelation conn rs = case stratify rs of
  Left err -> error ("PB.Pipeline.Datalog.runRuleSet: " <> T.unpack err)
  Right order -> for_ order $ \rel -> do
    onRelation rel
    void $ execute_ conn (Query ("DROP TABLE IF EXISTS " <> relName rel))
    let Query sql = compileRelation rs rel
    void $ execute_ conn (Query ("CREATE TABLE " <> relName rel <> " AS " <> sql))

-- ---------------------------------------------------------------------------
-- EDB views over existing DuckDB tables (no fact marshalling -- the rule
-- compiler queries these directly)

-- | (Re)create the EDB views every 'RuleSet' below assumes already exist:
-- @leg@ over 'schema_morphisms', @dead@ over 'dead_code', @stmt@ over the
-- 'StmtObj' rows of 'schema_objects'. Must run after
-- 'PB.Pipeline.DuckDb.initSchema'.
initEdbViews :: Connection -> IO ()
initEdbViews conn = for_ views (void . execute_ conn)
  where
    views :: [Query]
    views =
      [ "CREATE OR REPLACE VIEW leg AS \
        \SELECT from_key AS x, to_key AS y, leg_kind FROM schema_morphisms"
      , "CREATE OR REPLACE VIEW dead AS \
        \SELECT object, proc_name AS proc FROM dead_code"
      , -- 'dw_retrieve'-kind schema_objects rows are deliberately excluded: their
        -- stmt_proc is always NULL (a DW retrieve isn't a procedure), which would
        -- make `dead(Object,Proc)` vacuously never match and every DW retrieve
        -- unconditionally "live" -- confirmed against the real openpay corpus
        -- (114/115 stmt rows were dw_retrieve noise before this restriction).
        "CREATE OR REPLACE VIEW stmt AS \
        \SELECT stmt_file AS file, stmt_object AS object, stmt_proc AS proc, stmt_line AS line \
        \FROM schema_objects WHERE kind = 'stmt'"
      ]

-- ---------------------------------------------------------------------------
-- Concrete programs

legRel, reachesRel :: Relation
legRel     = Relation "leg" ["x", "y", "leg_kind"]
reachesRel = Relation "reaches" ["x", "y"]

-- | @reaches(X,Y) :- leg(X,Y,_).@
-- @reaches(X,Z) :- reaches(X,Y), leg(Y,Z,_).@
--
-- The Phase 0-validated port of 'PB.Analysis.SchemaCategory.blastRadius'/
-- 'validationWalkBack''s existence-only core: both functions' reachable-set
-- reprojects off this single relation (see Plan 161's Design section).
reachesRules :: RuleSet
reachesRules = RuleSet
  { rsRelations = [reachesRel]
  , rsRules =
      [ Rule (Literal reachesRel ["x", "y"] False)
             [ Literal legRel ["x", "y", "_"] False ]
      , Rule (Literal reachesRel ["x", "z"] False)
             [ Literal reachesRel ["x", "y"] False
             , Literal legRel ["y", "z", "_"] False
             ]
      ]
  }

stmtRel, deadRel, liveProcRel :: Relation
stmtRel     = Relation "stmt" ["file", "object", "proc", "line"]
deadRel     = Relation "dead" ["object", "proc"]
liveProcRel = Relation "live_proc" ["object", "proc"]

-- | @live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !dead(Object,Proc).@
--
-- Real stratified-negation demonstration answering Plan 161's Open
-- Question 4: 'dead' (from 'PB.Analysis.DeadCode', materialized by Pass 8)
-- is fully computed before this program ever runs, so no cross-run
-- ordering is needed here -- 'stratify' only has to confirm 'live_proc'
-- itself isn't negatively self-referential.
liveProcRules :: RuleSet
liveProcRules = RuleSet
  { rsRelations = [liveProcRel]
  , rsRules =
      [ Rule (Literal liveProcRel ["object", "proc"] False)
             [ Literal stmtRel ["_", "object", "proc", "_"] False
             , Literal deadRel ["object", "proc"] True
             ]
      ]
  }
