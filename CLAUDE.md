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

Write tests first. Each stub uses `assertFailure "unimplemented: <reason>"` where `<reason>` matches the Stage 1 proposal item. Verify:

```text
cabal build --enable-tests   # must compile cleanly
cabal test                   # tests must appear and fail, not error/crash
```

Do not proceed until tests are failing for the right reason.

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

**Stub format.** Do not use `undefined` or `error` in test stubs. Use:

```haskell
testCase "some thing" $ assertFailure "unimplemented: continuation across 3+ lines"
```

**HUnit vs Hedgehog:**

- `testCase`: specific named examples, edge cases, regression tests
- `testProperty`: invariants that must hold for all (generated) inputs

**Early Hedgehog invariants** (from README):

- idempotence: `normalize (normalize x) == normalize x`
- monotonicity: `llStartLine <= llEndLine`
- no logical line ends with `&`
- string literal parity preserved

**Table-driven tests.** When 3+ test cases share the same assertion shape, use a list and `mapM_` or a helper — do not repeat identical structure.

**No external snapshot files.** Inline expected values in assertions. Use a locally-defined `Text` literal for multi-line output.

**Megaparsec exploration.** Use `parseTest` from `Text.Megaparsec` in the REPL to get human-readable failure output. In tests, use `parse` with `assertBool`/`assertEqual` and a descriptive message.

---

## Prelude and Safety Rules

The custom Prelude is in `src/PB/Prelude.hs`. These rules are non-negotiable.

| Rule | Detail |
| --- | --- |
| `Text` everywhere | No `String` in exposed APIs; `OverloadedStrings` is set |
| No partial functions | `head`, `tail`, `(!!)`, `fromJust`, `read`, `cycle`, `maximum`, `minimum` are hidden |
| No `undefined` | Hidden from Prelude; use `error "impossible: <reason>"` only when GHC cannot prove totality |
| Text IO | `putStr`/`putStrLn`/`readFile` re-exported from `Data.Text.IO` |

All new modules must start with `import PB.Prelude` under `NoImplicitPrelude` (set in `common-settings` in the cabal file).

`cabal build` must be warning-free. `-Wall` and `-Wincomplete-patterns` are set. Incomplete pattern matches are a hard error.

---

## Module Placement

| Module | Purpose |
| --- | --- |
| `PB.AST.*` | Data types only — no parsing logic |
| `PB.Lexing.*` | Tokenization, layout, string mode |
| `PB.Grammar.*` | megaparsec parsers |
| `PB.Pipeline.*` | Multi-step transformations (preprocess, walk, sentinel) |
| `PB.Prelude` | Custom Prelude — no parsing or transformation logic |

New modules go in the most specific matching directory. If a new layer is needed, propose it in Stage 1.

---

## Code Index

Maintained here to avoid re-scanning the tree. Update when new exports are added.

### `PB.Pipeline.Preprocess`

```haskell
normalizeText :: Text -> [LogicalLine]

data LogicalLine = LogicalLine
  { llText      :: Text
  , llStartLine :: Int
  , llEndLine   :: Int
  }
```

All other modules are currently stubs (`PB.Lexing.*`, `PB.Grammar.*`, `PB.Pipeline.Sentinel`, `PB.Pipeline.WalkTree`, `PB.AST.*`).

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
