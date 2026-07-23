# Dead Code Analysis

Developer reference for the dead code detection system (Haskell `Analysis.DeadCodeReachability`).

## Overview

Dead code analysis determines which procedures (functions, subroutines, event
handlers, on-blocks) in a PowerBuilder application are **unreachable** — no
execution path leads from any entry point to that procedure. The analysis runs
over the DuckDB database populated by `./pb index` and is exposed via:

- **CLI:** `./pb dead-code` — prints a table of dead procedures
- **API:** `GET /analysis/dead-code` — returns JSON for the explorer UI

## Architecture

```
                    ┌─────────────┐
  Source .srw/.sru →│  pb index   │→ DuckDB (procedures, call_sites, resolved_calls,
                    │  (import)   │   objects, dw_controls)
                    └──────┬──────┘
                           │
                    ┌──────▼──────────────┐
                    │  materializeDeadCode │→ dead_code table
                    │  (Phase B)           │   (precomputed at import time)
                    └──────┬──────────────┘
                           │
                    ┌──────▼──────┐
                    │  SELECT *   │→ list of dead procedure rows
                    │  FROM dead_ │
                    │  code       │
                    └─────────────┘
```

The reachability analysis is precomputed at import time by `materializeDeadCode`
in `PB.Pipeline.DuckDb.Materialize`. The results are stored in the `dead_code` table.
At query time, `get_dead_code()` simply reads from this table — no recursive CTE
needed.

### Import Pipeline (Phase A)

The Haskell pipeline compiles each PowerBuilder source file through Phase A
(`PB.Pipeline.Runner.compileOne`), which:

1. **Walks the AST** for each procedure block (function, subroutine, event,
   on-block) and extracts call edges into the `call_sites` table
2. **Processes DataWindow `.srd` files**, walking `parsedExpression` and
   `parsedFormat` AST nodes on each control and emitting call edges with
   the DW object as `object` and the control name as `proc_name`

### Call Edge Types

The `call_sites` table stores raw call edges with these `call_type` values:

| call_type     | Source                                  | What it captures                    |
|---------------|-----------------------------------------|-------------------------------------|
| `ExCall`      | `PB.Compile.EffTerm` → `ExCall` nodes   | Bare function calls: `fn_name()`    |
| `ExMethodCall`| `PB.Compile.EffTerm` → `ExMethodCall` nodes | Method calls: `obj.Method()`    |
| `ExDispatch`  | `PB.Compile.EffTerm` → `ExDispatch` nodes | `POST EVENT name` / `TRIGGER EVENT` |
| `ExCallArg`   | nested calls inside `ExCall` arg arrays | Nested calls inside ExCall arg arrays |

### Call Resolution (`PB.Analysis.TypeResolve`)

The `resolved_calls` table is built by the type resolution pass, which resolves
cross-object targets using type information and the inheritance chain. Each row
has `target_object` and `target_proc` populated when the target can be
determined, or `NULL` when it cannot (e.g., builtin functions, unresolved
dynamic dispatch).

Resolution follows this priority order:

1. **Static dotted** — `object.method()` where `object` is a known procedure
2. **PB builtin** — `len()`, `messagebox()`, etc. from the PB API reference
3. **Inheritance chain** — bare calls walk the caller's ancestor chain via
   the MRO: the nearest ancestor defining the method wins.
4. **Instance variable type** — if the caller has a typed instance variable,
   the method is looked up on that type's ancestor chain
5. **Control type inference** — naming conventions (`dw_` → datawindow,
   `cb_` → commandbutton) infer the PB class for method lookup
6. **Unresolved** — none of the above matched

### Call Graph Construction (`PB.Analysis.DeadCodeReachability`)

`PB.Analysis.DeadCodeReachability` constructs the call graph and runs BFS from
entry points. The graph has three edge types:

1. **Same-object calls** — `call_sites` joined to `procedures` where callee lives
   in the same object (matched by `lower(call_sites.to_name) = lower(procedures.proc_name)`
   within the same `object`).

2. **Cross-object resolved calls** — `resolved_calls` table, which has
   `target_object` and `target_proc` from the type resolution system

3. **Inheritance override edges** — If procedure `p1` in parent object `P` is
   called, and child object `C` inherits from `P` and overrides the same method
   name, an edge `p1 → p2` is added. This ensures inherited overrides are
   transitively reachable when the parent method is reachable.

## Entry Points

The reachability analysis starts from two seeds:

### Seed 1: Event and On Handlers

Every `event … end event` block and every `on … end on` block is
**unconditionally reachable**. The PB framework dispatches these based on:

- **Lifecycle events:** `open`, `close`, `activate`, `deactivate`,
  `constructor`, `destructor`
- **User interaction:** `clicked`, `doubleclicked`, `getfocus`, `losefocus`,
  `rbuttondown`, etc.
- **Custom user events:** `event ue_xxx` — triggered by `POST EVENT ue_xxx` or
  `TRIGGER EVENT ue_xxx`
- **On-blocks:** `on open`, `on close`, etc. — override handlers

### Seed 2: DataWindow Compute Controls

Any procedure that makes calls within a DataWindow object is reachable, because
DataWindow compute controls execute whenever data is displayed. This seeds all
procedures that contain DW expression calls as entry points.

### Reachability Mechanism

BFS follows all three edge types from the seeds until fixed point. Any procedure
not in the reachable set is dead. Results are stored in the `dead_code` table
at import time — no query-time computation needed.

## Confidence Tiers

Dead procedures are classified by confidence:

| Tier | Condition | Meaning |
|------|-----------|---------|
| **High** | `caller_count_naive = 0` | No callers anywhere in the corpus |
| **Medium** | `caller_count_naive > 0`, `caller_count_scoped = 0` | Has name-collision callers but no scoped (same-object) callers |
| **Low** | `caller_count_scoped > 0` but reachable check failed | Has scoped callers that are themselves dead (transitive dead chain) |

`caller_count_naive` counts distinct `(object, proc_name)` pairs in `call_sites`
that call this procedure by name (unscoped, cross-object name match).
`caller_count_scoped` counts entries in `resolved_calls` that specifically
target this `(object, name)` pair.

## Known Limitations

### Wizard Framework Dynamic Dispatch

The PB wizard framework (`w_wizmain` and subclasses) registers step objects via
`addstep("step_name", label)`. The framework then dynamically invokes
`of_next`, `of_stepadded`, and `of_postactivate` on each step at runtime. This
dispatch is string-based and cannot be traced by static analysis.

**Impact:** 19 step callback procedures (across `bcv_step`, `step1_seasons`,
`step_kratapod_*`, and `wiz_misth_final_details_step{2,3,4}`) are falsely
marked dead. All inherit from `bcv_step`.

### `CALL Super :: event` (BsPbCall)

The parser produces `BsPbCall` nodes for `CALL ancestor :: event` statements:
```json
{"tag": "BsPbCall", "contents": {"ancestor": "super", "event": "create"}}
```

However, the call extraction pass does **not** extract `BsPbCall` as a
call edge. This means ancestor method invocations via `CALL Super` do not
generate entries in the `call_sites` table.

**Impact:** Ancestor implementations called via `CALL Super::ue_xxx` would
appear dead when they are actually reachable. The current openpay corpus does
not use this pattern for user-defined methods (only boilerplate `on
create`/`on destroy` calling external ancestors), so the dead count is
accurate for openpay.

### Dynamic Dispatch

`POST EVENT` / `TRIGGER EVENT` with string event names are captured as
`ExDispatch` call edges, but the target object is not always resolvable. When
the event name is a constant, it can be resolved at analysis time. When it is a
variable, it must be marked as "dynamic dispatch" — potentially reaching any
object that defines that event.

### PostEvent / TriggerEvent Functions

`object.PostEvent("ue_xxx")` and `object.TriggerEvent("ue_xxx")` are captured
as `ExMethodCall` edges. The target event is the method name, but the actual
dispatch depends on the runtime object type of `object`, which may not be
resolvable statically.

## Relevant Files

| File | Purpose |
|------|---------|
| `compiler/src/PB/Analysis/DeadCodeReachability.hs` | BFS reachability analysis (pure, Haskell) |
| `compiler/src/PB/Pipeline/Passes.hs` | `runPhaseB` — orchestrates dead code analysis in Phase B |
| `compiler/src/PB/Pipeline/DuckDb/Materialize.hs` | `materializeDeadCode` — writes results to DuckDB |
| `cli/api/src/pb/api/services/analysis.py` | `get_dead_code()` — reads from `dead_code` table |
| `cli/pipeline/src/pb/pipeline/cli.py` | `pb dead-code` CLI command |

---

## Appendix A — Openpay Corpus Baseline

Stats from the openpay-0.1.1b corpus (422 objects, 2649 procedures, 5375 call
edges, 287 inheritance edges, 1688 DW controls).

### Dead Code Summary

```
101 total dead procedures
 ├─  47  high confidence (caller_count_naive = 0)
 │        Zero callers anywhere in the corpus. All confirmed truly dead.
 │
 ├─  38  medium confidence (caller_count_naive > 0, scoped = 0)
 │        ├─  19  wizard framework dynamic dispatch (false positive)
 │        └─  19  confirmed dead (name-collision or transitive dead)
 │
 └─  16  low confidence (scoped > 0 but unreachable)
           Callers are themselves dead (transitive dead chain).
```

### Per-Confidence True Dead

| Confidence | Total | False Positives | True Dead |
|------------|-------|-----------------|-----------|
| High       | 47    | 0               | 47        |
| Medium     | 38    | 19              | 19        |
| Low        | 16    | 0               | 16        |
| **Total**  | **101** | **19**        | **82**    |

### Resolution Quality

| `kind` (SQL column) | Count | Meaning |
|-----------------|-------|---------|
| `builtin`       | 2526  | PB built-in function (len, string, messagebox, ...) |
| `virtual`       | 2291  | Resolved to a specific object via type info / inheritance |
| `unresolved`    | 523   | Could not determine target (dynamic dispatch, etc.) |
| `inherited`     | 35    | Resolved via inheritance chain |

### Notable True Dead Procedures

| Procedure | CC | Outgoing | Notes |
|-----------|-----|----------|-------|
| `fn_dateolografos.fn_dateolografos` | 12 | 89 | 321-line function, 0 callers — likely legacy |
| `fn_createodbc_access.fn_createodbc_access` | 1 | 12 | ODBC setup, 0 callers — likely unused config |
| `gsc_col_reset.gsc_col_reset` | 1 | 26 | Column reset helper, 0 callers |
| `fn_toupper.fn_toupper` | 1 | 13 | Greek uppercase converter, 0 callers |
| `fn_num2str.fn_num2str` | 5 | 3 | Number-to-string, 0 callers |
| `w_wizmain.getsteppos` | 3 | 0 | Wizard step position, 0 callers |
| `fn_test.fn_test` | 1 | 1 | Test function, 0 callers — intentional dead code |

### Naming Patterns in Dead Code

| Pattern | Count | Example | Notes |
|---------|-------|---------|-------|
| `fn_param_*` | 15 | `fn_param_afm` | Global parameter accessors — 0 callers each |
| `of_setmasks` | 5 | `w_krat_total_search.of_setmasks` | Name collision — callers resolve to other implementations |
| `of_open` | 7 | `wprn_report.of_open` | Print window setup — internal chains dead |
| `of_next`/`of_stepadded`/`of_postactivate` | 19 | `bcv_step.of_next` | Wizard callbacks — dynamic dispatch false positives |

---

## Appendix B — Query Patterns

### Schema Quick Reference

```
objects             — one row per PB object (window/userobject/function/menu/...)
  file, kind, object, ancestor, layout_json, type_blocks_json, confidence

procedures          — one row per procedure (function/subroutine/event/on-block)
  file, object, proc_name, proc_type, start_line, end_line,
  cfg_json, instr_graph_json, wiring_json, params, param_names,
  return_type, cyclomatic, confidence

call_sites          — raw call edges extracted from AST walking
  file, object, proc_name, to_name, call_type, line, receiver_object,
  to_name_start_line, to_name_start_col, to_name_end_line, to_name_end_col

resolved_calls      — calls with type resolution applied
  file, object, proc_name, to_name, call_type, line,
  target_object, target_proc, kind, confidence,
  to_name_start_line, to_name_start_col, to_name_end_line, to_name_end_col

dw_controls         — DataWindow control definitions
  file, object, band, control_type, name, x, y, width, height, expression

dead_code           — dead procedure analysis results
  object, proc_name, proc_type, cyclomatic, confidence,
  caller_count_naive, caller_count_scoped
```

### Investigating Why a Procedure Is Dead

**Step 1: Look up the procedure in the dead_code table.**

```sql
SELECT * FROM dead_code
WHERE proc_name = '<proc_name>' AND object = '<object_name>';
```

**Step 2: Check for callers (naive — any call by name anywhere).**

```sql
SELECT DISTINCT object, proc_name
FROM call_sites
WHERE to_name = '<proc_name>';
```

If this returns rows, the procedure has naive callers. They may be calling a
different object's implementation of the same method name (name collision).

**Step 3: Check for scoped callers (resolved to this specific object).**

```sql
SELECT DISTINCT object, proc_name
FROM resolved_calls
WHERE target_object = '<object_name>' AND target_proc = '<proc_name>';
```

If this returns rows, the procedure has scoped callers. If it's still dead,
those callers are themselves unreachable (transitive dead chain).

**Step 4: Check incoming call edges manually.**

```sql
-- Same-object calls (case-insensitive)
SELECT c.object, c.proc_name, c.to_name
FROM call_sites c
WHERE c.object = '<object_name>'
  AND lower(c.to_name) = lower('<proc_name>');

-- Cross-object resolved calls
SELECT rc.object, rc.proc_name, rc.target_object, rc.target_proc
FROM resolved_calls rc
WHERE rc.target_object = '<object_name>' AND rc.target_proc = '<proc_name>';

-- Override edges (child overrides parent's method)
SELECT p.object, p.proc_name
FROM procedures p
WHERE p.object IN (
    SELECT o.object FROM objects o
    WHERE o.ancestor = '<object_name>'
)
  AND lower(p.proc_name) = lower('<proc_name>');
```

**Step 5: Trace why an edge is missing.**

- **Same-object edge missing?** Check if `call_sites.to_name` matches
  `procedures.proc_name` — the BFS uses case-insensitive matching.
- **Cross-object edge missing?** Check `resolved_calls` — if `target_object`
  is NULL, the resolver could not determine the target (e.g., builtin
  misclassification).
- **Override edge missing?** Check `objects.ancestor` — does any child object
  inherit from this object and override the same method?

### Traversing the Inheritance Chain

Inheritance is stored as `objects.ancestor` — one column, not a separate table.

**Find what an object inherits from:**

```sql
-- Direct parent
SELECT ancestor FROM objects WHERE object = '<object_name>';

-- Full ancestor chain (recursive)
WITH RECURSIVE ancestors(obj, depth) AS (
    SELECT '<object_name>', 0
    UNION ALL
    SELECT o.ancestor, a.depth + 1
    FROM ancestors a
    JOIN objects o ON o.object = a.obj
    WHERE o.ancestor IS NOT NULL AND a.depth < 20
)
SELECT obj, depth FROM ancestors;
```

**Find all children of an object:**

```sql
WITH RECURSIVE descendants(obj, depth) AS (
    SELECT '<object_name>', 0
    UNION ALL
    SELECT o.object, d.depth + 1
    FROM descendants d
    JOIN objects o ON o.ancestor = d.obj
    WHERE d.depth < 20
)
SELECT obj, depth FROM descendants;
```

**Find the full inheritance tree for an object:**

```sql
WITH RECURSIVE anc(obj) AS (
    SELECT '<object_name>'
    UNION ALL
    SELECT o.ancestor FROM anc a JOIN objects o ON o.object = a.obj
    WHERE o.ancestor IS NOT NULL
)
SELECT o.object, o.ancestor
FROM objects o
WHERE o.object IN (SELECT obj FROM anc)
ORDER BY o.object;
```

### Reading instr_graph_json

The `instr_graph_json` column contains a flattened instruction graph (CFG) for
each procedure. The top-level shape is an `InstrGraph`:

```json
{
  "nodes": [ ... ],
  "entry": 0,
  "suspensionPoints": [2, 8],
  "sourceMap": [[0, 46], [1, 47], ...]
}
```

Each element in `nodes` is an `InstrNode` — a single flat instruction. Nodes
reference each other by integer PC index (array-backed CFG, not nested closures).

**Node tags and their fields:**

| Tag | Key fields | Meaning |
|-----|-----------|---------|
| `InstrAssign` | `var`, `rhs`, `next` | Assignment: `var = rhs` → fall through to `next` |
| `InstrBranch` | `cond`, `thenPc`, `elsePc` | Conditional: if `cond` → `thenPc`, else → `elsePc` |
| `InstrGoto` | `target` | Unconditional jump to `target` |
| `InstrCall` | `callee`, `args`, `result?`, `next` | Builtin/library function call → `next` |
| `InstrCallProc` | `callee`, `args`, `next` | User-defined procedure call → `next` |
| `InstrSuspend` | `effect`, `args`, `var?`, `continuation` | Effectful operation (SQL, DW retrieve) → resume at `continuation` |
| `InstrReturn` | `value?` | Return from procedure (terminal) |
| `InstrNop` | `next` | No-op → fall through to `next` |

Field names in JSON are produced by `stripCamelCasePrefix` (e.g. `anVar` → `var`,
`brThenPc` → `thenPc`, `suContinuation` → `continuation`). The Explore UI's
TypeScript loader further renames `thenPc` → `then_` and `elsePc` → `else_`
to avoid keyword collisions.

Or more practically, use `instr_graph_json` for human-readable debugging
(via the Explore UI, or directly for JSON inspection):

```sql
SELECT instr_graph_json FROM procedures
WHERE object = '<object_name>' AND proc_name = '<proc_name>';
```

### Common Investigation Patterns

**"Is this object ever opened/instantiated?"**

```sql
SELECT DISTINCT object, proc_name, to_name
FROM call_sites
WHERE lower(to_name) = lower('<object_name>');
```

**"What does this object inherit and what does it override?"**

```sql
SELECT p.proc_name AS method_name
FROM procedures p
WHERE p.object IN (
    SELECT o.object FROM objects o WHERE o.ancestor = '<object_name>'
)
  AND EXISTS (
      SELECT 1 FROM procedures p2
      WHERE p2.object = '<object_name>' AND p2.proc_name = p.proc_name
  );
```

**"Which objects define method X?"**

```sql
SELECT object, proc_type, start_line, end_line
FROM procedures
WHERE proc_name = '<method_name>'
ORDER BY object;
```

**"What are all the methods in an object?"**

```sql
SELECT proc_name, proc_type, start_line, end_line, cyclomatic
FROM procedures
WHERE object = '<object_name>'
ORDER BY start_line;
```

**"Show the full call chain from an entry point."**

```sql
WITH RECURSIVE
call_edges(caller_obj, caller_proc, callee_obj, callee_proc) AS (
    SELECT c.object, c.proc_name, p2.object, p2.proc_name
    FROM call_sites c
    JOIN procedures p2 ON p2.object = c.object AND lower(p2.proc_name) = lower(c.to_name)
    UNION ALL
    SELECT rc.object, rc.proc_name, rc.target_object, rc.target_proc
    FROM resolved_calls rc
    WHERE rc.target_object IS NOT NULL AND rc.target_proc IS NOT NULL
    UNION ALL
    SELECT p1.object, p1.proc_name, o.object, p2.proc_name
    FROM procedures p1
    JOIN objects o ON o.ancestor = p1.object
    JOIN procedures p2 ON p2.object = o.object AND p2.proc_name = p1.proc_name
),
trace(caller_obj, caller_proc, callee_obj, callee_proc, depth) AS (
    SELECT caller_obj, caller_proc, callee_obj, callee_proc, 1
    FROM call_edges
    WHERE caller_obj = '<entry_object>' AND caller_proc = '<entry_method>'
    UNION ALL
    SELECT ce.caller_obj, ce.caller_proc, ce.callee_obj, ce.callee_proc, t.depth + 1
    FROM call_edges ce
    JOIN trace t ON t.callee_obj = ce.caller_obj AND t.callee_proc = ce.caller_proc
    WHERE t.depth < 10
)
SELECT DISTINCT caller_obj || '.' || caller_proc AS caller,
       callee_obj || '.' || callee_proc AS callee,
       depth
FROM trace
ORDER BY depth, caller, callee;
```

**"List all dead procedures in an object."**

```sql
SELECT proc_name, proc_type, confidence, caller_count_naive, caller_count_scoped
FROM dead_code
WHERE object = '<object_name>';
```

**"What DW controls exist for a DataWindow?"**

```sql
SELECT name, control_type, band, expression
FROM dw_controls
WHERE object = '<dw_name>'
ORDER BY name;
```
