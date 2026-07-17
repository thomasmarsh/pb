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

**`doc/pb2025r2/` is a full local mirror of the official Appeon PowerBuilder 2025 R2 help docs** (`objects_and_controls/`, `datawindow_reference/`, `powerscript_reference/`, `datawindow_programmers_guide/`, etc. — one subdirectory per manual). `grep -rn` it directly for any question about builtin system-class hierarchy, control/DW properties-events-functions, or PowerScript syntax before searching the web — it's faster and it's the authoritative source `doc/spec.md` itself is amended against. Individual per-function reference pages often state their inheritance directly (e.g. a DataWindow function's own page saying "Inherited from DragObject"), which is more reliable than the hierarchy diagrams in `objects_and_controls/`, several of which are images, not extractable text.

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
| `PB.Analysis.*` | Pure analysis passes: Cfg, Dataflow, Taint, TypeEnv, TypeResolve, Builtins, SchemaCategory, SchFootprint, DwFootprint, ControlHierarchy. `PB.Analysis.Rules.*` holds the Soufflé rule sets + typed EDB-reshaping readers (DeadCode, Taint, Schema) |
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
   identically-shaped sources) — it's a typed `PB.Analysis.Rules.*` Haskell
   function, materialized into a plain DuckDB table via
   `recreateTextTable`/`appendTextRows` (amended 2026-07-15 per Plan 175,
   backed by that plan's Phase 1 real-corpus gate; this destination used to
   be "an EDB view" — a `CREATE VIEW` string — before that evidence landed).
   `PB.Analysis.Rules.Schema`'s `legSourceRows`/`stmtRows`/`seedRows` (feeding
   `querySchemaObjects`/`querySchemaMorphismRows`), `PB.Analysis.Rules.DeadCode`'s
   `procRows`/`procMetaRows`/`inheritsRows`/`callRefRows`/`resolvedCallEdgeRows`/
   `entryRows`/`callsRows`, and `PB.Analysis.Rules.Taint`'s
   `taintEdgeIntraRows`/`taintEdgeArgRows`/`taintEdgeGlobalRows`/
   `taintEdgeReturnRows`/`taintKeyRows` are the reference pattern. Every
   `initXEdbViews` in `PB.Analysis.Rules.*` is now a typed Haskell
   materializer — no `CREATE VIEW` SQL remains in this layer; do not write
   a _new_ `CREATE VIEW` for rule-3-shaped logic anywhere in the codebase
   going forward.

**House rule: EDB reshaping logic may not decide anything.** A typed
`PB.Analysis.Rules.*` reshaping function (or a not-yet-migrated legacy
`CREATE VIEW` in `initXEdbViews`, or a materializer's `INSERT ... SELECT`)
may only rename, cast, or filter by a static/structural predicate. If the
logic needs a `CASE`/branch, `ROW_NUMBER`/any window function, or a
`GROUP BY`/aggregate to produce its answer, that is a decision (question 2's
territory — a tie-break, a label, a count) and does not belong here. Move it
into a Datalog rule (`choice-domain` for tie-breaks, rule specialization for
labels, Souffle's own `count :` aggregate). This rule exists because every
real bug found in the Datalog substrate to date — `leg`'s writes-vs-retrieve
tie-break, `decomposition_coslice`'s direction-interleaved ordinals,
`taint_paths`' `step_kind` mislabeling of 0-hop paths — lived in exactly
this kind of logic, caught only by real-corpus/real-UI spot checks, never by
a test that ran before the fact. See
`doc/plan/171-datalog-decision-migration.md` for the concrete migration of
the two still-open instances.

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

### `PB.AST.Ident` (Plan 178 Phase 1, 2026-07-16)

```haskell
-- A PB identifier: originally-declared casing + canonicalized (lowercase)
-- form. Eq/Ord compare only identCanon; ToJSON renders identOrig only (wire
-- format unchanged from the plain-Text fields it replaces). IsString via
-- mkIdent, so OverloadedStrings literals ("w_main" :: Ident) work.
data Ident = Ident { identOrig :: Text, identCanon :: Text }
mkIdent :: Text -> Ident

-- Canonical-keyed set recovering original casing on lookup -- replaces the
-- Set.toList+T.toLower linear-scan shape PB.Analysis.TypeCheck's
-- findOriginalCase used to hand-roll.
newtype IdentSet = IdentSet (Map.Map Text Ident)   -- constructor not exported
identSetEmpty     :: IdentSet
identSetSingleton :: Ident -> IdentSet
identSetFromList  :: [Ident] -> IdentSet
identSetMember    :: Ident -> IdentSet -> Bool
identSetLookup    :: Ident -> IdentSet -> Maybe Ident
identSetToList    :: IdentSet -> [Ident]
identSetOrigTexts :: IdentSet -> Set.Set Text
-- ^ Bridge to legacy Set.Set Text consumers not yet migrated to Ident
-- (e.g. PB.Analysis.TypeMismatch.classifyFamily) -- reconstructs the same
-- originally-declared spellings an IdentSet recovers on lookup.
```

`TypeDecl.tdName` (Phase 1), `LvSegment.name` (Phase 2, `PB.AST.Expr`),
`TypeDecl.tdAncestorClass`/`tdAncestorOverride` (Phase 3), `VarDecl.vdName`/
`GlobalInstance.giName` (Phase 4), and `FnSig.fnsName`/`SubSig.ssName`/
`EventSig.esName` (Phase 5) are `Ident`. `TypeMismatch.classifyFamily`'s
`Set Text` interface is the sole remaining deferred item — see
`doc/plan/178-canonical-identifier.md`'s "Deferred scope" section.
`TypeDecl.tdAncestor` stays `Text` deliberately (raw
`AncestorClass\`LocalName` backtick-compound syntax, not a single identifier
— `splitAncestorRef` parses it further, minted once into
`tdAncestorClass`/`tdAncestorOverride` by `mkTypeDecl` at construction; see
`PB.AST.SourceFile`'s own entry below).

### `PB.AST.Expr`

```haskell
-- Field names are unprefixed (record-dot disambiguation under
-- DuplicateRecordFields). Token lists are [Text], NOT [Token]. name's
-- derived Eq is case-insensitive (Ident's own Eq, Plan 178 Phase 2) --
-- propagates to Lvalue's and Expr's own derived Eq for free.
data LvSegment = LvSegment { name :: Ident, subscript :: Maybe [Text] }
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

data TypeDecl = TypeDecl
  { tdName             :: Ident
  , tdAncestor         :: Text          -- raw compound syntax, verbatim (backtick-compound, see PB.AST.Ident's entry above)
  , tdAncestorClass    :: Ident         -- splitAncestorRef's 1st component, minted once by mkTypeDecl (Plan 178 Phase 3)
  , tdAncestorOverride :: Maybe Ident   -- splitAncestorRef's 2nd component, minted once by mkTypeDecl (Plan 178 Phase 3)
  , tdWithin           :: Maybe Text
  }
mkTypeDecl :: Text -> Text -> Maybe Text -> TypeDecl
-- name -> ancestor -> within -> TypeDecl. Sole way to construct a TypeDecl
-- (PB.Grammar.File.extractTypeDecl and every test fixture use it) -- mints
-- tdName via mkIdent and the ancestor split via splitAncestorRef once here,
-- so no consumer re-derives either independently.
data TypeBlock = TypeBlock { tbDecl :: TypeDecl, tbBody :: [Located BodyStmt] }
data VarDecl   = VarDecl  { vdModifiers :: [Text], vdType :: Text, vdName :: Ident }
data GlobalInstance = GlobalInstance { giType :: Text, giName :: Ident }

data FnSig  = FnSig  { fnsMods :: [Text], fnsReturnType :: Text, fnsName :: Ident, fnsParams :: Text, fnsThrows :: Maybe Text }
data SubSig = SubSig { ssMods  :: [Text], ssName :: Ident, ssParams :: Text, ssThrows :: Maybe Text }
data EventSig = EventSig { esName :: Ident, esRawSig :: Text }

data FunctionBlock   = FunctionBlock   { fbSig :: FnSig,   fbBody :: [Located BodyStmt] }
data SubroutineBlock = SubroutineBlock { sbSig :: SubSig,  sbBody :: [Located BodyStmt] }
data EventBlock      = EventBlock      { evSig :: EventSig, evOwner :: Maybe Text, evBody :: [Located BodyStmt] }
data OnBlock         = OnBlock         { obQualName :: Text, obOwner :: Text, obEvent :: Text, obBody :: [Located BodyStmt] }

srAllTypeDecls  :: SrFile -> [TypeDecl]           -- srTypeBlocks decls, then forward-only decls
srPrimaryObject :: SrFile -> (Ident, Maybe Text)   -- (name, ancestor) of the file's own object; name is Ident since Plan 178 Phase 1, ancestor stays Text
splitAncestorRef :: Text -> (Ident, Maybe Ident)
-- Plan 164 Phase A (2026-07-10); Ident-typed since Plan 178 Phase 3
-- (2026-07-16). Splits PowerBuilder's "AncestorClass`LocalName"
-- control-override syntax (e.g. tdAncestor = "w_form_tab2`page1", meaning
-- "this local override of page1 is based on ancestor w_form_tab2's own
-- declaration of a control named page1"). The lexer treats backtick as an
-- identifier-continuation char (isIdentCont), so tdAncestor carries the whole
-- compound token verbatim with nothing splitting it apart before this.
-- (class, Nothing) when there's no backtick; splits at the first backtick
-- only. Internal plumbing for mkTypeDecl, which mints tdAncestorClass/
-- tdAncestorOverride once at TypeDecl construction -- ControlHierarchy.
-- buildControlIndex, TypeResolve.buildInheritsMap, TypeEnv.extractTypeDecls,
-- and Emit.extractWindowLayout's mkControl (the rendered control "type"
-- label) all read those fields directly rather than calling
-- splitAncestorRef themselves. Still exported for direct unit testing.
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
-- Same IR as before: most EDB relations (stmt/leg_source/proc/entry/
-- taint_edge/etc.) are plain DuckDB tables materialized by typed Haskell
-- readers + pure reshaping functions in PB.Analysis.Rules.* (Plan 175, all
-- three phases landed 2026-07-16) -- not CREATE VIEW SQL; see this file's
-- Datalog Rule Placement Discipline section and each PB.Analysis.Rules.*
-- module's own entry. leg is the one EDB-consumed relation that is itself
-- Datalog-derived (legRules, Plan 171a, 2026-07-15) from leg_source rather
-- than a direct materialization. Facts DO round-trip through Haskell once,
-- out to Souffle's .facts files and back from its .csv output (unlike the
-- old module, which stayed inside DuckDB via WITH RECURSIVE the whole
-- time).
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
-- onRelation (runRuleSets' onRelation callback; PB.Pipeline.Passes' runPhaseB
-- wires this to emitProgress, one "step" event per relation, e.g. "Datalog:
-- reaches", same reason as before: the CLI reporter's Phase B view shows only
-- the latest step label with no sub-progress bar), reads back its <name>.csv output, then
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

```

### `PB.Analysis.Rules.Schema` (Plan 161 cutover, 2026-07-11; coslice witness reconstruction Plan 161 Phase 2c, 2026-07-12; leg tie-break rewritten Plan 171a, 2026-07-15; EDB relations migrated to typed Haskell Plan 175 Phase 1, 2026-07-15; implied-FK + risk scoring Plan 161 Phase 3a, 2026-07-15)

```haskell
-- initEdbViews (re)materializes leg_source/stmt/seed/join_leg/fk as plain
-- DuckDB tables via typed readers (querySchemaMorphismRows/
-- querySchemaObjects/queryCatFks, PB.Pipeline.DuckDb) + the pure reshaping
-- functions below -- the same pattern PB.Analysis.Rules.DeadCode/Taint use
-- (see those modules' own entries), NOT a CREATE VIEW. Must run after
-- PB.Pipeline.DuckDb.initSchema and after schema_objects/schema_morphisms
-- have been populated (PB.Pipeline.Passes.runPass9): the read is eager, not
-- a lazily-evaluated SQL view. No "dead" relation materialized here --
-- DeadCode.liveProcRules reads proc_dead directly instead.
initEdbViews :: DuckConn -> IO ()
legSourceRows :: [SchMorphismRow] -> [[Text]]
-- leg_source: pure rename of (smrFromKey, smrToKey, smrLegKind);
-- smrLegSource is deliberately unused -- leg_source carries no provenance
-- column. querySchemaMorphismRows returns this raw row type rather than a
-- decoded SchMorphism: the stored from_key/to_key are one-way-sanitized
-- strings with no inverse parser in this codebase. Deliberately undeduped
-- -- legRules' choice-domain cascade below is what dedupes it.
stmtRows :: [SchObject] -> [[Text]]
-- stmt: keeps only StmtObj/SqlStmtId rows (file, object, proc, line).
-- DwRetrieveId rows are excluded -- a DW retrieve's proc is always NULL,
-- which would make proc_dead(Object,Proc) vacuously never match and every
-- DW retrieve unconditionally "live" in DeadCode.liveProcRules.
seedRows :: [SchObject] -> [[Text]]
-- seed: keeps only ColumnObj rows, projected to schObjectKey -- the
-- coslice walk's starting points.
joinLegRows :: [SchMorphismRow] -> [[Text]]
-- join_leg: (x, y) filtered to smrLegSource == "dw_join" -- the only
-- LegSource expressing a genuine two-table join distinct from a
-- DDL-declared FK (SrcDdlFk) or a statement touch. Embedded SQL JOINs are
-- not modeled as legs at all, so implied-FK discovery below is scoped to
-- DataWindow joins only.
fkRows :: [CatFkRow] -> [[Text]]
-- fk: (x, y) built via the identical schObjectKey encoding buildSchema
-- applies to the same catalog_fks rows for its own SrcDdlFk legs -- a
-- declared FK's key here always matches the leg it produces there.
legRel, reachesRel :: Relation
legSourceRel :: Relation
legRawRel :: Relation
legP0Rel, legP0KeyRel, legP1Rel, legP1KeyRel, legP2Rel :: Relation
seedRel, minDistRel, minDistBackRel, pathLegFwdRel, pathLegBackRel :: Relation

legRules :: RuleSet
-- Derives leg(x, y, kind) from leg_source via a priority CASCADE (writes ->
-- 0, retrieve -> 1, else -> 2), not a SQL ROW_NUMBER/CASE tie-break (a
-- house-rule violation, see the Datalog Rule Placement Discipline section
-- above) or a correlated min-aggregate (asymptotically worse -- Souffle
-- re-evaluates a correlated aggregate once per MATCHING ROW of the first
-- body literal, not once per distinct key, so cost is O(group_size^2) per
-- key; confirmed on synthetic fixtures: 13x slower at a 200x1000 vs.
-- 200000x~1 group-size ratio, another ~4.9x at 40x5000). leg_p0/leg_p1/
-- leg_p2 each pick one tuple per key via their own choice-domain (x, y),
-- gated by the negated existence of any higher-priority tuple for that key
-- (leg_p1's !leg_p0_key, leg_p2's !leg_p0_key/!leg_p1_key) -- the same
-- stratified-negation mechanism DeadCode.liveProcRules uses. Cost is
-- linear in leg_raw size regardless of key fan-in. rsRelations =
-- [legRawRel, legP0Rel, legP0KeyRel, legP1Rel, legP1KeyRel, legP2Rel,
-- legRel]; rsChoiceDomains covers leg_p0/leg_p1/leg_p2/leg. Verified
-- byte-identical leg output vs. the old aggregate rule across an
-- adversarial fixture battery (writes/retrieve collision, retrieve/fk
-- collision, a same-priority tie, a 0-hop self-loop, a 3-way collision),
-- ~220x instruction-count reduction on a pathological 40x5,000 fixture.
-- Root cause of a real production incident: the old aggregate-based leg
-- stalled 13+ minutes/19.5GB+ resident (climbing, no plateau) on a real
-- corpus with heavy (x,y)-key fan-in, vs. ~2 minutes/3GB for the whole
-- prior (pre-171a, SQL-view-based) index.

data LegSourceFanout = LegSourceFanout
  { lsfTotalRows, lsfDistinctKeys, lsfMaxGroupSize :: !Int } deriving (Eq, Show)
legSourceFanout :: DuckConn -> IO LegSourceFanout
-- Cheap DuckDB GROUP BY characterization of leg_source's (x, y) key
-- fan-in, run before legRules (PB.Pipeline.Passes.reportLegSourceFanout,
-- right after materializeAllEdbViews) so a corpus with pathological
-- duplicate fan-in is visible immediately rather than discovered only via
-- a stalled/memory-hungry Souffle run. Emits a "step" progress event
-- always, plus a "warning" if lsfMaxGroupSize > 500 (leg_source has only
-- ~3 distinct kind buckets, so a group that large signals upstream
-- extraction duplication, not legitimate diversity). Kept even after the
-- O(group_size^2) fix above -- the fan-in number is diagnostically useful
-- on its own.

reachesRules :: RuleSet
-- reaches(X,Y) :- leg(X,Y,_). reaches(X,Z) :- reaches(X,Y), leg(Y,Z,_).
-- Materializes to table "reaches". Souffle handles the self-recursion
-- natively. The existence-only core PB.Analysis.SchemaCategory.blastRadius/
-- validationWalkBack reproject off of. runRuleSets orders this after
-- legRules (reads leg as EDB).

cosliceRules :: RuleSet
-- Path-leg witness reconstruction for decomposition_coslice
-- (columnCoslice = blastRadius UNION validationWalkBack, deduped to one
-- shortest path per StmtObj target). min_dist/min_dist_back compute
-- shortest forward/backward distance from seed via a native Souffle
-- recursive fixpoint, gated by a choice-domain (s, node) -- required for
-- termination on a cyclic graph (an "n != s" guard alone is not enough: a
-- cycle among non-seed nodes still derives ever-larger distances forever;
-- reproduced directly against the real souffle binary -- a real schema-
-- graph FK cycle not through the seed hung indefinitely before this fix).
-- path_leg_fwd/path_leg_back emit every shortest leg on a shortest path
-- from seed to target, each as two unioned rules expressing the
-- disjunction (leg ends at target, OR leg ends at an intermediate that
-- reaches target) -- reusing reachesRules' unioned-rule pattern rather
-- than extending the IR for disjunction. A reaches(lt, t) guard alone is
-- NOT sufficient on a cyclic graph (pure existence, no distance bound --
-- confirmed on a real corpus to admit legs at ordinals up to 7 for a
-- target whose own min_dist was 2); min_dist(s, t, td), o + 1 < td bounds
-- intermediate hops strictly within the target's own distance. Through a
-- diamond, multiple legs tie at one ordinal; the deterministic
-- single-witness tie-break (ROW_NUMBER, partitioned by (seed_key,
-- target_key, direction, leg_ordinal), ordered by (leg_from, leg_to)) is
-- deferred to SQL materialization (PB.Pipeline.DuckDb.
-- materializeDecompositionCoslice), keeping the IR free of inequality/
-- comparison operators. That materializer also renumbers backward legs
-- (max_ord - leg_ord) so both directions read seed-outward in
-- path_leg_back's Datalog output but land as target->seed in the final
-- table, matching the deleted Haskell columnCoslice's convention that
-- every UI consumer (e.g. DecompositionCandidatesCore.tsx) still expects.
-- Reuses seed (initEdbViews above) and leg/reaches as EDB; runRuleSets
-- orders this after reachesRules.

joinLegRel, fkRel, impliedFkRel :: Relation
impliedFkRules :: RuleSet
-- implied_fk_pairs(X, Y) :- join_leg(X, Y), !fk(X, Y), !fk(Y, X).
-- A DataWindow join edge with no matching declared FK in EITHER direction
-- (both orientations of fk are negated since a join's column order need
-- not match the FK's declared from/to side). Materializes to
-- implied_fk_pairs, a raw two-column ColKey table -- deliberately NOT
-- named implied_fk, so PB.Pipeline.DuckDb.materializeImpliedFk's
-- structured consumer table of that name is never clobbered by the
-- generic-arity recreateTextTable every IDB relation goes through (same
-- raw-vs-consumer name separation path_leg_fwd/back keep from
-- decomposition_coslice). No dependency on legRules/reachesRules -- runs
-- directly off initEdbViews' join_leg/fk EDB.

hasReachesRel, riskCountRel :: Relation
riskRules :: RuleSet
-- risk_count(X, N) :- has_reaches(X), N = count : { reaches(X, _) }.
-- Migration blast-radius / risk scoring: a downstream-footprint count
-- aggregated DIRECTLY over the existing reaches relation (same count :
-- idiom PB.Analysis.Rules.DeadCode.callerCountRules uses for caller
-- fan-in) -- deliberately NOT a second risk_leg/risk_reach traversal
-- unioning leg with implied_fk_pairs: every LegFk edge (DDL-declared or
-- DW-join-derived) already renders as a kind="fk" row in leg_source/leg
-- regardless of provenance (legSourceRows drops it), so reaches already
-- walks every undeclared-join edge implied_fk flags -- re-deriving a
-- parallel closure over the identical edge set would be a wasted second
-- fixpoint, not a new traversal. implied_fk stays a standalone
-- data-quality finding. Materializes to PB.Pipeline.DuckDb.
-- materializeColumnRisk's human-readable column_risk table (kind =
-- 'column' rows only -- see that function's own entry). runRuleSets
-- orders this after reachesRules.
```

### `PB.Analysis.Rules.DeadCode` (Plan 161 Phase 2b cutover, 2026-07-11; EDB relations migrated to typed Haskell Plan 175 Phase 2, 2026-07-16; ProcInfo demoted to a test-local fixture type, 2026-07-16)

```haskell
-- initDeadReachEdbViews materializes proc/entry/inherits/call_ref/
-- resolved_call_edge/calls/proc_meta as plain DuckDB tables via typed
-- readers (queryProcedures/queryObjectAncestors/queryDwObjects/
-- queryResolvedCalls, PB.Pipeline.DuckDb) + pure reshaping functions --
-- the PB.Analysis.Rules.Schema/Taint pattern (see those modules' own
-- entries). Every read of `procedures` excludes `confidence =
-- 'speculative'`, excluding synthetic builtin-class method stubs. Must run
-- after PB.Pipeline.DuckDb.initSchema and after objects/procedures/
-- resolved_calls/dw_objects have been populated; must also run AFTER a
-- test fixture seeds those tables (initDeadReachEdbViews reads them
-- eagerly, not as a lazily-evaluated SQL view).
initDeadReachEdbViews :: DuckConn -> IO ()
procRows          :: [ProcSummaryRow] -> [[Text]]              -- proc: (object, proc), speculative-filtered
procMetaRows      :: [ProcSummaryRow] -> [[Text]]              -- proc_meta: + proc_type/cyclomatic/lowercased name
inheritsRows      :: [(Text, Text)] -> [[Text]]                -- inherits: objects.ancestor, renamed (child, parent)
entryRows         :: [ProcSummaryRow] -> [Taint.ResolvedCallRow] -> [Text] -> [[Text]]
-- entry: event/on handlers (speculative-filtered) union every (object,
-- from_proc) whose object is a known DW object.
callRefRows       :: [Taint.ResolvedCallRow] -> [CallRef]
-- call_ref: same-object case-insensitive callee-name references (the text
-- after the last '.' in to_name, lowercased), deduped.
resolvedCallEdgeRows :: [Taint.ResolvedCallRow] -> [ResolvedCallEdge]
-- resolved_call_edge: fully cross-object-resolved call sites, NOT deduped
-- (unlike callRefRows) -- the scoped caller count must count every call
-- site, not collapse duplicates sharing the same (caller, callee).
callsRows         :: [CallRef] -> [ProcSummaryRow] -> [ResolvedCallEdge] -> [CallEdge]
-- calls: CallRef joined against procedures by lowercased name (speculative-
-- filtered) unioned with ResolvedCallEdge (line column dropped), deduped.
data CallRef         = CallRef { crCallerObj, crCallerProc, crCalleeName :: !Text }
data ResolvedCallEdge = ResolvedCallEdge { rceCallerObj, rceCallerProc, rceCalleeObj, rceCalleeProc, rceLine :: !Text }
data CallEdge        = CallEdge { ceCallerObj, ceCallerProc, ceCalleeObj, ceCalleeProc :: !Text }
callRefRel, resolvedCallEdgeRel, confidenceRel :: Relation

deadReachRules :: RuleSet
-- proc_reachable(Object,Proc) :- entry(Object,Proc).
-- proc_reachable(Object,Proc) :- proc_reachable(CObj,CProc), calls(CObj,CProc,Object,Proc).
-- proc_reachable(ChildObj,Method) :- proc_reachable(ParentObj,Method), override_edge(ChildObj,Method,ParentObj).
-- proc_dead(Object,Proc) :- proc(Object,Proc), !proc_reachable(Object,Proc).
-- descendant(Child,Parent) :- inherits(Child,Parent).  -- transitive closure
-- descendant(Child,GP) :- inherits(Child,Parent), descendant(Parent,GP).
-- override_edge(ChildObj,Method,ParentObj) :- proc(ParentObj,Method), descendant(ChildObj,ParentObj), proc(ChildObj,Method).
-- descendant/override_edge are internal IDB rules derived purely from
-- inherits/proc -- no separate overrides EDB relation or Haskell
-- pre-computation step exists. Materializes tables "proc_reachable"/
-- "proc_dead". PB.Pipeline.Passes.runPhaseB's B2 sub-phase runs this
-- (via allDatalogRuleSets, ordered before callerCountRules/
-- deadCodeRowsRules/liveProcRules, which all read proc_dead).

liveProcRules :: RuleSet
-- live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !proc_dead(Object,Proc).
-- Real stratified-negation demonstration (Plan 161 Open Question 4). Reads
-- proc_dead (deadReachRules) directly; runPhaseB's B2 orders deadReachRules
-- first (required -- proc_dead must already exist when this ruleset
-- exports its EDB facts).

callerCountRules :: RuleSet
-- has_naive_caller(CalleeName) :- call_ref(_,_,CalleeName).
-- has_scoped_caller(Obj,Proc) :- resolved_call_edge(_,_,Obj,Proc,_).
-- caller_count_naive(CalleeName,N) :- has_naive_caller(CalleeName), N = count : { call_ref(_,_,CalleeName) }.
-- caller_count_scoped(Obj,Proc,N) :- has_scoped_caller(Obj,Proc), N = count : { resolved_call_edge(_,_,Obj,Proc,L) }.
-- confidence(Object,Proc,"high"|"medium"|"low") -- 3 rules, joined through
-- proc_meta's lowercased proc_lower column (PowerBuilder identifiers are
-- case-insensitive; a raw-case join would silently misclassify a dead proc
-- whose only unresolved caller differs in case).

deadCodeRowsRules :: RuleSet
-- caller_count_naive_final/caller_count_scoped_final: caller_count_naive/
-- scoped's real counts, defaulted to 0 for a proc with no matching caller
-- fact at all (Soufflé aggregates produce no row for an empty group).
-- dead_code_rows(O,P,PT,Cyc,Lvl,NN,SN) :- proc_dead(O,P), proc_meta(O,P,PT,Cyc,PLower),
--   confidence(O,P,Lvl), caller_count_naive_final(PLower,NN), caller_count_scoped_final(O,P,SN).
-- Final projection into the dead_code table is
-- PB.Pipeline.DuckDb.materializeDeadCode (mechanical TEXT->typed cast, no
-- further classification -- see that function's own entry).
```

### `PB.Analysis.Rules.Taint` (Plan 161 Phase 2d; step_kind labeling Plan 171b, 2026-07-15; witness reconstruction moved to Haskell 2026-07-16; EDB relations migrated to typed Haskell Plan 175 Phase 3, 2026-07-15)

```haskell
-- initTaintEdbViews :: DuckConn -> IO () (re)materializes taint_edge/
-- taint_source/taint_sink as plain DuckDB tables via typed readers +
-- pure reshaping functions -- the PB.Analysis.Rules.Schema/DeadCode
-- pattern (see those modules' own entries). taintEdgeIntraRows joins
-- queryProcDefs/queryProcUses results on (object, proc_name, line),
-- excluding same-var pairs and defs with no line. taintEdgeArgRows/
-- taintEdgeGlobalRows filter queryInterprocEdges's InterprocEdgeRow
-- results by edge_kind ("arg"/"global_write"). taintEdgeReturnRows joins
-- InterprocEdgeRow (edge_kind="return") against a proc_uses row
-- (kind="return") in the callee. taintKeyRows projects+dedups a
-- TaintKeyRow list (queryTaintSourceRows/queryTaintSinkRows, DuckDb.hs) to
-- its object::proc::var key -- shared by both taint_source and
-- taint_sink, which reduce to the identical key shape. The four edge
-- lists are unioned into taint_edge in memory, not materialized under
-- their own names -- nothing reads taint_edge_intra/_arg/_global/_return
-- except via that union. Real-corpus gate MET, 2026-07-15: worktree-diff
-- against HEAD (454b5e6), openpay taint_paths (25 rows)/taint_annotations
-- (771 rows) and PowerBuilder-Example taint_paths (1 row)/
-- taint_annotations (31 rows) all byte-identical.

-- taintRules (RuleSet) computes ONLY the two cheap fixpoint-shaped
-- relations: taint_reaches(x, y) (transitive closure, seeded from
-- taint_source) and taint_confirmed(s, t) (source→sink reachability, two
-- rules: the 0-hop s==t case and the general taint_reaches(s,t) case).
-- rsChoiceDomains is empty -- there is no per-source distance table left
-- to need one.
taintRules :: RuleSet

-- reconstructTaintStepKind :: DuckConn -> IO () rebuilds taint_step_kind
-- (s, t, leg_ord, lf, lt, kind, step_kind, description) as a plain Haskell
-- BFS instead of a Souffle fixpoint -- one BFS per live source (shared
-- across all of that source's confirmed sinks via a parent-pointer map,
-- same worklist shape as PB.Analysis.Taint.propagateTaint but graph-
-- structural and per-source rather than global), then a backward walk per
-- confirmed (s, t) pair (mirrors PB.Analysis.Taint.traceTaintPath).
-- Row/label shape matches the four Datalog rules it replaces exactly:
-- leg_ord 0 is always "source" regardless of its real edge kind; every
-- other leg passes its edge kind through as both step_kind and
-- description; a terminal "sink" marker lands one ordinal past the last
-- leg; the 0-hop (source == sink) case is a single "source-sink" row.
-- Adjacency lists are pre-sorted ascending by (to, kind), so diamond ties
-- resolve deterministically to the lexicographically smallest witness --
-- NOT necessarily the same edge the old Datalog+SQL ranked_legs tie-break
-- would have picked (that chose per (s,t) pair independently; this shares
-- one tree per source), a documented cosmetic shape delta, same category
-- Plan 171b already accepted for steps_json content. Confirmed-pair set,
-- path lengths, and step_kind semantics are unaffected.
--
-- WHY: PB.Analysis.Rules.Taint carried four same-day perf fixes
-- (2026-07-15, doc/plan/171-datalog-decision-migration.md's Postscript)
-- restricting taint_min_dist/taint_path_leg's seeds -- all of them
-- premised on "most sources are dead ends that never reach a sink", the
-- shape of every synthetic fixture used to verify them. Real-corpus
-- verification showed NO improvement after all four landed: a synthetic
-- "shared-utility-layer" fixture (1,800 sources/700 sinks/~11K edges --
-- 27x FEWER edges than the real 301,754-edge corpus, but with heavy
-- reachable-set overlap across sources, mirroring shared library-proc
-- structure) reproduced the same symptom -- taint_source_live came back
-- 1,800/1,800 (every source "live", so that seed restriction did nothing),
-- and the fully-fixed Datalog rules still took 190s/4.66GB on it.
-- taint_reaches/taint_confirmed ALONE (no witness reconstruction) computed
-- the SAME fixture in 0.79s/41MB -- essentially 100% of the cost was
-- witness-path reconstruction (taint_min_dist/taint_path_leg), not knowing
-- which (source, sink) pairs are confirmed. Root cause: computing a full
-- per-source shortest-distance table for EVERY live source is inherently
-- O(#live_sources x avg-reachable-set-size), which Datalog's declarative
-- fixpoint has no way to avoid once "which pairs" and "what's the witness"
-- are fused into one relation -- exactly the shape the pre-Datalog
-- PB.Analysis.Taint.propagateTaint/traceTaintPath split (one global BFS,
-- then a cheap per-sink backward walk) never had to pay. User explicitly
-- chose to KEEP full per-(source,sink) attribution (richer security
-- signal: every distinct attack vector shown, not collapsed to one path
-- per sink) rather than reduce cardinality to match the old contract --
-- so the fix is moving WHERE the witness reconstruction runs, not what it
-- computes. Compiled-Haskell benchmark on the same hub fixture: 20.1s
-- total (1.9s Souffle taint_reaches/taint_confirmed + 18.2s Haskell BFS
-- reconstruction, the latter dominated by writing 3,230,980 output rows
-- via DuckDB's row-at-a-time Appender, not graph traversal) vs. 190s
-- baseline -- 9.4x, row count verified identical to a since-superseded
-- Datalog-side choice-domain experiment (3,230,980 both ways). Currently
-- runs inline in runPhaseB (PB.Pipeline.Passes) as part of `pb index`; a
-- `pb explore`-triggered background job (compute confirmed pairs eagerly,
-- backfill witnesses incrementally while the UI is running) was discussed
-- as a fallback if real-corpus numbers make the inline cost too large, but
-- not implemented -- inline-first was the explicit choice pending a real
-- benchmark. Real-corpus taint_paths/taint_annotations byte-identical
-- (see this module's own EDB-relations gate note above, which re-runs
-- this same check); the actual `pb index` wall-clock/memory number on a
-- production-scale corpus is still owed -- not accessible to the assistant.
reconstructTaintStepKind :: DuckConn -> IO ()
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
-- TypeCheckWorkspace -> Map.Map Text [(TableRef, Text)] ->
-- Maybe (SqlBridgePool, Int) -> Text -> ParseOutcome -> IO CompiledFile.
-- TypeCheckWorkspace param added Plan 177 Phase 4a (2026-07-16), slotted
-- right after controlIdx: PB.Analysis.TypeCheck.buildTypeCheckWorkspace
-- allParsedSrFiles built once in runModeDb alongside wsEnv/controlIdx (every
-- field is a pure fold over [SrFile], no DuckDB round-trip needed unlike
-- resolveTypes/resolveCalls's Phase-B inputs), threaded through
-- workerLoopFiles/workerLoopFilesNoBridge the same way. Per procedure,
-- compileOne builds a TypeCheckCtx (params from tcwParams looked up on
-- (obj, pName); body locals from CallClassify.collectBodyLocals, both sides
-- lowercased -- see TypeCheck.hs's own tcScope case-sensitivity fix) and
-- calls checkBody, gated on confidence /= "speculative" (same gate as
-- deadVars below), producing CompiledPs's new
-- cpsTypeMismatches :: [TypeMismatchFinding], appended via
-- DuckDb.appendTypeMismatches into a new type_mismatches table (object,
-- proc_name, line, target, lhs_type, rhs_desc, kind).
--
-- DwFootprintCtx itself is built once in runModeDb from the same DDL
-- catalog rows catTables is derived from (mkDwFootprintCtx catCols
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
cyclomaticComplexity :: Cfg -> Int   -- E - N + 2
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
-- classifyExpr/CallKind feed FromSSA's ECall/ESuspend IR-node choice --
-- a structural, single-bit decision -- and are unchanged by classifyEffects
-- below (Plan 174 T0-6, 2026-07-16).

data EffectTag = ReadsDb | WritesDb | WritesUi | Suspends
classifyEffects :: ScopedTypeEnv -> Expr -> Set.Set EffectTag
-- Additive sibling of classifyExpr/CallKind (kept separate, not a literal
-- widening of CallKind -- see above): a call may carry several effect tags
-- at once (e.g. a DW Update() both writes the DB and suspends), which a
-- single-constructor CallKind can't express. Mirrors classifyExpr's
-- dispatch shape exactly (same ExCall/ExMethodCall cases, same
-- resolveLvalueType/resolveReceiverType plumbing); unresolvable/untyped
-- calls fall back to Set.empty, the same conservative-fallback precedent
-- classifyExpr uses for PureCall. Not yet consumed anywhere in production
-- (feeds a future Plan 148 functor-key / Plan 149 wiring-box-styling
-- consumer, neither wired up this session).
builtinEffectTags :: Map.Map Text (Set.Set EffectTag)
-- Free-function (single-segment ExCall) tags, keyed by the same names
-- isBuiltinSuspendFn recognizes. run/execute -> {Suspends} only --
-- confirmed against real corpus usage (bare Run("clipbrd.exe")/
-- run(ls_tempfile) launch an external process/subshell, not a DB or UI
-- effect in this project's vocabulary; a `.Run()` *method* call on an
-- OLEOBJECT, e.g. WScript.Shell automation, is a different corpus pattern
-- entirely and this single-segment dispatch never reaches it).
-- isBuiltinSuspendFn is now `n \`Map.member\` builtinEffectTags` (was a
-- flat elem list) -- single source of truth, no behavior change.
dwTypes, transTypes :: Set.Set Text
-- Hoisted to top-level (were where-bound locals of isTypedSuspend only).
dwMethodEffectTags, transMethodEffectTags :: Map.Map Text (Set.Set EffectTag)
-- Per-method tag tables. isTypedSuspend now checks `Map.member` against
-- these (was a flat elem list) -- single source of truth, no behavior
-- change to isTypedSuspend/classifyExpr. retrieve -> {Suspends,ReadsDb};
-- update/delete/reset/rowscopy/rowsmove/sharedata/modify (buffer-mutating
-- DW ops) -> {Suspends,WritesDb}; print -> {Suspends,WritesUi} (rendering
-- output, not a data effect); commit -> {Suspends,WritesDb} (finalizes
-- pending writes); rollback/connect/disconnect/autocommit ->
-- {Suspends} only (connection/state management, no direct data effect).
typedEffectTags :: Map.Map Text Text -> Text -> Text -> Set.Set EffectTag
-- Method-call tag lookup mirroring isTypedSuspend's dwTypes/transTypes
-- dispatch. SetItem (DW buffer writes) deliberately NOT folded in here --
-- it's recognized by a completely different mechanism, a literal-argument
-- pattern match in PB.Analysis.SchFootprint.resolveSetItem, not by
-- isTypedSuspend's type-based dispatch table; out of scope for this
-- widening.
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
segName :: LvSegment -> Ident
-- Ident since Plan 178 Phase 2 (LvSegment.name migration). Callers use
-- identCanon for case-insensitive lookups (classifyExpr/classifyEffects/
-- resolveLvalueType/resolveReceiverType/isTriggerEvent), identOrig for
-- display (calleeName/lvHead). segName is redefined identically as a local
-- helper in TypeCheck.hs/TypeResolve.hs/DwFootprint.hs/Dataflow.hs -- not
-- shared, each returns Ident too (Dataflow.hs's own segName shims back to
-- Text via identOrig -- see its module entry below).
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

### `PB.Analysis.Dataflow` (Plan 111a; live variables + dsPartial added Plan 174 T0-1, 2026-07-16; partial-def kill/use + subscript-read generalization Plan 174 T0-1 follow-on, 2026-07-16)

```haskell
-- Pure intra-procedural dataflow: def-use + reaching definitions + live variables.
-- lvRoot/walkExprIdents's local segName shims LvSegment.name's Ident back to
-- Text via identOrig (Plan 178 Phase 2) -- var-name matching here is
-- exact-Text, not case-folded, unlike every other segName consumer in the
-- codebase. See BACKLOG's case-sensitivity finding: this may be a latent
-- correctness gap (PB variable names are case-insensitive), deliberately
-- not fixed in Phase 2 since it changes def/use matching behavior.
extractDefsUses      :: CfgBlock -> BlockFlow
extractSqlHostVars   :: Text -> [Text]   -- :identifier host-var names from raw embedded SQL text; also PB.Analysis.Taint's single source for this extraction (see that module's entry)
reachingDefinitions  :: Cfg -> Map Text BlockFlow -> (Map Text (Set Text), Map Text (Set Text))
liveVariables        :: Cfg -> Map Text BlockFlow -> (Map Text (Set Text), Map Text (Set Text))
-- (liveIn, liveOut) per block, backward fixpoint mirroring reachingDefinitions
-- with edges reversed. useSet per block is upwardExposedUses (internal, not
-- exported) -- a raw union of bfUses is WRONG here: a block that redefines a
-- var and then reads its own redefinition (e.g. `li_x = 2; li_y = li_x`)
-- must not count that read as "needed from outside the block."
analyzeProcedure     :: Text -> Text -> Cfg -> ProcFlow   -- obj, proc, cfg
-- analyzeWorkspace (Pass 6, writes proc_defs.json/proc_uses.json) is deferred to 111d-1.
data DefSite = DefSite { dsVar :: Text, dsBlock :: Text, dsStmtIdx :: Int, dsLine :: Maybe Int, dsKind :: Text, dsPartial :: Bool }
-- dsPartial: True when this def writes only one member of a multi-segment
-- lvalue (`item.label = x`), not the whole variable -- lvRoot collapses a
-- member chain to its root, so `item.label = a; item.pictureindex = b`
-- (the treeviewitem-population idiom) looks like two full redefinitions of
-- `item` to any consumer keyed on dsVar alone unless it checks this flag.
-- Only BsAssign's parsed Lvalue can populate it reliably; BsAugAssign/
-- BsInc/BsDec (token-list based) always get False.
data UseSite = UseSite { usVar :: Text, usBlock :: Text, usStmtIdx :: Int, usLine :: Maybe Int, usKind :: Text }
data BlockFlow = BlockFlow { bfBlockId :: Text, bfGen :: Set Text, bfKill :: Set Text, bfDefs :: [DefSite], bfUses :: [UseSite] }
data ProcFlow  = ProcFlow  { pfObject :: Text, pfProc :: Text, pfBlocks :: Map Text BlockFlow
                           , pfReachingIn :: Map Text (Set Text), pfReachingOut :: Map Text (Set Text)
                           , pfLiveIn :: Map Text (Set Text), pfLiveOut :: Map Text (Set Text)
                           , pfAllDefs :: Map Text [DefSite], pfAllUses :: Map Text [UseSite] }
-- walkExprIdents counts the ExCall callee root as a use (matches Python core/dataflow.py),
-- and its ExLvalue case counts subscript-expression identifiers too, not just
-- the root (`arr[i]` reads both `arr` and `i`) -- this covers a subscripted
-- lvalue read anywhere an expression appears (RHS, conditions, call args,
-- returns). extractUseVars's BsAssign case additionally calls
-- lvalueSubscriptIdents directly on the LHS itself (an assignment's own LHS
-- is never wrapped in an ExLvalue node, so walkExprIdents never sees it).
--
-- bfGen always includes every local def's dsVar, partial or not; bfKill
-- excludes dsPartial defs -- a partial def reaches past the block (bfGen)
-- but doesn't kill the variable's prior reaching/live value (bfKill), since
-- it only overwrites one member. extractUseVars's BsAssign case also adds
-- an implicit use of the def's own root var when isPartialDef holds (the
-- partial write reads the struct to reach into it) -- this is the single
-- source of truth both DeadVars.deadStoresInBlock's local backward walk and
-- liveVariables/reachingDefinitions' block-level fixpoints read; there is no
-- separate partial-def bookkeeping anywhere else in the codebase.
--
-- dsPartial/pfLiveIn/pfLiveOut are additive: dataflowDefRows/dataflowUseRows/
-- dataflowFacet's JSON row shape is unchanged, so no Python-consumer wire
-- format was touched by this addition.
```

### `PB.Analysis.DeadVars` (Plan 174 T0-1, 2026-07-16; wired into the `--db` pipeline same day)

```haskell
-- Pure query over Dataflow's ProcFlow + TypeResolve's LocalVar list --
-- no new IR, no new fixpoint of its own (the one new fixpoint, live
-- variables, lives in PB.Analysis.Dataflow as a generic companion to
-- reachingDefinitions). Wired into the `--db` pipeline: Runner.hs's
-- appendDeadVars populates the dead_vars table; see BACKLOG's Plan 174 T0-1
-- entries for the real-corpus finding-count histogram.
data DeadVarKind = NeverRead | OverwrittenBeforeRead | UnusedParam
data DeadVarFinding = DeadVarFinding { dvfObject, dvfProc, dvfVar :: Text, dvfLine :: Maybe Int, dvfKind :: DeadVarKind }
deadVarKindText :: DeadVarKind -> Text   -- "never-read" / "overwritten-before-read" / "unused-param"
findDeadVars :: [LocalVar] -> ProcFlow -> [DeadVarFinding]
-- [LocalVar] MUST be pre-scoped by the caller to the specific procedure
-- instance being analyzed -- lvProcName alone does not disambiguate same-
-- named procedures in one file (PB menu items each own a "clicked" event
-- body under the same name; PB also allows function overloading). Filter
-- by lvScopeLine falling within that procedure's own (sLine, eLine) span
-- for body locals. Parameters can't be scoped this way: extractLocalVars/
-- paramsToVars hardcodes lvScopeLine=0 for every parameter, so a caller
-- with overloaded same-name functions in one file will see the union of
-- every overload's params for each -- a known, pre-existing limitation of
-- extractLocalVars's output shape (not something this module introduces),
-- confirmed via a real-corpus spike (eon_appeon_resize.of_getscale in the
-- PowerBuilder-Example corpus, 9 overloads sharing one param list).
--
-- NeverRead: a declared local (LocalVar with lvIsParam=False) whose name
-- never appears in pfAllUses. UnusedParam: same check, lvIsParam=True.
-- OverwrittenBeforeRead: walks each block backward from pfLiveOut using
-- bfDefs/bfUses; a def is flagged only when (a) its dsKind isn't
-- local_var/for_var (a bare declaration or a for-loop counter is never the
-- "dead" side of a pair -- idiomatic, not a bug), (b) dsPartial is False (a
-- struct field write can't clobber a sibling field), and (c) the var IS
-- read somewhere in the procedure (else it's already NeverRead -- this
-- guard is what keeps the two kinds from double-reporting the same fully-
-- unused variable). Trusts Dataflow's bfUses/dsPartial directly for the
-- partial-def-doesn't-kill policy -- no local re-derivation of that policy.
```

### `PB.Analysis.Taint` (Plan 111 — 111b/c/d-2)

```haskell
-- Taint analysis: source/sink classification, BFS propagation, path tracing.
-- JSON path: reads proc_defs/uses, resolved_calls, global_vars from JSON files.
-- DuckDB path: reads from DB via PB.Pipeline.DuckDb query helpers.
-- Classifies sources (SELECT INTO, event params) and sinks (INSERT/UPDATE/DELETE/EXECUTE)
-- from AST. extractSqlStmts recurses into BsIf/BsFor/BsDo/BsChoose, not just top-level BsRaw.
-- classifySources/classifySinks extract :host_var names via
-- PB.Analysis.Dataflow.extractSqlHostVars (imported, not reimplemented --
-- this module has no host-var extraction of its own).
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
-- queryDwObjectSet is GONE (Plan 161 Phase 2b cutover, 2026-07-11):
-- DW-object seeding for dead-code reachability moved entirely into
-- Souffle's `entry` EDB view (SQL JOIN against dw_objects); no Haskell
-- consumer of the raw DW-object set remained once that happened.
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
-- Typed EDB-reshaping-layer readers feeding PB.Analysis.Rules.DeadCode's
-- initDeadReachEdbViews (see that module's own entry). Deliberately lean,
-- not the write-side ObjectRow/ProcRow/DwObjectRow -- those carry JSON blob
-- columns (layout_json/type_blocks_json; cfg_json/instr_graph_json/
-- wiring_json) none of DeadCode.hs's relations read.
queryObjectAncestors :: DuckConn -> IO [(Text, Text)]
-- "SELECT object, ancestor FROM objects WHERE ancestor IS NOT NULL"
data ProcSummaryRow = ProcSummaryRow
  { psrObject, psrProcName, psrProcType :: !Text
  , psrCyclomatic :: !(Maybe Int), psrConfidence :: !Text }
queryProcedures :: DuckConn -> IO [ProcSummaryRow]
queryDwObjects  :: DuckConn -> IO [Text]  -- "SELECT DISTINCT object FROM dw_objects"
-- Same lean-reader treatment, feeding PB.Analysis.Rules.Taint's
-- initTaintEdbViews (see that module's own entry). InterprocEdgeRow omits
-- interproc_edges' caller_line column -- unread by every taint edge
-- relation. TaintKeyRow is the shared (object, proc_name, var_name)
-- projection both taint_sources and taint_sinks reduce to; neither reader
-- touches file/source_type/sink_type/severity/line.
data InterprocEdgeRow = InterprocEdgeRow
  { ierCallerObject, ierCallerProc, ierCalleeObject, ierCalleeProc
  , ierEdgeKind, ierVarName, ierCallerContext, ierCalleeContext :: !Text }
queryInterprocEdges :: DuckConn -> IO [InterprocEdgeRow]
data TaintKeyRow = TaintKeyRow { tkrObject, tkrProcName, tkrVarName :: !Text }
queryTaintSourceRows :: DuckConn -> IO [TaintKeyRow]  -- FROM taint_sources
queryTaintSinkRows   :: DuckConn -> IO [TaintKeyRow]  -- FROM taint_sinks
-- Phase B write appenders:
appendResolvedTypes, appendResolvedCalls :: DuckConn -> [row] -> IO ()
appendInterprocEdges, appendProcSummaries :: DuckConn -> [row] -> IO ()
appendTaintSources, appendTaintSinks, appendTaintPaths, appendTaintAnnotations :: DuckConn -> [row] -> IO ()
-- dead_code: no appender -- materializeDeadCode (below, near
-- materializeDecompositionCoslice) is a pure SQL INSERT...SELECT reading
-- dead_code_rows (PB.Analysis.Rules.DeadCode.deadCodeRowsRules' Soufflé
-- output), not a Haskell-row appender. See PB.Analysis.Rules.DeadCode's
-- own Code Index entry for the rule sets that produce dead_code_rows.
-- schema_objects/schema_morphisms (Plan 148 Phase 1b, 2026-07-07): written
-- by runPass9 from SchemaCategory.buildSchema's SchGraph. object_key/
-- from_key/to_key columns hold SchemaCategory.schObjectKey's canonical
-- string form. schema_morphisms' leg_source column (Plan 163 Phase 4,
-- 2026-07-10; was fk_source, FK-only) holds renderLegSource (legSource m)
-- for every row -- see SchemaCategory's LegSource entry above.
appendSchemaObjects   :: DuckConn -> [SchemaCategory.SchObject]   -> IO ()
appendSchemaMorphisms :: DuckConn -> [SchemaCategory.SchMorphism] -> IO ()
-- decomposition_coslice (Plan 161 Phase 2c): materialized from the Souffle
-- path_leg_fwd/path_leg_back tables via materializeDecompositionCoslice.
-- Tie-break via ROW_NUMBER, leg_source joined from schema_morphisms,
-- StmtObj-only target filter. Python's get_decomposition_candidates (cli/api)
-- is the sole reader.
materializeDecompositionCoslice :: DuckConn -> IO ()
-- implied_fk/column_risk (Plan 161 Phase 3a, 2026-07-15): (namespace,
-- table, column) x2 / (namespace, table, column, downstream_count) --
-- decode Souffle's raw ColKey-pair output (implied_fk_pairs/risk_count,
-- see PB.Analysis.Rules.Schema's impliedFkRules/riskRules) back to
-- human-readable form via a join-back on schema_objects.object_key, same
-- decoding materializeDecompositionCoslice uses (schObjectKey has no
-- inverse parser). column_risk's join is restricted to kind = 'column' --
-- risk_count also scores StmtObj (stmt/dw_retrieve) nodes, which have no
-- namespace/table_name/column_name in schema_objects at all (only stmt_*
-- fields); an unfiltered join materialized 115 opaque all-NULL rows on the
-- real openpay corpus before this restriction.
materializeImpliedFk   :: DuckConn -> IO ()
materializeColumnRisk  :: DuckConn -> IO ()
-- dead_code (Plan 166 Stage 6): mechanical TEXT->typed INSERT...SELECT from
-- dead_code_rows (PB.Analysis.Rules.DeadCode.deadCodeRowsRules' Soufflé
-- output) -- no Haskell classification left. A ROW_NUMBER() dedup picks the
-- highest-cyclomatic overload deterministically when PowerBuilder function
-- overloading collapses several procedures to one (object, proc_name) row.
materializeDeadCode :: DuckConn -> IO ()
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
