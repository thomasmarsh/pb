# pb-ast — Working Protocol

## Quick Reference

```text
cabal build                           # compile library + executables
cabal build --enable-tests            # compile tests too
cabal test                            # run test suite
cabal test --test-show-details=direct # verbose output
bash scripts/check-corpus.sh          # 0 errors / 777 files = baseline
python3 scripts/analyze-debt.py       # BsRaw + ExRaw debt breakdown (both corpora)
python3 scripts/analyze-debt.py --no-build  # same, skip build step
```

## Session Scoping

**Charter first.** Before Stage 0, state a one-sentence charter:

> "This session delivers X. [Y is out of scope.]"

Infer the charter from the user's intent. If ambiguous, ask before reading any code. No work starts until the charter is written.

**Scope is fixed for the session.** If new problems surface mid-session, log them to `plan/BACKLOG.md` — do not expand the current session's scope without explicit user approval.

**Classifying new failures.** When a fix exposes additional failures:

- Same root cause as the current fix → fix it in this session (it is within charter)
- Different root cause → one-line entry in `plan/BACKLOG.md`; continue with the current charter

**Primary failures hide secondary failures.** Corpus error counts are keyed on the *first* failing line per file. A dominant failure mode can mask other bugs in the same file. Fix the primary mode, rerun the corpus check, then re-categorize the remaining errors before drawing conclusions.

**Stop condition.** Charter goal met + `cabal test` passes → stop. Do not pick up the next visible problem.

**`plan/BACKLOG.md`** is the authoritative work queue. The user sets priority order. The assistant only appends — never reorders. Read it at session start to confirm the charter matches the top unfinished item.

---

## The Staged Verification Loop

Scale gates to the size of the change. Trivial changes (typo, rename, single-line fix) may auto-proceed. Non-trivial changes stop at Stage 1 and optionally Stage 3.

### Stage 0 — Read First (always)

Before proposing any change, read every file that will be touched. Use `rg` to locate the relevant section before reading the full file:

```text
rg -n "functionName" src/
rg -l "LogicalLine" src/
```

No change is proposed without a prior read of all relevant modules. Locate callers before modifying a function.

**Diagnosing corpus failures.** When the charter is to reduce corpus errors, sample raw error messages before touching code:

```bash
bash scripts/check-corpus.sh 2>&1 | grep "Files processed"   # get count

# sample 5 error messages from a temporary run:
OUT=$(mktemp -d)
cabal run pb-runner -v0 -- -i example/openpay -o "$OUT" 2>/dev/null
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

**JSON body-statement encoding.** Know these tags before writing corpus sampling scripts — they are not obvious:

| Constructor | JSON `"tag"` | Distinguishing field |
|-------------|--------------|----------------------|
| `BsRaw s` | `"raw"` | `"text"` (source string) |
| `BsCall (ExCall ...)` | `"call"` | `"expr": {"tag":"call_expr", ...}` |
| `BsCall (ExRaw ...)` | `"call"` | `"expr": {"tag":"raw", "tokens":[...]}` |
| `BsAssign lv e` | `"assign"` | `"lhs"`, `"rhs"` |
| `BsReturn` | `"return"` | optional `"expr"` |
| `BsIf` | `"if"` | `"cond"`, `"then"`, `"elseIfs"`, `"else"` |
| `BsFor` | `"for"` | `"var"`, `"from"`, `"to"`, `"step"`, `"body"` |
| `BsDo` | `"do"` | `"cond"`, `"body"`, `"loop"` |
| `BsChoose` | `"choose"` | `"expr"`, `"clauses"` |

`ExRaw` tokens are **text strings** in `"tokens":[...]`, not objects. `BsRaw` has `"text"` (not `"tokens"`). A construct like `create ClassName` or `call super :: event` that has no parse failure will appear as `BsCall {"tag":"call", "expr":{"tag":"raw","tokens":["create","ClassName"]}}` — it is **not** in `BsRaw` unless the classifier explicitly emits one.

To search for unclassified statements starting with a keyword:

```python
def walk_bsraw_leading(node, keyword):
    if isinstance(node, list):
        for x in node: yield from walk_bsraw_leading(x, keyword)
    elif isinstance(node, dict):
        if node.get('tag') == 'raw' and 'text' in node:
            if node['text'].strip().lower().startswith(keyword):
                yield node['text'].strip()
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_bsraw_leading(v, keyword)
```

**Diagnosing implementation debt.** When the charter targets BsRaw or ExRaw reduction, run the debt analyser first — do NOT re-derive the breakdown from scratch:

```bash
python3 scripts/analyze-debt.py --no-build
```

This prints:

- Per-corpus BsRaw category counts (`sql`, `decl`, `ctrl`, `handled`, `other`) — `other` is the actionable BsRaw target; the rest are correct or already handled.
- A ranked ExRaw breakdown by leading token with examples — these are expression-level `ExRaw` fallbacks still to be promoted to typed `Expr` constructors. Use this to pick the highest-value next ExRaw charter.

**Keep `analyze-debt.py` in sync with any new `Expr` constructors.** When a new `ExXxx` constructor is added, confirm the ExRaw count drops correspondingly in the script output — it requires no code changes because it walks the live JSON, but the BACKLOG entry should quote the before/after counts.

**BACKLOG entries for BsRaw work are pre-loaded with Stage 0 analysis.** Each open BsRaw item records: current count, root cause (token kind + guard line), which shapes must stay BsRaw, and the Stage 1 fix sketch. Confirm the counts still match the script output, then proceed directly to Stage 1 — no re-sampling required.

**Confirm hypotheses with a narrow test before Stage 1.** After reading code and forming a theory, write a one-line `testCase` that asserts the correct output and run it. A test that currently fails is worth more than a long analysis. Do not skip this step.

### Stage 1 — Propose

A proposal must name:

- Function signatures being added or changed (with types)
- Test case names (not bodies) and which `testGroup` path they belong to
- Module placement for new code

**Non-trivial changes: stop here and wait for review.**

### Stage 2 — Failing Tests

Write tests first with real assertions expressing the correct behaviour. The tests must fail because the production code is wrong or absent — not because the test itself is a placeholder. Verify:

```text
cabal build --enable-tests   # must compile cleanly
cabal test                   # tests must appear and fail, not error/crash
```

Do not proceed until tests are failing for the right reason.

Use `assertFailure "unimplemented: <reason>"` only when the unit under test does not exist yet and you need a temporary stub in the production code to keep the project compiling. Once the production stub exists, replace the `assertFailure` with a real assertion before Stage 3.

### Stage 3 — Implementation

Write the code. Before proceeding:

```text
cabal build   # must be warning-free; -Wall is set; warnings are blockers
```

**Non-trivial changes: stop here and confirm before running the test suite.**

### Stage 4 — Verify

```text
cabal test --test-show-details=direct
```

All tests must pass. An unexpected failure is a regression — read it before changing anything.

---

## Evidence-Based Triangulation

**No speculative changes.** A change motivated by "might fix" or "should help" rather than a compiler error or a failing test requires explicit justification in the Stage 1 proposal.

Evidence hierarchy (highest to lowest confidence):

1. GHC compiler error with a stack trace
2. Failing test with an assertion message
3. `rg` result showing actual usage
4. Reading the file that contains the relevant code

**Triangulation for parser constructs.** Every new parser needs at least three test shapes:

- Positive: valid input → expected AST
- Negative: invalid input → parse failure (not a crash)
- Property: at least one Hedgehog invariant

---

## Testing Discipline

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

**Table-driven tests.** When 3+ test cases share the same assertion shape, use a list and `mapM_` or a helper — do not repeat identical structure.

**No external snapshot files.** Inline expected values in assertions. Use a locally-defined `Text` literal for multi-line output. Longer term we may loosen this requirement. Make a recommendation if unsure.

**Megaparsec exploration.** Use `parseTest` from `Text.Megaparsec` in the REPL to get human-readable failure output. In tests, use `parse` with `assertBool`/`assertEqual` and a descriptive message.

**Structuring.** Keep test files short and have a master test runner in `test/Main.hs` that imports and aggregates them. Keep PBT and unit tests separate. Don't refer to "phase numbers" or anything like that which has temporal implications, just give everything logical names.

---

## Prelude and Safety Rules

The custom Prelude is in `src/PB/Prelude.hs`. These rules are non-negotiable.

| Rule                 | Detail                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------- |
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
- app/Main.hs should have no functionality other than to call into src/PB/Pipeline/Runner.hs with two arguments 1) input source dir path and 2) output JSON AST tree path
- Accept no hacky solutions or greedy operations that will cause pain down the line: if we can't reliable detect the beginning / end of a regions (e.g., FUNCTION / END FUNCTION), we can't start working on it yet.
- Be creative and comprehensive in generating PBT and pathological unit test cases; PB has lots of issues like `foo()bar()` smashed together ` & // comment`
- Ensure the preprocess step is principled and resilient
- We always strongly type everything we can. E.g., in a DataWindow we will see `..(retrieve="..SQL string", ...)`. Rather than a map of properties, we should have an explicit record type that captures the possible known fields.

---

## Reference Docs

The parser specification is in `reference/SPEC.md` — consult it first for any question about lexical rules, token forms, file structure, or DataWindow syntax. It is synthesized from the battle-tested reference implementation and amended with corrections from the official Appeon docs.

**When the corpus contradicts SPEC.md, the corpus wins.** Real exported files are ground truth. Update SPEC.md to document the discrepancy before or alongside the parser fix — do not silently accept corpus patterns without recording them in the spec.

The official Appeon PowerBuilder 2025 R2 reference docs are in `reference/docs/markdown/` (converted from HTML; content-equivalent but ~30× smaller). Three doc trees:

| Tree | Path | Use for |
| ---- | ---- | ------- |
| PowerScript Reference | `powerscript_reference/` | Language syntax, statements, functions |
| DataWindow Reference | `datawindow_reference/` | DW expression functions, property names |
| Objects and Controls | `objects_and_controls/` | System object properties and type hierarchy |

**Key Language Basics files** (most parser-relevant, consult before implementing a lexer rule):

```text
powerscript_reference/xREF_94732_Comments.md           — // and /* */ comment forms
powerscript_reference/xREF_89555_Statement.md          — & continuation rules + exceptions
powerscript_reference/xREF_20385_Statement.md          — ; statement separation
powerscript_reference/xREF_81473_White_space.md        — dash-in-identifier ambiguity
powerscript_reference/xREF_55923_Identifier_names.md   — identifier character rules
powerscript_reference/xREF_80481_Reserved_words.md     — full reserved word list
powerscript_reference/xREF_87805_Standard_datatypes.md — all primitive types + literal forms
powerscript_reference/xREF_22106_Conditional.md        — #if DEFINED preprocessor
powerscript_reference/xREF_36556_Special_ASCII.md      — ~ escape sequences in strings
```

The individual function/property pages (one file per item) are thin reference stubs useful only for looking up a specific signature — not for understanding syntax or behaviour.

---

## Corpus Coverage Checklist

Every distinct top-level construct found in the 515 non-DataWindow corpus files.
Mark done/pending as body parsers land.

| Construct                                   | File types          | Status  |
|---------------------------------------------|---------------------|---------|
| `forward … end forward`                     | .srw, .sru          | done    |
| `forward prototypes … end prototypes`       | .srw, .sru          | done    |
| `type prototypes … end prototypes`          | .srf, .sru          | done    |
| `prototypes … end prototypes`               | .srf                | done    |
| `global variables … end variables`          | .srw, .sru          | done    |
| `type variables … end variables`            | .srw, .sru          | done    |
| `global type … end type`                    | .srw, .sru          | done    |
| `public function … end function`            | .srw, .sru          | done    |
| `protected subroutine … end subroutine`     | .srw, .sru          | done    |
| `on … end on`                               | .srw, .sru          | done    |
| `event … end event`                         | .srw, .sru          | done    |
| `type … end type` (TypeBlock)               | .srw, .sru          | done    |
| Body: `if … end if`                         | all                 | done    |
| Body: `choose case … end choose`            | all                 | done    |
| Body: `for … next`                          | all                 | done    |
| Body: `do … loop`                           | all                 | done    |
| Body: `try … catch … end try`               | all                 | pending |
| Body: embedded SQL                          | .srw, .sru          | pending |
| Body: assignment / call statements          | all                 | done    |

---

## Module Placement

| Module          | Purpose                                                 |
| --------------- | ------------------------------------------------------- |
| `PB.AST.*`      | Data types only — no parsing logic                      |
| `PB.Lexing.*`   | Tokenization, layout, string mode                       |
| `PB.Grammar.*`  | megaparsec parsers                                      |
| `PB.Pipeline.*` | Multi-step transformations (preprocess, walk, sentinel) |
| `PB.Prelude`    | Custom Prelude — no parsing or transformation logic     |

New modules go in the most specific matching directory. If a new layer is needed, propose it in Stage 1.

---

## Code Index

Maintained here to avoid re-scanning the tree. Update when new exports are added.

### `PB.AST.Expr`

```haskell
data LvSegment = LvSegment { lvsName :: Text, lvsSubscript :: Maybe [Token] }
data Lvalue    = Lvalue    { lvSegments :: [LvSegment] }   -- non-empty

data Literal
  = LitBool Bool | LitInt Text | LitReal Text | LitStr Text
  | LitDate Text | LitTime Text | LitNull

data CallExpr = CallExpr
  { ceCallee :: Lvalue     -- dotted name chain before '('
  , ceArgs   :: [[Token]]  -- each arg as raw tokens (split on ',' at depth 0)
  }

data Expr
  = ExLit    Literal    -- bool / numeric / string / date-time / null
  | ExEnum   Text       -- PowerBuilder enum name (without trailing '!')
  | ExLvalue Lvalue     -- bare ident / member chain / subscript
  | ExCall   CallExpr   -- function or method call
  | ExCreate CreateExpr -- CREATE ClassName / CREATE USING expr
  | ExArray  [Expr]     -- { e1, e2, ... } array literal
  | ExNot     Expr      -- NOT expr (unary boolean negation)
  | ExHostVar Lvalue    -- SQL host variable (:varname or :struct.field)
  | ExRaw     [Token]   -- binary ops, chained calls, or unrecognized
```

### `PB.AST.BodyStmt`

```haskell
data AugOp = AugAdd | AugSub | AugMul | AugDiv

data IfStmt = IfStmt
  { ifCond :: Expr, ifThen :: [BodyStmt]
  , ifElseIfs :: [(Expr, [BodyStmt])], ifElse :: Maybe [BodyStmt] }

data ForStmt = ForStmt
  { forVar :: Lvalue, forFrom :: Expr, forTo :: Expr
  , forStep :: Maybe Expr, forBody :: [BodyStmt] }

data DoCondition = DoWhile Expr | DoUntil Expr

data DoStmt = DoStmt
  { doCond :: Maybe DoCondition, doBody :: [BodyStmt]
  , doLoop :: Maybe DoCondition }

data CaseClause = CaseClause
  { ccExpr :: Maybe [Token]   -- Nothing = "case else"
  , ccBody :: [BodyStmt] }

data ChooseStmt = ChooseStmt
  { chooseExpr :: Expr, chooseClauses :: [CaseClause] }

data BodyStmt
  = BsLocalVar  [Token]               -- Type Name [= init …]
  | BsAssign    Lvalue Expr           -- lhs = rhs
  | BsAugAssign [Token] AugOp [Token] -- lhs_tokens op= rhs_tokens
  | BsInc       [Token]               -- lhs_tokens ++
  | BsDec       [Token]               -- lhs_tokens --
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
  | BsRaw       Statement             -- SQL, event decls, unclassified
```

### `PB.Grammar.Body`

```haskell
classifyBodyStmt :: Statement -> BodyStmt   -- leaf classifier; exit/continue/return/var/assign
parseBodyStmts   :: [Statement] -> [BodyStmt]  -- flat map; use pBodyStmt for recursive parsing
parseLvalue      :: [Token] -> Maybe Lvalue
parseExpr        :: [Token] -> Expr   -- total; ExRaw fallback
parseArrayExpr   :: [Token] -> Maybe Expr  -- { e1, e2, ... } array literal; Nothing if no leading '{'
pBodyStmt        :: FileParser BodyStmt  -- recursive; dispatches to pIfStmt/pForStmt/pDoStmt/pChooseStmt
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
data TypeBlock = TypeBlock { tbDecl :: TypeDecl, tbBody :: [BodyStmt] }
data VarDecl   = VarDecl  { vdModifiers :: [Text], vdType :: Text, vdName :: Text }
data GlobalInstance = GlobalInstance { giType :: Text, giName :: Text }

data FnSig  = FnSig  { fnsMods :: [Text], fnsRetType :: Text, fnsName :: Text, fnsParams :: Text, fnsThrows :: Maybe Text }
data SubSig = SubSig { ssMods  :: [Text], ssName :: Text, ssParams :: Text, ssThrows :: Maybe Text }
data EventSig = EventSig { esName :: Text, esRawSig :: Text }

data FunctionBlock   = FunctionBlock   { fbSig :: FnSig,   fbBody :: [BodyStmt] }
data SubroutineBlock = SubroutineBlock { sbSig :: SubSig,  sbBody :: [BodyStmt] }
data EventBlock      = EventBlock      { evSig :: EventSig, evBody :: [BodyStmt] }
data OnBlock         = OnBlock         { obQualName :: Text, obOwner :: Text, obEvent :: Text, obBody :: [BodyStmt] }
```

### `PB.Grammar.File`

```haskell
parseSrFile      :: [Text] -> [Statement] -> Either Text SrFile
pForwardBlock    :: FileParser ForwardBlock
pPrototypesBlock :: FileParser PrototypesBlock
pVariablesBlock  :: FileParser VariablesBlock
pGlobalInstance  :: FileParser GlobalInstance
pTypeDecl        :: FileParser TypeDecl
pVarDecl         :: FileParser VarDecl
pProtoDecl       :: FileParser ProtoDecl
pEndKw           :: Text -> FileParser ()
pBodyUntil       :: Text -> FileParser [BodyStmt]
pTypeBlock       :: FileParser TypeBlock
pOnBlock         :: FileParser OnBlock
pEventBlock      :: FileParser EventBlock
pFunctionBlock   :: FileParser FunctionBlock
pSubroutineBlock :: FileParser SubroutineBlock
```

### `PB.Grammar.Stream`

```haskell
newtype StmtStream = StmtStream [Statement]
type FileParser = Parsec Void StmtStream

satisfyStmt      :: (Statement -> Bool) -> FileParser Statement
leadingKind      :: TokenKind -> FileParser Statement
leadingText      :: Text -> FileParser Statement
isModifierToken  :: Token -> Bool   -- TkAccessModifier | TkStorageModifier
```

### `PB.Pipeline.Runner`

```haskell
runFile           :: FilePath -> Text -> Either Text Value
collectStatements :: [LexLine] -> Either Text [Statement]
wrapSrFile        :: FilePath -> SrFile -> Value
-- runFile calls fileKind to dispatch on extension: .srd → runDataWindow (stub), _ → runPowerScript
-- runPowerScript: normalizeText → stripHeaders → tokenize → collectStatements → parseSrFile → wrapSrFile
-- wrapSrFile: calls toJSON sf (via Serialise instances), merges "file" and "kind" metadata fields
-- collectStatements filters empty-token statements and surfaces the first LexError as Left Text
-- Note: leOffset in a LexError is always 0 (reports initial position state, not error position).
--       Only llStartLine (leSource e) is meaningful for diagnosis.
```

### `PB.Pipeline.Serialise`

```haskell
-- Orphan ToJSON instances for all PB.AST.* types.
-- Import as: import PB.Pipeline.Serialise ()
-- Brings ToJSON instances into scope; exports nothing explicitly.
-- Sum-type discriminator: "tag" key (string).
-- DoCondition: was "kind" pre-plan-13; now "tag".
```

All other modules are currently stubs (`PB.Pipeline.WalkTree`, `PB.AST.Library`, `PB.AST.Statement`, `PB.AST.Types`, `PB.AST.Workspace`).

---

## Token Efficiency

**Prefer SEARCH/REPLACE over full rewrites.** Use the Edit tool rather than rewriting whole files. Only rewrite when the diff would be larger than the file.

**Use `rg` before reading.** Locate the relevant lines before opening a file. `rg -l` to find which file, `rg -n` to find the line.

---

## Commit Discipline

- One commit per stage (or per logical unit within a stage)
- Commit message: what changed and why, not how
- Do not commit with a warning-dirty `cabal build`
- Failing test stubs (Stage 2) may be committed; mark them clearly with `assertFailure "unimplemented: ..."`
- Before committing parser changes: `bash scripts/check-corpus.sh`
  The error count must not increase. Baseline: 0 errors / 777 files.
- Any new failure categories found during a session must be recorded in `plan/BACKLOG.md` before committing.
