# Dead Code Analysis

Developer reference for the dead code detection system in `cli/pb_cli/`.

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
  Source .srw/.sru →│  pb index   │→ DuckDB (procedures, calls, resolved_calls,
                    │  (import)   │   inherits, dw_controls)
                    └──────┬──────┘
                           │
                    ┌──────▼──────────────┐
                    │  build_dead_code_   │→ dead_procedures table
                    │  table()            │   (precomputed at import time)
                    └──────┬──────────────┘
                           │
                    ┌──────▼──────┐
                    │  SELECT *   │→ list of dead procedure rows
                    │  FROM dead_ │
                    │  procedures │
                    └─────────────┘
```

The reachability analysis is precomputed at import time by `build_dead_code_table()`
in `shell/dead_code.py`. The results are stored in the `dead_procedures` table.
At query time, `get_dead_code()` simply reads from this table — no recursive CTE
needed.

### Import Pipeline (`core/importing.py`)

The `_import_ps()` function processes each PowerScript file:

1. **Walks the AST** for each procedure block (function, subroutine, event,
   on-block)
2. **Extracts call edges** via `walk_calls(body)` and
   `walk_excall_arg_calls(body)`, emitting `CallRow` entries into the `calls`
   table
3. **Classifies procedures** by key: `functions` → `proc_type = "function"`,
   `events` → `proc_type = "event"`, `onBlocks` → `proc_type = "on"`, etc.

The `_import_dw()` function processes DataWindow `.srd` files:

1. Walks `parsedExpression` and `parsedFormat` AST nodes on each control
2. Emits `CallRow` entries with `object = dw_name` and `from_proc = ctrl_name`

### Call Edge Types

The `calls` table stores raw call edges with these `call_type` values:

| call_type     | Source                                  | What it captures                    |
|---------------|-----------------------------------------|-------------------------------------|
| `ExCall`      | `walk_calls` → `ExCall` nodes           | Bare function calls: `fn_name()`    |
| `ExMethodCall`| `walk_calls` → `ExMethodCall` nodes     | Method calls: `obj.Method()`        |
| `ExDispatch`  | `walk_calls` → `ExDispatch` nodes       | `POST EVENT name` / `TRIGGER EVENT` |
| `ExCallArg`   | `walk_excall_arg_calls`                 | Nested calls inside ExCall arg arrays |

### Call Resolution (`core/type_resolution.py`)

The `resolved_calls` table is built by `resolve_calls()`, which resolves
cross-object targets using type information and the inheritance chain. Each row
has `target_object` and `target_proc` populated when the target can be
determined, or `NULL` when it cannot (e.g., builtin functions, unresolved
dynamic dispatch).

Resolution follows this priority order:

1. **Static dotted** — `object.method()` where `object` is a known procedure
2. **PB builtin** — `len()`, `messagebox()`, etc. from the PB API reference
3. **Inheritance chain** — bare calls walk the caller's ancestor chain via
   `_resolve_virtual()`. PB uses single inheritance with deterministic MRO:
   the nearest ancestor defining the method wins.
4. **Instance variable type** — if the caller has a typed instance variable,
   the method is looked up on that type's ancestor chain
5. **Control type inference** — naming conventions (`dw_` → datawindow,
   `cb_` → commandbutton) infer the PB class for method lookup
6. **Unresolved** — none of the above matched

### Call Graph Construction (`shell/dead_code.py`)

`build_dead_code_table()` constructs the call graph in Python and runs BFS from
entry points. The graph has three edge types:

1. **Same-object calls** — `calls` joined to `procedures` where callee lives
   in the same object (matched by `lower(calls.to_name) = lower(procedures.name)`
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
not in the reachable set is dead. Results are stored in the `dead_procedures` table
at import time — no query-time computation needed.

## Confidence Tiers

Dead procedures are classified by confidence:

| Tier | Condition | Meaning |
|------|-----------|---------|
| **High** | `caller_count_naive = 0` | No callers anywhere in the corpus |
| **Medium** | `caller_count_naive > 0`, `caller_count_scoped = 0` | Has name-collision callers but no scoped (same-object) callers |
| **Low** | `caller_count_scoped > 0` but reachable check failed | Has scoped callers that are themselves dead (transitive dead chain) |

`caller_count_naive` counts distinct `(object, from_proc)` pairs in `calls`
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

However, `walk_calls` in `ast_walker.py` does **not** extract `BsPbCall` as a
call edge. This means ancestor method invocations via `CALL Super` do not
generate entries in the `calls` table.

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
| `cli/pb_cli/core/importing.py` | `_import_ps()`, `_import_dw()` — AST walking, call edge extraction |
| `cli/pb_cli/core/ast_walker.py` | `walk_calls()`, `walk_excall_arg_calls()` — AST traversal |
| `cli/pb_cli/core/type_resolution.py` | `resolve_calls()` — cross-object call resolution |
| `cli/pb_cli/core/dead_code.py` | `compute_dead_procedures()` — BFS reachability (pure, no I/O) |
| `cli/pb_cli/shell/dead_code.py` | `build_dead_code_table()` — DuckDB I/O, populates `dead_procedures` |
| `cli/pb_cli/explorer/services/analysis.py` | `get_dead_code()` — reads from `dead_procedures` table |
| `cli/pb_cli/cli.py` | `pb dead-code` CLI command |

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

| resolution_kind | Count | Meaning |
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
procedures          — one row per procedure (function/subroutine/event/on-block)
  file, object, owner, proc_type, name, modifiers, params, return_type,
  start_line, end_line, body_json, source_rendered, cyclomatic

calls               — raw call edges extracted from AST walking
  file, object, from_proc, to_name, call_type

resolved_calls      — calls with type resolution applied
  file, object, from_proc, to_name, call_type, call_line,
  target_object, target_proc, resolution_kind, confidence, return_type

inherits            — inheritance edges (from_object inherits from to_object)
  from_object, to_object

objects             — one row per PB object (window/userobject/function/menu/...)
  file, name, kind, ancestor, source_text, type_blocks_json

dw_controls         — DataWindow control definitions
  file, dw_name, control_name, control_type, band, x, y, width, height,
  expression, tab_seq, source_line
```

### Investigating Why a Procedure Is Dead

**Step 1: Look up the procedure in the dead_procedures table.**

```sql
SELECT * FROM dead_procedures
WHERE name = '<proc_name>' AND object = '<object_name>';
```

**Step 2: Check for callers (naive — any call by name anywhere).**

```sql
SELECT DISTINCT object, from_proc
FROM calls
WHERE to_name = '<proc_name>';
```

If this returns rows, the procedure has naive callers. They may be calling a
different object's implementation of the same method name (name collision).

**Step 3: Check for scoped callers (resolved to this specific object).**

```sql
SELECT DISTINCT object, from_proc
FROM resolved_calls
WHERE target_object = '<object_name>' AND target_proc = '<proc_name>';
```

If this returns rows, the procedure has scoped callers. If it's still dead,
those callers are themselves unreachable (transitive dead chain).

**Step 4: Check incoming call edges manually.**

```sql
-- Same-object calls (case-insensitive)
SELECT c.object, c.from_proc, c.to_name
FROM calls c
WHERE c.object = '<object_name>'
  AND lower(c.to_name) = lower('<proc_name>');

-- Cross-object resolved calls
SELECT rc.object, rc.from_proc, rc.target_object, rc.target_proc
FROM resolved_calls rc
WHERE rc.target_object = '<object_name>' AND rc.target_proc = '<proc_name>';

-- Override edges (child overrides parent's method)
SELECT p.object, p.name
FROM procedures p
JOIN inherits inh ON inh.to_object = '<object_name>'
WHERE inh.from_object = p.object AND lower(p.name) = lower('<proc_name>');
```

**Step 5: Trace why an edge is missing.**

- **Same-object edge missing?** Check if `calls.to_name` matches
  `procedures.name` — the BFS uses case-insensitive matching.
- **Cross-object edge missing?** Check `resolved_calls` — if `target_object`
  is NULL, the resolver could not determine the target (e.g., builtin
  misclassification).
- **Override edge missing?** Check `inherits` — does any child object inherit
  from this object and override the same method?

### Traversing the Inheritance Chain

**Find what an object inherits from:**

```sql
-- Direct parent
SELECT to_object FROM inherits WHERE from_object = '<object_name>';

-- Full ancestor chain (recursive)
WITH RECURSIVE ancestors(obj, depth) AS (
    SELECT '<object_name>', 0
    UNION ALL
    SELECT i.to_object, a.depth + 1
    FROM ancestors a
    JOIN inherits i ON i.from_object = a.obj
    WHERE a.depth < 20
)
SELECT obj, depth FROM ancestors;
```

**Find all children of an object:**

```sql
WITH RECURSIVE descendants(obj, depth) AS (
    SELECT '<object_name>', 0
    UNION ALL
    SELECT i.from_object, d.depth + 1
    FROM descendants d
    JOIN inherits i ON i.to_object = d.obj
    WHERE d.depth < 20
)
SELECT obj, depth FROM descendants;
```

**Find the full inheritance tree for an object:**

```sql
SELECT i.from_object, i.to_object
FROM inherits i
WHERE i.from_object IN (
    WITH RECURSIVE anc(obj) AS (
        SELECT '<object_name>' UNION ALL SELECT i.to_object FROM anc a JOIN inherits i ON i.from_object = a.obj
    ) SELECT obj FROM anc
)
ORDER BY i.from_object;
```

### Reading body_json

The `body_json` column contains the parsed AST for each procedure as a JSON
array. Each element is a `Located BodyStmt`:

```json
{"line": 46, "node": {"tag": "BsLocalVar", "name": "ls_where", ...}}
```

**Key tags and their shapes:**

| Tag | Shape | Meaning |
|-----|-------|---------|
| `BsLocalVar` | `{tag, name, type, mods, init}` | Local variable declaration |
| `BsAssign` | `{tag, contents: [lhs, rhs]}` | Assignment statement |
| `BsCall` | `{tag, contents: {tag, callee, args}}` | Standalone call |
| `BsIf` | `{tag, contents: {cond, then, elseIfs, else}}` | If/else-if/else |
| `BsFor` | `{tag, contents: {var, from, to, step, body}}` | For loop |
| `BsDo` | `{tag, contents: {cond?, body, loop?}}` | Do/loop |
| `BsReturn` | `{tag, contents: expr?}` | Return statement |
| `BsRaw` | `{tag, contents: {text}}` | Unclassified (SQL, etc.) |
| `ExCall` | `{tag, callee, args}` | Function call expression |
| `ExMethodCall` | `{tag, contents: {tag, receiver, method, args}}` | Method call |
| `ExBinOp` | `{tag, contents: {lhs, op, rhs}}` | Binary operator |
| `ExLvalue` | `{tag, contents: {segments: [{name, subscript?}]}}` | Variable reference |

Or more practically, use `source_rendered` for human-readable debugging:

```sql
SELECT source_rendered FROM procedures
WHERE object = '<object_name>' AND name = '<proc_name>';
```

### Common Investigation Patterns

**"Is this object ever opened/instantiated?"**

```sql
SELECT DISTINCT object, from_proc, to_name
FROM calls
WHERE lower(to_name) = lower('<object_name>');
```

**"What does this object inherit and what does it override?"**

```sql
SELECT p.name AS method_name
FROM procedures p
JOIN inherits i ON i.from_object = p.object
WHERE i.to_object = '<object_name>'
  AND EXISTS (
      SELECT 1 FROM procedures p2
      WHERE p2.object = '<object_name>' AND p2.name = p.name
  );
```

**"Which objects define method X?"**

```sql
SELECT object, proc_type, start_line, end_line
FROM procedures
WHERE name = '<method_name>'
ORDER BY object;
```

**"What are all the methods in an object?"**

```sql
SELECT name, proc_type, start_line, end_line, cyclomatic
FROM procedures
WHERE object = '<object_name>'
ORDER BY start_line;
```

**"Show the full call chain from an entry point."**

```sql
WITH RECURSIVE
call_edges(caller_obj, caller_proc, callee_obj, callee_proc) AS (
    SELECT c.object, c.from_proc, p2.object, p2.name
    FROM calls c
    JOIN procedures p2 ON p2.object = c.object AND lower(p2.name) = lower(c.to_name)
    UNION ALL
    SELECT rc.object, rc.from_proc, rc.target_object, rc.target_proc
    FROM resolved_calls rc
    WHERE rc.target_object IS NOT NULL AND rc.target_proc IS NOT NULL
    UNION ALL
    SELECT p1.object, p1.name, p2.object, p2.name
    FROM procedures p1
    JOIN inherits inh ON inh.to_object = p1.object
    JOIN procedures p2 ON p2.object = inh.from_object AND p2.name = p1.name
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
SELECT name, proc_type, confidence, caller_count_naive, caller_count_scoped
FROM dead_procedures
WHERE object = '<object_name>';
```

**"What DW controls exist for a DataWindow?"**

```sql
SELECT control_name, control_type, band, expression
FROM dw_controls
WHERE dw_name = '<dw_name>'
ORDER BY tab_seq;
```
