# Compiler Analysis Subsystem

Architecture reference for `PB.Analysis.*`. This document captures design context that lives in code comments across the analysis modules.

## Categorical Pipeline

The core compilation pipeline converts PB procedure bodies through three intermediate representations:

```
BodyStmt → SSA (SsaProc) → CatOp (categorical IR) → InstrGraph (flat instruction array)
```

- **SSA** (`PB.Analysis.SSA`): Converts `BodyStmt` into block-structured `SsaProc` keyed by CFG block ID. Not classic dominance-based SSA — PB has one mutable runtime slot per variable name, so per-variable version numbering and phi-node placement are unnecessary. `buildSsa` produces unversioned `SsaVar`s; `CatLower` consumes them directly.

- **CatOp** (`PB.Analysis.CatOp`): A categorical combinator GADT implementing `Category`, `Cartesian`, `Cocartesian`, and `Effectful` typeclasses. `CatLower.compileSsa` lowers `SsaProc` into a single `CatOp () ()` term. `GraphBuilder.compileProcedureViaCatOp` flattens it into an `InstrGraph`.

- **InstrGraph** (`PB.Analysis.InstrGraph`): A flat, PC-indexed instruction array consumed by the TS runtime and diagnostic tools.

### Module Organization

The categorical compiler was originally a single 1367-line `CatOp.hs` mixing four stages. It was split into focused modules:

| Module | Role |
|--------|------|
| `CatOp` | Typeclasses, GADT, instances — the categorical IR only |
| `CatLower` | SSA → CatOp compilation (`compileSsa`) |
| `GraphBuilder` | CatOp → InstrGraph flattening + `LowCat` intermediary |
| `CatInterp` | Direct Haskell execution of CatOp terms (testing) |

`CatLower` is the largest stage — it handles loop-nesting, merge-point detection, back-edge classification, and call expression compilation.

### LowCat

`LowCat` is a monomorphic intermediary bridging the GADT-indexed `CatOp` to the flat `InstrGraph`. It exists because `CatOp`'s GADT indexing prevents direct pattern matching without `unsafeCoerce`, and because the `ToJSON` instance for wiring diagrams needs to extract `LTagged` block references without inlining their content (which would reproduce exponential node blowup).

### Semantic-Equivalence Oracle

Two independent backends execute compiled `CatOp` terms:

1. `CatInterp` interprets `CatOp` directly (the `Interp` instance)
2. `InstrInterp` interprets the flattened `InstrGraph` output

Both share `CatEval.evalExprMocked` for expression evaluation, ensuring identical condition/RHS resolution. The oracle (`--dual-trace` mode in `Runner.hs`) compiles a procedure through both backends and diffs the resulting traces byte-for-byte. Any divergence flags a backend-specific bug.

### Merge-Block Memoization

Shared SSA blocks at merge points (e.g. a join block after if/else) must compile once, not once per predecessor. `CatOp` tags merge-point subterms with `CatTagged blockId`. `GraphBuilder.bsBlockPcMemo` maps `(blockId, continuation pc)` to already-allocated PCs, preventing multiplicative node duplication. Without this, procedures with nested if/else inside loops exhibit exponential blowup in compiled instruction count.

### FoldCat Instances

`foldCat` dispatches a `CatOp` term into any `Effectful`/`Cartesian`/`Cocartesian` instance. Known instances:

| Instance | Module | Purpose |
|----------|--------|---------|
| `Interp` | `CatInterp` | Direct execution (testing) |
| `SchFootprint` | `SchFootprint` | Schema footprint extraction |

New instances must give total, law-respecting definitions for all `Effectful` operations. `loopK` must be uniform (same behavior on semantically-equal loop bodies). `ret` must absorb subsequent operations. An instance that makes some operations constant (like `SchFootprint` erasing to a monoid) is a legitimate model.

## Schema Category (`Sch`)

`SchemaCategory` models the database schema as a free category: objects are `(table, column)` pairs and statement instances; morphisms (`SchMorphism`) are "legs" a statement has into columns it reads or writes.

The schema category is built from multiple independent producers converging on a shared `Set SchMorphism` codomain:

```
CatOp --Fps--> Sch <--Fdw-- DwRetrieve
```

- **Fps** (`SchFootprint.foldSchFootprint`): A second `CatOp` fold instance that erases to a monoid — each `CatOp` constructor produces zero or more `SchMorphism`s. Covers dynamic-dispatch writes (e.g. `dw.SetItem(row, "col", value)`) that sqlglot text extraction cannot see.

- **Fdw** (`DwFootprint.dwRetrieveFootprint`): A total, control-flow-free walk over parsed `DwTable` records. Produces `LegWrites` (update-table columns), `LegReads` (WHERE-operand columns), `LegRetrieve` (retrieve column list), and `LegFk` (join FK legs).

Additional producers: sqlglot text extraction (`querySqlCols`), DW JOIN legs (`queryDwJoinLegs`), DDL foreign keys (`ddlFkLegs`), catalog-only column objects.

### LegSource

Every `SchMorphism` carries a `LegSource` tag identifying which analysis technique found that touch: `SrcSqlText`, `SrcCatFootprint`, `SrcDwRetrieve`, `SrcDwJoin`, `SrcDwWhere`, `SrcDdlFk`. This is orthogonal to `StmtId`'s front-end tag (`SqlStmtId` vs `DwRetrieveId`).

### Namespace Resolution

`SchemaCategory.resolveTableRef` resolves unqualified `TableRef`s against a default namespace — only when the DDL catalog actually defines the table there, never guessed. This unifies unqualified SQL/DW-retrieve column references with catalog-qualified `ColumnObj`s.

## Control Hierarchy

`ControlHierarchy` builds a workspace-wide index of PowerBuilder controls and resolves multi-segment dotted chains (e.g. `tab1.page1.uo_epidom.dw`) across file boundaries.

Two declaration conventions govern resolution at each hop:

- **Visual-tree**: a control redeclared `within <literal-parent>` at each nesting level in the same window's own file. Root stays fixed; owner follows the literal parent name.
- **Has-a**: an embedded instance of a different class has its own children declared `within <ClassName>` in that class's own file. Both root and owner switch to the resolved ancestor type.

The index key is `(root, owner, name)` — qualifying by the declaring file's top-level object prevents collisions across unrelated windows that reuse common generic child-control names (e.g. "page1" within "tab1").

## SSA Design Decisions

The SSA module does not compute dominance frontiers or place phi-nodes with version-numbered variables. PB's execution model has one mutable slot per variable name, not per lexical scope. Earlier dominance-based machinery was removed: phi source lists were always empty, version numbers were never read downstream, and phi resolution always compiled to a no-op.

`SsaVar` carries only `svName :: Text` — no version field.
