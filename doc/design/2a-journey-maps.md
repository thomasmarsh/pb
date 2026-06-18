# pb — User Experience: Emotional Journey Maps

> Part 2a of the pb design series. The emotional journey maps are the
> foundation for every interaction decision in the UX layer — read before
> the wireframes.
>
> Series: [1 — Information Architecture](1-information-architecture.md) ·
> **2a — Journey Maps** · [2b — Interaction Design](2b-interaction-design.md) ·
> [2c — Component Specs](2c-component-specs.md) · [3 — UI Direction](3-ui-direction.md)

---

The wireframes in the subsequent UX documents are only valid if they respond
to how each persona actually feels during their work. This document records
the emotional context — what each user brings to the landing screen, what
erodes trust, and what builds it. These observations constrain every layout
and interaction decision that follows.

---

## 1. PB Developer

**Context.** A late bug has been escalated. The developer did not write this
code. It is two hundred source files they have never opened. The IDE shows
one object at a time. Time pressure is real; spatial disorientation is
immediate.

**On landing.**
The developer arrives in an orientation-seeking state. Their first act will
be to locate the failing component in a spatial map — not to read metrics or
start a query. If the landing screen shows a corpus-wide health dashboard
before they can see the source tree, they feel slowed down. If the source
tree is the default left panel, they feel at home.

*Trust trigger:* The tree expands in a familiar hierarchy — library → object
→ grouped sub-elements (Functions, Events, Subroutines) — matching the IDE's
mental model. They can jump straight in.

*Trust loss:* If the first landing screen is a dashboard with abstract
metrics (complexity heatmaps, file counts), the developer must first
understand what they are looking at before they can do anything useful.
Unfamiliar territory, unfamiliar format. Every second spent understanding the
UI is time not spent debugging.

**While navigating.**
The developer is comfortable with keyboard shortcuts. They will reach for `/`
immediately. If the search overlay is fast and the results link directly into
source (not into a search-results purgatory), they feel the tool accelerating
their work. If following a caller link triggers a navigation away from the
source tree — losing the hierarchical context they built up — they feel
punished for following a question.

*Trust loss triggers:*
- Callers are not visible from the source view. Must "go to diagrams" — mode
  switch, spatial reset.
- Sub-elements appear as a flat list, not grouped by kind (Functions / Events
  / Subroutines). The PB IDE spatial model is broken.
- The Analysis face changes layout radically from the Source face. Must
  re-orient on every toggle.
- The breadcrumb disappears when navigating deep into a caller chain.
- An identifier in the source code is not a link.

*Confidence builders:*
- Source Tree is the first thing visible in the sidebar, already expanded
  to show libraries.
- Sub-elements are grouped by kind under each object: Functions, Events,
  Subroutines — matching the IDE.
- Callers listed on the Analysis face, accessible in one keystroke from
  Source.
- Breadcrumb always present, always correct, always navigable.
- Every name in every list is clickable.
- The source tree sidebar remains in place; its expansion state persists
  through navigation.

**The north star moment** for this persona: they follow a caller chain three
levels deep, return to the original function via breadcrumb, and find
everything exactly as they left it — tree expanded, source scroll position
preserved. The tool worked like a thought, not like a form.

---

## 2. Modernization Team

**Context.** Surveying an unfamiliar codebase to produce a migration
specification. "What does this window touch?" and "Is this the complete
picture?" are the two permanent questions. Completeness is the professional
stake — an incomplete inventory leads to a failed migration.

**On landing.**
The modernization team member arrives in an inventory-taking state. They
need the broad shape of the codebase before they can focus on specifics: how
many objects, how many DataWindows, how deep the inheritance, how complex the
hotspots. The dashboard is the right landing screen for this persona — but
only if the numbers on it are visibly complete and consistent.

*Trust trigger:* The dashboard shows "777 files parsed / 777 files found" or
equivalent. The corpus is fully indexed; nothing is hidden. Every count is
consistent with the others (object count matches library object listings,
DataWindow count matches the DataWindows list).

*Trust loss triggers:*
- A corpus health indicator showing parse errors without a clear path to
  understanding them. If 12 files failed, are those 12 files relevant?
- Inconsistent counts: the dashboard says "412 objects" but the Objects list
  shows 398 rows. Small discrepancies destroy confidence in the inventory.
- "Tables accessed" on an Object's analysis face is a partial list without
  explanation. Are these all the tables, or only the ones that parsed
  cleanly?
- No completeness indicator anywhere — the user cannot tell if they have the
  full picture or a subset.

**While navigating.**
This persona uses list views heavily — all DataWindows, all objects of a
given type, all procedures sorted by complexity. They are pattern-seeking
rather than target-seeking. They need filtering and sorting, and they need
results that drill down without abandoning the list context.

*Trust loss triggers:*
- Clicking a row in the Objects list opens the object in a way that loses the
  list's sort/filter state. Cannot return to "where I was."
- The analysis face does not aggregate across the full call graph. "Tables
  accessed" shows only the object's direct SQL, not the tables reached via
  called procedures.
- An analysis metric changes between visits without explanation — suggests
  inconsistent indexing.

*Confidence builders:*
- Every list view shows a total count and preserves filter state.
- The analysis face aggregates across the full graph (callees, DW
  dependencies) and says so explicitly.
- Parse errors are surfaced with a count and a link to the Diagnostics
  screen, so the user can evaluate whether they affect their work.
- P1 analysis results carry the label "Structural (P1)" so the user knows
  exactly what kind of analysis produced them.

**The north star moment** for this persona: they open Object Detail, toggle
to Analysis, and see a single table listing every database table the object
touches — including those reached through all DataWindows and all called
procedures — with a count and a "based on full call graph" label. The
question "what does this window touch?" is answered in one view, completely.

---

## 3. Auditor

**Context.** Needs to produce a defensible audit conclusion, not an opinion.
Ambiguity is a professional problem. The move from "I believe this path is
safe" (manual inspection) to "this is formally proven safe" (P4
verification) is the emotional north star for this persona. Anything that
makes a result look like a heuristic — imprecise language, unexplained
methodology, missing proof artifacts — is disqualifying.

**On landing.**
The auditor arrives in a calibration state. Before asking any question, they
need to understand what the tool can and cannot prove, at what confidence
level, and with what assumptions. If this is a P1-only deployment, the
auditor needs to know that structural analysis cannot prove the absence of a
data flow — it can only enumerate procedures. They should not be left to
infer the tool's limitations.

*Trust trigger:* The phase model is visible in the interface. Every analysis
result carries a phase label (P1: structural, P3: taint, P4: formal) that
maps to a clearly defined capability. The auditor can read those labels and
understand the strength of the evidence.

*Trust loss triggers:*
- A result presented without provenance: "taint path found" with no
  indication of what kind of analysis produced it, what its assumptions are,
  or whether it is exhaustive.
- Language that implies certainty without a formal basis: "safe," "no
  vulnerabilities found" at P1 or P2 analysis depth.
- A proof result (P4 UNSAT) with no proof artifact — just a badge. An
  auditor cannot sign off on a badge.
- Phase-gated features labelled "coming soon." This creates uncertainty: if
  P4 is "coming soon," does the current tool's P3 result constitute
  sufficient evidence for a conclusion?

**While navigating.**
The auditor uses Ask heavily — specifically P3 and P4 queries. They need to
follow a taint path step by step, from source to sink, and verify that each
step is exactly what the code says. Any gap between the analysis result and
the actual source is disqualifying.

*Trust loss triggers:*
- A taint path step that names a procedure and a line, but clicking it does
  not land on that exact line in the source.
- A taint path that does not show what transformation happened at each step —
  only the sequence of procedures, not the data flow within them.
- Ask results that silently omit paths because of an analysis limitation not
  surfaced to the user.

*Confidence builders:*
- Every taint path step is a precise link to the exact source line.
- Formal proofs show the Z3 proof certificate (or a summary) inline.
- Counterexamples are concrete: specific input values, specific execution
  path, each step linked to source.
- Phase labels are precise and informative: "P3 — context-insensitive taint
  analysis" not just "P3."
- The tool is honest about what is not yet built: a P4 gate says "Formal
  verification requires P4 analysis infrastructure; results below are P3
  taint analysis" — not "coming soon."

**The north star moment** for this persona: they ask "Prove that all paths
from user input to the accounts table pass through f_validate_user." The tool
returns UNSAT with a proof certificate. The auditor can expand the proof
tree, check the assumptions (no `Any`-typed values in scope, no dynamic
dispatch in the path), and produce a signed audit conclusion. The journey
from suspicion to proof happened in the tool, not in a spreadsheet.
