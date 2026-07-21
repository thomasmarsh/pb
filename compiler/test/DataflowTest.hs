module DataflowTest (tests) where

import PB.Prelude
import PB.AST.BodyStmt
import PB.AST.Expr         (Expr (..), LvSegment (..), Lvalue (..))
import PB.AST.Ident        (mkIdent)
import PB.AST.Type         (PbType (..))
import PB.AST.Located      (Located (..))
import PB.Lexing.Lexer        (tokenizeLine, LexLine (..))
import PB.Lexing.Token        (Token (..), TokenKind (..), SourceSpan (..))
import PB.Analysis.Cfg (Cfg (..), CfgBlock (..), CfgEdge (..))
import PB.Pipeline.Preprocess (mkLogicalLine)
import PB.Analysis.Dataflow

import Data.Aeson          (Value (..), toJSON)
import qualified Data.Aeson.Key    as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import qualified Data.Set        as Set
import Test.Tasty           (TestTree, testGroup)
import Test.Tasty.HUnit     (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Helpers

at :: Int -> a -> Located a
at n x = Located n x

lv1 :: Text -> Lvalue
lv1 n = Lvalue [LvSegment (mkIdent n) Nothing]

-- | Real-lex a single value for its correct TokenKind, then normalize its
-- span to a constant dummy -- callers compare against hand-built ASTs that
-- carry the same dummy span, not a real per-character position.
tok :: Text -> Token
tok t = case lexResult (tokenizeLine ll) of
  Right (tk:_) -> tk { tkSpan = SourceSpan 1 1 1 1 }
  _            -> Token TkIdent t (SourceSpan 1 1 1 1)
  where ll = mkLogicalLine t 1

-- | Make a simple CfgBlock for testing.
mkBlock :: Text -> [Located BodyStmt] -> CfgBlock
mkBlock bid stmts = CfgBlock
  { cbId        = bid
  , cbStmts     = stmts
  , cbFirstLine = Nothing
  , cbLastLine  = Nothing
  }

-- | Extract the single element of a list whose length was just asserted to be 1.
one :: [a] -> a
one [x] = x
one _   = error "one: expected single-element list (prior length assertion failed)"

-- | Aeson Value helpers for facet/row assertions (Python consumer shape).
fieldStr :: Text -> Value -> Value
fieldStr k (Object m) = fromMaybe Null (KM.lookup (Key.fromText k) m)
fieldStr _ _          = Null

hasKey :: Text -> Value -> Bool
hasKey k (Object m) = KM.member (Key.fromText k) m
hasKey _ _          = False

arrayAt :: Text -> Value -> [Value]
arrayAt k v = case fieldStr k v of
  Array xs -> toList xs
  _        -> []

-- | Make a minimal Cfg with one block.
mkCfg :: Text -> [CfgBlock] -> [CfgEdge] -> Cfg
mkCfg entry blocks edges = Cfg
  { cfgEntry  = entry
  , cfgExits  = []
  , cfgBlocks = blocks
  , cfgEdges  = edges
  }

-- ---------------------------------------------------------------------------
-- Tests

tests :: TestTree
tests = testGroup "Dataflow"

  [ testGroup "extractDefsUses"
    [ testCase "BsAssign creates def + use" $
        let blk = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "x"
          dsKind (one (bfDefs bf)) @?= "assign"

    , testCase "BsLocalVar with init creates def + use" $
        let blk = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "n" (Just (ExInt "0")))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "n"
          dsKind (one (bfDefs bf)) @?= "local_var"

    , testCase "BsLocalVar without init creates def only" $
        let blk = mkBlock "b0" [at 1 (BsLocalVar [] (PtPrimitive "integer") "n" Nothing)]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          length (bfUses bf) @?= 0

    , testCase "BsAssign with variable rhs creates use" $
        let blk = mkBlock "b0" [at 1 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "y"
          length (bfUses bf) @?= 1
          usVar (one (bfUses bf)) @?= "x"
          usKind (one (bfUses bf)) @?= "rhs"

    , testCase "BsIf condition creates condition use" $
        let blk = mkBlock "b0" [at 1 (BsIf (IfStmt
                { ifCond = ExLvalue (lv1 "flag")
                , ifThen = []
                , ifElseIfs = []
                , ifElse = Nothing
                }))]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 0
          length (bfUses bf) @?= 1
          usVar (one (bfUses bf)) @?= "flag"
          usKind (one (bfUses bf)) @?= "condition"

    , testCase "BsReturn creates return use" $
        let blk = mkBlock "b0" [at 1 (BsReturn (Just (ExLvalue (lv1 "result"))))]
            bf  = extractDefsUses blk
        in do
          length (bfUses bf) @?= 1
          usVar (one (bfUses bf)) @?= "result"
          usKind (one (bfUses bf)) @?= "return"

    , testCase "BsCall creates call_arg uses (callee + args)" $
        let blk = mkBlock "b0" [at 1 (BsCall (ExCall (lv1 "foo")
                [ ExLvalue (lv1 "x"), ExLvalue (lv1 "y") ]))]
            bf  = extractDefsUses blk
        in do
          -- ExCall counts the callee root plus every arg ident (now real
          -- Expr children, reached via exprChildren/foldExprs), so
          -- foo(x, y) → {foo, x, y} = 3 uses.
          length (bfUses bf) @?= 3
          Set.fromList (map usVar (bfUses bf)) @?= Set.fromList ["foo", "x", "y"]
          all (\u -> usKind u == "call_arg") (bfUses bf) @?= True

    , testCase "BsAugAssign def on member-chain lvalue extracts root" $
        let blk = mkBlock "b0" [at 1 (BsAugAssign
                (Lvalue [LvSegment (mkIdent "this") Nothing, LvSegment (mkIdent "count") Nothing])
                AugAdd [tok "1"])]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 1
          dsVar (one (bfDefs bf)) @?= "this"
          dsKind (one (bfDefs bf)) @?= "augassign"

    , testCase "BsInc/BsDec def is case-insensitive with declaration" $
        let blk = mkBlock "b0"
              [ at 1 (BsLocalVar [] (PtPrimitive "integer") "Li_Count" Nothing)
              , at 2 (BsInc (lv1 "li_count"))
              ]
            bf  = extractDefsUses blk
        in bfKill bf @?= Set.singleton "li_count"

    , testCase "gen set matches defs" $
        let blk = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
              , at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
              ]
            bf  = extractDefsUses blk
        in bfGen bf @?= Set.fromList ["x", "y"]

    , testCase "kill set matches defs" $
        let blk = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
              , at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
              ]
            bf  = extractDefsUses blk
        in bfKill bf @?= Set.fromList ["x", "y"]

    , testCase "gen/kill sets fold differently-cased defs of the same variable into one entry" $
        -- Real-corpus shape (openpay.open): SQLCA is defined, then
        -- re-defined as sqlca two lines later -- PB variable names are
        -- case-insensitive, so these must collapse to a single gen/kill
        -- entry, not two.
        let blk = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "SQLCA") (ExInt "1"))
              , at 2 (BsAssign (lv1 "sqlca") (ExInt "2"))
              ]
            bf  = extractDefsUses blk
        in do
          bfGen  bf @?= Set.singleton "sqlca"
          bfKill bf @?= Set.singleton "sqlca"

    , testCase "BsRaw embedded SQL creates a use per :host_var" $
        let blk = mkBlock "b0"
              [ at 1 (BsRaw "select count(kodypal) into :ll_count from misth_ypal \
                             \where kodxrisi = :gs_kodxrisi and exeldate <= :ldt_today") ]
            bf  = extractDefsUses blk
        in do
          length (bfDefs bf) @?= 0
          Set.fromList (map usVar (bfUses bf)) @?= Set.fromList ["ll_count", "gs_kodxrisi", "ldt_today"]
          all (\u -> usKind u == "sql_host_var") (bfUses bf) @?= True

    , testCase "BsAssign with a subscript index on the RHS creates a use of the index var" $
        -- Generalization of the LHS-subscript fix above (Plan 174 T0-1
        -- follow-on, item C): an ExLvalue with a subscript read anywhere in
        -- an expression tree -- not just an assignment's own LHS -- must
        -- surface the subscript's own identifiers too. `y = arr[i]` reads
        -- both `arr` and `i`.
        let rhsLv = Lvalue [LvSegment "arr" (Just ["i"])]
            blk = mkBlock "b0" [at 1 (BsAssign (lv1 "y") (ExLvalue rhsLv))]
            bf  = extractDefsUses blk
        in do
          Set.fromList (map usVar (bfUses bf)) @?= Set.fromList ["arr", "i"]

    , testCase "BsAssign with a subscript index on the LHS creates a use of the index var" $
        -- Real-corpus regression: this.Control[iCurrent+1] = this.pb_expr --
        -- iCurrent is read (to compute which array slot to write) but only
        -- appears inside the LHS's subscript, which extractUseVars never
        -- looked at (it only ever walked the RHS).
        let lhs = Lvalue [LvSegment "this" Nothing, LvSegment "control" (Just ["iCurrent", "+", "1"])]
            blk = mkBlock "b0" [at 1 (BsAssign lhs (ExLvalue (lv1 "pb_expr")))]
            bf  = extractDefsUses blk
        in do
          Set.member "iCurrent" (Set.fromList (map usVar (bfUses bf))) @?= True
    ]

  , testGroup "reachingDefinitions"
    [ testCase "single block: gen propagates to out" $
        let blk  = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b0" (pfReachingOut pf) @?=
            Set.singleton "x"

    , testCase "two blocks linear: def reaches through" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b1" (pfReachingIn pf) @?=
            Set.singleton "x"
          Map.findWithDefault Set.empty "b1" (pfReachingOut pf) @?=
            Set.fromList ["x", "y"]

    , testCase "two blocks: kill removes old def" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "x") (ExInt "2"))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b1" (pfReachingIn pf) @?=
            Set.singleton "x"
          Map.findWithDefault Set.empty "b1" (pfReachingOut pf) @?=
            Set.singleton "x"

    , testCase "diamond: defs from both branches reach merge" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "a") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "b") (ExInt "2"))]
            b2 = mkBlock "b2" [at 3 (BsAssign (lv1 "c") (ExInt "3"))]
            b3 = mkBlock "b3" [at 4 (BsAssign (lv1 "d") (ExLvalue (lv1 "a")))]
            cfg = mkCfg "b0" [b0, b1, b2, b3]
                    [ CfgEdge "b0" "b1" "T"
                    , CfgEdge "b0" "b2" "F"
                    , CfgEdge "b1" "b3" ""
                    , CfgEdge "b2" "b3" ""
                    ]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          let reaching = Map.findWithDefault Set.empty "b3" (pfReachingIn pf)
          assertBool "a should reach b3" ("a" `Set.member` reaching)
          assertBool "b should reach b3" ("b" `Set.member` reaching)
          assertBool "c should reach b3" ("c" `Set.member` reaching)

    , testCase "partial def still reaches through (bfGen unaffected by bfKill's partial-def exclusion)" $
        -- bfGen always re-adds a partial def's own dsVar to newOut regardless
        -- of bfKill, so excluding partial defs from bfKill (item A) must
        -- leave reachingDefinitions output unchanged for this shape.
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (Lvalue [LvSegment "x" Nothing, LvSegment "field" Nothing]) (ExInt "2"))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in Map.findWithDefault Set.empty "b1" (pfReachingOut pf) @?= Set.singleton "x"

    , testCase "def of SQLCA reaches a later use spelled sqlca (case-insensitive, real-corpus shape)" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "SQLCA") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "sqlca")))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b1" (pfReachingIn pf) @?= Set.singleton "sqlca"
          Map.findWithDefault Set.empty "b1" (pfReachingOut pf) @?= Set.fromList ["sqlca", "y"]
    ]

  , testGroup "analyzeProcedure"
    [ testCase "allDefs groups by variable" $
        let blk  = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "x") (ExInt "1"))
              , at 2 (BsAssign (lv1 "x") (ExInt "2"))
              ]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "myobj" "myproc" cfg
        in do
          pfObject pf @?= "myobj"
          pfProc pf @?= "myproc"
          length (Map.findWithDefault [] "x" (pfAllDefs pf)) @?= 2

    , testCase "allUses groups by variable" $
        let blk  = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))
              , at 2 (BsReturn (Just (ExLvalue (lv1 "x"))))
              ]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
        in length (Map.findWithDefault [] "x" (pfAllUses pf)) @?= 2
    ]

  , testGroup "liveVariables"
    [ testCase "single block: use makes var live-in, nothing after so live-out empty" $
        let blk = mkBlock "b0" [at 1 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))]
            cfg = mkCfg "b0" [blk] []
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b0" (pfLiveIn pf) @?= Set.singleton "x"
          Map.findWithDefault Set.empty "b0" (pfLiveOut pf) @?= Set.empty

    , testCase "two blocks linear: use in b1 makes x live-out of b0" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "x")))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in do
          Map.findWithDefault Set.empty "b0" (pfLiveOut pf) @?= Set.singleton "x"
          Map.findWithDefault Set.empty "b1" (pfLiveIn pf) @?= Set.singleton "x"

    , testCase "two blocks: def in b1 with no use anywhere is not live-out of b0" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "x") (ExInt "2"))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in Map.findWithDefault Set.empty "b0" (pfLiveOut pf) @?= Set.empty

    , testCase "two blocks: partial def in b1 does not kill x live-out of b0" $
        -- Cross-block counterpart of DeadVars's "datastore-populate idiom"
        -- test: a partial def in a SUCCESSOR block must not clobber a full
        -- def's liveness computed by the shared bfKill, not just DeadVars's
        -- own now-removed local walk (Plan 174 T0-1 follow-on, item A).
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (Lvalue [LvSegment "x" Nothing, LvSegment "field" Nothing]) (ExInt "2"))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in assertBool "x should still be live-out of b0 (partial def in b1 reads x, doesn't kill it)"
             ("x" `Set.member` Map.findWithDefault Set.empty "b0" (pfLiveOut pf))

    , testCase "diamond: var used only on one branch is live-out of entry" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "a") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "a")))]
            b2 = mkBlock "b2" [at 3 (BsAssign (lv1 "z") (ExInt "9"))]
            cfg = mkCfg "b0" [b0, b1, b2]
                    [ CfgEdge "b0" "b1" "T"
                    , CfgEdge "b0" "b2" "F"
                    ]
            pf  = analyzeProcedure "obj" "proc" cfg
        in assertBool "a should be live-out of b0" ("a" `Set.member` Map.findWithDefault Set.empty "b0" (pfLiveOut pf))

    , testCase "use of sqlca makes a differently-cased def of SQLCA live-out (case-insensitive)" $
        let b0 = mkBlock "b0" [at 1 (BsAssign (lv1 "SQLCA") (ExInt "1"))]
            b1 = mkBlock "b1" [at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "sqlca")))]
            cfg = mkCfg "b0" [b0, b1] [CfgEdge "b0" "b1" ""]
            pf  = analyzeProcedure "obj" "proc" cfg
        in assertBool "sqlca should be live-out of b0"
             ("sqlca" `Set.member` Map.findWithDefault Set.empty "b0" (pfLiveOut pf))
    ]

  -- -----------------------------------------------------------------------
  -- 111d-1: per-procedure facet + flat row emission (Python consumer shape)
  --
  , testGroup "dataflowRows (111d-1)"
    [ testCase "dataflowDefRows emits one dict per def with Python keys" $
        let blk = mkBlock "b0" [at 5 (BsAssign (lv1 "x") (ExInt "1"))]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
            rows = dataflowDefRows pf
        in do
          length rows @?= 1
          let r = one rows
          fieldStr "var_name"   r @?= String "x"
          fieldStr "block_id"   r @?= String "b0"
          fieldStr "stmt_index" r @?= toJSON (0 :: Int)
          fieldStr "line"       r @?= toJSON (Just (5 :: Int))
          fieldStr "kind"       r @?= String "assign"

    , testCase "dataflowUseRows emits callee + args for ExCall (3 uses)" $
        -- Mirrors the 111a invariant: walkExprIdents counts the ExCall callee
        -- root as a use, so foo(x, y) → {foo, x, y} = 3 uses. This is the
        -- reason proc_uses = 1162 (not fewer) on the openpay corpus.
        let blk = mkBlock "b0" [at 9 (BsCall (ExCall (lv1 "foo") [ExLvalue (lv1 "x"), ExLvalue (lv1 "y")]))]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
            rows = dataflowUseRows pf
        in do
          length rows @?= 3
          Set.fromList [fieldStr "var_name" r | r <- rows]
            @?= Set.fromList [String "foo", String "x", String "y"]
          all (\r -> fieldStr "kind" r == String "call_arg") rows @?= True

    , testCase "dataflowFacet has defs + uses keys with Python row shape" $
        let blk = mkBlock "b0"
              [ at 1 (BsLocalVar [] (PtPrimitive "integer") "n" (Just (ExInt "0")))
              , at 2 (BsAssign (lv1 "y") (ExLvalue (lv1 "n")))
              ]
            cfg = mkCfg "b0" [blk] []
            pf  = analyzeProcedure "obj" "proc" cfg
            v   = dataflowFacet pf
        in do
          assertBool "facet has 'defs' key" (hasKey "defs" v)
          assertBool "facet has 'uses' key" (hasKey "uses" v)
          let defs = arrayAt "defs" v
          length defs @?= 2
          -- first def is the local var declaration
          let firstDef = case defs of { (d : _) -> d ; [] -> Null }
          fieldStr "var_name" firstDef @?= String "n"
          fieldStr "kind"     firstDef @?= String "local_var"

    , testCase "facet row keys match consumer expectations (no file/object/proc)" $
        -- The facet rows carry only the per-block keys; file/object/proc_name
        -- are added by the consumer which already knows them. This matches
        -- what interproc.py:237 and slicing.py:53 read from DuckDB.
        let blk = mkBlock "b0" [at 1 (BsAssign (lv1 "x") (ExInt "1"))]
            cfg = mkCfg "b0" [blk] []
            pf  = analyzeProcedure "obj" "proc" cfg
            r   = one (dataflowDefRows pf)
        in do
          assertBool "has var_name"   (hasKey "var_name" r)
          assertBool "has block_id"   (hasKey "block_id" r)
          assertBool "has stmt_index" (hasKey "stmt_index" r)
          assertBool "has line"       (hasKey "line" r)
          assertBool "has kind"       (hasKey "kind" r)
          assertBool "no file key"    (not (hasKey "file" r))
          assertBool "no object key"  (not (hasKey "object" r))

    , testCase "def rows preserve each occurrence's own casing even though gen/kill fold case-insensitively" $
        -- Wire-format non-regression: canonicalizing variable IDENTITY for
        -- the internal gen/kill/reaching/live fixpoints (see extractDefsUses
        -- group) must not change what dsVar/var_name displays -- each row
        -- keeps its own original per-occurrence spelling.
        let blk = mkBlock "b0"
              [ at 1 (BsAssign (lv1 "SQLCA") (ExInt "1"))
              , at 2 (BsAssign (lv1 "sqlca") (ExInt "2"))
              ]
            cfg  = mkCfg "b0" [blk] []
            pf   = analyzeProcedure "obj" "proc" cfg
            rows = dataflowDefRows pf
        in do
          length rows @?= 2
          map (fieldStr "var_name") rows @?= [String "SQLCA", String "sqlca"]
    ]
  ]
