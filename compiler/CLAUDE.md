# PB Compiler (Haskell) — Subsystem Guide

Loaded automatically by Claude Code whenever a session reads or edits files under
`compiler/`. This file covers Haskell/parser-specific rules only — session
protocol, the staged verification loop, commit discipline, documentation
style, and change-scope rules live in the root `CLAUDE.md` and apply here too.

## Stage 0 — Compiler-Specific Diagnostics

**Diagnosing corpus failures.** When the charter is to reduce corpus errors, sample raw error messages before touching code:

```bash
./pb check-corpus 2>&1 | grep "Files processed"   # get count

# sample 5 error messages from a temporary run:
OUT=$(mktemp -d)
(cd compiler && cabal run pbc -v0 -- -i ../example/openpay-0.1.1b-extract -o "$OUT" 2>/dev/null)
python3 -c "
import json, os, glob
for f in list(glob.glob('$OUT/**/*.json', recursive=True))[:5]:
    d = json.load(open(f))
    if 'error' in d: print(d['error'][:200])
"
rm -rf "$OUT"
```

Map the error message to its layer before reading code:

- `"lex error at line N"` → look at physical line N in the source file; the issue is in `Lexer.hs` or `Preprocess.hs`
- Megaparsec grammar message → issue is in `Grammar/File.hs` or `Grammar/Stream.hs`

**JSON body-statement encoding.** `PB.Pipeline.Serialise` sets no `constructorTagModifier`, so
the `"tag"` value on every node is the **literal Haskell constructor name** — `BsRaw`, `BsIf`,
`ExCall`, etc, never lowercased or renamed. Two encoding shapes (see the doc comment atop
`PB.AST.Expr`):

- A constructor with **one positional field** wraps its payload in `"contents"`:
  `BsRaw Text` → `{"tag":"BsRaw","contents":"<source text>"}`;
  `ExRaw [Text]` → `{"tag":"ExRaw","contents":["tok1","tok2"]}`.
- A constructor with **multiple named fields** (record syntax, e.g. `ExCall{callee,callArgs}`)
  flattens those fields alongside `"tag"` — no `"contents"` wrapper. Field names go through
  `stripCamelCasePrefix` (`callArgs` → `args`, `ifThen` → `then`, `forBody` → `body`, etc).
- Every body statement is `Located BodyStmt`, serialized as **`{"line": Int, "node": {...}}`** —
  always unwrap `"node"` to reach the tagged value, at every nesting level (top-level statements
  _and_ everything inside `then`/`elseIfs`/`else`/`body`/`clauses`).

Do not hand-roll a walker that special-cases field names per constructor — it is fragile to
exactly this kind of schema drift (this bit us once: see BACKLOG's `pb index` SQL-extraction
entry). Use the AST walker pattern which recurses into every dict value and list
item unconditionally and can't miss a tag regardless of which field a constructor nests its
children under.

If you need ground truth on the wire format, don't trust committed example JSON (`output/` is
gitignored scratch and may be stale) — rebuild and run the binary directly:

```bash
(cd compiler && cabal build)
BIN=$(cd compiler && cabal list-bin pbc)
"$BIN" -i <dir-with-one-srf> -o /tmp/pbout && python3 -m json.tool /tmp/pbout/*.json
```

**Canonical cabal invocation:** always run cabal from the `compiler/` directory (either `cd compiler && cabal …` or `(cd compiler && cabal …)` from the repo root). This picks up both `cabal.project` at the repo root and `compiler/cabal.project.local` (which sets the duckdb-ffi library paths). Build output goes to `dist-newstyle/` at the repo root. Never use `--project-dir compiler` from the repo root — that skips `cabal.project.local` and loses the duckdb library paths.

**BACKLOG entries for BsRaw work are pre-loaded with Stage 0 analysis.** Each open BsRaw item records: current count, root cause (token kind + guard line), which shapes must stay BsRaw, and the Stage 1 fix sketch. Confirm the counts still match the script output, then proceed directly to Stage 1 — no re-sampling required.

---

## Prelude and Safety Rules

The custom Prelude is in `compiler/src/PB/Prelude.hs`. These rules are non-negotiable.

| Rule                 | Detail                                                                                      |
| --------------------- | -------------------------------------------------------------------------------------------- |
| `Text` everywhere    | No `String` in exposed APIs; `OverloadedStrings` is set                                     |
| No partial functions | `head`, `tail`, `(!!)`, `fromJust`, `read`, `cycle`, `maximum`, `minimum` are hidden        |
| No `undefined`       | Hidden from Prelude; use `error "impossible: <reason>"` only when GHC cannot prove totality |
| Text IO              | `putStr`/`putStrLn`/`readFile` re-exported from `Data.Text.IO`                              |

All new modules must start with `import PB.Prelude` under `NoImplicitPrelude` (set in `common-settings` in the cabal file).

`cabal build` must be warning-free. `-Wall` and `-Wincomplete-patterns` are set. Incomplete pattern matches are a hard error.

---

## General Coding Guidance

- **Megaparsec `try` invariant:** In a `choice`, every alternative that can consume input before failing must be wrapped in `try`. Without it, a partial match (e.g. consuming a sign character before failing on a non-digit) propagates the error and skips all remaining alternatives. Audit any `choice` whose alternatives share a leading character.
- Always prefer short, flattened code - no huge monolithic functions
- Always rename Aeson serialized fields ergonomic JSON (not just the raw Haskell names)
- compiler/app/Main.hs should have no functionality other than to call into compiler/src/PB/Pipeline/Runner.hs. Three modes: (1) `-i SRC -o DIR` per-file JSON, (2) `-i SRC --jsonl` streaming JSONL, (3) `-i SRC --db FILE` DuckDB-direct (passes 1–8 all in Haskell). No logic other than flag parsing and dispatch.
- Accept no hacky solutions or greedy operations that will cause pain down the line: if we can't reliable detect the beginning / end of a regions (e.g., FUNCTION / END FUNCTION), we can't start working on it yet.
- Be creative and comprehensive in generating PBT and pathological unit test cases; PB has lots of issues like `foo()bar()` smashed together ` & // comment`
- Ensure the preprocess step is principled and resilient
- We always strongly type everything we can. E.g., in a DataWindow we will see `..(retrieve="..SQL string", ...)`. Rather than a map of properties, we should have an explicit record type that captures the possible known fields.

---

## Testing Discipline (Haskell)

**Test structure.** Always use `testGroup` with a descriptive path so failures self-locate:

```haskell
testGroup "Pipeline"
  [ testGroup "Preprocess"
    [ testCase "continuation across 3+ lines" $ ...
    , testCase "continuation with escaped quotes" $ ...
    ]
  ]
```

**Stub format.** Write real assertions wherever possible. Use `assertFailure "unimplemented: <reason>"` only when the production function does not exist yet and a stub is needed to make the project compile:

```haskell
testCase "some thing" $ assertFailure "unimplemented: continuation across 3+ lines"
```

Replace it with a real assertion before Stage 3 — a test that permanently says "unimplemented" is not a test.

**HUnit vs Hedgehog:**

- `testCase`: specific named examples, edge cases, regression tests
- `testProperty`: invariants that must hold for all (generated) inputs

**Early Hedgehog invariants** (from README):

- idempotence: `normalize (normalize x) == normalize x`
- monotonicity: `llStartLine <= llEndLine`
- no logical line ends with `&`
- string literal parity preserved

**Megaparsec exploration.** Use `parseTest` from `Text.Megaparsec` in the REPL to get human-readable failure output. In tests, use `parse` with `assertBool`/`assertEqual` and a descriptive message.

**Structuring.** Keep test files short and have a master test runner in `test/Main.hs` that imports and aggregates them. Keep PBT and unit tests separate. Don't refer to "phase numbers" or anything like that which has temporal implications, just give everything logical names.

**Triangulation for parser constructs.** Every new parser needs at least three test shapes:

- Positive: valid input → expected AST
- Negative: invalid input → parse failure (not a crash)
- Property: at least one Hedgehog invariant

---

## Reference Docs

The parser specification is in `doc/spec.md` — consult it first for any question about lexical rules, token forms, file structure, or DataWindow syntax. It is synthesized from the battle-tested reference implementation and amended with corrections from the official Appeon docs.

**When the corpus contradicts SPEC.md, the corpus wins.** Real exported files are ground truth. Update SPEC.md to document the discrepancy before or alongside the parser fix — do not silently accept corpus patterns without recording them in the spec.

---

## Corpus Coverage Checklist

Every distinct top-level construct found in the 515 non-DataWindow corpus files.
Mark done/pending as body parsers land.

| Construct                               | File types | Status  |
| ---------------------------------------- | ---------- | ------- |
| `forward … end forward`                 | .srw, .sru | done    |
| `forward prototypes … end prototypes`   | .srw, .sru | done    |
| `type prototypes … end prototypes`      | .srf, .sru | done    |
| `prototypes … end prototypes`           | .srf       | done    |
| `global variables … end variables`      | .srw, .sru | done    |
| `type variables … end variables`        | .srw, .sru | done    |
| `global type … end type`                | .srw, .sru | done    |
| `public function … end function`        | .srw, .sru | done    |
| `protected subroutine … end subroutine` | .srw, .sru | done    |
| `on … end on`                           | .srw, .sru | done    |
| `event … end event`                     | .srw, .sru | done    |
| `type … end type` (TypeBlock)           | .srw, .sru | done    |
| Body: `if … end if`                     | all        | done    |
| Body: `choose case … end choose`        | all        | done    |
| Body: `for … next`                      | all        | done    |
| Body: `do … loop`                       | all        | done    |
| Body: `try … catch … end try`           | all        | done    |
| Body: embedded SQL                      | .srw, .sru | pending |
| Body: assignment / call statements      | all        | done    |

---

## Module Placement

| Module          | Purpose                                                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `PB.AST.*`      | Data types only — no parsing logic (Located, Expr, BodyStmt, Type, SourceFile, DataWindow)                                          |
| `PB.Lexing.*`   | Tokenization, layout, string mode                                                                                                   |
| `PB.Grammar.*`  | megaparsec parsers (Body, File, Stream, DataWindow)                                                                                 |
| `PB.Compile.*`  | Compilation pipeline: SSA IR (SSA), IR types (IR), loop analysis (LoopAnalysis), SSA lowering (FromSSA), flattening (Flatten), instruction types (InstrTypes), value model (ValueModel), interpreters (Interp, InstrInterp) |
| `PB.Pipeline.*` | Multi-step transformations: Preprocess, Emit, Passes, Runner, Serialise, FileWalk, DuckDb, SqlParse, Church                        |
| `PB.Analysis.*` | Pure analysis passes: Cfg, Dataflow, DeadCode, Taint, TypeEnv, TypeResolve, Builtins, SchemaCategory, SchFootprint, DwFootprint, ControlHierarchy |
| `PB.Prelude`    | Custom Prelude — no parsing or transformation logic                                                                                 |

New modules go in the most specific matching directory. If a new layer is needed, propose it in Stage 1.

---

## Datalog Rule Placement Discipline (Plan 170)

Read this before writing or reviewing any Souffle EDB view (`initXEdbViews`
in `PB.Analysis.Rules.*`), materializer SQL (`materialize*` in
`PB.Pipeline.DuckDb`), or Datalog rule. Governs where logic lives across the
four surfaces a whole-program analysis touches: compiler phases
(`PB.Grammar`/`PB.AST`/`PB.Compile`), `PB.Analysis.*` Haskell, EDB-view SQL,
and Souffle Datalog rules (`PB.Pipeline.Souffle`/`PB.Analysis.Rules.*`).

**History.** The original `PB.Pipeline.Datalog` (a hand-rolled DuckDB
`WITH RECURSIVE` rule compiler — `stratify`/`compileBody`/`compileRule`,
since deleted) was built from scratch on a misreading of project direction
as "avoid Souffle." `PB.Pipeline.Souffle`'s current `Rule`/`RuleSet` IR
(literal-text rules, a `ruleRefs` list the caller must hand-sync) and the
EDB-view-heavy pattern in `PB.Analysis.Rules.*` partly inherit that
detour's shape rather than being chosen specifically for Souffle. Treat
them as legacy defaults open to revision (see `doc/plan/172-categorical-
datalog-layer.md`), not settled precedent.

**The three-question placement test.** For any new piece of logic:

1. Is it true of ONE thing in isolation (one AST node/statement/procedure),
   computable without an unbounded walk over the corpus? → a compiler phase
   (syntax-only, single-file) or `PB.Analysis.*` Haskell (may need
   cross-file context — `ControlIndex`/`WorkspaceEnv`/DDL catalog — but
   still a bounded fold, never a fixpoint). Test with hand-typed HUnit
   fixtures.
2. Does answering it require an unbounded walk, a fixpoint, a count,
   stratified negation, or picking a winner among competing derived facts?
   → a Souffle Datalog rule. "Picking a winner among competing facts" is
   the one people miss — that's what `choice-domain` and rule
   specialization are _for_; it is not a SQL `CASE`'s job. Test via
   `SouffleTest.hs`-style fixtures against the real `souffle` CLI.
3. Otherwise — moving an already-computed fact from storage shape into
   relation shape (rename, cast, static-predicate filter, union of
   identically-shaped sources) — it's an EDB view.

**House rule: EDB views and materializers may not decide anything.** A
`CREATE VIEW` in `initXEdbViews`, or a materializer's `INSERT ... SELECT`,
may only rename, cast, or filter by a static/structural predicate. If the
SQL needs `CASE`, `ROW_NUMBER`/any window function, or `GROUP BY`/an
aggregate to produce its answer, that is a decision (question 2's
territory — a tie-break, a label, a count) and does not belong in
view/materializer SQL. Move it into a Datalog rule (`choice-domain` for
tie-breaks, rule specialization for labels, Souffle's own `count :`
aggregate). This rule exists because every real bug found in the Datalog
substrate to date — `leg`'s writes-vs-retrieve tie-break,
`decomposition_coslice`'s direction-interleaved ordinals, `taint_paths`'
`step_kind` mislabeling of 0-hop paths — lived in exactly this kind of SQL,
caught only by real-corpus/real-UI spot checks, never by a test that ran
before the fact. See `doc/plan/171-datalog-decision-migration.md` for the
concrete migration of the two still-open instances.

**Adversarial fixture requirement.** Any test-fixture set for a
Datalog-backed relation must cover, not just the "interesting" connected
case: (a) a duplicate-key collision (two facts competing for the same
derived key), (b) a 0-hop/degenerate case (source == sink, self-loop), (c)
a cycle not passing through the seed, where structurally possible for that
relation. All three shapes have independently caused a real, shipped bug in
this project and none were caught by the fixtures that existed at the time
— a new relation's test group is incomplete without them.

**Roadmap.** `doc/plan/170-datalog-discipline.md` is the index (history,
rationale, and links to the concrete follow-on plans); this section is the
enforceable summary and takes precedence if the two ever drift.

---

## Code Index

Maintained here to avoid re-scanning the tree. **Update when exports change.**
Verified against source on 2026-07-14 — if you edit a constructor and don't
update the matching entry here, the next session re-derives it the hard way
(this cost real time in the 111a session). Field names below are the raw
Haskell record names; the Aeson wire shape renames them via `stripCamelCasePrefix`
(see Stage 0 notes) — e.g. `callArgs` serialises as `args`, `lvSegments` as
`segments`.

### `PB.AST.Located`

```haskell
data Located a = Located
  { locLine :: Int   -- source start line (llStartLine of the originating LogicalLine)
  , locNode :: a
  } deriving (Eq, Show, Generic)
```

### `PB.AST.Expr`

```haskell
-- Field names are unprefixed (record-dot disambiguation under
-- DuplicateRecordFields). Token lists are [Text], NOT [Token].
data LvSegment = LvSegment { name :: Text, subscript :: Maybe [Text] }
newtype Lvalue = Lvalue { segments :: [LvSegment] }   -- non-empty

data BinOp
  = BopAdd | BopSub | BopMul | BopDiv | BopPow
  | BopEq  | BopNe  | BopLt  | BopGt  | BopLe | BopGe
  | BopAnd | BopOr  | BopXor

data DispatchMode = DmPost | DmTrigger | DmSync
data DispatchExpr = DispatchExpr
  { object :: Maybe Lvalue, mode :: DispatchMode, dynamic :: Bool
  , event :: Bool, name :: Text, args :: [[Token]] }

data Expr
  = ExBool       Bool             | ExInt Text  | ExReal Text
  | ExStr        Text             | ExDate Text | ExTime Text | ExNull
  | ExEnum       Text             -- enum constant (without trailing '!')
  | ExLvalue     Lvalue           -- bare ident / member chain / subscript
  | ExCall       { callee :: Lvalue, callArgs :: [[Token]] }
  | ExMethodCall { receiver :: Expr, method :: Text, methodArgs :: [[Token]] }
  | ExDispatch   DispatchExpr     -- POST/TRIGGER/DYNAMIC/EVENT dispatch
  | ExCreate     Text             -- CREATE ClassName
  | ExCreateUsing Expr            -- CREATE USING expr
  | ExArray      [Expr]
  | ExBinOp      { lhs :: Expr, op :: BinOp, rhs :: Expr }
  | ExNot        Expr
  | ExNeg        Expr             -- unary minus
  | ExHostVar    Lvalue           -- SQL host variable :varname
  | ExRaw        [Text]           -- SQL fragments / unrecognised
  -- NOTE: there is no ExLit / Literal type — literals are split across
  -- ExBool/ExInt/ExReal/ExStr/ExDate/ExTime/ExNull. Old index entries that
  -- referenced Literal/CallExpr/CreateExpr/ExUnaryMinus were stale.
```

### `PB.AST.BodyStmt`

```haskell
data AugOp = AugAdd | AugSub | AugMul | AugDiv

-- PB CALL statement: CALL ancestorobject [`controlname] :: event
data PbCall = PbCall { pbcAncestor :: Text, pbcEvent :: Text }

-- One elseif branch. ifElseIfs is [ElseIf], NOT [(Expr, [Located BodyStmt])].
data ElseIf = ElseIf { eifCond :: Expr, eifBody :: [Located BodyStmt] }

data IfStmt = IfStmt
  { ifCond :: Expr, ifThen :: [Located BodyStmt]
  , ifElseIfs :: [ElseIf], ifElse :: Maybe [Located BodyStmt] }

data ForStmt = ForStmt
  { forVar :: Lvalue, forFrom :: Expr, forTo :: Expr
  , forStep :: Maybe Expr, forBody :: [Located BodyStmt] }

data DoCondition = DoWhile Expr | DoUntil Expr

data DoStmt = DoStmt
  { doCond :: Maybe DoCondition, doBody :: [Located BodyStmt]
  , doLoop :: Maybe DoCondition }

data CaseClause = CaseClause
  { ccExpr :: Maybe [Token]   -- Nothing = "case else"
  , ccBody :: [Located BodyStmt] }

data ChooseStmt = ChooseStmt
  { chooseExpr :: Expr, chooseClauses :: [CaseClause] }

data BodyStmt
  = BsLocalVar  { varMods :: [Text], varType :: PbType, varName :: Text, varInit :: Maybe Expr }
  | BsAssign    Lvalue Expr           -- lhs = rhs
  | BsAugAssign [Token] AugOp [Token]   -- lhs_tokens op= rhs_tokens
  | BsInc       [Token]                -- lhs_tokens ++
  | BsDec       [Token]                -- lhs_tokens --
  | BsCall      Expr                  -- standalone call expression
  | BsPbCall    PbCall                -- CALL ancestor[`ctrl] :: event
  | BsReturn    (Maybe Expr)          -- return [expr]
  | BsIf        IfStmt
  | BsFor       ForStmt
  | BsDo        DoStmt
  | BsChoose    ChooseStmt
  | BsExit
  | BsContinue
  | BsDestroy   Lvalue                -- DESTROY objectvariable
  | BsAssignExpr Expr Expr            -- complex LHS = rhs (method-call chain . property)
  | BsTry       TryStmt
  | BsThrow     Expr
  | BsRaw       Text                  -- SQL, event decls, unclassified (source text)

-- | catch (ExceptionType varName) clause
data CatchClause = CatchClause { catchExnType :: Text, catchExnVar :: Text, catchBody :: [Located BodyStmt] }
-- | try … catch … end try
data TryStmt = TryStmt { tryBody :: [Located BodyStmt], tryCatches :: [CatchClause] }

  -- PbType comes from PB.AST.Type: PtPrimitive Text | PtUserDefined Text
  --   | PtAny | PtDecimalPrec Int. No IsString instance — always wrap as
  --   PtPrimitive "integer" etc. (the 111a test was wrong about this.)
```

### `PB.AST.Type`

```haskell
data PbType
  = PtPrimitive Text | PtUserDefined Text | PtAny | PtDecimalPrec Int
renderPbType :: PbType -> Text
parseTypeText :: Text -> PbType          -- inverse, used by TypeResolve/TypeEnv
-- No IsString instance. primitiveNames list in-module.
```

### `PB.AST.DataWindow` / `PB.Grammar.DataWindow`

Partial entry — only the fields/functions touched by Plan 163 Phase 1
(2026-07-10). The rest of these modules' types (`DwBand`/`DwGroup`/
`DwColumn`/`DwTable`/`DwControl`/etc, and their parsers) are not yet
indexed here.

```haskell
-- PB.AST.DataWindow
data DwWhereClause = DwWhereClause
  { dwcExp1, dwcOp, dwcExp2 :: Text, dwcLogic :: Maybe Text
  , dwcParsedExp1, dwcParsedExp2 :: Maybe Expr }  -- Plan 163 Phase 1 (D2)
-- Mirrors DwControl's dwcParsedExpression/dwcParsedFormat naming/pipeline.
-- 33/187 real corpus rows (openpay) carry a surplus leading '(' on EXP1
-- and/or trailing ')' on EXP2 -- PowerBuilder's own WHERE-grid grouping
-- parens, spliced onto whichever row sits at a visual group's boundary
-- (see doc/spec.md 7.3 "WHERE-clause grouping-paren leakage"; confirmed
-- NOT a powerbuilder-pbl-dump bug -- that tool does a verbatim byte
-- extraction, see doc/pbl.md's "Data chain" note). Fixed 2026-07-10:
-- parseWhereOperand strips the surplus via stripSurplusParens before
-- parsing, so dwcParsedExp1/2 resolve normally even on group-boundary
-- rows; dwcExp1/dwcExp2 (raw) stay verbatim, unaffected.

-- PB.Grammar.DataWindow
parseWhereOperand :: Text -> Maybe Expr
-- Not exported. stripSurplusParens . tokenizeExpr . parseExpr pipeline
-- (same tokenizeExpr/parseExpr DwControl's expression/format fields use,
-- plus the paren-leakage strip); top-level ExRaw result -> Nothing.
stripSurplusParens :: Text -> Text
-- Not exported. Strips a leading run of '(' from EXP1 (or trailing run of
-- ')' from EXP2) only while the text's own net paren balance is nonzero --
-- an already-balanced parenthesized sub-expression (real function call,
-- `(a+b)`) is left untouched. Deliberately local/per-field: does not (and
-- doesn't need to) reconstruct true cross-row group nesting -- verified
-- empirically (zero anomalies across all 33 affected corpus rows) that the
-- surplus is always a pure leading/trailing run, never interior or
-- cross-contaminated between EXP1/EXP2.
```

### `PB.Grammar.Body`

```haskell
classifyBodyStmt :: Statement -> BodyStmt          -- leaf classifier; exit/continue/return/var/assign
parseBodyStmts   :: [Statement] -> [Located BodyStmt]  -- flat map; uses llStartLine for locLine
parseLvalue      :: [Token] -> Maybe Lvalue
parseExpr        :: [Token] -> Expr   -- total; ExRaw fallback; TkColon guard for SQL host vars
pBodyStmt        :: FileParser (Located BodyStmt)  -- captures currentLine before dispatching
-- Internal helpers (not exported): parseAtom, climbPrec, chainCalls, etc.
```

### `PB.Pipeline.Preprocess`

```haskell
normalizeText :: Text -> [LogicalLine]
stripHeaders  :: [LogicalLine] -> ([Text], [LogicalLine])

data LogicalLine = LogicalLine
  { llText      :: Text
  , llStartLine :: Int
  , llEndLine   :: Int
  }
```

### `PB.AST.SourceFile`

```haskell
data SrFile = SrFile
  { srHeaders         :: [Text]
  , srForward         :: Maybe ForwardBlock
  , srPrototypes      :: Maybe PrototypesBlock
  , srVariables       :: Maybe VariablesBlock
  , srGlobalInstances :: [GlobalInstance]
  , srTypeBlocks      :: [TypeBlock]
  , srOnBlocks        :: [OnBlock]
  , srEvents          :: [EventBlock]
  , srFunctions       :: [FunctionBlock]
  , srSubroutines     :: [SubroutineBlock]
  }

data ForwardBlock    = ForwardBlock    { fwdTypes :: [TypeDecl], fwdInstances :: [GlobalInstance] }
data PrototypesBlock = PrototypesBlock { protoDecls :: [ProtoDecl] }
data ProtoDecl       = ProtoFn FnSig | ProtoSub SubSig | ProtoEv EventSig

data VariablesBlock = VariablesBlock { varScope :: VarScope, varDecls :: [VarDecl] }
data VarScope       = GlobalVars | TypeVars

data TypeDecl = TypeDecl { tdName :: Text, tdAncestor :: Text, tdWithin :: Maybe Text }
data TypeBlock = TypeBlock { tbDecl :: TypeDecl, tbBody :: [Located BodyStmt] }
data VarDecl   = VarDecl  { vdModifiers :: [Text], vdType :: Text, vdName :: Text }
data GlobalInstance = GlobalInstance { giType :: Text, giName :: Text }

data FnSig  = FnSig  { fnsMods :: [Text], fnsReturnType :: Text, fnsName :: Text, fnsParams :: Text, fnsThrows :: Maybe Text }
data SubSig = SubSig { ssMods  :: [Text], ssName :: Text, ssParams :: Text, ssThrows :: Maybe Text }
data EventSig = EventSig { esName :: Text, esRawSig :: Text }

data FunctionBlock   = FunctionBlock   { fbSig :: FnSig,   fbBody :: [Located BodyStmt] }
data SubroutineBlock = SubroutineBlock { sbSig :: SubSig,  sbBody :: [Located BodyStmt] }
data EventBlock      = EventBlock      { evSig :: EventSig, evOwner :: Maybe Text, evBody :: [Located BodyStmt] }
data OnBlock         = OnBlock         { obQualName :: Text, obOwner :: Text, obEvent :: Text, obBody :: [Located BodyStmt] }

srAllTypeDecls  :: SrFile -> [TypeDecl]           -- srTypeBlocks decls, then forward-only decls
srPrimaryObject :: SrFile -> (Text, Maybe Text)   -- (name, ancestor) of the file's own object
splitAncestorRef :: Text -> (Text, Maybe Text)
-- Plan 164 Phase A (2026-07-10). Splits PowerBuilder's "AncestorClass`LocalName"
-- control-override syntax (e.g. tdAncestor = "w_form_tab2`page1", meaning
-- "this local override of page1 is based on ancestor w_form_tab2's own
-- declaration of a control named page1"). The lexer treats backtick as an
-- identifier-continuation char (isIdentCont), so tdAncestor carries the whole
-- compound token verbatim with nothing splitting it apart before this.
-- (class, Nothing) when there's no backtick; splits at the first backtick
-- only. Consumed by TypeResolve.buildInheritsMap and TypeEnv.extractTypeDecls
-- (both build a name->ancestor map used for ancestor-chain walks -- without
-- this, a chain hits a backtick-declared node and silently stops, since no
-- object is ever literally named "w_form_tab2`page1") and by
-- Emit.extractWindowLayout's mkControl (replaced an ad hoc, Just-half-discarding
-- T.takeWhile (/= '`') that did the same job one-off, cosmetically, for the
-- rendered control "type" label).
-- srPrimaryObject (fixed Plan 163 Phase 3.5, 2026-07-10): prefers the
-- srTypeBlocks entry whose tdName matches the forward block's first
-- fwdTypes entry (PB's exporter always declares the file's own type first
-- in forward, ahead of nested control forwards) -- NOT simply "head of
-- srTypeBlocks". Falls back to head-of-srTypeBlocks, then forward's own
-- first entry, then ("", Nothing), when there's no forward block or no
-- name match. Needed because a top-level non-visual type block (e.g.
-- `type os_data from structure`) can be declared textually before the
-- file's real window/user-object block; every consumer keying off this
-- single per-file "obj" (Runner.hs's compileOne, Emit.hs's wrapSrFile,
-- Taint.hs's extractTaintInputs) was silently misattributing every
-- procedure/call-site/SetItem-binding-lookup in such files (11/433 files in
-- PowerBuilder-Example-extract, 0/139 in openpay -- see BACKLOG's closed
-- "Plan 163 Phase 3 wiring session" entry).
```

### `PB.Grammar.File`

```haskell
parseSrFile         :: [Text] -> [Statement] -> Either Text SrFile   -- no spans
parseSrFileWithSpans :: [Text] -> [Statement] -> Either Text (SrFile, SrSpans)  -- Runner uses this
-- SrSpans carries (startLine, endLine) per block; consumed by wrapSrFile for "meta".
pForwardBlock    :: FileParser ForwardBlock
pPrototypesBlock :: FileParser PrototypesBlock
pVariablesBlock  :: FileParser VariablesBlock
pGlobalInstance  :: FileParser GlobalInstance
pTypeDecl        :: FileParser TypeDecl
pVarDecl         :: FileParser VarDecl
pProtoDecl       :: FileParser ProtoDecl
pEndKw           :: Text -> FileParser ()
pTypeBlock       :: FileParser TypeBlock
pOnBlock         :: FileParser OnBlock
pEventBlock      :: FileParser EventBlock
pFunctionBlock   :: FileParser FunctionBlock
pSubroutineBlock :: FileParser SubroutineBlock
-- NOTE: the old pBodyUntil helper no longer exists (removed in the spans refactor).
```

### `PB.Grammar.Stream`

```haskell
newtype StmtStream = StmtStream [Statement]
type FileParser = Parsec Void StmtStream

satisfyStmt      :: (Statement -> Bool) -> FileParser Statement
leadingKind      :: TokenKind -> FileParser Statement
leadingText      :: Text -> FileParser Statement
isModifierToken  :: Token -> Bool   -- TkAccessModifier | TkStorageModifier
currentLine      :: FileParser Int  -- llStartLine of the next statement (without consuming)
```

### `PB.Pipeline.Emit`

```haskell
-- Single-file parsing, JSON wrapping, layout extraction.
runFile           :: FilePath -> Text -> Either Text Value
collectStatements :: [LexLine] -> Either Text [Statement]
wrapSrFile        :: Bool -> FilePath -> SrFile -> SrSpans -> TypeEnv -> Value
extractWindowLayout :: [TypeBlock] -> Maybe Value
reconstructRetrieveSql :: DwRetrieveOrRaw -> Text
fileKind          :: FilePath -> FileKind
data FileKind     = DataWindow | Pipeline | Project | PowerScript
data ParsedFile   = ParsedFile { pfPath :: FilePath, pfSrFile :: SrFile, pfSpans :: SrSpans, pfContents :: Text }
data ParseOutcome = PsParsed ParsedFile | PsDw FilePath Text DataWindowFile | PsFailed FilePath Text | OtherFile FilePath
parseOutcome      :: FilePath -> FilePath -> IO ParseOutcome
-- root -> src -> outcome (path relativization, 2026-07-09): every path in
-- the returned ParsedFile/PsDw/PsFailed/OtherFile is `makeRelative root src`,
-- not the raw absolute src used to actually read the file. This is the sole
-- choke point for ingested-path storage -- compileOne and every DB row
-- constructor just reads pfPath/the FilePath in the outcome verbatim, so
-- fixing it here fixes every stored/displayed path. Callers thread the
-- ingestion root (runModeDb's srcDir) down through workerLoopFiles/
-- workerLoopFilesNoBridge (see PB.Pipeline.Runner below).
stripBom          :: Text -> Text
```

### `PB.Pipeline.Passes`

```haskell
-- Phase B orchestration: link analysis in DuckDB mode. Structured as two
-- sub-phases (Plan 166 follow-up 1, 2026-07-12):
--   B1 (Haskell + EDB materialization): runPass5 (resolveTypes + resolveCalls
--     → resolved_types/resolved_calls), runPass67 (buildInterprocEdges +
--     taint → interproc_edges/taint_*), runPass9 (SchemaCategory.buildSchema
--     → schema_objects/schema_morphisms; returns SchGraph), then
--     materializeAllEdbViews (every SQL-view EDB relation the Soufflé rule
--     sets assume: DeadCodeRules.initDeadReachEdbViews over
--     procedures/resolved_calls/objects + SchemaRules.initEdbViews over
--     schema_morphisms/schema_objects).
--   B2 (one Soufflé run): every Phase B Datalog rule set runs in a single
--     Souffle.runRuleSets call (allDatalogRuleSets = deadReachRules,
--     callerCountRules, deadCodeRowsRules, legRules, reachesRules,
--     cosliceRules, liveProcRules). orderRuleSets resolves every
--     Soufflé-internal dependency edge automatically (proc_dead before
--     deadCodeRowsRules/liveProcRules; leg before reaches; reaches before
--     cosliceRules). The only manual
--     sequencing left is the Phase A→B boundary B1 enforces (EDB views'
--     source tables must be populated before the views are created) -- a
--     genuine data dependency, not an on-demand coupling between rule sets.
--     Then the two SQL materializers project IDB output into API-facing
--     tables: materializeDeadCode (dead_code_rows → dead_code) and
--     materializeDecompositionCoslice (path_leg_fwd/back →
--     decomposition_coslice).
runPhaseB :: DuckConn -> Maybe Text -> IO ()
-- 2nd param is mDefaultNamespace (Plan 157 Phase 1, 2026-07-09), threaded
-- through from Runner.runModeDb's --default-namespace flag into runPass9.
runPass9 :: DuckConn -> Maybe Text -> IO SchGraph
```

### `PB.Pipeline.Souffle` (Plan 161, Souffle migration done 2026-07-11 -- replaces the deleted `PB.Pipeline.Datalog`)

```haskell
-- Pure IR + a Souffle-CLI backend for the reaches-style whole-program
-- queries Plan 161 exists to replace bespoke Haskell traversals with.
-- Phase 0's original DuckDB-native decision was reversed same-day (see the
-- plan's "Phase 0 -- reopened" section): a Homebrew packaging bug wrongly
-- disqualified Souffle's compiled mode, and a re-measure with it included
-- showed Souffle beating DuckDB-native; a realistic aggregate rule (caller
-- fan-in count) had no home in the old IR's plain-SELECT compiler at all.
-- Same IR as before: most EDB relations (dead/stmt/leg_source) are VIEWS
-- over existing tables (initEdbViews) -- leg is the one exception since
-- Plan 171a (2026-07-15): it's Datalog-derived (legRules) from the
-- leg_source view, not a view itself -- no fact-marshalling round trip through DuckDB
-- itself, though facts DO now round-trip through Haskell once, out to
-- Souffle's .facts files and back from its .csv output (unlike the old
-- module, which stayed inside DuckDB via WITH RECURSIVE the whole time).
data Relation = Relation { relName :: Text, relCols :: [(Text, Text)] }  -- (name, souffle type), default "symbol"
-- Rule authoring dropped the Literal/Aggregate typed-AST layer (was:
-- ruleHead/ruleBody :: Literal, a positional-arg AST rendered by
-- renderLiteral). It gave no real static safety -- arity/variable-name
-- consistency between head and body was a documented runtime invariant,
-- never a type-checked one -- while being strictly more verbose than the
-- Souffle text it rendered, and it had already grown a LitBare escape
-- hatch (raw text) for anything Souffle-native (comparisons, arithmetic,
-- aggregate "N = count : { ... }" syntax) that didn't fit a flat relation
-- atom. Rules are now literal Souffle clause text plus an explicit
-- relation-reference list.
data Rule = Rule { ruleText :: Text, ruleRefs :: [Relation] }
-- ruleText: one full Horn clause in Souffle syntax, no trailing '.'
-- ("reaches(x, z) :- reaches(x, y), leg(y, z, _)"). ruleRefs: every
-- relation the clause mentions (head, body, any aggregate witness) --
-- edbRelations/orderRuleSets read ONLY this, not ruleText, so it must be
-- kept in sync by the rule's author.
data RuleSet  = RuleSet { rsRelations :: [Relation], rsRules :: [Rule], rsChoiceDomains :: [(Text, [Text])] }
-- a relation may have several alternative rules, unioned. rsChoiceDomains
-- names, per IDB relation (by relName), the column subset rendered as a
-- Souffle `choice-domain (...)` decl modifier -- once any tuple with a
-- given key is derived, later tuples sharing that key are dropped. [] (the
-- default) means no choice-domain. Used by min_dist/min_dist_back
-- (cosliceRules) and leg (legRules, Plan 171a).

edbRelations :: RuleSet -> [Relation]
-- List.nub of every ruleRefs entry across rsRules that is NOT in
-- rsRelations (the derived/IDB set) -- these are the EDB relations the
-- program assumes are already populated. Souffle hard-errors on a missing
-- .facts file for a declared .input relation, so every one of these gets a
-- file written, even an empty one.

compileProgram :: RuleSet -> Text
-- Renders a full Souffle .dl program: .decl+.input per EDB relation
-- (edbRelations), .decl+.output+translated rules per IDB relation
-- (rsRelations). Every column is declared `symbol` (Souffle's string type)
-- -- every value this project currently feeds through (schema keys, kinds,
-- object names) is already string-shaped. Souffle stratifies and evaluates
-- the whole program itself -- no ordering step is needed from the caller
-- (the old module's stratify/topoSort/compileRelation/compileBody/
-- compileRule/lookupBound are GONE; there is nothing left at the Haskell
-- level for them to do).

runRuleSet     :: DuckConn -> RuleSet -> IO ()
runRuleSetWith :: (Relation -> IO ()) -> DuckConn -> RuleSet -> IO ()
sanitizeFactField :: Text -> Text
-- runRuleSet = runRuleSetWith (\_ -> pure ()). Per call: withSystemTempDirectory
-- (temporary pkg) -> for each edbRelations member, PB.Pipeline.DuckDb.queryTextRows
-- reads its current rows and writes a tab-separated <name>.facts file (always
-- written, even with zero rows) -> compileProgram's output written to a .dl
-- file -> `souffle -F factsDir -D outDir program.dl` via readProcessWithExitCode
-- (interpreted mode; a non-zero exit is a hard `error`, same tier as the old
-- module's unstratifiable-ruleset error) -> for each rsRelations member, calls
-- onRelation (PB.Pipeline.Passes' runPass11 wires this to emitProgress, one
-- "step" event per relation, e.g. "Datalog: reaches", same reason as before:
-- the CLI reporter's Phase B view shows only the latest step label with no
-- sub-progress bar), reads back its <name>.csv output, then
-- PB.Pipeline.DuckDb.recreateTextTable + appendTextRows materializes it as a
-- DuckDB table (drop + create all-TEXT columns, generic-arity append -- see
-- that module's own entry). Any future, larger Phase 3 rule set MUST use
-- runRuleSetWith, not bare runRuleSet, for the same reason as before.
-- FIXED (Plan 173, 2026-07-15): the .csv-output read path used to filter
-- `not (T.null line)` on every line, meant to drop a spurious trailing
-- blank line -- but for a single-column relation, a row whose one field is
-- the empty string IS an empty line, so the filter silently dropped that
-- row's tuple entirely (found via SouffleFuzzTest.hs's round-trip
-- property, shrunk to a 1-column relation with one [""] row). Now only the
-- whole-file-empty case (0 output rows) is special-cased; T.lines already
-- excludes any spurious trailing-newline artifact on its own, no per-line
-- filter needed. sanitizeFactField exported (was internal) so
-- SouffleFuzzTest.hs's expected-output computation reuses the real
-- sanitizer instead of a duplicate that could drift from it.

initEdbViews :: DuckConn -> IO ()
-- (Re)creates leg_source (from schema_morphisms), stmt (from schema_objects),
-- and seed (column objects, the coslice seed) as views. leg_source is a pure
-- rename (from_key/to_key/leg_kind -> x/y/kind), undeduped -- no CASE/
-- ROW_NUMBER (Plan 171a, 2026-07-15: the old `leg` view here DID have a
-- ROW_NUMBER/CASE writes-vs-retrieve tie-break, a house-rule violation per
-- this file's own Datalog Rule Placement Discipline section; that decision
-- moved into legRules below). stmt is filtered to kind = 'stmt' ONLY --
-- excluding kind = 'dw_retrieve' rows is deliberate: a DwRetrieveId StmtObj's
-- stmt_proc is always NULL, and proc_dead only keys on real (object, proc)
-- pairs, so a NULL proc vacuously passes `NOT EXISTS proc_dead` -- every DW
-- retrieve would otherwise pollute live_proc as unconditionally "live"
-- (found via a real openpay --db smoke run: 114/115 stmt rows were this
-- noise before the fix). No "dead" view here (Plan 161 Phase 2b cutover,
-- 2026-07-11): liveProcRules reads proc_dead directly instead -- see its
-- own entry.

legRules :: RuleSet
-- Plan 171a (2026-07-15): derives leg(x, y, kind) from leg_source, replacing
-- the old SQL-view tie-break. leg_raw(x, y, kind, priority) tags each raw
-- row via rule specialization on a literal kind guard (writes -> 0,
-- retrieve -> 1, else -> 2 -- an explicit priority FACT per rule, not a
-- positional CASE). Materializes to table "leg"; runRuleSets orders it
-- before reachesRules (which reads leg as EDB). Real-corpus gate: openpay
-- decomposition_coslice byte-identical (5261/5261 rows) pre- vs
-- post-migration (171a original gate, still holds).
--
-- PERFORMANCE REWRITE (2026-07-15, found on a 1763-file/300KLOC production
-- corpus): leg's original tie-break used an inline correlated aggregate,
-- `leg(x,y,kind) :- leg_raw(x,y,kind,p), p = min p2 : { leg_raw(x,y,_,p2) }`
-- (the same min-aggregate + choice-domain idiom cosliceRules uses for
-- min_dist/min_dist_back). Verified against the real souffle 2.5 CLI on
-- synthetic fixtures: Souffle re-evaluates that aggregate once per MATCHING
-- ROW of the first body literal, not once per distinct (x, y) key, making
-- cost O(group_size^2) per key -- fine when leg_source (deliberately
-- undeduped, see initEdbViews above) has small collision groups (the
-- openpay/PowerBuilder-Example dev corpora this was validated against), but
-- catastrophic when a real corpus has large duplicate/near-duplicate fan-in
-- on one (x, y) edge (confirmed synthetically: identical total row count,
-- concentrated into fewer keys, cost scaled with the SQUARE of group size --
-- 13x slower at 200x1000 vs 200000x~1, another ~4.9x at 40x5000). Splitting
-- the aggregate into its own relation before joining (the usual Souffle
-- "aggregate-then-join" fix) does NOT help -- verified empirically identical
-- cost, since Souffle still fires the aggregate once per row, not once per
-- key. Root cause of a live incident: "Datalog: leg" stalled 13+ minutes and
-- 19.5GB+ resident (climbing, no plateau) on a real production corpus,
-- vs. ~2 minutes/3GB for the whole prior (pre-171a, SQL-view-based) index.
--
-- Fix: leg is now a priority CASCADE via stratified negation + per-tier
-- choice-domain, no aggregate -- leg_p0/leg_p1/leg_p2 relations each pick
-- one tuple per key at their own priority tier (own choice-domain (x, y)),
-- gated by the negated existence of any higher-priority tuple for that key
-- (leg_p1's `!leg_p0_key(x,y)`, leg_p2's `!leg_p0_key(x,y), !leg_p1_key(x,y)`
-- -- leg_p0_key/leg_p1_key are single-column existence projections of
-- leg_p0/leg_p1); leg unions the three tiers. Same stratified-negation
-- mechanism PB.Analysis.Rules.DeadCode.liveProcRules already uses -- not a
-- new technique. An existence check is a plain indexed semi-join, so cost
-- is linear in leg_raw size regardless of key fan-in. Verified byte-
-- identical leg output vs. the old aggregate rule (5%-collision fixture +
-- an adversarial battery: writes/retrieve collision, retrieve/fk collision,
-- a same-priority tie between two distinct "other" kinds, a 0-hop
-- self-loop, a 3-way collision) and a ~220x instruction-count reduction on
-- the pathological 40x5,000 fixture, with no regression on the
-- near-unique-key case. rsRelations now [legRawRel, legP0Rel, legP0KeyRel,
-- legP1Rel, legP1KeyRel, legP2Rel, legRel]; rsChoiceDomains covers all of
-- leg_p0/leg_p1/leg_p2/leg.
--
-- Companion diagnostic: PB.Analysis.Rules.Schema.legSourceFanout (also new
-- this session) runs a cheap DuckDB GROUP BY over leg_source before
-- legRules executes (wired into PB.Pipeline.Passes.runPhaseB's
-- reportLegSourceFanout, right after materializeAllEdbViews) and reports
-- (total rows, distinct (x,y) keys, max rows sharing one key) via the same
-- progress-event channel as ddl_loaded/warning -- always emits a "step"
-- summary line, plus a "warning" event if the largest group exceeds 500
-- rows (heuristic threshold: leg_source has only ~3 distinct kind buckets,
-- so a group that large signals real upstream duplication, not legitimate
-- diversity). Kept even after the O(group_size^2) fix above -- the fan-in
-- number is diagnostically useful on its own, and a fast up-front
-- characterization beats discovering a pathological corpus shape only via
-- a stalled/memory-hungry Souffle run.

reachesRules  :: RuleSet
-- reaches(X,Y) :- leg(X,Y,_).  reaches(X,Z) :- reaches(X,Y), leg(Y,Z,_).
-- Materializes to table "reaches". Souffle handles the self-recursion
-- natively -- no WITH RECURSIVE translation needed on this side. leg is now
-- Datalog-derived (legRules, above), not a raw SQL EDB view.

cosliceRules :: RuleSet
-- Plan 161 Phase 2c: path-leg witness reconstruction for decomposition_coslice.
-- min_dist/min_dist_back compute shortest forward/backward distance; path_leg_fwd/
-- path_leg_back emit every shortest leg on a shortest path from seed to target.
-- Uses LitBare for the "n != s" termination guard and inline arithmetic in
-- head arguments. Reuses reaches and leg as EDB; runRuleSets orders after
-- reachesRules. Materialized by materializeDecompositionCoslice (DuckDb.hs).

liveProcRules :: RuleSet
-- live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !proc_dead(Object,Proc).
-- Real stratified-negation demonstration (Plan 161 Open Question 4). Reads
-- proc_dead (deadReachRules) directly -- Plan 161 Phase 2b cutover,
-- 2026-07-11: used to read a `dead` EDB view over the Haskell-computed
-- dead_code table until real-corpus parity was proven exact; runPass8 now
-- runs deadReachRules BEFORE this ruleset (required ordering -- proc_dead
-- must already exist when this ruleset exports its EDB facts).

-- Plan 161 Phase 2b (2026-07-11): port of the seeded-BFS reachability core
-- that used to live in Haskell as DeadCode.computeDeadProcedures (deleted
-- once parity was proven exact on two real corpora -- 104/104 openpay,
-- 279/279 PowerBuilder-Example -- see PB.Analysis.DeadCode.classifyDeadProcedures,
-- its replacement, which now takes the dead set as an INPUT instead of
-- computing it). initDeadReachEdbViews (Re)creates proc/entry/calls (SQL
-- views over procedures/resolved_calls/dw_objects -- every read of
-- `procedures` filters `confidence != 'speculative'`, excluding synthetic
-- builtin-class method stubs; a real --db run caught this the hard way,
-- inflating proc_dead by 45 rows before the fix) and overrides (a thin
-- view over the procedure_overrides table, fed by
-- DeadCode.computeOverrideEdges -- that edge-flattening step stays
-- Haskell/SQL-computed, same treatment `leg` gets for `reaches`). Must run
-- after PB.Pipeline.DuckDb.initSchema.
initDeadReachEdbViews :: DuckConn -> IO ()
deadReachRules :: RuleSet
-- proc_reachable(Object,Proc) :- entry(Object,Proc).
-- proc_reachable(Object,Proc) :- proc_reachable(CObj,CProc), calls(CObj,CProc,Object,Proc).
-- proc_reachable(ChildObj,Method) :- proc_reachable(ParentObj,Method), overrides(ChildObj,Method,ParentObj).
-- proc_dead(Object,Proc) :- proc(Object,Proc), !proc_reachable(Object,Proc).
-- Materializes to tables "proc_reachable"/"proc_dead". PB.Pipeline.Passes.runPass8
-- runs this INSIDE dead-code detection (before classifying confidence),
-- not in runPass11 (which now only runs reachesRules/liveProcRules).
```

### `PB.Analysis.Rules.Taint` (Plan 161 Phase 2d; step_kind labeling Plan 171b, 2026-07-15; taint_sink guard perf fix 2026-07-15)

```haskell
-- PERFORMANCE FIX (2026-07-15, same production incident as legRules'
-- O(group_size^2) fix): taint_path_leg's two rules now guard on
-- `taint_sink(t)`. Root cause: every downstream consumer of
-- taint_path_leg/taint_step_kind (materializeTaintPaths, DuckDb.hs) only
-- ever reads rows whose (s, t) pair is in taint_confirmed -- which already
-- requires taint_sink(t) -- but taint_path_leg's own rules derived a
-- witness leg for EVERY node t reachable from a source (not just real
-- sinks), so Souffle computed a full shortest-path-witness reconstruction
-- to every intermediate variable a taint value ever flows through, then
-- materializeTaintPaths' SQL JOIN silently discarded all but the
-- confirmed-sink subset. Verified against the real souffle 2.5 CLI on a
-- synthetic 100-source/7,000-edge/20-sink fixture (each source fanning out
-- to thousands of non-sink nodes, mirroring a real corpus' shared-utility-
-- layer shape): 11.7s/121MB -> 0.75s/28MB (15.6x/4.3x), taint_path_leg
-- 405,000 -> 4,000 rows (101x), taint_step_kind 407,000 -> 6,000 rows
-- (68x). taint_confirmed unchanged; taint_step_kind rows restricted to
-- confirmed (s, t) pairs (the only ones materializeTaintPaths ever reads)
-- verified byte-identical before/after. taint_min_dist/taint_reaches
-- themselves are untouched -- still computed to every reachable node,
-- since the BFS must pass through non-sink intermediates en route to a
-- distant sink; this guard only prunes witness-LEG reconstruction. Found
-- because "Datalog: leg"'s progress label is stale during this ruleset's
-- run (taintRules is topologically ready in the same round as legRules,
-- landing immediately after it -- see PB.Pipeline.Passes.souffleProgress's
-- own note) -- a live production run looked stuck on "leg" but process
-- inspection (temp dir contents: program.dl + taint_edge.facts) showed
-- taintRules actually executing. See doc/plan/171-datalog-decision-
-- migration.md's Postscript for the full incident writeup.

-- taintRules (RuleSet) gained taint_step_kind(s, t, leg_ord, lf, lt, kind,
-- step_kind, description) via rule specialization, replacing the SQL CASE
-- that used to live in materializeTaintPaths (a house-rule violation per
-- this file's own Datalog Rule Placement Discipline section). 4 rules:
-- (1) the leg starting at the source (leg_ord 0) is always labeled
-- "source" regardless of its real edge kind; (2) every other witness leg
-- passes its edge kind through unchanged as both step_kind and (via
-- Souffle's cat functor) the description text; (3) a terminal "arrived at
-- sink" marker row, one ordinal past the last witness leg (max-aggregate
-- over taint_path_leg, same idiom legRules uses for priority and
-- cosliceRules for min_dist), guarded s != t; (4) the 0-hop degenerate
-- case (source == sink) — a single "source-sink" row, since
-- taint_path_leg has no rows at all for that pair. `ord` is a reserved
-- word in Souffle 2.5 -- every relation here uses `leg_ord`, matching
-- taintPathLegRel's existing column name. materializeTaintPaths
-- (DuckDb.hs) now reads taint_step_kind directly -- no CASE, and the old
-- legs_with_sink UNION ALL that synthesized the terminal row in SQL is
-- gone (taint_step_kind already includes it). Real-corpus gate: openpay
-- taint_paths byte-identical (25/25 rows, full steps_json content) pre-
-- vs post-migration.
```

### `PB.Pipeline.SqlParse`

```haskell
-- Python sqlglot bridge: per-worker subprocess pool over a length-prefixed
-- JSON stdin/stdout protocol (sql_worker.py). ColumnRef/RowFilter (Plan 148
-- Phase 1a-2) are SqlResult's per-statement, scope-qualified column
-- attribution. TableRef/CatalogTable/CatalogPrimaryKey/CatalogForeignKey/
-- SchemaCatalog (Plan 148 Phase 1a-3, 2026-07-07) are the static DDL
-- catalog shape -- row-oriented (list, not Map TableRef [Text]) to match
-- the JSON wire format and DuckDb's row-oriented appenders directly.
-- PB.Analysis.SchemaCategory (Phase 1b, 2026-07-07) does NOT consume this
-- type directly -- it takes catalog_columns/catalog_fks rows queried back
-- from DuckDb (CatColumnRow/CatFkRow, its own read-shape types) instead,
-- keeping PB.Analysis.* free of any duckdb-ffi dependency.
--
-- Oracle DDL hardening (2026-07-08): SchemaCatalog gained scChecks
-- (CatalogCheckConstraint -- named CHECK predicates, sqlglot's normalized-SQL
-- rendering, not a re-parsed expression AST). SqlBridgePool gained
-- sbpDialect :: Text, set once at pool construction and used by BOTH
-- sendReceive (regular SQL) and parseDdl (DDL) -- previously DDL parsing
-- hardcoded "mysql" while SQL parsing hardcoded "oracle", a silent drift
-- that zeroed catalog_columns/catalog_pks for any non-MySQL corpus. parseDdl
-- now returns the full DdlResponse envelope (catalog + stats + parse_ok +
-- error), not just SchemaCatalog -- Runner.hs surfaces this via emitProgress
-- so a silently-empty catalog can never again go unreported. parseDdl also
-- takes a Maybe Text default-namespace (fills in the schema for a table/FK
-- reference left unqualified in the DDL text -- the common per-schema-dump
-- export convention); sql_worker.py's parse_ddl uses error_level=WARN and
-- strips Oracle's ENABLE/DISABLE/VALIDATE/NOVALIDATE/USING INDEX
-- constraint-state tail before parsing (sqlglot's grammar doesn't model it,
-- and one occurrence anywhere in a CREATE TABLE poisons the whole
-- statement otherwise) -- see cli/lib/src/pb/lib/ddl.py's module docstring.
data ColumnRef = ColumnRef { crNamespace, crTable :: Maybe Text, crColumn :: Text, crIsWrite :: Bool }
data RowFilter = RowFilter { rfNamespace, rfTable :: Maybe Text, rfColumn, rfOp :: Text, rfValues :: [Text] }
data SqlResult = SqlResult { srTables, srColumns :: [Text], srOperation :: Maybe Text
                            , srParseOk :: Bool, srColumnRefs :: [ColumnRef], srRowFilters :: [RowFilter] }
data TableRef = TableRef { trNamespace :: Maybe Text, trTable :: Text }   -- Ord; lowercased upstream
data CatalogTable      = CatalogTable      { ctRef  :: TableRef, ctColumns  :: [Text] }
data CatalogPrimaryKey = CatalogPrimaryKey { cpkRef :: TableRef, cpkColumns :: [Text] }
data CatalogForeignKey = CatalogForeignKey
  { cfkConstraintName :: Maybe Text
  , cfkFromTable :: TableRef, cfkFromColumns :: [Text]
  , cfkToTable   :: TableRef, cfkToColumns   :: [Text] }   -- from/to columns paired by position
data CatalogCheckConstraint = CatalogCheckConstraint
  { cckConstraintName :: Maybe Text, cckTable :: TableRef, cckPredicate :: Text }
data SchemaCatalog = SchemaCatalog
  { scTables :: [CatalogTable], scPrimaryKeys :: [CatalogPrimaryKey]
  , scForeignKeys :: [CatalogForeignKey], scChecks :: [CatalogCheckConstraint] }
data DdlStats = DdlStats { dsStatementsTotal, dsStatementsParsed, dsStatementsSkipped :: Int }
data DdlResponse = DdlResponse
  { ddlCatalog :: SchemaCatalog, ddlStats :: DdlStats, ddlParseOk :: Bool, ddlError :: Maybe Text }
data SqlBridgePool = SqlBridgePool
  { sbpSlots :: Vector (IORef WorkerConn), sbpCmd :: FilePath, sbpArgs :: [String], sbpDialect :: Text }
-- sbpCmd/sbpArgs (SQL bridge discovery hardening, 2026-07-09; was sbpBinary,
-- always exec'd with no args): startWorker now execs `cmd args` directly
-- (no shell). Production (PB.Pipeline.Runner) sets cmd = the python
-- interpreter path from --sql-worker-python (always sys.executable from the
-- pb CLI, never absent) and args = sqlWorkerModuleArgs = ["-m",
-- "pb.pipeline.bridge.sql_worker"] -- the worker module's location within
-- its own distribution is fixed and needs no discovery (formerly execed an
-- *installed pb-sql-worker console-script shim* directly, which depended on
-- that shim existing at all -- removed). Tests (SqlParseTest.hs/
-- RunnerTest.hs) pass a directly-executable shebang'd mock-worker script as
-- cmd with args = [] to substitute fake worker behavior (crash-on-Nth-
-- request, wrong protocol, etc) -- unchanged from before this rename.
sqlWorkerModuleArgs :: [String]  -- = ["-m", "pb.pipeline.bridge.sql_worker"]; exported constant
startSqlBridgePool  :: Int -> FilePath -> [String] -> Text -> IO SqlBridgePool   -- n, cmd, args, dialect (shared by parseSql + parseDdl)
shutdownSqlBridgePool :: SqlBridgePool -> IO ()
parseSql :: SqlBridgePool -> Int -> Text -> IO SqlResult          -- per-statement, any slot; retries once on worker crash
parseDdl :: SqlBridgePool -> Maybe Text -> Text -> IO DdlResponse -- pool, defaultNamespace, ddlText; always slot 0 (one-shot per run)
extractBsRawNodes :: [Located BodyStmt] -> [(Int, Text)]          -- recurses into if/for/do/choose bodies
-- Internal: requestResponse (shared framing, both parseSql/parseDdl go through it), encodeLen/decodeLen (4-byte BE length prefix)
```

### `PB.Pipeline.Runner`

```haskell
-- Batch orchestration: DuckDB streaming, worker loops.
-- Re-exports from Emit: runFile, collectStatements, wrapSrFile, extractWindowLayout, reconstructRetrieveSql
runModeDb :: FilePath -> FilePath -> [Text] -> Text -> Maybe FilePath -> Maybe Text -> IO ()
-- srcDir, dbPath, ddlArgs, dialect, mSqlWorkerFlag (Plan 148 Phase 1a-3; Oracle
-- hardening 2026-07-08 changed the DDL param from Maybe FilePath to [Text] and
-- added the dialect param). ddlArgs are raw --ddl CLI values in [schema:]path
-- form (repeatable -- e.g. --ddl CLIMS:clims.sql --ddl CLIMS_COMMON:common.sql
-- for multiple per-schema dumps with cross-schema FKs). dialect is the sqlglot
-- dialect for BOTH DDL and regular embedded-SQL parsing, set once on the
-- SqlBridgePool (see SqlParse's sbpDialect) so the two can't drift --
-- previously DDL silently hardcoded "mysql" while SQL parsing hardcoded
-- "oracle", which zeroed catalog_columns/catalog_pks for any non-MySQL
-- corpus. mSqlWorkerFlag (SQL bridge discovery hardening, 2026-07-09; final
-- form after 3 rounds -- see BACKLOG's retrospective) is a python
-- interpreter path passed explicitly via --sql-worker-python; preferred over
-- lookupEnv "PB_SQL_WORKER" (used only when the flag is Nothing, for
-- direct/manual `cabal run pbc --` invocations) so bridge availability can't
-- be lost anywhere in a shell -> uv run -> python -> subprocess.Popen chain.
-- The pb CLI always passes its own sys.executable here unconditionally --
-- never absent for a running interpreter, so there is no discovery/lookup
-- on the Python side at all. The bridge worker itself is then launched as
-- `pythonExe -m pb.pipeline.bridge.sql_worker` (SqlParse.sqlWorkerModuleArgs)
-- rather than exec'ing an installed pb-sql-worker console-script shim --
-- the checked-in module's location within its own distribution is fixed
-- and needs no separate discovery step either. When the bridge is
-- available, each ddlArg is read + parsed independently (parseDdlArg splits
-- the schema tag, parseDdl applies it as the default namespace for
-- unqualified tables/FK refs in that file) and appended via catalogToRows;
-- an emitProgress "ddl_loaded" event reports per-file parse_ok/error/
-- statement-stats/table+pk+fk+check counts -- so a silently-empty catalog
-- (the original bug report) can never go unnoticed again. When no bridge,
-- emits a "warning" progress event per ddlArg and skips (no hard error).
-- Main.hs's --ddl/--sql-dialect/--sql-worker-python flags thread through
-- here. The final 'Maybe Text' param is --default-namespace (Plan 157;
-- Phase 0 threaded it this far as mDefaultNamespace, Phase 1 wires it
-- through runPhaseB/runPass9 into SchemaCategory.buildSchema, which
-- resolves an unqualified table ref to this namespace iff the DDL catalog
-- defines the table under it -- never guessed).
parseDdlArg :: Text -> (Maybe Text, FilePath)
-- Pure. Splits a --ddl CLI value in [schema:]path form -- the prefix before
-- the first ':' is treated as a schema tag only when it contains no '/' (so
-- a bare path with no tag, e.g. "../clims.sql", passes through untouched).
catalogToRows :: SchemaCatalog -> ([CatalogColumnRow], [CatalogPkRow], [CatalogFkRow], [CatalogCheckRow])
-- Pure. Flattens SqlParse's row-oriented SchemaCatalog into DuckDb's row
-- types, assigning positional ordinals; composite FKs pair
-- fromColumns[i]/toColumns[i] by position. 4th tuple element (checks) added
-- alongside SchemaCatalog's scChecks field, 2026-07-08.
-- Internal: CompiledPs, CompiledDw, CompiledFile, compileOne, appendToDb,
--           workerLoopFiles, workerLoopFilesNoBridge, emitProgress, jsonText
-- CompiledDw gained cdDwRetrieveColumns :: [DwRetrieveColumnRow] (Plan 148
-- Phase 1b, 2026-07-07): compileOne's PsDw branch splits each DwRetrieve's
-- drColumns via SchemaCategory.splitColumnRef.
--
-- compileOne gained a DwFootprintCtx param (Plan 163 Phase 6, 2026-07-10),
-- slotted right after mDefaultNamespace: compileOne :: Set.Set (Text, Text)
-- -> Maybe Text -> DwFootprintCtx -> WorkspaceEnv -> ControlIndex ->
-- Map.Map Text [(TableRef, Text)] -> Maybe (SqlBridgePool, Int) -> Text ->
-- ParseOutcome -> IO CompiledFile. Built once in runModeDb from the same
-- DDL catalog rows catTables is derived from (mkDwFootprintCtx catCols
-- mDefaultNamespace on the bridge path; mkDwFootprintCtx [] mDefaultNamespace
-- -- empty catalog -- on the no-bridge path, matching catTables there), then
-- threaded through workerLoopFiles/workerLoopFilesNoBridge the same way
-- wsEnv/controlIdx already are. The PsDw branch calls
-- PB.Analysis.DwFootprint.dwRetrieveFootprint dwfCtx fpT obj table and
-- keeps only its LegWrites/LegReads legs (pattern-matched directly off the
-- Set SchMorphism; LegRetrieve/LegFk are dropped -- see this module's own
-- CompiledDw fields below), producing 2 new CompiledDw fields:
-- cdDwWriteColumns, cdDwWhereColumns :: [DwRetrieveColumnRow], appended via
-- 2 new DuckDb functions appendDwWriteColumns/appendDwWhereColumns.
-- CompiledPs gained cpsCatFootprintColumns :: [SqlStmtColumnRow] (Plan 163
-- Phase 3, 2026-07-10). compileOne's type signature gained a 4th positional
-- param, globalDwColumns :: Map.Map Text [(TableRef, Text)] (every DW's
-- resolved retrieve columns, keyed by lowercased DW name) -- built once in
-- runModeDb from Phase A0's already-parsed PsDw outcomes via the new pure
-- helper dwRetrieveColRowsForFootprint (deliberately not shared with
-- compileOne's own PsDw-branch DW-column extraction, which builds the
-- DuckDb-side DwRetrieveColumnRow, not SchemaCategory's DwRetrieveColRow --
-- same write-side/read-shape split as SqlParse's row types). Per procedure,
-- compileOne builds a PB.Analysis.SchFootprint.FunctorCtx (fcStmtObj =
-- SqlStmtId fp obj pName sLine; fcControlBindings = controlBindings'
-- (Plan 164 Phase C, see below) and folds compileProcedureToCatOp through
-- foldSchFootprint; morphismToColRow (Runner.hs, not exported) converts
-- each resulting SchMorphism back into the same SqlColRow-shaped raw fact
-- inSqlColumns already uses (see SchemaCategory's SchemaInputs note above
-- for why -- namespace resolution must stay centralized in buildSchema, not
-- baked in here) as a SqlStmtColumnRow, appended via
-- appendCatFootprintColumns. workerLoopFiles/workerLoopFilesNoBridge both
-- gained the same globalDwColumns param, threaded through from runModeDb.
-- FIXED (Plan 163 Phase 3.5, 2026-07-10, see BACKLOG's now-closed "Plan 163
-- Phase 3 wiring session" entry): resolveSetItem matches on
-- (T.toLower obj, ctrl), and obj comes from srPrimaryObject -- previously
-- wrong for any file declaring a non-window type block (e.g. `type X from
-- structure`) before its real window/user-object type block (11/433 files
-- in PowerBuilder-Example-extract, 0/139 in openpay). srPrimaryObject now
-- prefers the srTypeBlocks entry matching the forward block's first
-- fwdTypes entry (see its own Code Index entry below); verified against
-- pbexamw1.pbl/w_dw_copy.srw that objects/procedures now attribute to
-- w_dw_copy (not os_data) and cat_footprint_columns went from 0 to 5 rows
-- across PowerBuilder-Example-extract (this 5-row count is PowerBuilder-
-- Example's real baseline -- Plan 164's plan file/BACKLOG previously
-- misremembered it as "7/7"; re-confirmed via git stash before Phase C's
-- own changes too). Openpay's separate 0/6 SetItem gap (runtime aliasing,
-- e.g. `ctrl = other.uo.dw`) is addressed by Plan 164 Phase C below;
-- Phase C's own real-corpus gate didn't fully materialize until Phase E's
-- ControlIndex key-qualification fix (see that note) -- both now confirmed
-- against the real corpus.
--
-- compileOne gained a ControlIndex param (Plan 164 Phase C, 2026-07-10),
-- threaded through workerLoopFiles/workerLoopFilesNoBridge from a
-- workspace-wide `controlIdx = buildControlIndex allParsedSrFiles` built
-- once in runModeDb (same input file set as wsEnv). Inside the PsParsed
-- branch, the zip logic that used to be inlined directly into procs's list
-- comprehension is now a shared `procSpecs` binding (used by both procs and
-- the new alias scan below -- no behavior change, just de-duplication).
-- `aliasBindings = Map.unions [PB.Analysis.SchFootprint.runtimeDwAliasBindings
-- controlIdx (weHierarchy wsEnv) obj procEnvWithLocals body | ... <- procSpecs]`
-- scans every procedure in the file (steLocal seeded per-procedure via
-- CallClassify.collectBodyLocals) for the runtime DW-alias-assignment
-- pattern and unions the results file-wide (the alias assignment and the
-- SetItem call site are commonly in different procedures -- confirmed
-- against the real w_misth_fylo_form.srw example). `controlBindings' =
-- Map.union controlBindings aliasBindings` (static literal bindings win on
-- a key collision) is what every procedure's FunctorCtx now uses instead of
-- the old file-static-only controlBindings. FIXED (Plan 164 Phase E,
-- 2026-07-10): controlIdx's own (owner, name) key used to collide across
-- unrelated windows reusing a common generic child-control name at
-- full-corpus scale, so this wiring's real openpay gate (2 new
-- cat_footprint_columns rows) didn't materialize even though the wiring
-- itself was correct (real-corpus-fixture-verified in isolation). Phase E
-- qualified ControlIndex's key to (root, owner, name) -- see
-- PB.Analysis.ControlHierarchy's own entry below for the full design. The
-- gate now reaches 2/2 rows against the real corpus.
-- Phase A: parse → compile → append to DuckDB (concurrent producer-consumer)
-- Phase B: delegates to PB.Pipeline.Passes.runPhaseB (takes the
-- mDefaultNamespace param, Plan 157 Phase 1)
--
-- Plan 144 Phase 5 Step 7 (2026-07-06): the old CpsCompile.compileProcedure
-- compiler and every diagnostic that compared it against
-- CatOp.compileProcedureViaCatOp were deleted once the swap (Step 6) was
-- verified equivalent — collectAllProcs, runModeDualCps ("--dual-cps"),
-- runModeDualTrace ("--dual-trace"), runInspect/runInspectOn ("--inspect"),
-- isRealDiff, traceMaxSteps, and the corresponding Main.hs flags no longer
-- exist. compileProcedureViaCatOp (now PB.Compile.Flatten, moved from
-- CatOp in the Plan 151 module split, 2026-07-06) was the sole compiler
-- through Plan 167 Phase 7 Step 6 (2026-07-14), which switched compileOne's
-- instrJs binding (and Emit.hs's own instrGraph call site) to
-- compileProcedureViaEffTerm, and its catFpRows binding (below) from
-- foldSchFootprint/compileProcedureToCatOp to
-- foldSchFootprintEff/compileProcedureToEff. compileProcedureViaCatOp/
-- foldSchFootprint themselves are unchanged, kept as cross-check oracles
-- until Phase 7 Step 8 retires the untyped CatOp/LowCat stack.
```

### `PB.Pipeline.Serialise`

```haskell
-- Orphan ToJSON instances for all PB.AST.* types and PB.Analysis.Taint types.
-- Import as: import PB.Pipeline.Serialise ()
-- Brings ToJSON instances into scope; exports nothing explicitly.
-- Sum-type discriminator: "tag" key (string); single-field payload → "contents".
-- InterprocEdge, ProcedureSummary, ProcSummaryReturnFlow use manual instances
-- to match Python snake_case keys (caller_object, callee_proc, etc.).
```

### `PB.Pipeline.CfgBuild`

```haskell
-- Pure. buildCfg :: [Located BodyStmt] -> Cfg. Mirrors cfg_builder.py.
```

Moved to `PB.Analysis.Cfg` (Plan 118 H1; renamed from `PB.Analysis.CfgBuild`
in Plan 151 Phase 2a, 2026-07-06 — noun module name matching `SSA.hs`'s own
precedent, no content change).

### `PB.Analysis.Cfg`

```haskell
-- Pure. buildCfg :: [Located BodyStmt] -> Cfg. Mirrors cfg_builder.py.
data CfgBlock = CfgBlock { cbId :: Text, cbStmts :: [Located BodyStmt], cbFirstLine :: Maybe Int, cbLastLine :: Maybe Int }
data CfgEdge  = CfgEdge  { ceSrc :: Text, ceDst :: Text, ceLabel :: Text }
data Cfg      = Cfg      { cfgEntry :: Text, cfgExits :: [Text], cfgBlocks :: [CfgBlock], cfgEdges :: [CfgEdge] }
-- Edge labels: "T"/"F" (branches), "" (fallthrough), "loop" (back-edge), "case:N".
```

### `PB.Analysis.CallClassify`

```haskell
-- Pure call classification, plus two small pure AST helpers (parseArgList,
-- collectBodyLocals) moved in from the old PB.Analysis.CpsCompile in Plan
-- 151 Phase 2b (2026-07-06) -- they have nothing to do with InstrGraph's own
-- type (renamed from CpsGraph in Plan 152) and were already imported
-- alongside it by every consumer.
-- Shared by the old (deleted) compiler and the current SSA→CatOp pipeline.
data CallKind = PureCall | SuspendCall
classifyExpr :: ScopedTypeEnv -> Expr -> CallKind
-- classifyExpr returns SuspendCall (no effect name baked in).
-- effectName is a separate function (takes pre-parsed [Expr] args).
-- ExCall branch (Plan 164 D4, 2026-07-10): a single segment checks
-- isBuiltinSuspendFn; 2+ segments splits into (all-but-last, last) via
-- resolveLvalueType/reverse (no partial head/init/last -- PB.Prelude hides
-- them) and classifies on the resolved head-chain's type + the last segment
-- as method name. Previously only exactly-2-segment chains (`dw_1.retrieve()`)
-- were handled; a real dotted-chain-then-call of 3+ segments (the ONLY shape
-- Grammar.Body's lvaluePrefix/chainCalls ever produces for e.g.
-- `tab1.page1.uo_epidom.dw.Retrieve()` -- it's always a flat ExCall, never
-- nested ExMethodCall) silently fell through to PureCall.
effectName :: Expr -> [Expr] -> Text
isBuiltinSuspendFn :: Text -> Bool
isTypedSuspend :: Map.Map Text Text -> Text -> Text -> Bool
resolveLvalueType :: ScopedTypeEnv -> Lvalue -> Maybe Text
-- Not exported. Shared by classifyExpr's ExCall branch and
-- resolveReceiverType's ExLvalue branch (Plan 164 D4). 1 segment ->
-- lookupScopedVar; 2+ segments -> resolveMemberChainType (steControlIndex
-- env) (steHierarchy env) (steObject env) segs -- the workspace-wide
-- multi-hop control-chain resolver from PB.Analysis.ControlHierarchy.
resolveReceiverType :: ScopedTypeEnv -> Expr -> Maybe Text
-- ExLvalue branch now calls resolveLvalueType (multi-hop, was: first-segment
-- only). ExCall-as-receiver branch (a receiver that is itself a call, e.g.
-- `foo().bar()`) deliberately left single-segment-only -- that's call
-- return-type inference, a different unsolved problem, out of D4's scope.
calleeName :: Expr -> Text
segName :: LvSegment -> Text
lvHead :: Lvalue -> Text
isTriggerEvent :: Lvalue -> Bool
parseArgList      :: [Token] -> Expr                            -- imported by CatLower, CatEval
collectBodyLocals :: [Located BodyStmt] -> Map.Map Text PbType  -- imported by GraphBuilder
```

### `PB.Compile.IR`

```haskell
-- Pure module — no I/O. The typeclasses ('Category', 'Cartesian',
-- 'Cocartesian', 'Effectful') plus the Freyd-split GADT pair 'Pure'/'Eff'
-- that implements them. The surrounding pipeline lives in sibling modules:
--
--   * 'PB.Compile.FromSSA'  -- SSA -> Eff compilation (compileSsaToEff)
--   * 'PB.Compile.Flatten'  -- Eff -> flat InstrGraph flattening
--   * 'PB.Compile.Interp'   -- direct Haskell execution (Interp target,
--                             used for testing)
class Category k where { id :: k a a; (.) :: k b c -> k a b -> k a c }
class Category k => Cartesian k where { exl, exr, (&&&) }
class Category k => Cocartesian k where { inl, inr, (|||) }
class Category k => Effectful k where { eval, assign, lookup, suspend, callProc, splitValue, ret, loopK, branchK, assignWithRhs, memoTag }
-- branchK: promotes branching to a primitive with direct access to both arms.
-- assignWithRhs: fused assign-with-rhs (avoids erasing the RHS through
-- no-value-channel carriers like NGB/WB).
-- memoTag: hook for carriers that must not re-materialize shared ELetRef bodies.
branch  :: (Effectful k, Cartesian k, Cocartesian k) => Expr -> k env b -> k env b -> k env b
branchEff :: Expr -> Eff env b -> Eff env b -> Eff env b
foldFreyd :: EffTerm a b -> k a b  -- where k is any Effectful/Cartesian/Cocartesian instance
data Pure a b where  -- the cartesian (duplication-safe) category
  PId, PComp, PFork, PExl, PExr, PInl, PInr, PFanIn, PEval :: ...
data Eff a b where   -- the premonoidal (effectful) category
  J :: Pure a b -> Eff a b
  EComp, EBranch, ELetRef, ELoop, EReturn, EAssign, EAssignWithRhs,
  ECall, ESuspend, ESplitValue, EFanIn :: ...
data EffTerm a b = EffTerm (Eff a b) (Map Text (Eff () ()))  -- spine + shared-term table
```

### `PB.Compile.SSA`

```haskell
-- Pure. Converts a procedure's body ('[Located BodyStmt]') into a
-- block-structured 'SsaProc' ('PB.Compile.LoopAnalysis' consumes it directly by
-- unversioned variable name). NOT dominance-based SSA despite the name —
-- Plan 155 F1 (2026-07-08) deleted the dominator-tree/dominance-frontier/
-- phi-placement/variable-renaming machinery this module used to have: it
-- was fully vestigial (every phi's source list was always [], and renaming
-- only ever touched a version field nothing downstream read — PB has no
-- block-scoped locals, so there was never a case needing per-version
-- disambiguation). See the module's own top-of-file history note for the
-- full argument. ~396 lines (was ~700).
newtype SsaVar = SsaVar { svName :: Text }   -- no version field
data SsaVal = SsaConst Expr | SsaVarRef SsaVar | SsaBinOp BinOp SsaVal SsaVal | SsaNot SsaVal | SsaNull
data SsaAssign = SsaAssign { saVar :: SsaVar, saRhs :: SsaVal }
data SsaBlock = SsaBlock { sbAssigns :: [SsaAssign], sbTerm :: SsaTerm }
data SsaTerm = SsaGoto Text | SsaBranch SsaVal Text Text
             | SsaSwitch SsaVal [(SsaVal, Text)] Text | SsaReturn (Maybe SsaVal)
             | SsaBreak | SsaContinue
data SsaProc = SsaProc { spName :: Text, spBlocks :: Map.Map Text SsaBlock
                        , spEntry :: Text, spVars :: [SsaVar] }
  -- spVars: every assigned var, one entry per assignment, block-declaration
  -- order. Not consumed by CatLower (which walks spBlocks directly) — kept
  -- for tests/debugging only.
buildSsa :: ScopedTypeEnv -> Text -> [Located BodyStmt] -> SsaProc
-- Internal (not exported): assignTarget, lhsToExpr, rawArgsToExpr, headDef,
-- buildEdgeMap, cfgBlockToSsa, findLoopBackEdgeStmts, findLoopHeaderStmts,
-- stmtToAssigns, exprToSsaVal, cfgTermToSsa, doCondExpr, findControlStmt,
-- findEdgeLabel.
```

### `PB.Compile.LoopAnalysis`

```haskell
-- Pure. Loop/merge-point analysis shared by the SSA -> Eff lowering pass
-- (PB.Compile.FromSSA). Takes a SsaProc (already in SSA form — see
-- PB.Compile.SSA) and computes the loop-header/merge-point/loop-exit
-- structure that compileSsaToEff needs to lower it.
data CompileCtx = CompileCtx { ccEnv :: ScopedTypeEnv, ccUserFns :: Set Text, ccMergePoints :: Set Text }
-- Exported: computeMergePoints, computeLoopHeaders, computeLoopNestParents,
-- computeAllLoopExits, computeLoopBodyBlocks, discoverReachable, canReach,
-- determineLoopExitTarget, isLoopExit, termSuccessors, ssaValToExpr.
```

### `PB.Compile.Flatten`

```haskell
-- Pure (every monad here is a bare State, never IO). EffTerm -> flat
-- InstrGraph flattening. Contains two Effectful instances over EffTerm:
-- NGB (instruction-graph construction) and WB (wiring-diagram construction).
--
-- NamedGraphBuilder (NGB): the production flattener. NGB a b = Text -> Text ->
-- NamedBuilder Text (next, loopCont). A loop body's Left/Right exit needs
-- two distinct continuations.
newtype NGB a b = NGB { runNGB :: Text -> Text -> NamedBuilder Text }
newtype NamedBuilder a = NamedBuilder { runNamedBuilder :: State NamedBuilderState a }
buildEffGraphNamed :: EffTerm () () -> InstrGraph' Text
compileProcedureToEff :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> EffTerm () ()
-- THE PRODUCTION ENTRY POINT -- both PB.Pipeline.Emit's injectCompiled and
-- PB.Pipeline.Runner's compileOne call this.
compileProcedureViaEffTerm :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> InstrGraph
-- WiringBuilder (WB): a third Effectful instance over EffTerm, producing
-- WiringGraph/WiringNode for JSON serialization. Dedup falls out of Map key
-- uniqueness via memoTag.
data WiringNode p = WireAssign {..} | WireCond { wcExpr :: Expr, wcNext :: p }
                  | WireBranch { wtThen :: p, wtElse :: p } | WireCall {..}
                  | WireSuspend {..} | WireReturn | WireNop {..}
data WiringGraph p = WiringGraph { wgNodes :: Map.Map Text (WiringNode p), wgEntry :: p }
newtype WB a b = WB { runWB :: Text -> Text -> WiringB Text }
buildEffGraphWiring :: EffTerm () () -> WiringGraph Text
compileProcedureToWiring :: ScopedTypeEnv -> Set.Set Text -> [Located BodyStmt] -> WiringGraph Text
```

### `PB.Compile.Interp`

```haskell
-- Direct Haskell execution of a compiled EffTerm (the "Interp" target) —
-- used for testing, without going through PB.Compile.Flatten or the TS
-- runtime. Parallels PB.Compile.InstrInterp (interprets the flat InstrGraph
-- Flatten produces instead) — the semantic-equivalence oracle cross-checks
-- the two.
data InterpState = InterpState { isEnv :: Map.Map Text Value, isTrace :: [TraceEvent], isMocks :: MockResponses }
newtype ReturnUnwind = ReturnUnwind InterpState  -- thrown by ret to unwind past all enclosing loops
newtype Interp a b = Interp { runInterp :: a -> StateT InterpState IO b }
interpretLoop :: Interp a (Either a b) -> Interp a b
runInterpIO :: Interp a b -> a -> IO b
runEff :: EffTerm a b -> Interp a b  -- foldFreyd specialization (test-only)
```

### `PB.Compile.InstrTypes`

```haskell
-- Pure. Shared InstrNode/InstrGraph types + canonical-shape helpers for
-- hand-trace/golden-fixture tests. Production flattens via
-- PB.Compile.Flatten.compileProcedureViaEffTerm (SSA -> EffTerm -> InstrGraph).
data InstrNode = InstrAssign {..} | InstrBranch {..} | InstrGoto {..} | InstrCall {..}
               | InstrSuspend {..} | InstrReturn {..} | InstrNop {..} | InstrCallProc {..}
data InstrGraph = InstrGraph { igNodes, igEntry, igSuspensionPoints, igSourceMap }
-- ShapeNode/canonicalize/normalizeCallTag: canonical BFS-numbered shape of an
-- InstrGraph with names/values erased, for hand-trace/golden-fixture tests.
data ShapeNode = SAsgn Int | SBrnch Int Int | SGoto Int | SCall Int
               | SSusp Text Int | SRet | SNop Int | SCProc Int
canonicalize     :: InstrGraph -> [ShapeNode]
normalizeCallTag :: ShapeNode -> ShapeNode  -- SCProc n -> SCall n (cosmetic tag-only divergence)
-- Named-graph intermediate (InstrGraph'/linearize):
data InstrNode' p = InstrAssign' {..} | InstrBranch' {..} | ...
data InstrGraph' p = InstrGraph' { igNodes' :: Map.Map Text (InstrNode' p), igEntry' :: p }
linearize :: InstrGraph' p -> InstrGraph
```

### `PB.Analysis.Dataflow` (Plan 111a)

```haskell
-- Pure intra-procedural dataflow: def-use + reaching definitions.
extractDefsUses      :: CfgBlock -> BlockFlow
reachingDefinitions  :: Cfg -> Map Text BlockFlow -> (Map Text (Set Text), Map Text (Set Text))
analyzeProcedure     :: Text -> Text -> Cfg -> ProcFlow   -- obj, proc, cfg
-- analyzeWorkspace (Pass 6, writes proc_defs.json/proc_uses.json) is deferred to 111d-1.
data DefSite = DefSite { dsVar :: Text, dsBlock :: Text, dsStmtIdx :: Int, dsLine :: Maybe Int, dsKind :: Text }
data UseSite = UseSite { usVar :: Text, usBlock :: Text, usStmtIdx :: Int, usLine :: Maybe Int, usKind :: Text }
data BlockFlow = BlockFlow { bfBlockId :: Text, bfGen :: Set Text, bfKill :: Set Text, bfDefs :: [DefSite], bfUses :: [UseSite] }
data ProcFlow  = ProcFlow  { pfObject :: Text, pfProc :: Text, pfBlocks :: Map Text BlockFlow
                           , pfReachingIn :: Map Text (Set Text), pfReachingOut :: Map Text (Set Text)
                           , pfAllDefs :: Map Text [DefSite], pfAllUses :: Map Text [UseSite] }
-- walkExprIdents counts the ExCall callee root as a use (matches Python core/dataflow.py).
```

### `PB.Analysis.Taint` (Plan 111 — 111b/c/d-2)

```haskell
-- Taint analysis: source/sink classification, BFS propagation, path tracing.
-- JSON path: reads proc_defs/uses, resolved_calls, global_vars from JSON files.
-- DuckDB path: reads from DB via PB.Pipeline.DuckDb query helpers.
-- Classifies sources (SELECT INTO, event params) and sinks (INSERT/UPDATE/DELETE/EXECUTE)
-- from AST. extractSqlStmts recurses into BsIf/BsFor/BsDo/BsChoose, not just top-level BsRaw.
-- Propagates through intra-proc def-use chains and inter-proc
-- arg/return/global edges (computed internally from resolved_calls).
data TaintSource = TaintSource { tsFile, tsObject, tsProcName, tsVarName, tsSourceType :: Text, tsLine :: Maybe Int }
data TaintSink   = TaintSink   { tskFile, tskObject, tskProcName, tskVarName, tskSinkType, tskSeverity :: Text, tskLine :: Maybe Int }
data TaintPath   = TaintPath   { tpSource :: TaintSource, tpSink :: TaintSink, tpSteps :: [TaintStep], tpSeverity, tpCategory :: Text }
data TaintStep   = TaintStep   { tstObject, tstProcName, tstVarName :: Text, tstLine :: Maybe Int, tstStepKind, tstDescription :: Text }
data TaintAnnotation = TaintAnnotation { taFile, taObject, taProcName, taBlockId :: Text, taIsTaintEntry, taIsTaintSink :: Bool, taTaintedVars :: [Text }
data InterprocEdge = InterprocEdge { ieCallerObject, ieCallerProc :: Text, ieCallerLine :: Maybe Int, ieCalleeObject, ieCalleeProc, ieEdgeKind, ieVarName, ieCallerContext, ieCalleeContext :: Text }
data ProcSummaryReturnFlow = ProcSummaryReturnFlow { psrfObject, psrfProc, psrfLhsVar :: Text }
data ProcedureSummary = ProcedureSummary { psFile, psObject, psProcName :: Text, psParamsIn, psGlobalsRead, psGlobalsWritten :: [Text], psReturnFlowsTo :: [ProcSummaryReturnFlow] }
data TaintResult = TaintResult { trSources :: [TaintSource], trSinks :: [TaintSink], trPaths :: [TaintPath], trAnnotations :: [TaintAnnotation], trEdges :: [InterprocEdge], trProcedureSummaries :: [ProcedureSummary] }
data DefRow  -- FromJSON for proc_defs.json (file, object, proc_name, var_name, block_id, stmt_index, line, kind)
data UseRow  -- FromJSON for proc_uses.json
data ResolvedCallRow  -- FromJSON for resolved_calls.json
data GlobalVarRow     -- FromJSON for global_vars.json; field key is "name" (NOT "var_name" — bug fixed 2026-06-24)
classifySources    :: [SqlStmt] -> [ProcMeta] -> [TaintSource]
classifySinks      :: [SqlStmt] -> [TaintSink]
buildInterprocEdges :: [ResolvedCallRow] -> [DefRow] -> [UseRow] -> Set Text -> [ProcMeta] -> [InterprocEdge]
buildProcedureSummaries :: [InterprocEdge] -> [DefRow] -> [UseRow] -> Set Text -> [ProcMeta] -> [ProcedureSummary]
propagateTaint     :: [TaintSource] -> [DefRow] -> [UseRow] -> [InterprocEdge] -> (Set (Text,Text,Text), Provenance)
traceTaintPath     :: TaintSource -> TaintSink -> Provenance -> [TaintStep]
buildTaintAnnotations :: Set (Text,Text,Text) -> [TaintSource] -> [TaintSink] -> [DefRow] -> [UseRow] -> [TaintAnnotation]
taintAnalysis      :: [ResolvedCallRow] -> [DefRow] -> [UseRow] -> Set Text -> Text -> SrFile -> TaintResult
```

### `PB.Analysis.DeadCode` (Plan 161 Phase 2b cutover, 2026-07-11)

```haskell
data ProcInfo = ProcInfo { piObject, piName, piProcType :: Text, piCyclomatic :: Maybe Int }
data DeadProcedure = DeadProcedure
  { dpObject, dpName, dpProcType :: Text, dpCyclomatic :: Maybe Int
  , dpConfidence :: Text   -- "high" | "medium" | "low"
  , dpCallerCountNaive, dpCallerCountScoped :: Int
  }

cyclomaticComplexity :: Cfg -> Int   -- E - N + 2, unrelated to the reachability logic below

-- computeDeadProcedures (the seeded-BFS reachability computation: same-object
-- + cross-object + override-propagation edges, event/on/DW seeds) is GONE --
-- deleted once its Datalog port (PB.Pipeline.Souffle.deadReachRules --
-- proc_reachable/proc_dead) was proven exact against it on two real corpora
-- (104/104 openpay, 279/279 PowerBuilder-Example), rather than kept as a
-- dual-implementation "oracle": Souffle is already a hard runtime dependency
-- of this pipeline (shelled out to unconditionally since Plan 161 Phase 1),
-- so a redundant Haskell copy bought no dependency-safety margin, only
-- upkeep cost. classifyDeadProcedures is what replaced it -- same output
-- shape, but takes the dead set as an INPUT (read back from proc_dead via
-- PB.Pipeline.DuckDb.queryProcDead) instead of computing it. What's left is
-- genuinely Haskell-only: confidence/caller-count classification is report
-- formatting, not a fixpoint query.
classifyDeadProcedures
  :: Set (Text, Text)            -- dead (object, proc) pairs, from proc_dead
  -> [ProcInfo]                  -- all procedures
  -> [(Text, Text, Text)]        -- raw calls: (object, from_proc, to_name)
  -> [(Text, Text, Text, Text)]  -- resolved calls: (object, from_proc, target_object, target_proc)
  -> [DeadProcedure]

-- Every (childObj, method, parentObj) triple where childObj is a transitive
-- descendant of parentObj and both declare a procedure named method --
-- extracted from the old computeDeadProcedures' override-edge flattening
-- (allDescOf/methodsByObj), which stays Haskell/SQL-computed (same
-- treatment `leg` gets for `reaches`) since it's persisted as a fact table
-- (PB.Pipeline.DuckDb.appendProcedureOverrides -> procedure_overrides table)
-- and consumed as PB.Pipeline.Souffle's `overrides` EDB relation, not
-- reimplemented in Datalog itself.
computeOverrideEdges :: [ProcInfo] -> [(Text, Text)] -> [(Text, Text, Text)]
```

### `PB.Analysis.TypeEnv`

```haskell
-- Cross-file type environment. Used by PB.Compile.Flatten consumers + Runner (Plan 114 unified them).
data TypeEnv = TypeEnv { teVars :: Map Text PbType, teUserTypes :: Map Text Text }
buildWorkspaceTypeEnv :: [SrFile] -> TypeEnv
lookupVarType    :: Text -> TypeEnv -> Maybe PbType      -- case-insensitive
lookupUserType   :: Text -> TypeEnv -> Maybe Text        -- case-insensitive
lookupBaseType   :: Text -> TypeEnv -> Maybe Text        -- resolves var → base type, walks inheritance chain with cycle guard
withProcScope    :: [(Text, PbType)] -> TypeEnv -> TypeEnv  -- overlay params (shadow globals of same name)
-- extractTypeDecls (internal, feeds teUserTypes/weHierarchy) now applies
-- PB.AST.SourceFile.splitAncestorRef to tdAncestor before use (Plan 164
-- Phase A, 2026-07-10) -- a backtick-declared ancestor resolves to just the
-- class part, so lookupBaseType/isDescendantOf's chain walk doesn't
-- silently stop at a backtick-compound node.

-- Workspace-wide + per-procedure scoped env (built once per compile run /
-- once per procedure respectively); consumed by CallClassify/CatLower/
-- GraphBuilder's whole SSA->CatOp pipeline.
data WorkspaceEnv = WorkspaceEnv
  { weGlobals      :: Map.Map Text PbType
  , weInstanceVars :: Map.Map Text (Map.Map Text PbType)  -- object name -> instance vars
  , weHierarchy    :: Map.Map Text Text                   -- full inheritance map
  }
buildWorkspaceEnv :: [SrFile] -> WorkspaceEnv

-- steObject/steControlIndex (Plan 164 D4, 2026-07-10): the enclosing
-- object name and workspace-wide ControlIndex, added so
-- CallClassify.resolveLvalueType can resolve a multi-segment dotted chain
-- (e.g. tab1.page1.uo_epidom) via PB.Analysis.ControlHierarchy
-- .resolveMemberChainType instead of only ever inspecting the first
-- segment. Piggybacks on ScopedTypeEnv the same way steHierarchy already
-- does -- one opaque value threaded through the whole compile pipeline,
-- no signature changes needed in CatLower/GraphBuilder/CompileCtx.
data ScopedTypeEnv = ScopedTypeEnv
  { steGlobal       :: Map.Map Text PbType
  , steInstance     :: Map.Map Text PbType
  , steLocal        :: Map.Map Text PbType   -- params only in P2a; body locals added in P2b
  , steHierarchy    :: Map.Map Text Text
  , steObject       :: Text          -- enclosing object; root for multi-hop chain resolution
  , steControlIndex :: ControlIndex  -- from PB.Analysis.ControlHierarchy
  }
procEnv :: WorkspaceEnv -> ControlIndex -> Text -> [(Text, PbType)] -> ScopedTypeEnv
-- Gained the ControlIndex param in Plan 164 D4 (was: WorkspaceEnv -> Text ->
-- params -> ScopedTypeEnv). Callers: Runner.hs passes its workspace-wide
-- controlIdx (already built for SchFootprint's SetItem resolution, Plan 164
-- Phase C); Emit.hs's single-file wrapSrFile builds `buildControlIndex [sf]`
-- locally (same single-file scope buildWorkspaceEnv [srFile] already has).
lookupScopedVar :: Text -> ScopedTypeEnv -> Maybe PbType  -- case-insensitive; steLocal > steInstance > steGlobal
```

### `PB.Analysis.TypeResolve` (Plan 109 — Pass 5)

```haskell
-- Pure. Produces resolved_types.json / resolved_calls.json / global_vars.json.
extractLocalVars  :: Text -> Text -> SrFile -> [LocalVar]   -- file, object, sf
extractCallSites  :: Text -> Text -> SrFile -> [CallSite]
extractGlobalVars :: Text -> Text -> SrFile -> [GlobalVar]
resolveTypes :: [LocalVar] -> Set Text -> Set Text -> [ResolvedType]   -- objs, userTypes; falls back to control-name inference
resolveCalls :: [CallSite] -> Map Text (Set Text) -> Map Text Text -> Set Text -> Set Text -> [ResolvedCall]
buildInheritsMap :: [SrFile] -> Map Text Text
-- buildInheritsMap now applies PB.AST.SourceFile.splitAncestorRef to
-- tdAncestor before storing the parent value (Plan 164 Phase A,
-- 2026-07-10) -- same fix/reasoning as TypeEnv.extractTypeDecls above;
-- fixes a latent gap where a backtick-declared ancestor (e.g. PowerBuilder's
-- "w_form_tab2`page1" extend-ancestor's-own-control syntax) made
-- ancestorChain/resolveVirtual silently stop, since no object is ever
-- literally named the raw compound string.
buildProcMap     :: [SrFile] -> Map Text (Set Text)
buildObjectSet, buildUserTypeSet :: [SrFile] -> Set Text
parseParams :: Text -> [(Text, PbType)]          -- "ref long al_row" → ("al_row", PtPrimitive "long")
classifyPbType :: PbType -> Set Text -> Set Text -> (Text, Maybe Text)  -- (kind, target)
classifyControlType :: Text -> Maybe Text  -- dw_main → datawindow (naming convention)
-- extractDwControlBindings (Plan 148 Phase 3, 2026-07-07): the DW-control ->
-- DW-object binding extraction the Phase 3 infra-slice session found
-- missing. Walks srTypeBlocks; a block's tbBody containing a "dataobject"-
-- named (case-insensitive) BsLocalVar with an ExStr literal init binds
-- (owner, control) -> dwName, where (owner, control) = (tdWithin, tdName)
-- when tdWithin is Just, else (tdName, "this") for the object's own outer
-- TypeBlock. Static-only by design: does not follow runtime aliasing
-- (ctrl = other.uo.dw, real corpus pattern in w_misth_fylo_form.srw) — no
-- binding produced rather than guessing.
extractDwControlBindings :: Text -> SrFile -> [DwControlBinding]
-- findLiteralDataObject (Plan 164 Phase B, 2026-07-10): the "dataobject"-
-- literal-BsLocalVar scan extractDwControlBindings always did, promoted
-- from a local `where`-bound helper to a top-level export so
-- PB.Analysis.ControlHierarchy.buildControlIndex can reuse it verbatim
-- instead of reimplementing the same scan a third time (already duplicated
-- once, separately, in Emit.extractWindowLayout).
findLiteralDataObject :: [Located BodyStmt] -> Maybe Text
-- Record types: LocalVar{lvFile,lvObject,lvProcName,lvVarName,lvRawType,lvIsParam,lvScopeLine}
--   CallSite{csFile,csObject,csFromProc,csToName,csCallType,csLine}
--   GlobalVar{gvFile,gvObject,gvName,gvType,gvMods}
--   ResolvedType{rtFile,rtObject,rtProcName,rtVarName,rtRawType,rtKind,rtTarget,rtIsParam,rtScopeLine}
--   ResolvedCall{rcFile,rcObject,rcFromProc,rcToName,rcCallType,rcLine,rcTargetObject,rcTargetProc,rcKind,rcConfidence}
--   DwControlBinding{dcbFile,dcbObject,dcbControlName,dcbDwName}
--   (lvPbType exists but is excluded from JSON.)
```

### `PB.Analysis.ControlHierarchy` (Plan 164 Phase B, done 2026-07-10; key qualification Phase E, done 2026-07-10)

```haskell
-- Pure. Workspace-wide control/object hierarchy index + multi-hop
-- member-chain resolver -- generalizes TypeResolve.extractDwControlBindings
-- (per-file) to walk a dotted chain (e.g. tab1.page1.uo_epidom.dw) across
-- file boundaries. All ControlDecl Text fields except cdDwBinding are
-- lowercased at construction time (case-insensitive lookup).
data ControlDecl = ControlDecl
  { cdOwner :: Text, cdName :: Text, cdAncestorType :: Text
  , cdOverridesName :: Maybe Text, cdDwBinding :: Maybe Text }
type ControlIndex = Map.Map (Text, Text, Text) ControlDecl   -- (root, owner, name), all lowercased
buildControlIndex :: [SrFile] -> ControlIndex
-- Uses TypeResolve.findLiteralDataObject for cdDwBinding. root = fst
-- (srPrimaryObject sf) for whichever file declared the TypeBlock -- the
-- Phase E fix. A flat (owner, name) key (Phase B's original design)
-- collided across unrelated windows redeclaring a common generic
-- child-control name -- CONFIRMED IN PRODUCTION (Plan 164 Phase C,
-- 2026-07-10): 11 windows in the openpay corpus alone redeclare "page1"
-- within "tab1", so last-file-wins Map.fromList bias picked an arbitrary
-- one, defeating Phase C's real-corpus SetItem-resolution gate even though
-- the resolver was correct on an isolated fixture. Qualifying by root (each
-- window's own redeclaration gets its own entry) fixed it: openpay's
-- cat_footprint_columns reached the targeted 2 rows for w_misth_fylo_form.

resolveMemberChainType      :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe Text
resolveMemberChainDwBinding :: ControlIndex -> Map.Map Text Text -> Text -> [Text] -> Maybe Text
-- Both take a starting object and chain segments (e.g. "w_misth_fylo_form",
-- ["tab1","page1","uo_epidom","dw"]); the Map.Map Text Text is an inherits
-- map (TypeResolve.buildInheritsMap's raw, case-sensitive output is fine --
-- normalized internally once per call). Public signatures are unchanged
-- since Phase B -- obj already serves as root==owner for the first hop, so
-- Phase E's key-shape change needed zero caller changes (Runner.hs,
-- SchFootprint.hs).
--
-- Each hop resolves via lookupScoped (Phase E; replaces the old
-- lookupWithAncestry): direct (root,owner,name) lookup, else walk root's
-- own class-ancestor chain via the inherits map (cycle-safe on root), then
-- unwinds any D1 cdOverridesName chain (cycle-safe on (root,owner,name))
-- to a fully-resolved terminal ControlDecl. lookupScoped distinguishes two
-- modes by whether root == owner at the call's start: "coupled" (true at
-- the very first hop, and again right after a has-a jump -- "does this
-- class directly declare a control called name") walks owner in lock-step
-- with root on ancestor-chain fallback; "decoupled" (owner is a literal
-- parent-control name distinct from root, e.g. continuing into page1
-- within tab1) holds owner fixed and only root climbs. The same
-- distinction governs D1 override-unwinding, derived for free from
-- foundRoot == cdOwner decl (no separate flag threaded) -- naively always
-- switching both root and owner to cdAncestorType decl on every override
-- (matching Phase B's original 2-tuple-owner-only formula) would mis-scope
-- a *nested* override's target (page1's own override must stay scoped to
-- the literal tab1 in the ancestor's own file, not jump to the ancestor
-- class's top-level scope).
--
-- Continuing to the NEXT segment tries two (root, owner) pairs in order,
-- since a single strategy can't distinguish them from a per-file view: (1)
-- the resolved control's own literal name with root held fixed (the
-- "visual tree" convention -- every file in one window's own ancestor
-- chain redeclares a nested control `within <literal-name>`, so the same
-- literal name is the right scope at every level, still within the SAME
-- window's own declaration space); (2) only if that fails, switching BOTH
-- root and owner to the fully-resolved ancestor type (the "has-a"
-- convention -- an embedded instance of a *different* class has its own
-- children declared `within <ClassName>` in that class's own file, never
-- under the instance name its container gave it -- e.g. uo_epidom's `.dw`
-- control is declared `within uo_misth_fylo_epidom_grid`, not `within
-- uo_epidom`, in uo_misth_fylo_epidom_grid's OWN separate file).
-- resolveMemberChainType returns the fully-unwound terminal's cdAncestorType
-- (the true base type). resolveMemberChainDwBinding does NOT use the same
-- full-unwind value for the binding -- it returns the CLOSEST override's
-- cdDwBinding found while unwinding (first Just wins, closest to furthest),
-- since a more-derived override's own literal dataobject must win over
-- whatever a generic ancestor declares (or, commonly, doesn't declare)
-- further up -- confirmed against real data: uo_misth_fylo_epidom_grid's own
-- `dw` control sets dataobject="dw_misth_fylo_epidom_list", but its D1
-- override target (u_grid's own `dw`, `from datawindow`) sets none at all;
-- a naive full-unwind-for-everything design would have returned Nothing for
-- exactly the case this module exists to resolve (Plan 163 Phase 3's
-- "openpay 0/6" SetItem gap). Both Nothing when any hop is unresolvable --
-- no guessing past what the workspace actually declares.
-- Verified end-to-end against the real fylo.pbl/w_misth_fylo_form.srw +
-- afxlib.pbl/w_form_tab2.srw + fylo.pbl/uo_misth_fylo_epidom_grid.sru +
-- afxlib.pbl/u_grid.sru fixture (openpay corpus): tab1.page1.uo_epidom.dw
-- from w_misth_fylo_form resolves to type "datawindow" / binding
-- "dw_misth_fylo_epidom_list". Wired into production since Phase C; full
-- workspace-scale correctness confirmed by Phase E (real --db ingestion:
-- openpay cat_footprint_columns 0->2 for w_misth_fylo_form, PowerBuilder-
-- Example stayed at 5, no regression).
```

### `PB.Analysis.Builtins`

```haskell
-- PB built-in function/method name sets for call classification (Plan 109b).
builtinFnNames     :: Set Text     -- free functions (used by resolveCalls)
builtinMethodNames :: Set Text     -- class methods
```

### `PB.Analysis.SchemaCategory` (Plan 148 Phase 1b/2, 2026-07-07)

```haskell
-- Pure. The DB schema as a free category (Sch). Objects are (table,column)
-- pairs and SQL-statement/DW-retrieve instances; morphisms are the "legs" a
-- statement has into columns it reads/writes, plus FK morphisms from DW
-- JOIN blocks and DDL foreign keys. Span encoding of a hyperedge -- see
-- doc/plan/148-db-schema-category.md "Design" section for the rationale.
-- Reuses TableRef from PB.Pipeline.SqlParse (does not redefine it).
data StmtId = SqlStmtId { siFile, siObject, siProc :: Text, siLine :: Int }
            | DwRetrieveId { siFile, siDwName :: Text }
data SchObject = ColumnObj TableRef Text | StmtObj StmtId
data LegKind   = LegReads | LegWrites | LegRetrieve | LegFk
-- LegSource (Plan 163 Phase 4, D3, 2026-07-10): supersedes the old FkSource
-- type (FkDdl | FkDwJoin, a second field meaningful only on LegFk rows) --
-- every SchMorphism now carries provenance, tagging which analysis
-- technique found it. Orthogonal to StmtId's front-end tag (DW/PS/future
-- PL/SQL) and to LegKind (the leg's direction/role).
data LegSource = SrcSqlText | SrcCatFootprint | SrcDwRetrieve
               | SrcDwJoin | SrcDwWhere | SrcDdlFk
renderLegSource :: LegSource -> Text
-- SrcSqlText->"sql_text", SrcCatFootprint->"cat_footprint",
-- SrcDwRetrieve->"dw_retrieve", SrcDwJoin->"dw_join",
-- SrcDwWhere->"dw_where", SrcDdlFk->"ddl_fk"
data SchMorphism = SchMorphism { legFrom, legTo :: SchObject, legKind :: LegKind, legSource :: LegSource }
data SchGraph  = SchGraph { sgObjects :: Set.Set SchObject, sgLegs :: [SchMorphism]
                          , sgOut, sgIn :: Map.Map SchObject [SchMorphism] }
schObjectKey :: SchObject -> Text   -- canonical DB key (object_key/from_key/to_key)

splitColumnRef :: Text -> Maybe (TableRef, Text)
-- Last-dot split (namespace.table.column), lowercased. Nothing for
-- unqualified text or a malformed ref (trailing dot etc).

-- SchemaInputs' first five fields are Analysis-owned "read-shape" row types
-- -- distinct from (but same-shaped as) PB.Pipeline.DuckDb's write-side row
-- types (DwJoinRow/SqlStmtColumnRow/CatalogColumnRow/CatalogFkRow), same
-- split as TypeResolve.ResolvedCall (write) vs. Taint.ResolvedCallRow
-- (read) for resolved_calls. Keeps PB.Analysis.* free of any
-- PB.Pipeline.DuckDb/duckdb-ffi dependency. DuckDb.hs's
-- queryDwRetrieveColumns/queryDwJoinLegs/querySqlCols/queryCatColumns/
-- queryCatFks return these types directly (new FromRow orphan instances).
data DwRetrieveColRow = DwRetrieveColRow { drcFile, drcDwName :: Text, drcNamespace :: Maybe Text, drcTable, drcColumn :: Text }
data DwJoinLegRow     = DwJoinLegRow { djlFile, djlDwName, djlLeftRef, djlRightRef :: Text }
data SqlColRow        = SqlColRow { scStmt :: StmtId, scNamespace :: Maybe Text, scTable :: Maybe Text, scColumn :: Text, scIsWrite :: Bool }
-- scTable = Nothing for an ambiguous unqualified column (old-style implicit
-- join, no catalog to resolve against) -- buildSchema skips these rows
-- rather than guessing; they produce no ColumnObj/leg.
data CatColumnRow = CatColumnRow { cclNamespace :: Maybe Text, cclTable, cclColumn :: Text }
data CatFkRow     = CatFkRow { cfrFromNamespace :: Maybe Text, cfrFromTable, cfrFromColumn :: Text
                              , cfrToNamespace :: Maybe Text, cfrToTable, cfrToColumn :: Text }
data SchemaInputs = SchemaInputs { inDwRetrieveColumns :: [DwRetrieveColRow], inDwJoins :: [DwJoinLegRow]
                                  , inDwWriteColumns :: [DwRetrieveColRow], inDwWhereColumns :: [DwRetrieveColRow]
                                  , inSqlColumns :: [SqlColRow], inCatFootprintColumns :: [SqlColRow]
                                  , inCatalogColumns :: [CatColumnRow]
                                  , inCatalogFks :: [CatFkRow], inDefaultNamespace :: Maybe Text }
-- inCatFootprintColumns (Plan 163 Phase 3, 2026-07-10): same SqlColRow shape
-- and resolve treatment as inSqlColumns, sourced from
-- PB.Analysis.SchFootprint.foldSchFootprint (dynamic-dispatch writes, e.g. a
-- DataWindow SetItem call) instead of sqlglot text extraction. Kept as its
-- own field (not merged into inSqlColumns) so each row's producing
-- technique stays distinguishable for a future leg_source column (Phase 4).
-- buildSchema folds it through the same mkSqlLegs helper inSqlColumns uses.
--
-- inDwWriteColumns/inDwWhereColumns (Plan 163 Phase 6, 2026-07-10): wires
-- PB.Analysis.DwFootprint.dwRetrieveFootprint's LegWrites/LegReads legs
-- (DW update-table columns / catalog-gated WHERE-operand columns) into
-- production -- same DwRetrieveColRow shape as inDwRetrieveColumns, reusing
-- its existing FromRow instance (dw_write_columns/dw_where_columns are new
-- DuckDb tables, same 5-column shape as dw_retrieve_columns). buildSchema's
-- dwWriteLegs/dwWhereLegs comprehensions mirror dwRetrieveLegs exactly
-- (StmtObj (DwRetrieveId ..) <-> ColumnObj), just LegWrites/SrcDwRetrieve
-- and LegReads/SrcDwWhere respectively instead of LegRetrieve/SrcDwRetrieve.
-- Real-corpus-verified: 559 write legs, 175 WHERE-read legs (openpay),
-- exact match to Phase 2's own predicted counts. dwRetrieveFootprint's
-- LegRetrieve/LegFk legs are NOT also fed through these fields -- Runner.hs's
-- compileOne keeps only LegWrites/LegReads from its dwRetrieveFootprint
-- call, since inDwRetrieveColumns/inDwJoins already cover retrieve/FK.
--
-- IMPORTANT (found wiring this in, not anticipated by the plan): DW-sourced
-- writes are deliberately EXCLUDED from cli's get_co_update_rituals/
-- get_decomposition_candidates ritual-evidence query (`_CO_WRITE_SQL` filters
-- `leg_source != 'dw_retrieve'`) even though they're fully present in
-- schema_morphisms/get_footprint/get_column_usage. A DW's update=yes column
-- set is a *design-time* "this form treats these columns as one editable
-- unit" fact -- PowerBuilder's generated Update() rewrites the whole SET
-- clause from the buffer every save, regardless of which field the user
-- touched, so it can't attest "these changed together in this save" the way
-- a PS write does. Blending the two into one co_write_support number
-- inflated this corpus's ritual count 45->1685 and its (previously zero,
-- genuinely verified) violation count 0->1092 -- see doc/plan/163-unified-
-- statement-footprint.md's Open Question #5 for the full rationale, and
-- its still-open follow-on: report DW-column-grouping as its own,
-- lower-confidence evidence type rather than only omitting it.
buildSchema :: SchemaInputs -> SchGraph   -- total, pure
-- Catalog-only columns (no statement/JOIN touches them) still become
-- objects with no legs -- a free normalization signal (dead-column
-- candidates); see done-condition verification below for real counts.
-- inDefaultNamespace (Plan 157 Phase 1, 2026-07-09): a local unexported
-- resolveTableRef helper resolves a Nothing-namespace TableRef (built at
-- the sqlLegs/dwRetrieveLegs/dwJoinLegs construction sites) to
-- TableRef (Just ns) tbl iff inCatalogColumns actually defines (ns, tbl)
-- -- never guessed; already-qualified refs and DDL-sourced legs
-- (ddlFkLegs, catalogOnlyObjects) are untouched. This is what unifies an
-- unqualified SQL/DW-retrieve column with the catalog's schema-qualified
-- ColumnObj for the same physical table (the root cause behind an
-- empty-looking column-affinity/decomposition/FK-graph query for any
-- table whose real touches are all unqualified -- see BACKLOG/doc/plan/
-- 157-default-namespace.md).
```

### `PB.Analysis.SchFootprint` (Plan 148 Phase 3, done 2026-07-07)

```haskell
-- Pure. The functor F : CatOp -> Sch_|_ (design doc's "(a) Categorical
-- structure" amendment), implemented as a second instance of CatOp.hs's
-- Category/Cartesian/Cocartesian/Effectful classes rather than a
-- hand-written match -- foldCat folds any compiled CatOp term into it.
data FunctorCtx = FunctorCtx
  { fcStmtObj         :: StmtId                              -- CatOp carries no line info; any edge is procedure-granularity
  , fcTypeEnv         :: ScopedTypeEnv
  , fcDwColumns       :: Map.Map Text [(TableRef, Text)]      -- DW object name -> (table,col) targets, lowercased key
  , fcControlBindings :: Map.Map (Text, Text) Text            -- (object, control) -> dw name, all lowercased
  }
controlBindingsMap :: [DwControlBinding] -> Map.Map (Text, Text) Text  -- from TypeResolve.extractDwControlBindings
dwColumnsFromRows  :: [DwRetrieveColRow] -> Map.Map Text [(TableRef, Text)]  -- from dw_retrieve_columns rows
newtype SchFootprint a b = SchFootprint { runSchFootprint :: FunctorCtx -> Set.Set SchMorphism }
-- Elliott's "compiling to categories" constant-annotation category: erases
-- a/b entirely. id/exl/exr/inl/inr = const Set.empty; (.)/(&&&)/(|||) = 
-- pointwise union. loopK propagates the loop body's own footprint (not a
-- constant empty one) -- a static, iteration-count-oblivious analysis must
-- still count whatever the body touches.
--
-- callProc recognizes a "<ctrl>.SetItem(row, <literal col>, value)" call
-- (name ending ".setitem", case-insensitive) and resolves it via
-- fcControlBindings then fcDwColumns to a real LegWrites SchMorphism; any
-- lookup miss (unbound control, dynamic column arg, unknown column) is
-- Set.empty, no guessing. Deliberately hooks callProc, not suspend:
-- SetItem is not (and should not become) a suspending call -- unlike
-- Retrieve/Open/Close it's a synchronous in-process buffer write, and
-- 'suspend'/CatSuspend is the mechanism the interpreter/UI runtime use to
-- mean "must await an external response". SetItem already compiles to
-- CatCall (PB.Analysis.CallClassify.dwMethods omits "setitem"), so this
-- needed zero changes to CallClassify. suspend and the ExHostVar case
-- remain unimplemented -- not needed; callProc alone reaches Phase 3's
-- done-condition against a real corpus example (verified: w_dw_copy.srw's
-- `dw_dest.SetItem(ll_Cnt, "id", li_Data)`, value flowing through
-- li_Data <- dw_source.GetItemNumber(...), resolves to a LegWrites edge on
-- sales_order_items.id via dw_dest's static `DataObject="d_items"` binding
-- and d_items.srd's real retrieve columns -- an edge Phase 1's BsRaw/SQL-
-- text extraction cannot see since there is no SQL statement in this
-- procedure at all).
foldSchFootprint :: FunctorCtx -> CatOp a b -> Set.Set SchMorphism
-- No longer the production entry point (Plan 167 Phase 7 Step 6 switched
-- Runner.hs's compileOne to foldSchFootprintEff below) -- kept as a
-- test/cross-check oracle. foldSchFootprintEff :: FunctorCtx -> EffTerm a b
-- -> Set.Set SchMorphism -- THE PRODUCTION ENTRY POINT since Step 6. A
-- clause-for-clause transliteration of foldSchFootprint's force-time-
-- memoized `go` onto Eff's GADT (J _ covers every embedded Pure morphism,
-- all constant-empty; EBranch/EFanIn both union their two arms; ELetRef
-- resolves against EffTerm's table, memoized on blockId exactly like
-- CatTagged). Corpus-wide-verified against foldSchFootprint with zero
-- mismatches (422 openpay + 621 PowerBuilder-Example real files, temporary
-- side-by-side comparison in compileOne, reverted after the run).
foldSchFootprintEff :: FunctorCtx -> EffTerm a b -> Set.Set SchMorphism

-- runtimeDwAliasBindings (Plan 164 Phase C / D3, done 2026-07-10): the
-- second, dynamic source Runner.hs's compileOne merges into
-- fcControlBindings alongside controlBindingsMap's static one. Scans a
-- procedure body for BsAssign lhs rhs where lhs is a bare
-- datawindow/datastore-typed instance-or-local var (checked via
-- lookupScopedVar) and rhs is a multi-segment member-chain lvalue (e.g.
-- idw_epidom = tab1.page1.uo_epidom.dw); resolves rhs via
-- PB.Analysis.ControlHierarchy.resolveMemberChainDwBinding. BsAssignExpr is
-- not scanned -- classifyBodyStmt only emits it when the LHS does NOT parse
-- as a plain Lvalue, which a bare instance var always does. Recurses into
-- if/for/do/choose (mirrors Taint.extractSqlStmts); any lookup miss
-- contributes nothing, no guessing. Real-corpus-verified (unit test, not
-- just synthetic): w_misth_fylo_form.srw's of_open assigns the alias,
-- if_kodfylo_changed calls SetItem on it -- two DIFFERENT procedures, which
-- is why compileOne aggregates this file-wide (Map.unions over every
-- procedure's own runtimeDwAliasBindings call, each with steLocal seeded
-- via CallClassify.collectBodyLocals), not per-procedure.
--
-- FIXED (Plan 164 Phase E, done 2026-07-10 -- was a KNOWN LIMITATION found
-- via this same real-corpus verification): ControlHierarchy's ControlIndex
-- used to key on (owner, name) using only the immediate tdWithin name,
-- which collided across unrelated windows reusing a common generic
-- child-control name (e.g. "page1" within "tab1", declared by 11 different
-- windows in the openpay corpus) -- confirmed via cabal repl over the full
-- 422-file corpus to make the workspace-wide resolveMemberChainDwBinding
-- call above land on a real-but-wrong DW name for w_misth_fylo_form's own
-- chain in production (the isolated 4-file fixture this module's own test
-- uses resolved correctly even before the fix -- the collision only
-- manifested at full-corpus scale). Phase E qualified ControlIndex's key
-- to (root, owner, name), root = the declaring file's own top-level object
-- -- see PB.Analysis.ControlHierarchy's own entry above for the full
-- design. Confirmed via real --db ingestion: openpay's
-- cat_footprint_columns now reaches 2/2 rows for w_misth_fylo_form.
runtimeDwAliasBindings
  :: ControlIndex -> Map.Map Text Text -> Text -> ScopedTypeEnv
  -> [Located BodyStmt] -> Map.Map (Text, Text) Text
```

### `PB.Analysis.DwFootprint` (Plan 163 Phase 2, done 2026-07-10; wired into production Phase 6, 2026-07-10)

```haskell
-- Pure. The "Fdw" half of Plan 163's cospan (schema <- statement, tagged by
-- front-end), sibling to PB.Analysis.SchFootprint's "Fps" functor. Unlike
-- SchFootprint (folds a compiled CatOp term), a DW retrieve has no control
-- flow -- this is a total walk over the already-parsed DwTable/DwRetrieve
-- record straight into the same Set SchMorphism codomain. Deliberately
-- reproduces all four leg categories (column list, update-table, WHERE,
-- joins) directly from the AST -- overlaps with PB.Analysis.SchemaCategory
-- .buildSchema's existing row-based dwRetrieveLegs/dwJoinLegs producers on
-- purpose. Real openpay-corpus row-count diff (134 real .srd files, real
-- catalog_columns): LegRetrieve 863 -> 863 (exact match, corroborates the
-- row-based producer), LegFk FkDwJoin 52 distinct edges both ways (192 raw
-- rows in schema_morphisms is the same 52 edges un-deduped -- sgLegs is a
-- list, not a Set), LegWrites 0 -> 559 (new), LegReads/WHERE 0 -> 175 (new,
-- DDL-catalog-gated). See doc/plan/163-unified-statement-footprint.md
-- Phase 2 for the full diff table.
--
-- Phase 6 wiring (2026-07-10): PB.Pipeline.Runner's compileOne PsDw branch
-- now calls dwRetrieveFootprint for real and keeps only its LegWrites/
-- LegReads legs (LegRetrieve/LegFk are dropped at that call site --
-- inDwRetrieveColumns/inDwJoins already persist those, via the pre-existing
-- row-based producers this module's own LegRetrieve/LegFk output is
-- reconciled against above -- keeping both would double-count in
-- schema_morphisms). See PB.Analysis.SchemaCategory's SchemaInputs entry
-- for the inDwWriteColumns/inDwWhereColumns fields this feeds, and its own
-- note on why cli's get_co_update_rituals deliberately excludes these
-- writes from ritual/violation detection.
data DwFootprintCtx = DwFootprintCtx
  { dfcCatalogTables    :: Set.Set (Text, Text)             -- (namespace, table) DDL defines -- feeds resolveTableRef
  , dfcCatalogColumns   :: Set.Set (Maybe Text, Text, Text)  -- (namespace, table, column) DDL defines -- WHERE-leg gate only
  , dfcDefaultNamespace :: Maybe Text
  }
mkDwFootprintCtx :: [CatColumnRow] -> Maybe Text -> DwFootprintCtx  -- from the same catalog_columns rows buildSchema consumes
-- Recognizes a plain, unsubscripted 2- or 3-segment dotted ExLvalue
-- (table.column / namespace.table.column) as a column ref; any other shape
-- (subscript, 1 or 4+ segments, ExHostVar, literals, calls) -> Nothing.
-- Segment names lowercased, mirrors SchemaCategory.splitColumnRef.
lvalueColumnRef :: Expr -> Maybe (TableRef, Text)
-- file, dwName, the DwTable (not just DwRetrieve -- dtColumns/dtUpdate live
-- there, sibling to dtRetrieve). WHERE-derived LegReads legs are the only
-- catalog-gated category (via dfcCatalogColumns) -- LegRetrieve/LegWrites/
-- LegFk are never catalog-checked, matching buildSchema's existing column/
-- join producers, which don't check catalog membership either.
dwRetrieveFootprint :: DwFootprintCtx -> Text -> Text -> DwTable -> Set.Set SchMorphism
```

### `PB.Pipeline.FileWalk`

```haskell
walkFiles      :: (FilePath -> Bool) -> FilePath -> IO [FilePath]   -- [] if root missing
walkPsFiles    :: FilePath -> IO [FilePath]   -- .srf .srw .sru .srm .sra .srx
walkDwFiles    :: FilePath -> IO [FilePath]   -- .srd
walkAllSrFiles :: FilePath -> IO [FilePath]   -- any .sr<single-char>
```

### `PB.Pipeline.DuckDb`

```haskell
-- DuckDB-direct I/O for pbc --db mode. C FFI to libduckdb.dylib via duckdb-ffi.
-- Single-writer constraint: DuckConn is NOT thread-safe for concurrent appenders;
-- runModeDb uses MVar mutex (bridge path) or sequential mapM_ (no-bridge path).
-- Phase A appenders (Plan 169: pooled, create once after initSchema, destroy at
-- Phase A/B boundary — avoids ~13K create/flush/destroy FFI cycles per corpus):
newtype AppenderPool = AppenderPool (Map.Map Text DuckDBAppender)
withAppenderPool :: DuckConn -> [Text] -> (AppenderPool -> IO a) -> IO a
appendRow :: AppenderPool -> Text -> (DuckDBAppender -> IO ()) -> IO ()
-- Phase A appenders all take AppenderPool (not DuckConn):
appendObjects, appendProcedures, appendDwObjects, appendDwControls :: AppenderPool -> [row] -> IO ()
appendLocalVars, appendCallSites, appendGlobalVars :: AppenderPool -> [row] -> IO ()
appendProcDefs, appendProcUses, appendSqlStmts :: AppenderPool -> [row] -> IO ()
appendSqlStmtColumns, appendSqlStmtFilters :: AppenderPool -> [row] -> IO ()
-- cat_footprint_columns (Plan 163 Phase 3, 2026-07-10): identical shape to
-- sql_statement_columns, populated by PB.Analysis.SchFootprint.foldSchFootprint
-- (currently: DataWindow SetItem calls with a literal column + a statically-
-- resolvable control binding) instead of sqlglot text extraction. Kept as
-- its own table (not merged into sql_statement_columns) for future
-- leg_source provenance tagging. Reuses SqlStmtColumnRow on the append side.
appendCatFootprintColumns :: AppenderPool -> [SqlStmtColumnRow] -> IO ()
-- catalog_columns/catalog_pks/catalog_fks (Plan 148 Phase 1a-3, 2026-07-07):
-- static DDL catalog, row-oriented (namespace/table_name/column_name/ordinal
-- for columns+pks; +constraint_name/from_*/to_* for fks, one row per
-- from/to column pair for composite FKs). Populated once per DDL file (Oracle
-- hardening 2026-07-08: now once per --ddl arg, not once per run -- multiple
-- schema-tagged dumps each get their own parseDdl call) from
-- PB.Pipeline.Runner.catalogToRows, itself fed by PB.Pipeline.SqlParse.parseDdl.
appendCatalogColumns, appendCatalogPks, appendCatalogFks :: AppenderPool -> [row] -> IO ()
-- catalog_checks (2026-07-08): (constraint_name, namespace, table_name,
-- predicate) -- named CHECK constraints, sqlglot's normalized-SQL predicate
-- text (not a re-parsed expression AST; see SqlParse's CatalogCheckConstraint
-- doc comment for why). Fed by the same per-DDL-file catalogToRows call.
appendCatalogChecks :: AppenderPool -> [CatalogCheckRow] -> IO ()
appendParseErrors :: AppenderPool -> [row] -> IO ()
-- dw_retrieve_columns (Plan 148 Phase 1b, 2026-07-07): (file, dw_name,
-- namespace, table_name, column_name), one row per qualified DwRetrieve
-- column ref (splitColumnRef'd from drColumns in Runner.hs's PsDw branch --
-- fills the "drColumns never reaches DuckDB" survey gap).
appendDwRetrieveColumns :: AppenderPool -> [DwRetrieveColumnRow] -> IO ()
-- dw_write_columns/dw_where_columns (Plan 163 Phase 6, 2026-07-10): same
-- 5-column shape as dw_retrieve_columns, populated from Runner.hs's
-- compileOne PsDw branch (dwRetrieveFootprint's LegWrites/LegReads legs).
appendDwWriteColumns, appendDwWhereColumns :: AppenderPool -> [DwRetrieveColumnRow] -> IO ()
-- dw_retrieve_where (Track SCHEMA-BUGS, 2026-07-09): (file, dw_name, idx,
-- exp1, op, exp2, logic) -- one row per DwWhereClause in a DwRetrieve's
-- drWhere, idx preserves clause order (zip [0..] at the Runner.hs
-- construction site). Mirrors dw_joins's shape exactly. Restores a feature
-- that datawindows.py/tables.py already queried (exception-guarded, so it
-- silently returned [] rather than erroring) but the table never existed in
-- initSchema -- found incidentally during Plan 157 Phase 4.5.
appendDwRetrieveWhere :: AppenderPool -> [DwRetrieveWhereRow] -> IO ()
-- Phase B read helpers (SELECT → typed rows):
queryLocalVars, queryCallSites, queryGlobalVars :: DuckConn -> IO [row]
queryObjInfo     :: DuckConn -> IO [(Text, Text)]       -- (file, object) pairs per PS file
queryProcDefs    :: DuckConn -> IO [Taint.DefRow]
queryProcUses    :: DuckConn -> IO [Taint.UseRow]
queryResolvedCalls :: DuckConn -> IO [Taint.ResolvedCallRow]
queryTaintInputs :: DuckConn -> IO [Taint.TaintFileInputs]  -- includes procedure-less PS objects via objects table
queryProcInfos   :: DuckConn -> IO [DeadCode.ProcInfo]
-- Filters `confidence != 'speculative'` (excludes synthetic builtin-class
-- method stubs). Feeds Pass 8's overrideEdges computation and
-- PB.Pipeline.Souffle's proc/entry/calls EDB views apply the same filter.
-- queryDwObjectSet is GONE (Plan 161 Phase 2b cutover, 2026-07-11):
-- DW-object seeding for dead-code reachability moved entirely into
-- Souffle's `entry` EDB view (SQL JOIN against dw_objects); no Haskell
-- consumer of the raw DW-object set remained once that happened.
queryProcDead :: DuckConn -> IO (Set (Text, Text))
-- Plan 161 Phase 2b cutover: reads back proc_dead (Souffle.deadReachRules'
-- materialized output) so runPass8 can pass it into
-- DeadCode.classifyDeadProcedures instead of computing the dead set in
-- Haskell.
-- SchemaCategory read-side queries (Plan 148 Phase 1b, 2026-07-07): return
-- PB.Analysis.SchemaCategory's own read-shape types directly (new FromRow
-- orphan instances here), consumed by Passes.hs's runPass9.
queryDwRetrieveColumns :: DuckConn -> IO [SchemaCategory.DwRetrieveColRow]
-- queryDwWriteColumns/queryDwWhereColumns (Plan 163 Phase 6): same query
-- shape as queryDwRetrieveColumns, reading dw_write_columns/dw_where_columns.
queryDwWriteColumns, queryDwWhereColumns :: DuckConn -> IO [SchemaCategory.DwRetrieveColRow]
queryDwJoinLegs        :: DuckConn -> IO [SchemaCategory.DwJoinLegRow]
querySqlCols           :: DuckConn -> IO [SchemaCategory.SqlColRow]
-- queryCatFootprintColumns (Plan 163 Phase 3): same shape/query as
-- querySqlCols, reading cat_footprint_columns instead -- the existing
-- FromRow SqlColRow instance is reused verbatim, no new instance needed.
queryCatFootprintColumns :: DuckConn -> IO [SchemaCategory.SqlColRow]
queryCatColumns        :: DuckConn -> IO [SchemaCategory.CatColumnRow]
queryCatFks            :: DuckConn -> IO [SchemaCategory.CatFkRow]
-- Phase B write appenders:
appendResolvedTypes, appendResolvedCalls :: DuckConn -> [row] -> IO ()
appendInterprocEdges, appendProcSummaries :: DuckConn -> [row] -> IO ()
appendTaintSources, appendTaintSinks, appendTaintPaths, appendTaintAnnotations :: DuckConn -> [row] -> IO ()
appendDeadCode   :: DuckConn -> [DeadCode.DeadProcedure] -> IO ()
-- procedure_overrides (Plan 161 Phase 2b, 2026-07-11): (child_object,
-- method, parent_object) rows from DeadCode.computeOverrideEdges, read
-- back by Souffle's `overrides` EDB view (initDeadReachEdbViews). Written
-- by runPass8 before deadReachRules runs.
appendProcedureOverrides :: DuckConn -> [(Text, Text, Text)] -> IO ()
-- schema_objects/schema_morphisms (Plan 148 Phase 1b, 2026-07-07): written
-- by runPass9 from SchemaCategory.buildSchema's SchGraph. object_key/
-- from_key/to_key columns hold SchemaCategory.schObjectKey's canonical
-- string form. schema_morphisms' leg_source column (Plan 163 Phase 4,
-- 2026-07-10; was fk_source, FK-only) holds renderLegSource (legSource m)
-- for every row -- see SchemaCategory's LegSource entry above.
appendSchemaObjects   :: DuckConn -> [SchemaCategory.SchObject]   -> IO ()
appendSchemaMorphisms :: DuckConn -> [SchemaCategory.SchMorphism] -> IO ()
-- decomposition_coslice (Plan 153 D5, 2026-07-07): written by runPass10,
-- decomposition_coslice (Plan 161 Phase 2c): materialized from the Souffle
-- path_leg_fwd/path_leg_back tables via materializeDecompositionCoslice.
-- Tie-break via ROW_NUMBER, leg_source joined from schema_morphisms,
-- StmtObj-only target filter. Python's get_decomposition_candidates (cli/api)
-- is the sole reader.
materializeDecompositionCoslice :: DuckConn -> IO ()
-- Generic EDB/IDB bridge (Plan 161, Souffle migration, 2026-07-11):
-- PB.Pipeline.Souffle needs to read/write relations whose column count is a
-- runtime value (Relation's relCols), not fixed by a Haskell type -- no
-- per-relation FromRow/appender pair is possible, so these three are the
-- dynamic-arity counterparts of the typed query/appender pairs above.
-- Every value round-trips as TEXT (every EDB relation currently fed through
-- -- keys, kinds, names -- is already string-shaped; a numeric column like
-- stmt's line is CAST to VARCHAR at read time since no rule inspects it
-- other than by equality/wildcard).
queryTextRows     :: DuckConn -> Text -> [Text] -> IO [[Text]]
-- table/view name, column names -> rows, in that column order, each value
-- CAST(... AS VARCHAR) at the SQL level (works regardless of underlying
-- column type). Backed by an internal, unexported `newtype TextRow = TextRow
-- [Text]` FromRow instance built on numFieldsRemaining/field (loops until no
-- fields remain, rather than a fixed-arity tuple instance).
recreateTextTable :: DuckConn -> Text -> [Text] -> IO ()
-- DROP TABLE IF EXISTS + CREATE TABLE with the given column names, all TEXT
-- -- the write-side counterpart of queryTextRows.
appendTextRows    :: DuckConn -> Text -> [[Text]] -> IO ()
-- Generic-arity appender (reuses the existing withRaw/aText/endRow
-- machinery) -- no per-arity ToRow instance needed.
-- Schema init:
withWriteConn    :: FilePath -> (DuckConn -> IO a) -> IO a
initSchema       :: DuckConn -> IO ()
```
