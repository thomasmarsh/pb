# pb — UI Direction

> Part 3 of the pb design series. This document is the visual and mechanical
> direction layer — it identifies what carries over unchanged, gives directional
> notes for each new component, and establishes the visual language for
> Analysis Views and phase indicators. Full implementation specs (tokens as
> concrete values, pixel measurements, component APIs) belong to Plan 85.
>
> Series: [1 — Information Architecture](1-information-architecture.md) ·
> [2a — Journey Maps](2a-journey-maps.md) · [2b — Interaction Design](2b-interaction-design.md) ·
> [2c — Component Specs](2c-component-specs.md) · **3 — UI Direction**

---

## 1. What Carries Over

The following elements of the existing app's visual language are settled.
Plan 85 should preserve them unchanged — these are the "do not redesign"
boundaries.

### Typography

| Element | Setting |
|---|---|
| UI body | Inter, -apple-system fallback chain; 13px base |
| Code / monospace | JetBrains Mono, Fira Code, Consolas; 13px |
| Table headers | 11px, uppercase, 0.5px letter-spacing, `--text-muted` |
| Badges | 11px, 600 weight, 0.3px letter-spacing |
| Section / group labels | 11px, uppercase, 0.5px letter-spacing |

The two-font system (Inter for UI, monospace for code and identifiers) is
established across every existing component. It must not be diluted by
adding additional UI fonts for new surfaces. New surfaces that display code
or identifiers use the monospace stack; everything else uses Inter.

### Colour Palette

The CSS custom property palette in `cli/api/src/pb/api/static/style.css`
is the complete colour contract. Existing tokens and their assigned domains:

| Token | Domain |
|---|---|
| `--accent` | Links, active states, focus rings, selected rows; the primary interactive colour |
| `--green` | Tables, SQL, DataWindow controls, success indicators |
| `--yellow` | Events (procedure gutter bar, event badge); warning-adjacent states |
| `--red` | Parse errors, cyclomatic complexity badge, error row highlights |
| `--orange` | Subroutines (procedure gutter bar, sub badge) |
| `--purple` | Functions (procedure gutter bar, func badge, AST type tags) |
| `--text-primary / secondary / muted` | Three-tier text hierarchy |
| `--bg-primary / secondary / tertiary / card` | Four-tier background hierarchy |
| `--border` | The single border token |

Both dark-mode defaults and `[data-theme="light"]` overrides exist for all
tokens. New tokens must follow this same two-declaration pattern.

### Component Styles

| Component | What is settled |
|---|---|
| `.card` | 10px border-radius, `--bg-card`, `--border` border, 20px padding |
| `.badge` | 4px border-radius, 11px, colour from type-specific tokens |
| `.data-table` | Collapsed borders, 8px/12px padding, hover at 4% accent opacity |
| `.tab-btn` | Border-bottom active indicator at `--accent`; no fill on active |
| Source viewer | Dark inset bg, monospace, line gutter with `--text-muted` line numbers |
| Diagram viewport | Dark inset bg, grab/grabbing cursor, `icon-btn` toolbar; pan/zoom/momentum already implemented |
| Sidebar | 220px fixed, `--bg-secondary`, `--accent` gradient on h1 |
| `.metric-card` | `--bg-tertiary`, 22px value, 11px label, auto-filling grid |

### Spacing and Density

The app is deliberately dense — a code-navigation tool for developers, not
a marketing surface. Established density:

- Table row: 8px vertical / 12px horizontal padding
- Card: 20px padding
- Card gap: 16px
- Sidebar nav item: 8px/12px padding

Plan 85 must not loosen this density on new components. New surfaces should
match or be denser.

### Procedure-Type Badge Colours

The colours `.badge-func` (purple), `.badge-sub` (orange), `.badge-event`
(yellow), `.badge-on` (green), `.badge-cc` (red) are settled and appear in
both the badge system and the source viewer gutter bars. These must not
be reassigned. The new phase-status palette in §4 occupies different hue
regions to avoid collision.

---

## 2. New Components: Visual Direction

These are the seven gaps from [2c §4.3](2c-component-specs.md#43-gaps-in-the-new-design-not-present-in-the-current-app).
One to three sentences of directional guidance per gap.

### Gap 1 — Phase Indicator on FaceToggle

Visual register: **status badge, informational**. The phase indicator
("P2 available" / "P1 only" / "P3 available") is a small pill badge rendered
to the right of the Source / Analysis toggle. It uses the `.badge` shape but
draws from the dedicated phase-status colour palette (see §4) rather than
any existing badge colour. The badge is not interactive — it must not look
like a button; lower contrast than an action badge is appropriate.

### Gap 2 — LinearTrace and ProofTree

Visual register: **formal-proof / data-pipeline**. Both templates are entirely
new surfaces with no existing equivalent in the app. They share the overall
shell (BreadcrumbBar, title bar, card layout, phase label footer) with entity
detail screens, but their content regions use a structured, step-list density.
See §3 for full visual language direction.

### Gap 3 — Typed Breadcrumb Icons

Visual register: **navigation chrome, neutral**. The icons are small in-line
type markers preceding each segment label, rendered at 14px or smaller.
Icons must be monochrome — `--text-muted` by default, `--text-primary` for
the current (last) segment. Entity type is communicated by icon shape, not
colour.

*Rejected: colour-coding icons by entity type.* The source viewer gutter
already colour-codes procedure types (purple/orange/yellow/green). Repeating
those colours in the breadcrumb would add a secondary semantic layer that
conflicts with the phase-status palette introduced in §4. Monochrome keeps
breadcrumb chrome neutral and non-competing.

### Gap 4 — PhaseGate Component

Visual register: **structural signpost, not error**. The full-page variant
uses the amber phase-status colour (see §4.1) for its ⚠ icon and must be
visually distinct from the red error state. The inline collapsed row is
deliberately quiet — `--text-muted` text, `▸` disclosure triangle (matching
the existing tree pattern) — because phase gates within an analysis face
are secondary information. The ⚠ icon appears only on the full-page variant.

*Rejected: red ⚠ on the inline row.* Red carries error semantics throughout
the app. A phase gate is a capability boundary, not a failure. Using red
would cause users to read inline gates as broken sections. The amber ⚠
(full-page only) communicates "attention, not alarm" at the right elevation.

### Gap 5 — CFGDiagram with Colour Coding

Visual register: **code-adjacent, graph**. The existing diagram viewport
shell (pan/zoom/momentum, toolbar, cursor styles, `icon-btn` reset/fit
controls) carries over directly. The colour coding for node states adds a
semantic layer to the graph; see §3.2 for phase colour direction. The
selected-block detail panel uses the `.card` pattern; statements within it
use monospace at the established 12–13px density.

### Gap 6 — ResultTable Entity Detection

Visual register: **data table**. ResultTable extends the existing
`.data-table`. Entity-name cells rendered as links should use `--accent`
colour with dotted underline — matching the `.src-link` / `.src-link-proc`
pattern already established in the source viewer — rather than a button
treatment. The detection mechanism is an open question for Plan 85 (see §6);
visually, the only difference from a plain cell is the link style.

### Gap 7 — Ask Context Preservation in URL

No new visual component is required. The URL-state change is mechanical; the
visible consequence is that the breadcrumb reliably shows `Ask › query-name`
when navigating away from a result. Breadcrumb styling follows Gap 3 direction.

---

## 3. Analysis View Visual Language

LinearTrace, CFGDiagram, and ProofTree introduce a visual register not
present anywhere in the current app. The shared chrome (BreadcrumbBar,
title bar, generating-context label, entity links, phase label, assumptions
footer) uses the existing card and typography system. The content regions
below are new.

### 3.1 LinearTrace Step Treatment

Each step is a self-contained row with four information zones:

**1. Step number + type label** (SOURCE / TRANSFORM / SINK; AFFECTED /
AFFECTING for slices). The type label is a monochrome uppercase `.badge`.
Colour assignment reuses existing semantic colours:

| Label | Colour | Rationale |
|---|---|---|
| SOURCE | `--accent` | Origin; uses the primary interactive/reference colour |
| TRANSFORM | `--text-muted` | Neutral; a transform is neither source nor destination |
| SINK | `--red` | Destination/risk; red carries the "end of the line" weight |
| AFFECTED | `--purple` | Slice target; purple is the function/capability colour |
| AFFECTING | `--orange` | Influencer; orange is the subroutine/contributing colour |

*Rejected: unique colours per label.* New colours overcrowd an already dense
palette. Reusing `--accent` / `--red` / `--purple` / `--orange` connects
step types to semantic analogues already learned by the user.

**2. Entity link + line number.** Entity name in `--accent`, line number in
`--text-muted`, both 13px, `.src-link` dotted underline — same as the source
viewer's identifier links.

**3. Statement text.** Monospace, 12px, `--text-secondary`. Same density as
`.ast-leaf` in the existing AST explorer.

**4. Annotation.** 12px Inter, `--text-muted`, italic. Clearly subordinate
to the statement text.

Step rows use a 2px left border in `--border` to provide vertical alignment
and visual cadence. The collapse affordance for long traces uses the `▸ / ▼`
disclosure triangle from the existing tree pattern.

### 3.2 Phase Colour Coding

Used in CFGDiagram node states and referenced in LinearTrace annotations.
Four new CSS custom properties are introduced to avoid colliding with the
existing semantic palette (`--red` for errors, `--yellow` for events,
`--green` for tables, `--orange` for subroutines):

| Token | Hue region | Assigned meaning |
|---|---|---|
| `--phase-p1` | blue-violet (same as `--accent`) | P1 structural annotations — reuses accent; P1 is the foundational state |
| `--phase-p2` | teal (~175°) | P2 typing/CFG annotations; distinct from accent and green |
| `--phase-p3` | amber-orange (~40°) | P3 taint annotations; risk-adjacent, between yellow and orange at lower saturation |
| `--phase-p4` | indigo (~245°) | P4 formal proof; cooler and darker than accent, distinct from purple |

In CFGDiagram, node states map as follows:

| CFG state | Visual treatment |
|---|---|
| Default | `--bg-tertiary` fill, `--border` stroke — standard card tone |
| Unreachable (P2) | `--yellow` at 50% opacity, diagonal hashed fill | Structural observation; low saturation signals "note this" not "error" |
| Taint-entering (P3) | `--phase-p3` border, no fill change | Border-only avoids obscuring statement text; amber-orange signals risk |
| Proven safe (P4) | `--phase-p4` border, `--bg-tertiary` fill | Consistent with P4 annotation colour; fill signals certainty |

*Rejected: `--red` for taint-entering blocks* (as suggested in the 2b
wireframe annotation). Red means "error" throughout this app — parse errors,
cyclomatic complexity, error row highlights. A taint-entering block is a
structural observation, not an error. Amber-orange (`--phase-p3`) signals
risk without conflating it with the error state.

*Rejected: `--green` for proven-safe blocks.* `--green` is the table/SQL
colour. A proven-safe CFG block and a table chip would both be green,
overloading one colour with two unrelated semantics. Indigo (`--phase-p4`)
keeps the formal-proof domain visually separate from the data-model domain.

### 3.3 ProofTree Verdict Badges

The root-level verdict badge is the most prominent element in the Formal
Proof View and must be immediately legible.

**UNSAT — Proved.** A pill badge using `--green` tone with `--phase-p4`
border, medium weight (not bold). Icon: ✓. The green signals success, the
indigo border anchors it to the formal-proof register. The treatment is
intentionally restrained — this is a careful result to be read, not a
celebration.

*Rejected: a full-width green banner header.* A wide green banner reads as
a success toast. The proof result is a formal claim; underplaying the visual
exuberance keeps the auditor in a reading posture rather than a done posture.

**SAT — Counterexample Found.** A pill badge using `--phase-p3` (amber).
Text: "SAT — Counterexample Found." Not red — a counterexample is a finding,
not an error. The counterexample execution pane below the tree uses
`--bg-tertiary` background to visually distinguish it from the proof tree
body.

**Proof certificate export affordance.** A ghost button — `--border` border,
transparent background, `--text-secondary` text, `icon-btn` dimensions —
placed below the proof tree. On hover: border becomes `--accent`. This reuses
the existing `.icon-btn` pattern from the diagram toolbar rather than
introducing a new download-button component.

---

## 4. Phase Indicator Visual Language

The FaceToggle badge, PhaseGate banner, AnalysisNavItem phase labels, and
PhaseHealthRow status badges all express phase status. A consistent treatment
across these surfaces requires a dedicated phase-status palette that does not
collide with the existing semantic palette.

### 4.1 Phase-Status Palette

| Status | Colour direction | Contexts |
|---|---|---|
| Active / built | `--green` tone | PhaseHealthRow "Active" badge, FaceToggle "available" badge |
| Pending / not run | `--text-muted` grey | AnalysisNavItem gated text, FaceToggle "P1 only" badge |
| Attention (gate) | `--phase-amber` (new) | PhaseGate ⚠ icon (full-page variant only) |

`--phase-amber` is a new CSS custom property in the muted-gold family
(~#f59e0b in dark mode). It is distinct from:
- `--yellow` (#facc15, h ~55°) — too bright and saturated; reused for events
- `--orange` (#fb923c, h ~25°) — too warm and action-adjacent; reused for subroutines

Amber at h ~38° occupies a gap between them at lower saturation, carrying
the "caution, not alarm" tone appropriate to a capability boundary.

*Rejected: reusing `--yellow` for PhaseGate.* `--yellow` is the event badge
colour. A developer scanning an analysis face would confuse a phase-gate ⚠
with an event marker if both used the same yellow. A distinct amber token
eliminates the confusion.

### 4.2 FaceToggle Phase Badge Shape

The phase badge beside the Source / Analysis toggle is a `.badge`-shaped pill:
4px border-radius, 11px text, phase label + availability text. Colour states:

| Text | Border | Text colour | Meaning |
|---|---|---|---|
| "P2 available" | `--phase-p2` (teal) | `--text-secondary` | New capability present |
| "P1 only" | `--border` | `--text-muted` | Baseline; no new capability |
| "P3 available" | `--phase-p3` (amber) | `--text-secondary` | Risk analysis available |
| "P4 available" | `--phase-p4` (indigo) | `--text-secondary` | Formal verification available |

The badge has no background fill — border-only treatment signals
"informational" rather than "action." It must not look like a clickable
button; the FaceToggle buttons themselves provide the interaction.

### 4.3 Non-Collision Summary

The four new phase-status tokens occupy hue regions with clear separation
from existing semantic tokens:

```
Existing:  --accent ~230°  --purple ~270°  --red ~0°  --orange ~25°  --yellow ~55°  --green ~145°
New:       p4 ~245° (between accent/purple) · p2 ~175° (between accent/green) · p3/amber ~38–40° (gap between orange/yellow at lower saturation)
```

At typical monitor calibration and at 11px badge size, these distinctions
are legible in both dark and light modes.

---

## 5. Keyboard Model (Reference)

The complete keyboard shortcut table is specified in [2c §3](2c-component-specs.md#3-keyboard-model).
No corrections to that table are required.

One addition identified during this direction pass:

| Key | Scope | Action |
|---|---|---|
| `Esc` | `?` help overlay | Dismiss the overlay |

(The global `Esc` rule in 2c §3 already covers overlays and dropdowns; this
row makes the `?` overlay explicit for documentation clarity.)

### `?` Help Overlay Design

The overlay is a modal sheet using the existing pattern established by
`.health-overlay` / `.health-modal` in style.css: semi-transparent backdrop,
centred panel, `--bg-card` background, `--border` border, 12px border-radius.
A width of ~480px is sufficient for two-column shortcut display.

**Shortcut groups** (displayed as labelled sections within the panel):

| Group heading | Contents |
|---|---|
| Global | `/` search, `?` help, `G→D / G→A / G→E / G→T` goto chords, `[` / `]` breadcrumb |
| Entity Detail | `T` face toggle |
| Analysis Views | `←` / `→` path navigation, `E` expand steps, `F` fit CFG, `R` reset CFG |
| Lists | `j` / `k` row navigation, `↑` / `↓` , `Enter` open |
| Sidebar | `1` / `2` / `3` focus group |

**Visual treatment.** Group headings use `--text-muted`, uppercase, 11px —
the same section-label style used throughout the app. Each shortcut row is
a two-column table: left column is a `<kbd>`-style tag (`--bg-tertiary`
background, `--border` border, monospace font); right column is the
description in 13px Inter.

The `G then X` chord shortcuts are listed explicitly as two key tags in
sequence (`G` then `D`) because chords are not self-discoverable from
the key alone.

Dismissed by `Esc` or clicking the backdrop. No close button required —
`Esc` is the universal dismiss convention already in the shortcut table.

---

## 6. Open Questions for Plan 85

These decisions cannot be resolved directionally without implementation
exploration. Plan 85 must resolve each before building the affected component.

**1. BreadcrumbBar icon implementation.** The 2b wireframes use emoji (📦 🪟
⚙ 📋 🗄 ❓ 🔍 ☰). Options: emoji (no styling control, platform-dependent
rendering at small sizes), SVG sprites (full control, requires design assets),
unicode geometric symbols (monochrome, limited set), icon font (single
resource, dependency added). The direction in §2 Gap 3 requires monochrome
icons at ~14px or smaller; emoji fails this requirement on most platforms.
Plan 85 should choose between SVG sprites and a curated set of unicode
symbols, and confirm the icon set will not grow beyond the current 8 entity
types before committing to SVG production.

**2. SourceTree virtual scroll.** Large-corpus support (100+ libraries)
requires virtual scroll for the tree. Options: a SolidJS-compatible virtual
scroll library (e.g. `@tanstack/virtual`), or a lightweight custom
implementation using the existing `For` loop with scroll-position detection.
The question is whether most real target corpuses exceed 100 libraries; if
not, the dependency may not be warranted. Plan 85 should sample 2–3 customer
corpus sizes before committing to an implementation.

**3. LinearTrace step-type label rendering.** SOURCE / TRANSFORM / SINK
could be plain `.badge` spans (consistent with the existing badge system) or
a custom `<StepTypeLabel>` component with a coloured left stripe affording
filter interaction. The direction in §3.1 defaults to the plain badge;
a custom component is only warranted if step-type becomes a filter axis in
the LinearTrace UI.

**4. ProofTree recursive component vs. library.** The collapsible sub-goal
tree could reuse the `TreeNode` pattern already implemented in
`ui/src/features/explore/TreeNode.tsx` (recursive SolidJS component), or
use an external tree library. Given the existing implementation, the
recursive pattern is the likely path; Plan 85 should confirm whether
ProofTree depth or performance requirements exceed what the existing pattern
handles before adding a dependency.

**5. CFGDiagram colour injection.** The existing diagram rendering is
SVG-based, generated server-side by Graphviz. Node colour coding for P2/P3/P4
states requires either: server-side SVG annotation (Graphviz node
`style="fill:..."` attributes driven by analysis output), or client-side SVG
DOM manipulation post-render. The server-side approach is architecturally
cleaner but requires the analysis pipeline (Haskell/Python) to emit node
state alongside graph structure. This is a cross-layer question; Plan 85
must decide the API contract before implementing the colour layer.

**6. ResultTable entity detection.** Two approaches: the server tags
entity-name columns in the DuckDB query result schema (e.g.
`{"column": "procedure_name", "entity_type": "procedure"}`), or the client
heuristically resolves cell values against the in-memory corpus index.
Server-side tagging is more reliable and avoids a false-positive problem.
Plan 85 should check whether the existing query infrastructure in
`cli/api/src/pb/api/routes/queries.py` can emit column-type metadata before
designing the client-side ResultTable component API.

---

*End of Part 3. Plan 85 implements against the component specifications in
[2c](2c-component-specs.md) and the directional guidance in this document.*
