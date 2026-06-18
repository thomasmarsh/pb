# pb — User Experience: Component Specifications

> Part 2c of the pb design series. This document contains the state
> inventory, component vocabulary, keyboard model, and usability walk
> findings — the specification Plan 85 implements against.
>
> Series: [1 — Information Architecture](1-information-architecture.md) ·
> [2a — Journey Maps](2a-journey-maps.md) · [2b — Interaction Design](2b-interaction-design.md) ·
> **2c — Component Specs** · [3 — UI Direction](3-ui-direction.md)

---

## 1. State Inventory

Complete state inventory for all screens. Each screen must handle all four
states gracefully.

| Screen | Loading | Empty | Error / Partial | Success |
|---|---|---|---|---|
| Dashboard | Skeleton metric cards; spinner | Never empty — shows parse status even with 0 objects | Parse errors: amber banner "N files failed to parse · Diagnostics" | Full metrics: file count, object count, phase health rows |
| Library Detail (source) | Skeleton object rows | "No objects in this library" | — | Object list with type badges and LOC |
| Library Detail (analysis) | Skeleton cards | Per-card empty states | PhaseGate rows for unavailable phases | Full analysis cards |
| Object Detail (source) | Skeleton code block | "No source available for this object" | Partial parse: "Source partially available — N lines parsed cleanly" | Full rendered PowerScript |
| Object Detail (analysis) | Skeleton sections | No callers: inline note | PhaseGate for P2/P3/P4 sections | Full analysis sections |
| Procedure Detail (source) | Skeleton code | "No source available" | Partial parse | Rendered PowerScript; P2 hover annotations |
| Procedure Detail (analysis) | Skeleton callers/callees | No callers: inline note; no SQL: SQL section hidden | PhaseGate for CFG/taint/formal | Full analysis; CFG; taint paths |
| DW Detail (source) | Skeleton PBSELECT | "No PBSELECT definition found" | PBSELECT present but unparsed: shown verbatim, analysis face limited | Full PBSELECT + control inventory |
| DW Detail (analysis) | Skeleton sections | No usage: "Not referenced by any object in corpus" | PhaseGate for taint section | Tables linked; retrieve SQL parsed; taint params |
| Table Detail (source) | Skeleton columns | "Table schema not available — inferred from SQL only" | Column types inferred, not verified | Column listing with types |
| Table Detail (analysis) | Skeleton sections | No DW refs or proc refs: inline note | PhaseGate for taint/formal | Full sections |
| Objects List | Skeleton rows | "No objects indexed — index may still be building" | — | Sortable/filterable paginated list |
| DataWindows List | Same | Same | — | Same |
| Tables List | Same | Same | — | Same |
| Procedures List | Same | Same | — | Same |
| Global Search | — | "No results for…" | — | Type-ahead results grouped by entity type |
| Schema Explorer | Skeleton graph | "No tables inferred from corpus SQL" | Some tables without relationships | Full ERD with linked table nodes |
| Dead Code Report | Skeleton rows | "No uncalled procedures found" | PhaseGate for P2/P4 sections | Grouped by type: uncalled (P1) / unreachable (P2) / proven dead (P4) |
| Taint Explorer | PhaseGate (if P3 not built) | PhaseGate or "No taint paths found in corpus" | — | Filterable taint path table |
| Taint Path View | Spinner | "No paths found" with precision note | — | LinearTrace with N steps |
| Slice View | Spinner | "No statements in slice" with note | — | LinearTrace |
| CFG Diagram | Spinner | Single-block note | PhaseGate if P2 not built | Zoomable CFG |
| Formal Proof View | Z3 solving spinner | — | Timeout: explicit message | UNSAT or SAT with proof/counterexample |
| Ask | — | Initial empty state with recent queries | LLM error / query error banners | Results table or Analysis View preview |
| Diagnostics | Skeleton rows | "No parse errors — all files indexed cleanly" | — | Error list with file + line; links into source |

---

## 2. Component Vocabulary

Named recurring UI patterns. Each is a first-class component with a
behavioural contract. These become Plan 85's implementation target list.

---

### SourceTree

**Description:** The hierarchical source tree in the left sidebar. Mirrors
the PB IDE's object hierarchy: Library → Object → grouped sub-elements
(Functions, Events, Subroutines).

**Behaviour:**
- Three-group accordion sidebar: Source Tree (default expanded), Entity
  Navigation (default collapsed), Analysis Navigation (default collapsed).
- Library nodes expand to show Object nodes; Object nodes expand to show
  sub-element groups; sub-element groups expand to show individual procedures.
- Sub-element groups labelled by kind with count: "Functions (3)," "Events
  (2)," "Subroutines (1)." Empty groups are hidden.
- Clicking a library node navigates to Library Detail.
- Clicking an object node navigates to Object Detail (source face).
- Clicking a sub-element group label expands/collapses — no navigation.
- Clicking an individual procedure navigates to Procedure Detail (source
  face).
- Tree expansion state persists in the reducer through navigation.
- Auto-reveal: when the user arrives at an entity via search, breadcrumb, or
  Ask result, the tree expands to show that entity's location and highlights
  it. Does not collapse previously expanded nodes.
- Large corpus (100+ libraries): virtual scroll + search-within-tree input
  at the top of the Source Tree group.
- Collapsible to a narrow icon rail; a collapse button restores full width.

**Phase availability:** P1+.

---

### EntityCard

**Description:** A small inline card representing a single entity (procedure,
object, DW, table, library). Used in callers lists, Ask results, search
results, and anywhere an entity name appears inline.

**Behaviour:**
- Displays: entity-type icon, entity name, one-line context (containing
  object name, or procedure signature, or table name).
- Entire card is clickable — navigates to entity detail.
- Hover: shows a preview tooltip with the entity's key metadata (type, LOC,
  phase depth, first line of source if procedure).
- Keyboard: focusable via Tab; Enter navigates.

**Phase availability:** P1+. No phase-dependent content — the card itself
is always the same structure; deeper analysis adds tooltip content.

---

### FaceToggle

**Description:** The Source | Analysis toggle control on entity detail
screens.

**Behaviour:**
- Two named buttons: "Source" and "Analysis."
- Phase indicator to the right: "P2 available" or "P1 only" or "P3
  available."
- Active face is highlighted.
- `T` keyboard shortcut toggles from anywhere on the detail screen.
- Toggle stores scroll position per face per entity in the reducer.
- Transition: instant (no animation) to avoid the appearance of loading.

**Phase availability:** P1+. Phase indicator updates as phases land.

---

### PhaseGate

**Description:** A banner or row indicating that a feature requires a phase
not yet built.

**Full-page variant:** Used for Analysis Navigation screens not yet built.
Shows icon, heading, capability description, current phase.

**Inline variant:** Used within entity detail analysis faces for sections not
yet available. Renders as a collapsed row: `▸ [Section name] [P2 — requires
typing pass]`. Click to expand and show the full-page description inline.

**Behaviour:**
- Never red (not an error).
- Amber icon (⚠) for the full-page variant; grey for the inline row.
- Phase label is always specific: "P3 — context-insensitive taint analysis"
  not just "P3."
- No time-relative language ("coming soon," "planned").

**Phase availability:** Always rendered (by definition for gated phases).
Removed from the layout when the phase lands.

---

### BreadcrumbBar

**Description:** The typed-icon breadcrumb strip in the top bar.

**Behaviour:**
- Renders each chain segment with a type icon and a clickable label.
- Truncates at depth 5: collapses middle segments to `…`.
- `…` hover reveals full chain as a dropdown; keyboard-navigable.
- Entire bar is accessible: each segment is a button/link with aria-label
  including type and name.
- The current segment (last in chain) is not a link (it is where the user
  is).

**Phase availability:** P1+.

---

### AnalysisView

**Description:** The full-width screen type for analysis results (taint
paths, slices, CFGs, formal proofs). Not an entity detail screen — it is a
distinct surface with its own URL and breadcrumb.

**Behaviour:**
- Three templates selected by result type: LinearTrace, CFGDiagram,
  ProofTree.
- Shares chrome: BreadcrumbBar, title bar (with generating-context label,
  entity links, phase label, assumptions footer).
- Can be reached from: Analysis face of entity detail, Ask results, Taint
  Explorer, Formal Reports.
- Can be saved as a named query result (button: "Save this view").

**Phase availability:** P3+ for taint/slice; P2+ for CFG; P4+ for formal
proof/symbolic execution.

---

### LinearTrace

**Description:** An ordered list of steps for taint paths and program slices.
Used as the content region of the AnalysisView for these types.

**Behaviour:**
- Each step: step number, step type label (SOURCE / TRANSFORM / SINK for
  taint paths; AFFECTED / AFFECTING for slices), entity link, line number,
  statement text, annotation.
- Very long traces (> 20 steps) collapse the middle by default.
- Right panel: mini call graph of traversed procedures.
- Keyboard: `←` / `→` navigate between paths; `E` expands all steps.
- Every entity name in every step is a link (EntityCard pattern).

**Phase availability:** P3+ (taint paths, slices).

---

### CFGDiagram

**Description:** A zoomable, pannable directed graph for control flow graphs.
Used as the content region of the AnalysisView for CFG results, and as a
section within the Procedure Detail analysis face.

**Behaviour:**
- Nodes are basic blocks; edges are control flow.
- Edge labels: `true` / `false` for conditional branches; unlabeled for
  unconditional.
- Node colour coding: default / unreachable (yellow, P2) / taint-entering
  (red border, P3) / proven safe (green, P4).
- Click node → selected-block detail panel (statements, source links).
- Double-click node → navigate to Procedure Detail source face at block's
  first line.
- `F` key: fit to viewport. `R` key: reset. Scroll/pinch: zoom. Drag: pan.
- Momentum on pan/zoom (already implemented in the existing app).

**Phase availability:** P2+ (requires CFG computation from typing pass).

---

### ProofTree

**Description:** A collapsible tree view for Z3 formal proof results.

**Behaviour:**
- Root node: the stated claim.
- Children: sub-goals, rules applied, axioms used.
- Leaf nodes: either proved (✓) or open (for SAT counterexample paths).
- Verdict badge: UNSAT (green) or SAT (red) at the root.
- Assumptions displayed above the tree in a collapsed section.
- Export actions: JSON, PDF.
- For SAT results: counterexample pane below the tree with step-by-step
  execution path (LinearTrace pattern).

**Phase availability:** P4+.

---

### AskInput

**Description:** The main query input surface on the Ask screen.

**Behaviour:**
- Single text area; placeholder: "Ask a question, or start with SELECT to
  write SQL directly."
- Auto-detects `SELECT`/`WITH` at the start to route directly to DuckDB.
- Otherwise: routes via LLM translation.
- "▼ Show generated query" expandable pane below input; adapts label to
  query type (SQL / taint query / Z3 proposition).
- Recent queries strip: last 5 queries, each clickable to re-run.
- Submit: `↵` (Enter) or the "Ask" button.
- Loading state: input disabled, status line below shows translation
  progress.

**Phase availability:** P1+ for SQL/NL → DuckDB; P3+ for taint queries;
P4+ for Z3 queries.

---

### ResultTable

**Description:** A tabular result display for Ask SQL/structural queries.

**Behaviour:**
- Columns determined by the query result schema.
- Entity-name cells are automatically wrapped in EntityCard (the system
  recognises columns that contain entity names by their type metadata).
- Sortable by any column header click.
- Pagination: 50 rows per page, with page controls.
- "Open in Analysis View" action: if the result is derivable as an Analysis
  View (e.g. a taint path query), shows a button to generate it.
- "Save query" and "Export CSV" actions.

**Phase availability:** P1+.

---

### EntityTypeList

**Description:** The paginated, sortable, filterable list views for each
entity type (Objects List, DataWindows List, Tables List, Procedures List).

**Behaviour:**
- Column set varies by entity type (see IA Site Map).
- Sort: click column header; arrow indicates direction.
- Filter: inline filter inputs per column; full-text filter on name.
- Each row is an EntityCard-style link.
- Total count shown; filter count shown when active ("Showing 42 of 412").
- List state (sort, filter, scroll, page) preserved through navigation —
  returning from entity detail restores the list to its previous state.
- Keyboard: `j`/`k` or arrow keys navigate rows; Enter opens detail.

**Phase availability:** P1+. Procedures list gains taint exposure column at
P3.

---

### GlobalSearch

**Description:** The type-ahead search overlay activated by `/`.

**Behaviour:**
- `/` key (from anywhere) opens the overlay.
- As the user types, results appear grouped by entity type: Objects,
  Procedures, DataWindows, Tables.
- Each result is an EntityCard.
- Up/down arrows navigate results; Enter navigates to the entity.
- `Esc` dismisses.
- Results are ranked by: exact-name match first, then prefix match, then
  substring match, then keyword match across source.
- Recent searches shown before typing starts.

**Phase availability:** P1+. Search scope deepens with phases (P2: search
by type name; P3: search by taint source/sink).

---

### PhaseHealthRow

**Description:** A single row on the Dashboard summarising one phase's
availability and key metrics.

**Behaviour:**
- Phase label (P1/P2/P3/P4) + status badge: Active (green) / Pending
  (amber) / Not built (grey).
- Key metric for active phases: e.g. P1: "777 files, 412 objects, 3,841
  procedures"; P3: "142 taint paths found."
- Link to the primary Analysis Navigation screen for that phase (e.g. P3
  → Taint Explorer).
- For pending phases: shows capability description (same content as
  PhaseGate full-page variant).

**Phase availability:** Always shown (reflects all four phases including
pending).

---

### AnalysisNavItem

**Description:** A single item in the Analysis Navigation sidebar group.

**Behaviour:**
- Displays nav item name and a small phase badge (P1/P2/P3/P4).
- Active: highlighted background.
- Phase-gated items: visible but use a muted style; clicking navigates to
  the capability-preview screen (PhaseGate full-page).
- Available items: normal style; clicking navigates to the live screen.

**Phase availability:** All phases; item style varies by availability.

---

## 3. Keyboard Model

Complete shortcut table. These shortcuts are active unless the user is in a
focused input field (text input, SQL editor, Ask input).

| Key | Scope | Action |
|---|---|---|
| `/` | Global | Open GlobalSearch overlay |
| `?` | Global | Open keyboard shortcuts help overlay |
| `T` | Entity Detail | Toggle Source/Analysis face |
| `←` | Analysis View (multi-path) | Previous path / previous slice |
| `→` | Analysis View (multi-path) | Next path / next slice |
| `E` | Linear Trace | Expand all collapsed steps |
| `F` | CFG Diagram | Fit graph to viewport |
| `R` | CFG Diagram | Reset zoom and pan |
| `j` | Entity Type List | Move selection down one row |
| `k` | Entity Type List | Move selection up one row |
| `↑` / `↓` | Entity Type List, GlobalSearch | Move selection |
| `Enter` | Any focused EntityCard, list row, search result | Navigate to entity detail |
| `Esc` | GlobalSearch overlay, any dropdown | Close/dismiss |
| `[` | Navigation | Go back in breadcrumb chain (one level) |
| `]` | Navigation | Go forward in breadcrumb chain (if navigated back) |
| `1` | Sidebar | Focus Source Tree group |
| `2` | Sidebar | Focus Entity Navigation group |
| `3` | Sidebar | Focus Analysis Navigation group |
| `G then D` | Global (chord) | Go to Dashboard |
| `G then A` | Global (chord) | Go to Ask |
| `G then E` | Global (chord) | Go to Diagnostics (Errors) |
| `G then T` | Global (chord) | Go to Taint Explorer (P3) |
| `S` | Procedure Detail source face | Focus source code area (enable line-level keyboard navigation) |

**Notes on scope:**
- `T` does not conflict with any form focus because it is only active on
  entity detail screens when no input is focused.
- `G then X` chord shortcuts follow the "goto" convention from Vim-like
  tooling; the `?` help overlay lists them explicitly.
- The `[` / `]` navigation shortcuts are supplementary to the breadcrumb —
  they traverse the same history chain.
- All shortcuts are listed in the `?` overlay and are configurable via
  `settings.json` in a future iteration.

---

## 4. Usability Walk Findings

### 4.1 Current App — Friction Analysis by Journey

These observations are drawn from the current app's feature structure
(explore, objects, datawindows, diagrams, errors, navigation, queries,
search, tables, dashboard).

---

**Journey 1: PB Developer tracing callers of a function**

| Step | Current app | Friction |
|---|---|---|
| 1. Locate function | Explore sidebar → expand library → object → function | OK — familiar IDE layout |
| 2. View source | Source code rendered in right panel (ProcDetailPanel) | OK |
| 3. Find callers | Not shown on Explore/source view — must navigate to Diagrams | **Mode switch** — Diagrams is a separate nav section; tree context lost |
| 4. View call graph | Diagrams section — SVG rendering | Call graph visible but nodes may not be linked; SVG interaction is limited |
| 5. Follow a caller | If node link exists, click opens another panel | **No breadcrumb** through the chain; cannot return to original function cleanly |
| 6. Continue chain | Must repeat navigation from step 3 | **Dead end** — the chain breaks at each hop |

**Root cause:** Callers are not on the source/Explore view. Diagrams is a
separate section with independent navigation — entering it drops the tree
context.

---

**Journey 2: Modernization team — tables a window reads**

| Step | Current app | Friction |
|---|---|---|
| 1. Find window | Objects list or Explore | OK |
| 2. View object source | ObjectsDetailPanel | OK — source visible |
| 3. Find DataWindows used | Not aggregated on object view | **Must navigate to DataWindows feature** |
| 4. Filter DWs by naming convention | DataWindows list — manually filter by name pattern | **No formal link** from object to its DWs |
| 5. Open each DW | DW detail shows PBSELECT as raw text | PBSELECT is not parsed into table references |
| 6. Identify tables | Read PBSELECT manually | **No table links** — tables are text in SQL, not links |
| 7. Aggregate | Manual copy-paste | **No aggregation** across all DWs of the object |

**Root cause:** Object detail does not aggregate DW dependencies or table
references. Each must be opened individually. Tables in PBSELECT are text,
not links.

---

**Journey 3: Auditor — formal query to source**

| Step | Current app | Friction |
|---|---|---|
| 1. Go to Queries (Ask) | Nav link | OK |
| 2. Type NL question | NL input → LLM generates SQL | OK |
| 3. Run query | SQL executes | OK |
| 4. View results | Results table shown | Entity names may not be linked |
| 5. Click an entity name (if linked) | Navigates away from Queries | **Query context lost** — Queries view does not restore |
| 6. Return to Queries | Must retype query | **No breadcrumb** back to Queries with query state |
| 7. Ask follow-up | Retype, starting from scratch | **No conversation context** |
| 8. Seek formal proof | Not possible at P1/P2 | P3/P4 not built — but not clearly explained |

**Root cause:** Ask (Queries) results do not consistently link entity names.
Navigating away loses query state. No breadcrumb back to the query. No
phase-aware capability communication.

---

### 4.2 New Design — Friction Confirmed Eliminated

| Friction point | How the new design eliminates it |
|---|---|
| Callers not on source view | Callers list is on the Analysis face of Procedure Detail — one `T` keystroke from source |
| Mode switch to Diagrams for callers | No separate Diagrams section — all structural analysis is on the entity's Analysis face |
| Tree context lost on navigation | Source Tree sidebar persists and maintains expansion state across all navigation |
| No breadcrumb through caller chain | BreadcrumbBar tracks every navigation step; `[` navigates back |
| Object does not show DW dependencies | Object Analysis face (P1) shows "DataWindows Used" as a linked list |
| Tables not aggregated on object | Object Analysis face shows "Tables Accessed" aggregated across all DWs and SQL procedures |
| PBSELECT not parsed into table links | DW Analysis face shows parsed SELECT with linked table references |
| Ask result entity names not linked | ResultTable wraps entity name cells in EntityCard automatically |
| Ask query context lost on navigation | Ask state in URL and reducer; breadcrumb back to Ask is always present |
| No phase capability communication | PhaseGate components with precise capability descriptions; phase labels on every result |
| No formal verification path | P4 formal proof and counterexample views fully specced; P4 gate visible and descriptive at P1/P2/P3 |

---

### 4.3 Gaps in the New Design Not Present in the Current App

The new design introduces these surfaces that will require new implementation
work (recorded here as inputs to Plan 85):

1. **Phase indicator on FaceToggle** — the current app has no concept of
   phases; the indicator requires phase metadata per entity in the index.
2. **LinearTrace and ProofTree** — entirely new Analysis View templates.
3. **Typed breadcrumb icons** — the current breadcrumb (if any) does not
   have typed segments.
4. **PhaseGate component** — no equivalent in the current app.
5. **CFGDiagram with colour coding** — the current app's diagram rendering
   (SVG-based, unlinked nodes) must be extended to support clickable, coloured
   blocks and the `F`/`R`/`S` keyboard model.
6. **ResultTable entity detection** — requires the server to tag entity-name
   columns in query results, or the client to resolve names against the index.
7. **Ask context preservation in URL** — the current Queries feature does not
   URL-encode query state.

These gaps do not invalidate any decision in this document — they are
implementation requirements for Plan 85 to address.

---

*End of Part 2. Part 3 (UI Direction) covers new component types, visual
language notes for the new surfaces, and a definitive keyboard shortcut
table. Propose before starting Part 3.*
