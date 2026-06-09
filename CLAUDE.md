# pb-ast — Working Protocol

## Quick Reference

```text
cabal build                           # compile library + executables
cabal build --enable-tests            # compile tests too
cabal test                            # run test suite
cabal test --test-show-details=direct # verbose output
```

## The Staged Verification Loop

Scale gates to the size of the change. Trivial changes (typo, rename, single-line fix) may auto-proceed. Non-trivial changes stop at Stage 1 and optionally Stage 3.

### Stage 0 — Read First (always)

Before proposing any change, read every file that will be touched. Use `rg` to locate the relevant section before reading the full file:

```text
rg -n "functionName" src/
rg -l "LogicalLine" src/
```

No change is proposed without a prior read of all relevant modules. Locate callers before modifying a function.

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
| Body: `if … end if`                         | all                 | pending |
| Body: `choose case … end choose`            | all                 | pending |
| Body: `for … next`                          | all                 | pending |
| Body: `do … loop`                           | all                 | pending |
| Body: `try … catch … end try`               | all                 | pending |
| Body: embedded SQL                          | .srw, .sru          | pending |
| Body: assignment / call statements          | all                 | pending |

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

### `PB.AST.Object`

```haskell
data SrFile = SrFile
  { srHeaders     :: [Text]
  , srForward     :: Maybe ForwardBlock
  , srPrototypes  :: Maybe PrototypesBlock
  , srVariables   :: Maybe VariablesBlock
  , srTypeBlocks  :: [TypeBlock]
  , srOnBlocks    :: [OnBlock]
  , srEvents      :: [EventBlock]
  , srFunctions   :: [FunctionBlock]
  , srSubroutines :: [SubroutineBlock]
  }

data ForwardBlock    = ForwardBlock    { fwdTypes   :: [TypeDecl] }
data PrototypesBlock = PrototypesBlock { protoDecls :: [ProtoDecl] }
data ProtoDecl       = ProtoFn FnSig | ProtoSub SubSig | ProtoEv EventSig

data VariablesBlock = VariablesBlock { varScope :: VarScope, varDecls :: [VarDecl] }
data VarScope       = GlobalVars | TypeVars

data TypeDecl = TypeDecl { tdName :: Text, tdAncestor :: Text, tdWithin :: Maybe Text }
data TypeBlock = TypeBlock { tbDecl :: TypeDecl, tbVarDecls :: [VarDecl] }
data VarDecl   = VarDecl  { vdModifiers :: [Text], vdType :: Text, vdName :: Text }

data FnSig  = FnSig  { fnsMods :: [Text], fnsRetType :: Text, fnsName :: Text, fnsParams :: Text, fnsThrows :: Maybe Text }
data SubSig = SubSig { ssMods  :: [Text], ssName :: Text, ssParams :: Text, ssThrows :: Maybe Text }
data EventSig = EventSig { esName :: Text, esRawSig :: Text }

data FunctionBlock   = FunctionBlock   { fbSig :: FnSig,   fbBody :: [Statement] }
data SubroutineBlock = SubroutineBlock { sbSig :: SubSig,  sbBody :: [Statement] }
data EventBlock      = EventBlock      { evSig :: EventSig, evBody :: [Statement] }
data OnBlock         = OnBlock         { obQualName :: Text, obOwner :: Text, obEvent :: Text, obBody :: [Statement] }
```

### `PB.Grammar.File`

```haskell
parseSrFile      :: [Text] -> [Statement] -> Either Text SrFile
pForwardBlock    :: FileParser ForwardBlock
pPrototypesBlock :: FileParser PrototypesBlock
pVariablesBlock  :: FileParser VariablesBlock
pTypeDecl        :: FileParser TypeDecl
pVarDecl         :: FileParser VarDecl
pProtoDecl       :: FileParser ProtoDecl
pEndKw           :: Text -> FileParser ()
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

satisfyStmt :: (Statement -> Bool) -> FileParser Statement
leadingKind  :: TokenKind -> FileParser Statement
leadingText  :: Text -> FileParser Statement
```

### `PB.Pipeline.Runner`

```haskell
runFile           :: FilePath -> Text -> Either Text Value
collectStatements :: [LexLine] -> Either Text [Statement]
-- runFile dispatches on extension: .srd → runDataWindow (stub), _ → runPowerScript
-- runPowerScript: normalizeText → stripHeaders → tokenize → collectStatements → parseSrFile → encodeSrFile
-- collectStatements filters empty-token statements and surfaces the first LexError as Left Text
```

All other modules are currently stubs (`PB.Pipeline.Sentinel`, `PB.Pipeline.WalkTree`, `PB.AST.Library`, `PB.AST.Script`, `PB.AST.Statement`, `PB.AST.Types`, `PB.AST.Workspace`).

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
  The error count must not increase. Baseline (Plan 10): 493 errors / 777 files;
  22 clean (all `.srs`). All non-`.srs` file types currently fail.
