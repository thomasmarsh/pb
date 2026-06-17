# Bombadil PBT — Reference and Session Guide

Bombadil is a temporal-logic property-based testing framework for web UIs.
It drives a real Chromium browser, extracts DOM state after each action,
checks all exported `Formula` values, and continues until it finds a
violation or the time limit expires.

The spec lives at `ui/bombadil-spec.ts`. Sessions are tracked in
`doc/plan/76` through `doc/plan/80`. The backlog entry is in the
`Track BOM` section of `doc/plan/BACKLOG.md`.

---

## Running Bombadil

### Prerequisites

The FastAPI backend must be running before Bombadil starts:

```bash
cd cli && uv run pb explore        # starts on http://localhost:8000
```

### Scripts (from `ui/package.json`)

```bash
pnpm bombadil          # exit-on-violation, 5m, writes to /tmp/bombadil-pb/
pnpm bombadil:long     # no early exit, 5m, same output dir
```

`bombadil` is the default; use it for iterative development — it stops immediately
when a violation is found so you see the first failure fast.
`bombadil:long` is for coverage surveys — it runs the full 5 minutes and records
every action, letting you see action distribution even when there are no violations.

### Running in the background (recommended for Claude sessions)

A 5-minute run ties up the foreground context for the full duration. The cleaner
approach is to launch with `run_in_background=true` and tee output to a log file:

```bash
cd ui && pnpm bombadil 2>&1 | tee /tmp/pb-bombadil-run.log
```

When the background process completes, Claude is notified and can read:

```bash
tail -50 /tmp/pb-bombadil-run.log          # summary + violation messages
ls -la /tmp/bombadil-pb/                   # output directory
```

If a violation was found, the output directory contains:

- `trace.jsonl` — every action taken, one JSON object per line
- `screenshot-*.png` — browser state at the moment of violation

### Extracting the action sequence before a violation

```bash
# Last 20 actions before the run ended:
tail -20 /tmp/bombadil-pb/trace.jsonl | jq -r '.action // "check"'

# Find which property violated:
grep '"violation"' /tmp/bombadil-pb/trace.jsonl | head -5 | jq .
```

### Action distribution (coverage survey, after a long run)

```bash
jq -r 'select(.action != null) | .action | if type == "string" then . else keys[0] end' \
  /tmp/bombadil-pb/trace.jsonl | sort | uniq -c | sort -rn | head -20
```

Note: actions from the `defaults` re-export (`Back`, `Forward`, `Reload`, `Wait`) are bare
strings in the trace, not objects — the `if type == "string"` branch handles them.

**B1 observed distribution (5m headed run, 2026-06-17):**
Click 4612, TypeText 379, ScrollDown 158, PressKey 9, ScrollUp 3,
plus Back/Reload/Forward/Wait from defaults (counted separately as bare strings).

**B2 observed distribution (5m headless run, 2026-06-17):**
Click 930, Back 144, Forward 131, ScrollDown 128, ScrollUp 113, TypeText 83.
No PressKey — `export *` from defaults replaced with selective import; `clearSearch` unexported.
`--output-path-overwrite` flag removed from package.json (dropped in Bombadil 0.6.0).

---

## Trace Output Skill

After completing BOM-B2 (Plans 76–77), evaluate whether a `bombadil-trace`
skill is worth writing. The skill would:

1. Read `/tmp/pb-bombadil-run.log` and `/tmp/bombadil-pb/trace.jsonl`
2. Extract: which property violated, the N actions before the violation,
   and the action distribution for the full run
3. Summarize in a structured report the LLM can act on without reading raw JSONL

Decision criteria: if interpreting the raw trace file consistently takes more
than 2–3 minutes per session, the skill earns its cost. If the console log
already supplies enough information, skip it.

**B1 evaluation (2026-06-17):** The console log tail was sufficient for all three
violations found in B1 — the property name, extractor values, and timestamp were
printed directly in the log. The JSONL trace was not consulted. Defer to B2.

---

## Spec Structure

`ui/bombadil-spec.ts` exports:

| Export type                           | Purpose                                               |
| ------------------------------------- | ----------------------------------------------------- |
| `Formula` (named export)              | Property checked at each state                        |
| `Actions` (named export)              | Generator returning a list of browser actions         |
| `* from defaults` (re-export line 27) | `noUncaughtExceptions`, standard click/reload actions |

Bombadil picks actions from the exported generators on each step. Weighted
generators bias exploration toward navigation-heavy paths.

---

## Selector Conventions

DOM selectors used in the spec. Update this table as sessions confirm or
correct each entry.

| Purpose              | Selector                                | Status            |
| -------------------- | --------------------------------------- | ----------------- |
| Sidebar nav links    | `.sidebar-nav a`                        | ✅ validated      |
| Active nav link      | `.sidebar-nav a.active`                 | ✅ validated      |
| Main content area    | `.main-content`                         | ✅ validated      |
| Back buttons         | `.back-btn`                             | ✅ validated (B1) |
| Loading spinners     | `.loading, [class*=spinner]`            | ✅ validated      |
| Search inputs        | `input.search-input:not([type=number])` | ✅ validated      |
| Clickable table rows | `tr.clickable`                          | ✅ validated      |
| Table chips          | `.table-chip`                           | ✅ validated      |
| Explore tree nodes   | `.tree-node-row.clickable`              | ✅ validated      |
| All buttons          | `button`                                | ✅ validated      |
| Sidebar header       | `.sidebar-header h1`                    | ✅ validated      |
| Query run buttons    | `button[data-query]`                    | ✅ validated      |
| Theme class          | `document.documentElement[data-theme]`  | ✅ validated (B1) |
| Error panel          | TBD — confirm in BOM-B3                 | ⬜ pending        |
| Success detail panel | TBD — confirm in BOM-B3                 | ⬜ pending        |
| Sortable headers     | `th.sortable, th[data-sort]`            | ⬜ no elements yet (B2: no `<th>` in UI) |
| Pagination buttons   | `.pagination button, button[data-page]` | ⬜ no elements yet (B2: no pagination in UI) |
| Detail heading       | TBD — confirm in BOM-B3                 | ⬜ pending        |
| Explore active tab   | TBD — confirm in BOM-B5                 | ⬜ pending        |

---

## Property Inventory

### Currently in spec (as of 2026-06-17)

| Property                            | Category        | Status                                                  |
| ----------------------------------- | --------------- | ------------------------------------------------------- |
| `pathnameAlwaysWellFormed`          | URL coherence   | ✅ validated                                            |
| `pathnameNeverTrailingSlash`        | URL coherence   | ✅ validated                                            |
| `sidebarHasCorrectCount`            | Structural      | ✅ validated                                            |
| `sidebarHasAllLabels`               | Structural      | ✅ validated                                            |
| `sidebarOrderIsStable`              | Structural      | ✅ validated                                            |
| `sidebarHeaderVisible`              | Structural      | ✅ validated                                            |
| `exactlyOneActiveLink`              | State coherence | ✅ validated                                            |
| `activeLinkMatchesRoute`            | State coherence | ✅ validated                                            |
| `mainContentNeverEmpty`             | View safety     | ✅ validated                                            |
| `noStaleLoadingIndicator`           | Loading safety  | ✅ validated                                            |
| `backButtonsAreClickable`           | Navigation      | ✅ validated (B1 — viewport-bounds `visible` fix)       |
| `noUncaughtExceptions`              | Crash safety    | ✅ validated (from defaults)                            |
| `searchInputsAreInteractive`        | Input safety    | ✅ validated                                            |
| `noBlankScreensAfterNavigation`     | Navigation      | ✅ validated                                            |
| `tableChipsAreAlwaysClickable`      | Cross-link      | ✅ validated (B1 — viewport-bounds `visible` fix)       |
| `scrollPositionNonNegative`         | Scroll safety   | ✅ validated                                            |
| `badgesAreVisibleWhenPresent`       | Badge integrity | ✅ validated                                            |
| `queryRunDisabledWhenMissingParams` | Form safety     | ✅ validated (B1 — fixed `paramValues` namespace bug)   |
| `routeAlwaysKnown`                  | State coherence | ✅ validated (B1)                                       |
| `themeAlwaysSet`                    | Frame condition | ✅ validated (B1)                                       |
| `detailViewsAlwaysHaveBackButton`   | Navigation      | ✅ validated (B2 — found+fixed real bug: back btn was inside `<Show when={data}>` on all 4 detail views; refined to `length > 0` not viewport-visible) |

Removed in B1 (dead code):

- `noConsoleErrors` — always returned 0; real crash guard is `noUncaughtExceptions` from defaults
- `sidebarActiveGroup` extractor — identical to `activeNavIndex`
- `activeLinkGroupConsistent` — weaker duplicate of `activeLinkMatchesRoute`

### Planned (not yet in spec)

| Property                             | Plan | Category           |
| ------------------------------------ | ---- | ------------------ |
| `detailViewsAlwaysHaveBackButton`    | B2   | Navigation safety  |
| `loadingAlwaysTerminates`            | B4   | Liveness (bounded) |
| `errorAndSuccessNeverBothVisible`    | B3   | Mutual exclusion   |
| `noOverlappingSpinnerAndContent`     | B3   | Loading safety     |
| `urlMatchesDetailHeading`            | B3   | URL coherence      |
| `numberInputsAlwaysValid`            | B3   | Input safety       |
| `exploreTabSwitchPreservesSelection` | B5   | Frame condition    |

### Known false-positive risks

| Property                         | Risk                                    | Mitigation                                   |
| -------------------------------- | --------------------------------------- | -------------------------------------------- |
| `loadingAlwaysTerminates`        | Backend slow → false positive           | Use `within(10, "seconds")`                  |
| `noOverlappingSpinnerAndContent` | Transition frames during render         | Guard with `.loading:not(.hidden)` if needed |
| `urlMatchesDetailHeading`        | Heading may use display name ≠ URL slug | Confirm by reading component source first    |

---

## Action Generators (current)

| Generator           | Weight | Notes                                                      |
| ------------------- | ------ | ---------------------------------------------------------- |
| `clickNavLinks`     | 15     | Primary navigation                                         |
| `clickTableRows`    | 8      | List → detail navigation                                   |
| `clickBackButtons`  | 5      | Detail → list navigation                                   |
| `clickTableChips`   | 4      | Cross-link navigation                                      |
| `clickAllButtons`   | 3      | Catch-all                                                  |
| `browserNavActions` | 3      | Browser Back/Forward — tests `setupPopstateHandler` (B2)   |
| `scrollActions`     | 2      | ScrollDown/ScrollUp — replaces defaultActions (B2)         |
| `clickTreeNodes`    | 2      | Explore feature                                            |
| `typeIntoSearch`    | 2      | Search feature                                             |
| `clickSortHeaders`  | 2      | Sort headers — no `<th>` in UI yet; noop (B2)              |
| `clickPagination`   | 2      | Pagination — no pagination in UI yet; noop (B2)            |

**`clearSearch` deferred**: PressKey hangs headless Chrome (Bombadil 0.6.0 + chromiumoxide). Not exported. Test in headed mode first before re-enabling. `export * from defaults` replaced with selective import to avoid `defaultActions` (which also includes PressKey).

### Planned additions (B3+)

| Generator                      | Reason                            |
| ------------------------------ | --------------------------------- |
| `clearSearch`                  | Re-enable once PressKey confirmed safe in headless |

---

## Session Protocol

Each BOM session follows this structure:

1. **Read `doc/bombadil.md`** — update your mental model of current selector status
2. **Read `ui/bombadil-spec.ts`** — the live ground truth
3. **Stage 0**: Check which source component files need reading to confirm selectors
4. **Edit spec** — add/fix properties and generators per the session's plan file
5. **Run**: launch `pnpm bombadil` in background (`run_in_background=true`),
   redirecting to log file; notify user that the backend must be running
6. **Analyze**: read log tail + output directory after notification fires
7. **Refine**: fix false positives or bad selectors; re-run if needed
8. **Grooming**: update this doc's selector table and property inventory to reflect
   what was confirmed, what was removed, and what remains pending; evaluate
   whether a trace-output skill is warranted (see §Trace Output Skill above)

---

## Terminology

**Safety property** (`always`): something that must never be violated. All but
one of our properties are safety properties — the `always()` operator checks the
condition at every state Bombadil visits.

**Liveness property** (`always(now(...).implies(eventually(...).within(T)))`):
something that must eventually become true within a time bound. We have one:
`loadingAlwaysTerminates` (Plan 79). Use sparingly — false positives from backend
latency degrade the signal-to-noise ratio.

**Frame condition**: a safety property that asserts some piece of state does _not_
change when an unrelated action occurs. Example: `themeAlwaysSet` is not just
"theme exists" but also "theme is not cleared by navigation."

**State machine property** (`always(now(...).implies(next(...)))`): checks that
the next state satisfies some condition given the current state. Used for
transition validity. The Bombadil `now()`/`next()` combinators make these
expressible without custom state tracking.
