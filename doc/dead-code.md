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
  Source .srw/.sru →│  pb index   │→ DuckDB (procedures, calls, call_edges,
                    │  (import)   │   resolved_calls, dw_controls)
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  get_dead_  │→ list of dead procedure rows
                    │  code()     │
                    └─────────────┘
```

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

The `resolved_calls` table is built by `resolve_calls()` in `type_resolution.py`,
which resolves cross-object targets using type information and the inheritance
chain. Each row has `target_object` and `target_proc` populated.

### Call Edge CTE (`explorer/services/analysis.py`)

The `call_edges` CTE in `_DEAD_CODE_SQL` unions three edge types:

1. **Same-object calls** — `calls` joined to `procedures` where callee lives
   in the same object (matched by `calls.to_name = procedures.name` within the
   same `object`)

2. **Cross-object resolved calls** — `resolved_calls` table, which has
   `target_object` and `target_proc` from the type resolution system

3. **Inheritance override edges** — If procedure `p1` in object `O1` is called,
   and object `O2` inherits from `O1` and overrides the same method name, an
   edge `p1 → p2` is added. This ensures inherited overrides are transitively
   reachable when the parent method is reachable.

## Entry Points

The reachability analysis starts from two seeds:

### Seed 1: Event and On Handlers

```sql
SELECT object, name FROM procedures WHERE proc_type IN ('event', 'on')
```

Every `event … end event` block and every `on … end on` block is
**unconditionally reachable**. The PB framework dispatches these based on:

- **Lifecycle events:** `open`, `close`, `activate`, `deactivate`,
  `constructor`, `destructor`
- **User interaction:** `clicked`, `doubleclicked`, `getfocus`, `losefocus`,
  `rbuttondown`, etc.
- **Custom user events:** `event ue_xxx` — triggered by `POST EVENT ue_xxx` or
  `TRIGGER EVENT ue_xxx`
- **On-blocks:** `on open`, `on close`, etc. — override handlers

This is the correct PB semantic: events are triggered by user actions or
framework callbacks, and on-blocks are override handlers. The analysis must
never mark an event handler as dead.

### Seed 2: DataWindow Compute Controls

```sql
SELECT DISTINCT c.object, c.from_proc
FROM calls c
WHERE c.object IN (SELECT DISTINCT dw_name FROM dw_controls)
```

Any procedure that makes calls within a DataWindow object is reachable, because
DataWindow compute controls execute whenever data is displayed. This seeds all
procedures that contain DW expression calls as entry points.

### Reachability Mechanism

The recursive CTE follows all three edge types from the seeds until fixed point:

```sql
reachable RECURSIVE AS (
    -- Seeds
    SELECT object, name FROM procedures WHERE proc_type IN ('event', 'on')
    UNION
    SELECT DISTINCT c.object, c.from_proc FROM calls c
    WHERE c.object IN (SELECT DISTINCT dw_name FROM dw_controls)
    UNION
    -- Recursive step
    SELECT e.callee_obj, e.callee_proc
    FROM call_edges e
    JOIN reachable r ON r.obj = e.caller_obj AND r.proc = e.caller_proc
)
```

All procedures NOT in the `reachable` set are dead.

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

## Anatomy (openpay corpus, post Plan 99)

```
120 total dead
 ├─  ~50  truly uncalled — caller_count_naive = 0
 │         (none targeted by dynamic/dispatch calls)
 └─  ~70  have naive callers (calls.to_name = p.name somewhere in corpus)
           ├─  ~14  same-object callers — callers are themselves dead (transitive)
           └─  ~56  different-object name collisions only (see §Symbol Scoping)
```

To get the precise breakdown:

```bash
./pb dead-code | awk 'NR>2 && $5==0' | wc -l    # truly uncalled
./pb dead-code | awk 'NR>2 && $5>0 && $6==0' | wc -l  # naive callers, no scoped
./pb dead-code | awk 'NR>2' | wc -l              # total
```

## Known Limitations

### Symbol Scoping

The `call_edges` CTE uses `calls.to_name = procedures.name` for same-object
edges. This is **unscoped** — a call to `of_setmasks` from any object prevents
*every* object that defines `of_setmasks` from appearing as dead, even if those
implementations are never transitively reachable.

The `resolved_calls` table provides scoped resolution, but only for
cross-object calls where the type resolution system can determine the target.
For same-object calls, the unscoped join is the only option.

**Impact:** ~56 of the 120 dead procedures share their name with procedures in
other objects. These are genuinely unreachable via the current analysis, but
the name-collision creates ambiguity.

### Multi-Definition Names

~56 dead procedures share their name with procedures in other objects. When
`_resolve_virtual` sees a call to `of_setmasks` from `w_pbgrid.open`, it
correctly assigns `target_object = w_pbgrid`. But other objects (`w_form`,
`w_form_tab2`, etc.) also define `of_setmasks` without inheriting `w_pbgrid`;
those overrides are never reached.

Without type-annotated call sites, we cannot know which object's implementation
is invoked. The current analysis is correct to leave them dead.

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
create`/`on destroy` calling external ancestors), so the 120 dead count is
accurate for openpay.

**Fix:** Add a `BsPbCall` branch to `walk_calls` that resolves the ancestor
name to the actual ancestor object via the inheritance chain and emits a call
edge. This would require:
1. Handling `BsPbCall` in `walk_calls` (ast_walker.py)
2. Resolving the ancestor name to a target object using the type resolution
   system (type_resolution.py)
3. Adding tests with a corpus that uses `CALL Super::ue_xxx`

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
| `cli/pb_cli/explorer/services/analysis.py` | `get_dead_code()` — reachability CTE |
| `cli/pb_cli/cli.py` | `pb dead-code` CLI command |
| `cli/pb_cli/sql/` | Named SQL queries |
