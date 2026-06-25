# pb — Gap Analysis

> Part 4 of the pb design series. This document bridges the design series
> (Parts 1–3) and the implementation roadmap (Plan 86, track sequencing).
> It answers: given the completed design, what is the full gap between the
> design and the current app, and how do we decompose it into bounded tracks?
>
> Series: [1 — Information Architecture](1-information-architecture.md) ·
> [2a — Journey Maps](2a-journey-maps.md) · [2b — Interaction Design](2b-interaction-design.md) ·
> [2c — Component Specs](2c-component-specs.md) · [3 — UI Direction](3-ui-direction.md) ·
> **4 — Gap Analysis**

---

## Methodology

**Component-Centric Gap Analysis with Named Tracks.** Not epics or user stories.

The journey maps ([2a](2a-journey-maps.md)) and friction analysis ([2c §4](2c-component-specs.md)) already express the user-need dimension precisely. Re-expressing them as "As a PB developer, I want…" adds noise without adding information. The component vocabulary in [2c §2](2c-component-specs.md) is the correct decomposition unit: 14 named components, each with a behavioural contract that maps directly to implementation tasks.

"Tracks" are the project's native sequencing unit (used in BACKLOG and STRATEGY). Each track has a clear prerequisite, a bounded component list, and a task list.

**Three-step structure:**

1. **Resolve open questions** — the 6 from [Part 3 §6](3-ui-direction.md) cannot be left open for implementation. This document resolves each.
2. **Inventory the gap** — map each component and screen to current status (✓ exists, ≈ partial, ✗ new) and assign a track.
3. **Define tracks** — goal, prerequisite, components, and task list for Plan 86 to sequence.

**Scope boundary.** This analysis covers UI/UX work buildable at **P1** (current structural analysis infrastructure). P2/P3/P4 UI surfaces are identified and scoped, but flagged as phase-gated — they do not block P1 work and their backend dependencies are noted where relevant.

---

## 1. Resolved Open Questions

The following six decisions were explicitly deferred to this document by [Part 3 §6](3-ui-direction.md). Each is resolved here with a single chosen approach; no question is left open.

### Q1 — BreadcrumbBar icon implementation

**Question:** Emoji, SVG sprites, or unicode geometric symbols for typed segment icons?

**Resolution: Unicode symbols.**

The 8 entity types are a stable, fixed set that is unlikely to grow beyond the current inventory. Unicode geometric symbols are monochrome and render identically at ≤14px across platforms. Emoji fails the monochrome requirement on most platforms at small sizes. SVG sprites require design assets and a production pipeline for 8+ assets — a dependency not warranted for a fixed set.

If the symbol set proves inadequate after real use (legibility, platform rendering), migration to SVG sprites is straightforward. Start with unicode; migrate only when there is a concrete problem.

**Symbol assignments:**

| Type | Symbol |
|---|---|
| Library | `◆` |
| Object (window) | `⬜` |
| Object (menu / NVO) | `○` |
| Procedure | `ƒ` |
| DataWindow | `▦` |
| Table | `⊟` |
| Ask query | `?` |
| Analysis View | `◎` |
| List view | `≡` |

*Rejected: emoji.* Platform-dependent rendering at small sizes; cannot be styled monochrome. Fails the visual requirement in [Part 3 §2 Gap 3](3-ui-direction.md).

*Rejected: SVG sprites.* Requires design asset production for a fixed, small set. Adds a build-pipeline dependency with no present benefit.

---

### Q2 — SourceTree virtual scroll

**Question:** Add a SolidJS-compatible virtual scroll library (`@tanstack/virtual` or similar), or a lightweight custom implementation?

**Resolution: Defer virtual scroll; add search-within-tree filter instead.**

No known target corpus exceeds 100 libraries — the threshold at which virtual scroll provides a meaningful benefit. A client-side filter input at the top of the Source Tree group handles large corpora without adding a dependency. The filter is faster to implement, adds zero dependency weight, and solves the browsability problem independently of list length.

Revisit virtual scroll when a corpus with 100+ libraries is encountered in practice.

*Rejected: @tanstack/virtual at this stage.* Dependency not warranted without evidence that real target corpora exceed 100 libraries. Adds maintenance surface for a speculative problem.

---

### Q3 — LinearTrace step-type label rendering

**Question:** Plain `.badge` spans or a custom `<StepTypeLabel>` component with coloured left stripe and filter affordance?

**Resolution: Plain `.badge` spans.**

Step-type filtering is a P3+ feature with no present requirement. Introducing `<StepTypeLabel>` before a filter requirement exists is premature abstraction. The direction in [Part 3 §3.1](3-ui-direction.md) defaults to plain badges; this resolution removes the ambiguity.

Upgrade to a custom component if and when step-type becomes a filter axis in the LinearTrace UI.

*Rejected: `<StepTypeLabel>` now.* No filter requirement; premature abstraction.

---

### Q4 — ProofTree recursive component vs. library

**Question:** Reuse `TreeNode.tsx` or use an external tree library?

**Resolution: Reuse `ui/src/features/explore/TreeNode.tsx`.**

The existing recursive SolidJS component handles arbitrary tree depth. ProofTree depth is bounded by Z3 proof structure; performance issues are not anticipated. No external dependency warranted.

*Rejected: external tree library.* Adds a dependency for a problem the existing component already solves.

---

### Q5 — CFGDiagram colour injection

**Question:** Server-side SVG annotation (Graphviz node attributes), or client-side SVG DOM manipulation post-render?

**Resolution: Hybrid — server emits SVG + node-state array; client patches colour.**

Graphviz SVG output structure can change between versions, making client-side DOM manipulation fragile as a primary approach. Pure server-side annotation requires the Python pipeline to produce CSS custom property values in SVG — also fragile. The hybrid keeps each side responsible for what it owns: the server owns graph structure; the client owns design tokens.

**API contract:** `GET /diagrams/cfg/{proc_id}` returns:

```json
{
  "svg": "...",
  "nodeStates": [
    {"blockId": "block_0", "state": "default"},
    {"blockId": "block_3", "state": "unreachable"},
    {"blockId": "block_7", "state": "taint-entering"}
  ]
}
```

The client patches SVG element `fill` and `stroke` attributes by element ID after load. Colour values are the design tokens defined in [Part 3 §3.2](3-ui-direction.md).

*Rejected: pure client-side DOM manipulation.* Fragile against Graphviz SVG output changes.

*Rejected: pure server-side CSS annotation.* Requires the Python pipeline to produce CSS custom property values — couples design tokens to the backend.

---

### Q6 — ResultTable entity detection

**Question:** Server-side column tagging, or client-side heuristic resolution against the in-memory corpus index?

**Resolution: Server-side column tagging.**

`cli/api/src/pb/api/routes/queries.py` already has schema knowledge at query time and can annotate result columns. Client-side heuristic resolution requires loading a name index and produces false positives on short common strings. Server-side tagging is reliable and keeps the client simple.

**Column metadata format added to query response:**

```json
{
  "columns": [
    {"name": "procedure_name", "entity_type": "procedure"},
    {"name": "object",         "entity_type": "object"},
    {"name": "caller_count",   "entity_type": null}
  ],
  "rows": [...]
}
```

The client renders `entity_type`-tagged columns as EntityCards; untagged columns as plain text.

*Rejected: client-side heuristic.* False positives on short/common strings; requires loading the full name index on the client.

---

## 2. Component Gap Inventory

Every named component from [2c §2](2c-component-specs.md) mapped to its current status in the app and the delta required to match the design spec.

| Component | Current status | Delta | Track |
|---|---|---|---|
| **SourceTree** | ≈ Partial — `explore/TreeNode.tsx` + `explore/TreeNodes.tsx`; flat list under each object; no grouping by kind; no auto-reveal on external navigation | Group by kind (Functions / Events / Subroutines); count labels; hide empty groups; auto-reveal on arrival; search-within-tree filter input; collapsible to icon rail | T1 |
| **EntityCard** | ≈ Partial — ad-hoc clickable rows in multiple features; no unified component; no hover tooltip; inconsistent keyboard handling | Extract as a reusable component: type icon + name + one-line context; hover preview tooltip; keyboard-focusable (Tab + Enter) | T2 |
| **FaceToggle** | ✗ New — no equivalent; Objects feature uses tab-style navigation but not this pattern | New component: two named buttons (Source / Analysis), phase indicator badge, `T` keyboard shortcut, scroll position stored per face per entity in reducer | T2 |
| **PhaseGate** | ✗ New — no equivalent | Full-page variant (⚠ amber icon, capability description, current phase footer); inline collapsed-row variant | T2 |
| **BreadcrumbBar** | ✗ New — no typed breadcrumb exists in the current app | New component: typed unicode segment icons, truncation at depth 5, `…` hover dropdown, `[`/`]` keyboard shortcuts, aria-labels per segment | T1 |
| **AnalysisView** | ≈ Partial — Diagrams is a separate top-level nav section; no URL-based state; no generating-context chrome | Dissolve Diagrams section; AnalysisView as a full-width screen with URL + breadcrumb; three templates (LinearTrace, CFGDiagram, ProofTree) | T3 (chrome) + T5 (templates) |
| **LinearTrace** | ✗ New (P3+) | New template: step list (step number, type badge, EntityCard link, line number, statement, annotation); mini call graph panel; `←`/`→`/`E` keyboard; long-trace collapse | T5 (gated P3) |
| **CFGDiagram** | ≈ Partial — SVG diagrams exist via Graphviz; pan/zoom/momentum implemented; no node interaction; no colour coding | Node click → selected-block detail panel; double-click → ProcDetail at line; hybrid colour annotation per Q5; `F`/`R` keyboard; P2 PhaseGate | T5 (gated P2) |
| **ProofTree** | ✗ New (P4+) | New component reusing `TreeNode.tsx` recursive pattern; verdict badge (UNSAT/SAT); assumptions section; certificate export; SAT counterexample pane (LinearTrace pattern) | T6 (gated P4) |
| **AskInput** | ≈ Partial — Queries NL input exists; no URL state; no expandable query pane; no SQL detection in placeholder | URL state; expandable "▼ Show generated query" pane; SQL detection (`SELECT`/`WITH` prefix → DuckDB direct); recent queries strip (last 5) | T4 |
| **ResultTable** | ≈ Partial — table output in Queries; no entity detection; not sortable; not paginated | Server entity detection per Q6; EntityCard cells; sortable by column header; paginated (50 rows) | T4 |
| **EntityTypeList** | ≈ Partial — Objects/DW/Tables lists exist; no sort/filter state preservation across navigation; no `j`/`k` keyboard nav | Sort/filter/scroll/page state preserved in reducer; `j`/`k` row navigation; "Showing X of Y" count; all rows as EntityCard links | T2 |
| **GlobalSearch** | ≈ Partial — Search feature exists; no entity-type grouping; no typed result icons; no recent searches | Entity-type grouping in results; EntityCard per result; typed unicode icons; recent searches before typing | T1 |
| **PhaseHealthRow** | ✗ New | Dashboard phase summary rows: phase label, status badge (Active/Pending/Not built), key metric, link to primary analysis screen | T3 |
| **AnalysisNavItem** | ✗ New | Sidebar group item: nav item name, phase badge; available items — normal style, navigates to screen; gated items — muted style, navigates to PhaseGate screen | T1 |

---

## 3. Screen Gap Inventory

Every screen from the IA site map ([Part 1 §2](1-information-architecture.md)) mapped to current status.

| Screen | Phase | Current status | Delta | Track |
|---|---|---|---|---|
| **Dashboard / Landing** | P1 | ≈ Partial — exists; no PhaseHealthRows; metrics not linked; no completeness signal | PhaseHealthRows; parse error banner; linked entry tiles; completeness signal (files parsed / files found) | T3 |
| **Source Tree (sidebar)** | P1 | ≈ Partial — Explore sidebar shows flat object list; no kind grouping; single accordion section | 3-group accordion; grouping by kind; auto-reveal | T1 |
| **Entity Navigation (sidebar group)** | P1 | ≈ Partial — top-level nav links exist but as a flat nav, not an accordion group | Collapse into accordion group (collapsed by default) | T1 |
| **Analysis Navigation (sidebar group)** | P1 | ✗ New — no analysis nav group | New accordion group; Schema/ERD, Dead Code, Taint Explorer (gated), Formal Reports (gated) | T1 |
| **Library Detail** | P1 | ✗ New — clicking a library node shows no detail screen | New screen: object listing with type badges + LOC; complexity histogram; inter-library dependency summary; uncalled proc count | T3 |
| **Object Detail (source)** | P1 | ≈ Partial — exists across Explore and Objects features; two separate implementations | Unify; variable declarations index; procedure index; FaceToggle | T2 |
| **Object Detail (analysis)** | P1 | ≈ Partial — CallGraph, Inheritance, Metrics cards exist in `objects/detail/`; no DWs Used, no Tables Accessed aggregation | Add DWs Used card; Tables Accessed aggregated across DWs + SQL; Callers card; FaceToggle; PhaseGate rows for P2/P3/P4 | T2 |
| **Procedure Detail (source)** | P1 | ≈ Partial — `ProcDetailPanel.tsx` in Explore + `ProcedureDetail.tsx` in Objects; two implementations | Merge into one; FaceToggle | T2 |
| **Procedure Detail (analysis)** | P1 | ≈ Partial — callers accessible only via Diagrams section; no analysis face on the procedure view | Callers, Callees, SQL Statements on analysis face (not behind Diagrams nav); FaceToggle; PhaseGate for CFG/taint/formal sections | T2 |
| **DataWindow Detail (source)** | P1 | ≈ Partial — `DwDetailPanel.tsx` shows PBSELECT; control inventory partial | PBSELECT verbatim; complete control inventory; FaceToggle | T2 |
| **DataWindow Detail (analysis)** | P1 | ≈ Partial — some table links; no "Used By" aggregation | Tables Accessed from parsed PBSELECT; Used By (objects + procedures); FaceToggle | T2 |
| **Table Detail (source)** | P1 | ≈ Partial — `TableDetail.tsx` exists | Column listing; "inferred from corpus SQL" note when schema not available; FaceToggle | T2 |
| **Table Detail (analysis)** | P1 | ≈ Partial — DW refs and proc refs partially shown | Read/write access pattern; PhaseGate for P3 (taint) and P4 (formal) sections | T2 |
| **Objects List** | P1 | ≈ Partial — `ObjectList.tsx` exists; no state preservation | Sort/filter/scroll/page state preserved; `j`/`k` keyboard nav; "Showing X of Y" | T2 |
| **DataWindows List** | P1 | ≈ Partial — `DataWindows.tsx` exists | Same as Objects List | T2 |
| **Tables List** | P1 | ≈ Partial — `Tables.tsx` exists | Same | T2 |
| **Procedures List** | P1 | ≈ Partial — no dedicated list; accessible via Explore only | New dedicated list screen (route + backend endpoint); sort by complexity, caller count | T2 |
| **Global Search Results** | P1 | ≈ Partial — `Search.tsx` exists; flat results, no entity-type grouping, no typed icons | Entity-type grouping; EntityCard per result; typed unicode icons; recent searches | T1 |
| **Schema Explorer / ERD** | P1 | ≈ Partial — ERD diagram exists (Graphviz SVG); table nodes not linked to TableDetail; not in Analysis Nav | Table node click → TableDetail; wire to Analysis Navigation group | T3 |
| **Dead Code Report** | P1 | ✗ New | New screen: uncalled procedures list (P1); PhaseGate rows for unreachable branches (P2) and proven dead (P4); links to ProcDetail | T3 |
| **Ask** | P1 | ≈ Partial — `Queries.tsx` exists; no URL state; no expandable query pane; query context lost on navigation | URL state; expandable query pane; recent queries strip; SQL detection | T4 |
| **Ask Results** | P1 | ≈ Partial — table output shown; no EntityCard cells; query context not preserved in breadcrumb | EntityCard cells (server entity detection); breadcrumb preserves Ask context | T4 |
| **Diagnostics** | P1 | ≈ Partial — `Errors.tsx` exists; no file + line source links; not named Diagnostics | Rename to Diagnostics; file + line links into source face at that line; parse error categorisation | T3 |
| **Taint Explorer** | P3 | ✗ New (gated) | PhaseGate screen now; full LinearTrace implementation when P3 backend lands | T5 |
| **Taint Path View** | P3 | ✗ New (gated) | LinearTrace template; PhaseGate until P3 | T5 |
| **Slice View** | P3 | ✗ New (gated) | LinearTrace template; PhaseGate until P3 | T5 |
| **CFG Diagram** | P2 | ≈ Partial (gated) — SVG renders; no interaction; no colour coding | Interactive node click; hybrid colour annotation; PhaseGate until P2 backend | T5 |
| **Formal Proof View** | P4 | ✗ New (gated) | ProofTree template; PhaseGate until P4 backend | T6 |

---

## 4. Track Definitions

Six tracks: four P1-buildable, two phase-gated.

---

### T1 — Shell & Navigation

**Goal:** Restructure the persistent shell so navigation primitives exist for all downstream tracks. BreadcrumbBar and the 3-group sidebar accordion are prerequisites for T2, T3, and T4.

**Prerequisite:** None. Can start from current main.

**Components:** SourceTree (delta), BreadcrumbBar (new), GlobalSearch (delta), AnalysisNavItem (new).

**Tasks:**

1. Sidebar: 3-group accordion state in reducer (Source Tree / Entity Navigation / Analysis Navigation); each group independently expand/collapse; default state: Source Tree expanded, others collapsed
2. SourceTree: sub-element grouping by kind — Functions / Events / Subroutines; count label per group ("Functions (3)"); hide empty groups
3. SourceTree: auto-reveal — when user arrives at an entity via search, breadcrumb, or Ask result, expand tree to show that entity; never collapse previously expanded nodes
4. SourceTree: search-within-tree filter input at top of Source Tree group; client-side filter on library and object names; no virtual scroll
5. SourceTree: collapsible to narrow icon rail (three group icons); restore button
6. BreadcrumbBar: new component; typed unicode segment icons per §1 Q1; truncation at depth 5; `…` hover dropdown showing full chain, each segment clickable; `[` / `]` keyboard shortcuts for breadcrumb back/forward; aria-label including type + name per segment
7. AnalysisNavItem: new component; phase badge (P1/P2/P3/P4); available items navigate to live screen; gated items use muted text style, navigate to PhaseGate full-page screen
8. Analysis Navigation group: Schema/ERD (P1), Dead Code (P1), Taint Explorer (P3 gated), Formal Reports (P4 gated)
9. GlobalSearch: entity-type grouping in results (Objects / Procedures / DataWindows / Tables sections); EntityCard per result; typed unicode icons in results; recent searches shown before typing starts
10. Keyboard: `1` / `2` / `3` focus sidebar groups; `G then D` / `G then A` / `G then E` goto chords; `?` help overlay scaffold (shell only — populated across T1–T4)

---

### T2 — Entity Detail Pattern

**Goal:** Apply the FaceToggle + PhaseGate pattern uniformly across all 5 entity types; complete P1 analysis face content for each; unify the two parallel entity view implementations (Explore vs. Objects/DataWindows/Tables features).

**Prerequisite:** T1 — BreadcrumbBar must exist so it can update correctly on face toggle and entity navigation.

**Components:** EntityCard (new), FaceToggle (new), PhaseGate (new), EntityTypeList (delta), all entity detail screens (delta).

**Tasks:**

1. EntityCard: unified reusable component; entity-type unicode icon + name + one-line context (containing object, or signature, or table name); entire card clickable; hover preview tooltip (type, key metadata); keyboard-focusable (Tab + Enter navigates)
2. FaceToggle: two named buttons (Source / Analysis); phase indicator badge to the right ("P1 only" at launch; no fill — border-only treatment); `T` keyboard shortcut active on entity detail screens; scroll position stored per face per entity in reducer; instant transition (no animation)
3. PhaseGate: full-page variant (⚠ amber icon, "Requires [phase label] analysis infrastructure" heading, 2–3 sentence capability description, "Current analysis depth: P1" footer with Dashboard link); inline variant (single collapsed row `▸ [Section name] [P2 — requires typing pass]`; click to expand full-page description inline)
4. Object Detail: apply FaceToggle; source face (rendered PowerScript, variable declarations, procedure index); analysis face P1 (DWs Used card — EntityCard links; Tables Accessed aggregated across all DWs and direct SQL — EntityCard links; Callers of Object card; Complexity Metrics card); PhaseGate rows for P2, P3, P4 sections
5. Procedure Detail: apply FaceToggle; source face (rendered PowerScript, parameter/return meta, containing object linked); analysis face P1 (Callers, Callees, SQL Statements — all EntityCard links); PhaseGate rows for CFG (P2), taint paths (P3), formal properties (P4); unify `ProcDetailPanel.tsx` (Explore) and `ProcedureDetail.tsx` (Objects) into one canonical implementation
6. DataWindow Detail: apply FaceToggle; source face (PBSELECT verbatim, control inventory); analysis face P1 (Tables Accessed from parsed PBSELECT — EntityCard links; Used By — objects and procedures, EntityCard links; Retrieve Definition parsed ergonomically); PhaseGate row for taint on SQL parameters (P3)
7. Table Detail: apply FaceToggle; source face (column listing, "inferred from corpus SQL" note); analysis face P1 (DataWindows reading this table, Procedures referencing in SQL, Read/Write access pattern — all EntityCard links); PhaseGate rows for taint paths (P3) and formal access constraints (P4)
8. Object Detail: Tables Accessed aggregation — must span direct SQL in the object's procedures AND all DataWindows used by the object; label the aggregation explicitly ("based on full call graph and all DataWindows")
9. EntityTypeList: sort/filter/scroll/page state stored in reducer per list; restored when returning from entity detail; `j` / `k` row navigation; "Showing X of Y" count when filter active; all rows as EntityCard links
10. Procedures List: new dedicated screen — route + backend endpoint; columns: name, object, type, cyclomatic complexity, caller count; sortable by complexity and caller count; filterable by object and type
11. Reducer: scroll position per face (source/analysis) per entity stored and restored on navigation

---

### T3 — Dashboard & Analysis Navigation Content

**Goal:** Give the Dashboard meaningful P1 content and completeness signals; create Library Detail and Dead Code Report; rename/extend Errors → Diagnostics; wire Schema Explorer into Analysis Navigation.

**Prerequisite:** T1 — Analysis Navigation sidebar group must exist to wire new screens into it.

**Components:** PhaseHealthRow (new), AnalysisView chrome (partial — chrome only, not templates).

**Tasks:**

1. Dashboard: PhaseHealthRow component — phase label, status badge (Active green / Pending amber / Not built grey), key P1 metric ("777 files · 412 objects · 3,841 procedures"), link to primary Analysis Navigation screen for that phase; show all 4 phases (P2/P3/P4 as Pending/Not built)
2. Dashboard: parse error banner ("N files failed to parse · [Diagnostics]") shown when parse errors > 0; linked to Diagnostics screen
3. Dashboard: completeness signal — files parsed / files found count; entry count tiles (Objects, DataWindows, Tables, Procedures) all linked to their list views
4. Library Detail: new route (`/library/:id`); new backend endpoint returning object listing for a library; screen shows object list (type badge + LOC per object, each row an EntityCard link); FaceToggle with source face (object list) and analysis face P1 (complexity distribution; inter-library dependency table; uncalled procedure count with link to Dead Code Report filtered to this library)
5. Dead Code Report: new screen and route; backend query for uncalled procedures (procedures with caller count = 0); grouped list with type badges and object context; each row links to ProcDetail; PhaseGate rows for unreachable branches (P2) and formally proven dead (P4)
6. Diagnostics: rename route + nav link + screen title from "Errors" to "Diagnostics"; extend with file path and line number links into source face at the specific line; parse error categorisation (lexer vs. parser); consistent deepening as phases land (type errors P2, taint warnings P3 — PhaseGate rows now)
7. Schema Explorer: table node click navigates to TableDetail; wire Schema Explorer link to Analysis Navigation group under P1; no new graph features — only the navigation integration

---

### T4 — Ask Modernisation

**Goal:** Make Ask a context-preserving, first-class surface: query state survives navigation; entity links appear in results; breadcrumb back from any entity navigated to from an Ask result.

**Prerequisite:** T1 (BreadcrumbBar); T2 (EntityCard).

**Components:** AskInput (delta), ResultTable (delta).

**Tasks:**

1. URL-encode Ask query and result state — URL hash or query param + reducer sync; navigating back via browser back button or `[` keyboard shortcut restores the Ask surface with query and results intact
2. `cli/api/src/pb/api/routes/queries.py`: add `entity_type` metadata to result column schema in the query response (format specified in §1 Q6)
3. ResultTable: render `entity_type`-tagged columns as EntityCard links; untagged columns as plain text; sortable by any column header; paginated at 50 rows with page controls; "Save query" and "Export CSV" actions
4. AskInput: expandable "▼ Show generated query" pane below input; collapsed by default; label adapts to query type (SQL, taint query, Z3 proposition); pane is editable — user can modify and re-run
5. AskInput: SQL detection — input starting with `SELECT` or `WITH` routes directly to DuckDB without LLM translation; shown in placeholder text: "Ask a question, or start with SELECT to write SQL directly"
6. AskInput: recent queries strip — last 5 queries from reducer; each clickable to re-run; shown before typing starts
7. Breadcrumb: when user navigates from an Ask result to an entity, breadcrumb segment `❓ query-name` is set before the entity segment; clicking that breadcrumb segment returns to Ask with query and results intact (URL state restores)

---

### T5 — Analysis Views (P2/P3 gated)

**Goal:** Build the AnalysisView chrome and implement the CFGDiagram (P2) and LinearTrace (P3) templates. Gated on backend infrastructure — the chrome and PhaseGate screens can be built now; interactive content is populated when the backend lands.

**Prerequisite:** T1 + T2. P2 backend required for CFG content; P3 backend required for taint/slice content.

**Components:** AnalysisView (new chrome), LinearTrace (new template), CFGDiagram (delta).

**Tasks:**

1. AnalysisView route + shared chrome: BreadcrumbBar integration; title bar (entity name + generating-context label, e.g. "Generated by: Ask query '…'"); phase label footer (e.g. "P3 — context-insensitive taint analysis"); assumptions footer (collapsed section); "Save this view" action
2. CFGDiagram: node click → populate selected-block detail panel (statements list with monospace text, source line links); double-click → navigate to Procedure Detail source face at block's first line with BreadcrumbBar updated
3. CFGDiagram: hybrid colour annotation per §1 Q5 — API contract + client-side SVG element patching; phase state colours follow [Part 3 §3.2](3-ui-direction.md) tokens
4. CFGDiagram: `F` key fit to viewport; `R` key reset zoom/pan; P2 PhaseGate inline row within Procedure Analysis face (visible but gated until P2 backend lands)
5. LinearTrace: step list — each step is: step number, type badge (SOURCE / TRANSFORM / SINK for taint; AFFECTED / AFFECTING for slices; plain `.badge` spans per §1 Q3), EntityCard link with line number, statement in monospace, annotation in muted italic
6. LinearTrace: mini call graph panel in right sidebar — small-scale Graphviz SVG of procedures traversed; each node is an EntityCard link
7. LinearTrace: keyboard model — `←` / `→` navigate between paths when this is one of N results from the same query; `E` expands all collapsed steps; long trace (> 20 steps) shows first 4 and last 4, collapses middle with "N intermediate steps — click to expand"
8. Wire Taint Explorer, Taint Path View, Slice View nav items to AnalysisView + LinearTrace (PhaseGate full-page until P3 backend); wire CFG Diagram action from Procedure Detail analysis face (PhaseGate until P2 backend)

---

### T6 — Formal Proof View (P4 gated)

**Goal:** ProofTree template for Z3 formal proof and counterexample results.

**Prerequisite:** T5; P4 backend (Z3 integration).

**Components:** ProofTree (new).

**Tasks:**

1. ProofTree: reuse `ui/src/features/explore/TreeNode.tsx` recursive SolidJS component; root node = stated claim; children = sub-goals and rules; leaf nodes = proved (✓) or open; click to expand/collapse
2. Verdict badge at root: UNSAT — green tone with `--phase-p4` border, ✓ icon, text "UNSAT — Proved"; SAT — `--phase-p3` amber badge, text "SAT — Counterexample Found"; per visual direction in [Part 3 §3.3](3-ui-direction.md)
3. Assumptions section: collapsible above proof tree; lists all assumptions (no `Any`-typed values, no dynamic dispatch in path, etc.); explicit note that "violating any assumption invalidates this proof"
4. Certificate export: ghost button below proof tree → JSON download; PDF deferred until there is a concrete auditor requirement
5. SAT counterexample pane: below proof tree for SAT results; uses LinearTrace pattern (step-by-step execution path, each step linked to source line)

---

## 5. Summary

### P1-Buildable Tracks

| Track | Goal | Prerequisite | Sessions est. |
|---|---|---|---|
| **T1 — Shell & Navigation** | Shell restructure; BreadcrumbBar; Analysis Nav group; GlobalSearch delta | None | 2–3 |
| **T2 — Entity Detail Pattern** | FaceToggle + PhaseGate; entity content completeness; EntityTypeList state; Procedures List | T1 | 3–4 |
| **T3 — Dashboard & Analysis Nav** | Dashboard PhaseHealthRows; Library Detail; Dead Code Report; Diagnostics rename | T1 | 1–2 |
| **T4 — Ask Modernisation** | URL state; entity links in results; breadcrumb preservation | T1 + T2 | 1–2 |

### Phase-Gated Tracks

| Track | Goal | Gate | Sessions est. |
|---|---|---|---|
| **T5 — Analysis Views** | AnalysisView chrome; CFGDiagram interactive (P2); LinearTrace (P3) | P2 (CFG), P3 (taint/slice) | 2–3 when ready |
| **T6 — Formal Proof View** | ProofTree template | P4 (Z3 backend) | 1–2 when ready |

### Recommended Sequence for Plan 86

```
T1  →  T2  →  T3
                ↘
                 T4  (T3 and T4 can run in parallel after T2)

T5  (when P2 backend lands)
T6  (when P4 backend lands)
```

T1 is the foundation. T2 is the largest track and the most consequential for UX quality. T3 and T4 are independent of each other after T2 and can be scheduled in either order or in parallel sessions.

---

*End of Part 4. Plan 86 sequences these tracks into sessions with seed prompts, baseline metrics, and stop conditions.*
