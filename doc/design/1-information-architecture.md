# pb — Information Architecture

> Part 1 of the pb design series. Every section that resolves a real design
> choice includes an "Alternatives considered" note. These notes prevent future
> sessions from re-debating settled decisions and prevent Plan 85 from
> reintroducing rejected approaches.
>
> Series: **1 — Information Architecture** · [2a — Journey Maps](2a-journey-maps.md) · [2b — Interaction Design](2b-interaction-design.md) · [2c — Component Specs](2c-component-specs.md) · [3 — UI Direction](3-ui-direction.md)

---

## Phase model

Analysis capabilities are built incrementally. Each capability below is
annotated with the phase in which it becomes available. The IA is defined
across all phases — the design does not change when a phase lands; new surfaces
become visible and existing surfaces gain depth.

| Phase | Label | Prerequisite | Contents |
|---|---|---|---|
| 1 | **P1** | Current state | Structural analysis: call graphs, inheritance, DW dependencies, complexity metrics, ERD inference from SQL, structural dead code |
| 2 | **P2** | Typing pass | Type information on all expressions; CFG per procedure; intra-procedural data flow; type-level queries; type safety diagnostics |
| 3 | **P3** | Analysis infrastructure | Inter-procedural data flow; program slicing; context-insensitive taint analysis; narrow symbolic execution |
| 4 | **P4** | Formal reasoning | Context-sensitive taint; Z3-backed property verification; symbolic execution at scale; formal specification export |

**On `Any`.** PowerBuilder supports an `Any` type that accepts any value at
runtime. It is relatively rare in practice but present in the corpus. The
typing pass assigns `Any` at the top of the type lattice: expressions of type
`Any` are treated conservatively in all static analyses — they cannot be ruled
out as taint sources, cannot participate in type-level narrowing, and require
widening in Z3 constraint generation. The design accommodates this without
special-casing it in the UI.

**On the LLM's role in P3/P4.** The Ask surface does not change structurally
across phases. The LLM always translates a natural language question into the
appropriate formal query. In P1/P2 that query is SQL over the structural
database. In P3 it may be a data flow query or slice query. In P4 it may be a
Z3 proposition, a taint query with formal guarantees, or a symbolic execution
request. The user's question looks the same; the back-end deepens.

---

## 1. Design Principles

### 1.1 Core Principle: Fluent Traversal

pb is built around a single invariant: **following a chain of questions must
never require a mode switch, a context reset, or a dead end.** When a developer
is tracing a bug, a modernization team is specifying what a window does, or an
auditor is formally verifying a data access constraint, each answer raises the
next question. The tool must make each step instantaneous and frictionless — the
work of understanding is thinking, not navigating software.

Every design decision in this document is evaluated against this invariant. A
proposed design that creates a dead end, loses breadcrumb context, or forces a
user out of their navigation chain violates the core principle and must be
revised.

### 1.2 Analysis is a First-Class Pillar

pb is a **static analysis platform** whose navigation layer feels like a code
browser. The call graph, inheritance diagram, and ERD are not the product —
they are the rudimentary structural foundations. The product is what the
complete compiler front-end enables: control flow, data flow, program slices,
taint paths, and formally verified properties over the entire codebase.

This shapes the entity model: every entity has an analysis face that deepens
across phases, not a fixed set of diagrams. It shapes Ask: the LLM front-end
translates questions into whichever formal system can answer them. It shapes
the navigation model: cross-entity analysis results (taint paths, slices) are
first-class navigable surfaces with their own breadcrumb support.

The IA is not defined by what is built today. It is defined by the full
capability of the front-end and progressively populated as infrastructure lands.

### 1.3 Traversal Model

```mermaid
flowchart LR
    Shell["Shell\ntree · search · ask · lists · analysis"]
    Shell --> Detail

    subgraph Detail["Entity Detail"]
        direction TB
        S["Source Face\nrendered code · type annotations [P2]"]
        A["Analysis Face\nstructural [P1] · type/CFG [P2]\nflow/slice [P3] · formal [P4]"]
        S <-->|"one click"| A
    end

    A -->|"node · link · metric"| Detail
    A -->|"generate"| AnalysisView

    subgraph AnalysisView["Analysis View [P3+]"]
        direction TB
        AV["Navigable result\ntaint path · slice · formal proof"]
    end

    AnalysisView -->|"node"| Detail
    S -->|"identifier"| Detail
    Detail -->|"breadcrumb"| Shell
    AnalysisView -->|"breadcrumb"| Shell
```

**Implications:**

- Browse and Understand are two faces of every entity — toggling between source
  and analysis is a toggle on the detail screen, not a navigation event.
- Every entity name anywhere in the app is a link into entity detail.
- Analysis Views are a distinct screen type generated by formal analysis queries
  (taint, slice, Z3). Each node in an Analysis View links into the relevant
  entity detail at the relevant source line. Analysis Views have breadcrumb
  support and can be saved as named queries.
- The breadcrumb always preserves the navigation chain, whether the chain
  passes through entity details, list views, Ask results, or Analysis Views.

### 1.4 Entity Model

```mermaid
graph TD
    Library["Library (.pbl)"]
    Object["Object\nwindow · menu · NVO · user object"]
    Procedure["Procedure\nfunction · event · subroutine · on-block"]
    DataWindow["DataWindow (.srd)"]
    Table["Database Table"]

    Library -->|"contains"| Object
    Object -->|"has many"| Procedure
    Object -->|"uses"| DataWindow
    Object -->|"inherits from"| Object
    Procedure -->|"calls"| Procedure
    Procedure -->|"SQL"| Table
    DataWindow -->|"PBSELECT → SELECT"| Table
```

**Source and analysis faces per entity type:**

| Entity | Source Face | Analysis Face |
|---|---|---|
| **Library** | Object listing (name, type, LOC); file path | **P1:** Complexity distribution; object type breakdown; inter-library dependency summary; uncalled procedure count **P2:** Type error count **P3:** Taint source/sink summary for this library |
| **Object** | Rendered PowerScript; variable declarations; procedure/event index | **P1:** Inheritance diagram; call graph; DataWindows used; callers; complexity metrics **P2:** Type information; intra-procedural data flow summary **P3:** Taint paths that pass through this object; slice entry points **P4:** Z3-verified object invariants |
| **Procedure** | Rendered PowerScript with syntax highlighting; parameter and return types; containing object context **[P2: hover-type annotations on all expressions]** | **P1:** Callers; callees; call graph; SQL statements; cyclomatic complexity **P2:** CFG diagram; type information; intra-procedural data flow; unreachable branches (structural) **P3:** Backward/forward slice from any expression; inter-procedural data flow; taint paths through this procedure; dead branches (proven) **P4:** Z3-verified preconditions and postconditions; symbolic execution results; formal property proofs |
| **DataWindow** | Rendered DW definition with PBSELECT shown as written (IDE parity); control inventory | **P1:** Parsed SELECT retrieve definition; tables accessed with links; compute expressions; WHERE clause parameters; usage — which objects and procedures reference this DW **P2:** Column types; parameterized query analysis **P3:** Taint analysis on SQL parameters — which columns receive user-controlled values; injection risk flags **P4:** Formal SQL safety properties |
| **Table** | Table name; column list and types (when schema available); inferred from DW SQL | **P1:** DataWindows that read this table; procedures that reference it in SQL; read/write access pattern **P3:** Taint paths that reach this table — which sources flow to this table, and through which procedures **P4:** Formally verified access constraints |

**Note on PBSELECT vs SELECT.** PBSELECT is a mechanical encoding artifact —
the PB IDE stores the retrieve SQL in a PBSELECT dialect rather than standard
SQL, but it is semantically a SELECT. The source face preserves PBSELECT as
written (IDE parity). The analysis face treats it as a plain SELECT: same table
references, same join relationships, same dependency links, same taint analysis
surface.

**Alternatives considered:**

*Flattening Object and Procedure into one entity type:* Object and Procedure
have fundamentally different analysis surfaces. An Object has an inheritance
chain, a set of DataWindows, and callers from other objects. A Procedure has a
CFG, intra/inter-procedural data flow, slices, and taint paths. Merging them
would force incompatible analysis faces onto the same screen. Rejected.

*Making Analysis Views persistent entity types:* Taint paths and slices are
generated, not stored. Making them first-class entities would require a
persistence model that adds complexity with little benefit — they are more
naturally treated as named query results. Rejected.

*Separating the analysis depth levels into separate "modes":* Splitting P1/P2/P3
into distinct app modes (e.g., "basic" vs. "advanced" view) would require users
to opt into analysis depth and would create the mode-switching anti-pattern the
traversal invariant prohibits. Instead, deeper analysis surfaces appear
progressively on the same analysis face as infrastructure lands. Rejected.

---

## 2. Site Map

Phase labels mark which phase a screen or capability becomes available.

```mermaid
graph TD
    Dashboard["Dashboard / Landing\ncorpus overview · health summary · entry points"]

    subgraph Shell["Persistent Shell"]
        SideTree["Source Tree\nPBL → Object → Procedure"]
        SideNav["Entity Navigation\nObjects · DataWindows · Tables · Procedures"]
        AnalysisNav["Analysis Navigation [P1+]\nSchema/ERD · Dead Code · Taint Explorer [P3]\nFormal Reports [P4]"]
        SearchBar["Global Search  /"]
    end

    Dashboard --> LibDetail
    Dashboard --> AskView
    Dashboard --> DiagView
    Dashboard --> SchemaExplorer

    SideTree --> LibDetail
    SideTree --> ObjDetail
    SideTree --> ProcDetail

    SideNav --> ObjList
    SideNav --> DWList
    SideNav --> TableList
    SideNav --> ProcList

    AnalysisNav --> SchemaExplorer
    AnalysisNav --> DeadCode
    AnalysisNav --> TaintExplorer
    AnalysisNav --> FormalReports

    SearchBar --> SearchResults
    SearchResults --> ObjDetail
    SearchResults --> ProcDetail
    SearchResults --> DWDetail
    SearchResults --> TableDetail

    LibDetail["Library Detail\nobject listing · health by phase"]
    LibDetail --> ObjDetail

    ObjList["Objects List\nsortable · filterable · paginated"]
    ObjList --> ObjDetail

    DWList["DataWindows List\nsortable · filterable · paginated"]
    DWList --> DWDetail

    TableList["Tables List [P1]\nlinks to Schema Explorer"]
    TableList --> TableDetail
    TableList --> SchemaExplorer

    ProcList["Procedures List\nsortable by complexity · caller count · taint exposure [P3]"]
    ProcList --> ProcDetail

    subgraph ObjDetail["Object Detail"]
        ObjSrc["Source Face"]
        ObjAna["Analysis Face\nP1: structural · P2: types/flow\nP3: taint paths · P4: invariants"]
        ObjSrc <-->|"toggle"| ObjAna
    end
    ObjAna --> ObjDetail
    ObjAna --> ProcDetail
    ObjAna --> DWDetail

    subgraph ProcDetail["Procedure Detail"]
        ProcSrc["Source Face\nP2: hover-type annotations"]
        ProcAna["Analysis Face\nP1: callers/callees/SQL · P2: CFG/types/flow\nP3: slices/taint · P4: Z3/symbolic"]
        ProcSrc <-->|"toggle"| ProcAna
        ProcSrc -->|"select expression [P3]"| SliceView
        ProcSrc -->|"select expression [P4]"| SymbolicView
    end
    ProcAna --> ProcDetail
    ProcAna --> TableDetail
    ProcAna --> TaintPath

    subgraph DWDetail["DataWindow Detail"]
        DWSrc["Source Face\nPBSELECT as written"]
        DWAna["Analysis Face\nP1: SQL/tables/usage · P3: taint on params"]
        DWSrc <-->|"toggle"| DWAna
    end
    DWAna --> TableDetail
    DWAna --> ObjDetail

    subgraph TableDetail["Table Detail"]
        TblSrc["Source Face\ncolumn listing · inferred schema"]
        TblAna["Analysis Face\nP1: DW refs/proc refs · P3: taint paths in · P4: access constraints"]
        TblSrc <-->|"toggle"| TblAna
    end
    TblAna --> DWDetail
    TblAna --> ProcDetail
    TblAna --> TaintPath

    SchemaExplorer["Schema Explorer / ERD [P1]\nFull ER model inferred from all SQL\nColumn-level detail · relationship inference"]
    SchemaExplorer --> TableDetail

    DeadCode["Dead Code Report [P1/P2]\nP1: uncalled procedures\nP2: unreachable branches (CFG)\nP4: proven unreachable (Z3)"]
    DeadCode --> ProcDetail

    TaintExplorer["Taint Explorer [P3]\nAll taint paths corpus-wide\nFilterable by source/sink type · severity"]
    TaintExplorer --> TaintPath

    TaintPath["Taint Path View [P3]\nSource → transformations → sink\nEach step linked to source line"]
    TaintPath --> ProcDetail
    TaintPath --> TableDetail

    SliceView["Slice View [P3]\nBackward or forward slice from selected expression\nEach statement linked · navigable"]
    SliceView --> ProcDetail

    SymbolicView["Symbolic Execution View [P4]\nInputs → path conditions → outputs\nZ3 constraints · counterexamples"]
    SymbolicView --> ProcDetail

    FormalReports["Formal Reports [P4]\nZ3-verified property proofs\nAccess constraint verification · invariant reports"]
    FormalReports --> ProcDetail
    FormalReports --> TableDetail

    AskView["Ask\nP1: DuckDB structural + NL\nP2: type-aware queries\nP3: slice/flow/taint queries\nP4: Z3 formal · symbolic execution"]
    AskView --> AskResults["Ask Results\nlinked entity names · derivable Analysis Views"]
    AskResults --> ObjDetail
    AskResults --> ProcDetail
    AskResults --> DWDetail
    AskResults --> TableDetail
    AskResults --> TaintPath
    AskResults --> SliceView
    AskResults --> SymbolicView
    AskResults --> AskView

    DiagView["Diagnostics\nParse errors [P1] · type errors [P2] · taint warnings [P3]"]
    DiagView --> ObjDetail
    DiagView --> ProcDetail
```

**Screen inventory:**

| Screen | Phase | Purpose |
|---|---|---|
| Dashboard / Landing | P1+ | Corpus overview; phased health summary; entry point tiles |
| Source Tree (sidebar) | P1 | Hierarchical browse: PBL → Object → Procedure; always visible |
| Objects List | P1 | All objects, sortable/filterable; links to detail |
| DataWindows List | P1 | All DataWindows, sortable/filterable; links to detail |
| Tables List | P1 | All tables; links to detail and Schema Explorer |
| Procedures List | P1 | All procedures; sortable by complexity, caller count; P3: taint exposure |
| Global Search Results | P1 | Type-ahead + full results; links into any entity detail |
| Library Detail | P1 | Object listing; complexity distribution; P2+ health metrics |
| Object Detail (source) | P1 | Rendered PowerScript; variable declarations; procedure index |
| Object Detail (analysis) | P1+ | Structural → type/flow → taint paths → invariants across phases |
| Procedure Detail (source) | P1 | Rendered PowerScript; P2: hover-type annotations on expressions |
| Procedure Detail (analysis) | P1+ | Callers/callees → CFG/types → slices/taint → Z3/symbolic across phases |
| DataWindow Detail (source) | P1 | DW definition; control inventory; PBSELECT as written |
| DataWindow Detail (analysis) | P1+ | SQL/tables/usage → parameterized query analysis → taint on params |
| Table Detail (source) | P1 | Column listing; inferred or live schema |
| Table Detail (analysis) | P1+ | DW refs/proc refs → taint paths in → formal access constraints |
| Schema Explorer / ERD | P1 | Full ER model inferred from all DataWindow SQL across corpus |
| Dead Code Report | P1/P2/P4 | Uncalled procedures (P1); unreachable branches (P2); Z3-proven (P4) |
| Taint Explorer | P3 | All corpus-wide taint paths; filterable by source/sink/severity |
| Taint Path View | P3 | Single taint path: source → transformations → sink; each step linked |
| Slice View | P3 | Backward or forward program slice from a selected expression |
| Symbolic Execution View | P4 | Inputs, path conditions, outputs, Z3 constraints, counterexamples |
| Formal Reports | P4 | Z3-verified proofs; access constraint verification; invariant reports |
| Ask | P1+ | Multi-modal query: DuckDB (P1) → type queries (P2) → flow/slice/taint (P3) → Z3/symbolic (P4) |
| Ask Results | P1+ | Tabular results with linked entity names; derivable Analysis Views |
| Diagnostics | P1+ | Parse errors (P1); type errors (P2); taint warnings (P3) |

---

## 3. Navigation Model

### 3.1 Hard Question: Shell Structure

**Question:** How do the source tree, global search, and analysis surfaces
relate in the outer shell?

**Resolution: Persistent sidebar tree + entity-type navigation + analysis
navigation + top bar search.**

The shell has four structural components:

1. **Left sidebar — source tree** (collapsible). Libraries → objects →
   procedures. The PB developer's home. Familiar IDE spatial layout.

2. **Left sidebar — entity navigation.** Objects, DataWindows, Tables,
   Procedures as direct links to list views. Serves modernization teams
   browsing by type rather than hierarchy.

3. **Left sidebar — analysis navigation** (phase-gated). Schema/ERD, Dead
   Code, Taint Explorer, Formal Reports. Corpus-level analysis views that
   don't belong to any entity type. New items appear here as phases land.

4. **Top bar.** Global search (`/`), breadcrumb, Ask link, Diagnostics link.
   Always accessible regardless of location.

**Alternatives considered:**

*Merging entity navigation and analysis navigation into one nav group:* Entity
types (Objects, DataWindows) and corpus-level analysis views (Taint Explorer,
Dead Code) serve different browsing modes. Merging them creates a nav group
that grows unboundedly as new analyses are added and mixes structural browsing
with formal analysis. Separate groups are cleaner and phase-gate naturally.
Rejected.

*Tab-based shell:* Tabs imply mutually exclusive modes. The vision requires
Browse and Understand to be two faces of every entity, not two destinations.
Rejected (same as previous session).

*Overlay tree:* Hides the spatial orientation the PB developer depends on.
Rejected (same as previous session).

### 3.2 Hard Question: Browsing Without a Target

**Resolution:** Same as previous session — dedicated entity-type list views
with sort/filter controls, accessible from the entity navigation group.

**Addition:** The analysis navigation group extends this for analysis-level
browsing: "show me all taint paths in the corpus" or "show me all dead
procedures" are navigation targets, not search queries.

### 3.3 Hard Question: Landing Screen

**Resolution:** Dashboard with corpus overview and phased health summary.

The Dashboard adds to the previous design: as phases land, new health metrics
appear — type error count (P2), taint path count (P3), formal property
verification status (P4). The dashboard is not a static "corpus size" view; it
is a live summary of the analysis depth currently available and what it reveals.

### 3.4 New Hard Question: Where Do Analysis Views Live?

**Question:** A taint path, a program slice, a symbolic execution result — these
are generated, cross-entity, and don't belong to any single entity's detail
page. How do they fit the navigation model?

**Resolution: Analysis Views are a distinct screen type with full breadcrumb
support.**

An Analysis View is generated by: a formal query in Ask, a "generate slice"
action from a procedure's source view, a node click in Taint Explorer, or a
Z3 query result. It has:

- Its own URL/state (saveable as a named query result)
- Breadcrumb back to the surface that generated it
- Every node in the view is a link into entity detail
- A link back to the generating Ask query for refinement

The breadcrumb for an Analysis View reads:

- `Ask › query-name › Taint Path` (generated from Ask)
- `Object › Procedure › Slice from line 47` (generated from procedure source view)

**Alternatives considered:**

*Making Analysis Views persistent entities:* Taint paths and slices are
generated, not stored. Persisting them as entities would require a storage
model that adds complexity for little benefit. Named query results (saved Ask
queries whose results are re-runnable) cover the persistence use case. Rejected.

*Displaying Analysis Views inside the entity detail panel:* A taint path spans
many entities and doesn't belong to any one. Trying to display it inside, say,
the Procedure detail would truncate the cross-entity view. Analysis Views need
their own full-width surface. Rejected.

### 3.5 Navigation Model Diagram

```mermaid
graph LR
    subgraph TopBar["Top Bar (persistent)"]
        Breadcrumb["Breadcrumb"]
        GlobalSearch["Global Search  /"]
        NavLinks["Ask · Diagnostics"]
    end

    subgraph Sidebar["Left Sidebar (persistent, collapsible)"]
        SourceTree["Source Tree\nPBL → Object → Procedure"]
        EntityNav["Entity Navigation\nObjects · DataWindows\nTables · Procedures"]
        AnalysisNav["Analysis Navigation\nSchema/ERD · Dead Code\nTaint Explorer [P3]\nFormal Reports [P4]"]
    end

    subgraph Main["Main Content Area"]
        Dashboard["Dashboard"]
        EntityDetail["Entity Detail\nSource ↔ Analysis (deepens by phase)"]
        ListViews["Entity Type List Views"]
        AnalysisViews["Analysis Views [P3+]\ntaint path · slice · symbolic · formal"]
        SearchResults["Search Results"]
        AskSurface["Ask (multi-modal by phase)"]
        Diagnostics["Diagnostics (deepens by phase)"]
    end

    SourceTree -->|"click node"| EntityDetail
    EntityNav -->|"click type"| ListViews
    AnalysisNav -->|"click analysis"| AnalysisViews
    ListViews -->|"click row"| EntityDetail
    GlobalSearch -->|"type + select"| SearchResults
    SearchResults -->|"click result"| EntityDetail
    NavLinks -->|"Ask"| AskSurface
    NavLinks -->|"Diagnostics"| Diagnostics
    AskSurface -->|"entity link"| EntityDetail
    AskSurface -->|"analysis result [P3+]"| AnalysisViews
    EntityDetail -->|"entity link"| EntityDetail
    EntityDetail -->|"generate analysis [P3+]"| AnalysisViews
    AnalysisViews -->|"node link"| EntityDetail
    AnalysisViews -->|"breadcrumb"| AskSurface
    Breadcrumb -->|"navigate back"| ListViews
    Breadcrumb -->|"navigate back"| SearchResults
    Breadcrumb -->|"navigate back"| AskSurface
    Breadcrumb -->|"navigate back"| AnalysisViews
```

---

## 4. User Flows

Each flow is traced twice: first through the current app (friction analysis),
then through the new design. The friction points become the explicit
requirements the new design must satisfy.

---

### 4.1 PB Developer: Tracing Callers of a Function

**Friction analysis — current app:**

```mermaid
flowchart TD
    A[Developer knows function name] --> B{Knows library/object?}
    B -->|yes| C[Explore: expand library → object → function]
    B -->|no| D[Go to Search]
    C --> E[See source in code pane]
    D --> F[Search result]
    F --> G[Navigate to result — lose Explore tree context]
    G --> E
    E --> H{Where are callers shown?}
    H -->|"not in Explore"| I["⚠ Go to Diagrams section or Search again"]
    H -->|"partially surfaced"| J[Caller list visible but not linked]
    I --> K[Find a caller — no breadcrumb back]
    J --> L[No direct click to caller source]
    K --> M["⚠ Dead end"]
    L --> M
```

**Friction points:** Callers not on the source view; mode switch required to
Diagrams; following a caller link loses tree context; no breadcrumb through the
chain.

**New design:**

```mermaid
flowchart TD
    A[Press /] --> B[Type function name]
    B --> C[Select from type-ahead]
    C --> D[Procedure detail — Source face]
    D --> E[Toggle to Analysis face]
    E --> F["P1: Callers list + call graph — all linked\nP2: + type information on parameters\nP3: + data flow from/to this procedure"]
    F --> G[Click a caller]
    G --> H["Procedure detail — caller\nbreadcrumb: Search › f_name › caller_name"]
    H --> I[Toggle to Analysis face for caller — continue chain]
    H --> K[Click breadcrumb — return to f_name]

    style E fill:#d4edda
    style F fill:#d4edda
    style K fill:#d4edda
```

**P3 extension:** Developer can also ask Ask: "What procedures call `f_process_payment` with a parameter derived from user input?" — a data flow query that filters callers by the provenance of their arguments. The result is an Ask Result table linking into each caller's procedure detail.

---

### 4.2 Modernization Team: "What Tables Does This Window Read?" and "What Is This Window's Full Specification?"

**Friction analysis — current app:**

```mermaid
flowchart TD
    A[Which tables does w_payment read?] --> B[Find window in Explore or Objects]
    B --> C[Object view — source visible]
    C --> D{DWs used visible?}
    D -->|"⚠ no"| E[Go to DataWindows — search by name pattern]
    D -->|"partially"| F[Some DW names — not linked]
    E --> G[Find candidate DWs — no completeness guarantee]
    F --> G
    G --> H[Open each DW individually]
    H --> I[SQL visible as raw text]
    I --> J{Tables linked?}
    J -->|"⚠ no"| K[Read SQL manually]
    J -->|"partially"| L[Table names — may not link to detail]
    K --> M["⚠ No aggregation — must compile manually"]
    L --> M
```

**New design — P1 (tables) and P3 (full specification):**

```mermaid
flowchart TD
    A[Search for window or browse Objects list] --> B[Object detail — Source face]
    B --> C[Toggle to Analysis face]
    C --> D["P1: 'Tables accessed' — aggregated across all DWs — all linked\nP1: 'DataWindows used' — list, all linked"]
    D --> E{Need overview or deep spec?}
    E -->|"overview"| F[Click table → Table detail\nSee taint paths into this table P3]
    E -->|"deep spec P3"| G["Ask: 'What does the value of field f_total in w_payment depend on?'"]
    G --> H["Slice query → Slice View\nBackward slice: all statements that affect f_total"]
    H --> I["Every statement in the slice is linked to source\nMigration specification derived"]
    H --> J["Ask follow-up: 'What inputs can cause this slice to branch?'\nP4: symbolic execution result"]

    style D fill:#d4edda
    style G fill:#d4edda
    style H fill:#d4edda
```

**Requirements satisfied:**

- P1: Aggregated tables view answers the structural question in one toggle.
- P3: Slice extraction from Ask answers the behavioral specification question.
- P3: Migration team can ask "what can I safely not port?" → Dead Code Report shows uncalled procedures in this object's call graph.

---

### 4.3 Auditor: Formally Verifying a Data Access Constraint

**Friction analysis — current app:**

```mermaid
flowchart TD
    A[Which procedures access accounts table?] --> B[Navigate to Queries]
    B --> C[Type NL question]
    C --> D[LLM generates SQL]
    D --> E[Results table]
    E --> F{Entity names linked?}
    F -->|"⚠ no"| G[Copy name — go to Search — lose query context]
    F -->|"partially"| H[Some links — navigating away loses Ask context]
    G --> I["⚠ Dead end"]
    H --> I
    E --> J{Is the SQL visible?}
    J -->|"⚠ hidden"| K[Results without transparency]
```

**New design — P1 through P4, showing the progression:**

```mermaid
flowchart TD
    A[Auditor: can user input reach the accounts table without validation?]

    A --> P1["P1 — Structural query\n'Which procedures reference accounts table?'\n→ DuckDB result — all procedure names linked"]
    P1 --> P1b[Click procedure → Procedure detail → inspect callers manually]
    P1b --> P1c["⚠ Still manual: must trace validation by reading source"]

    A --> P3["P3 — Taint query\n'Trace all paths from user input to accounts table'\n→ Taint Explorer: list of taint paths, severity-ranked"]
    P3 --> P3b[Click a path → Taint Path View\nSource → each transformation step → sink\nEach step linked to source line]
    P3b --> P3c["Inspect: does any step pass through f_validate_user?\nIf not: taint path is a finding"]
    P3c --> P3d["Ask follow-up: 'Find all taint paths that bypass f_validate_user'\n→ filtered result"]

    A --> P4["P4 — Formal query\n'Prove that all paths from wf_entry to accounts table\npass through f_validate_user'\n→ Z3 formal query"]
    P4 --> P4b{Z3 result}
    P4b -->|"UNSAT — proved"| P4c["Formal proof: constraint holds\nReport exportable"]
    P4b -->|"SAT — counterexample"| P4d["Counterexample: a concrete input and execution path\nthat reaches accounts without validation\nPath linked step by step into source"]
    P4d --> P4e[Navigate the counterexample → find the gap → fix it]

    style P3 fill:#d4edda
    style P4 fill:#d4edda
    style P4c fill:#d4edda
    style P4d fill:#cce5ff
```

**Requirements satisfied:**

- P1: Structural results are linked — no dead ends, query context preserved in breadcrumb.
- P3: Taint analysis answers the question automatically, without manual tracing through source.
- P4: Formal verification produces a proof or a counterexample with a concrete execution path. The auditor can follow the counterexample directly into source.
- Every phase is a complete, useful answer to the question — P4 is not required for the tool to be useful to auditors.
