# Bombadil UI Testing Skill

Self-contained guide for writing, validating, and maintaining Bombadil property-based tests for web UIs. Load this document when tasked with writing or reviewing `bombadil-spec.ts` files.

---

## PART 1: LEARN

---

### 1. Overview

Bombadil is a temporal-logic property-based testing framework for web UIs. It:

1. Launches a real Chromium browser against your app
2. Generates random sequences of actions (clicks, scrolls, typing, navigation)
3. Extracts DOM state after each action
4. Checks every exported `Formula` against the current state
5. Reports violations with a full action trace

**30-second mental model:** Property-based testing that walks the UI for you. You write invariants ("the sidebar always has 5 items"). Bombadil randomly explores the UI trying to break them.

**When to use Bombadil:**
- Testing SPA routing, navigation, and state coherence
- Finding crashers and blank-screen bugs via random interaction
- Regression testing after UI refactors
- Verifying structural invariants survive rapid interaction

**When NOT to use Bombadil:**
- Unit testing individual components (use vitest)
- Visual regression testing (use Percy/Chromatic)
- Performance benchmarking
- Testing non-Chromium browsers

---

### 2. API Reference

#### 2.1 Imports and Run Configuration

```typescript
import {
  extract,
  always,
  now,
  next,
  eventually,
  actions,
  weighted,
  type Formula,
} from "@antithesishq/bombadil";
import type { State, Action } from "@antithesishq/bombadil/browser";

// Selective defaults — import only what you need.
// WARNING: defaultActions includes PressKey which hangs headless Chrome (Bombadil 0.6.0).
export {
  noUncaughtExceptions,
  noUnhandledPromiseRejections,
} from "@antithesishq/bombadil/browser/defaults";
```

**Run commands** (from `package.json`):

| Command | Behavior | Use case |
|---------|----------|----------|
| `pnpm bombadil` | Headless, exit-on-violation, 5m | Iterative development — stops at first failure |
| `pnpm bombadil:long` | Headless, no early exit, 5m | Coverage survey — records all actions |
| `pnpm bombadil:headed` | Visible browser, exit-on-violation, 5m | Debugging — watch what Bombadil does |

**Output directory:** `/tmp/bombadil-pb/`
- `trace.jsonl` — every action, one JSON object per line
- `screenshot-*.png` — browser state at violation moment

**Prerequisite:** Backend must be running (`uv run pb explore` on localhost:8000).

---

#### 2.2 Extractors

Extractors pull data from the browser state. They run fresh on every check — no state carries over between invocations.

```typescript
// Simple extractor
const pathname = extract((state) => state.window.location.pathname);

// Compound extractor (multiple fields, single DOM query)
const backButtons = extract((state) => {
  const btns = state.document.querySelectorAll(".back-btn");
  const winH = state.window.innerHeight;
  return Array.from(btns).map((b) => {
    const rect = b.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      text: b.textContent?.trim() ?? "",
      visible: rect.width > 0 && rect.height > 0
        && rect.top >= 0 && rect.bottom <= winH
        && rect.left >= 0 && rect.right <= state.window.innerWidth,
    };
  });
});
```

**Access pattern:** `extractorName.current` gives the current value in formulas.

**`state` object:**
- `state.document` — the DOM (use `querySelector`, `querySelectorAll`)
- `state.window` — `location`, `innerHeight`, `innerWidth`, `scrollX`, `scrollY`

---

#### 2.3 Temporal Operators

| Operator | Signature | Semantics |
|----------|-----------|-----------|
| `always(() => bool)` | Safety | Must be true at EVERY state. Checked after every action. |
| `now()` | State accessor | Current state value (inside extractors for transition checks). |
| `next()` | State accessor | Next state value (for `now().implies(next(...))` patterns). |
| `eventually(() => bool)` | Liveness | Must become true at some future state. |
| `.within(N, "unit")` | Time bound | `eventually` must succeed within N seconds/minutes. |
| `implies` | Logical | `A.implies(B)` = if A then B. Used with `now().implies(...)`. |

**Safety property** (most common):
```typescript
export const sidebarHasCorrectCount: Formula = always(() =>
  sidebarNavLinks.current.length === 5,
);
```

**Liveness property** (use sparingly):
```typescript
export const loadingAlwaysTerminates: Formula = always(() =>
  now(loadingSpinners.current > 0).implies(
    eventually(() => loadingSpinners.current === 0).within(10, "seconds")
  )
);
```

**State machine property** (transition validity):
```typescript
// Example: after clicking a nav link, the active state changes
export const navClickChangesActiveState: Formula = always(() => {
  const before = activeNavCount.current;
  // After any action, if we were in a valid state before, we're still valid
  return before >= 0; // simplified — real usage is more nuanced
});
```

---

#### 2.4 Actions

Actions are the random inputs Bombadil generates. Define them with `actions()`, compose with `weighted()`.

```typescript
// Single action generator
export const clickNavLinks = actions(() =>
  navLinksAction.current.map((link) => ({
    Click: { name: `nav-${link.label}`, point: { x: link.x, y: link.y } },
  })),
);

// Multi-step action (focus → type)
export const typeIntoSearch = actions(() => {
  const inputs = searchInputs.current.filter((i) => i.visible);
  if (inputs.length === 0) return [];
  const inp = inputs[0]!;
  return [
    { Click: { name: "search-focus", point: { x: inp.x, y: inp.y } } },
    { TypeText: { text: "test", delayMillis: 30 } },
  ];
});

// Static action list
export const browserNavActions = actions((): Action[] => ["Back", "Forward"]);
```

**Action types:**

| Type | Shape | Notes |
|------|-------|-------|
| `Click` | `{ Click: { name: string, point: { x, y } } }` | Primary interaction |
| `TypeText` | `{ TypeText: { text: string, delayMillis: number } }` | Text input |
| `ScrollDown` | `{ ScrollDown: { origin: { x, y }, distance: number } }` | Vertical scroll |
| `ScrollUp` | `{ ScrollUp: { origin: { x, y }, distance: number } }` | Vertical scroll |
| `PressKey` | `{ PressKey: { code: number } }` | **BUGGY in headless 0.6.0** |
| `"Back"` | bare string | Browser back |
| `"Forward"` | bare string | Browser forward |
| `"Reload"` | bare string | Page reload |
| `"Wait"` | bare string | No-op, lets async settle |

**Weighted composition:**

```typescript
export const navigationActions = weighted([
  [15, clickNavLinks],     // Primary navigation (highest weight)
  [8,  clickTableRows],    // List → detail
  [5,  clickBackButtons],  // Detail → list
  [4,  clickTableChips],   // Cross-link navigation
  [3,  clickAllButtons],   // Catch-all
  [3,  browserNavActions], // Browser Back/Forward
  [2,  scrollActions],     // Scroll
  [2,  clickTreeNodes],    // Explore feature
  [2,  typeIntoSearch],    // Search
]);
```

---

#### 2.5 Formula Type and Export Conventions

- All properties must be exported as `const name: Formula`
- Action generators must be exported (Bombadil discovers them by export name)
- The `Formula` type is imported from `@antithesishq/bombadil`
- Section headers use `// ==` comment blocks with a category number and name
- Properties within a section are grouped by concern

---

## PART 2: DISCOVER WHAT TO TEST

---

### 3. Prescriptive Methodology: UI Property Discovery

Follow this order. Each step builds on the previous one. Skipping steps leads to gaps.

**Step 1: Structural invariants** — "the DOM shape doesn't break"
- Sidebar has correct number of items, correct labels, correct order
- Header exists and is visible
- Element counts match expectations
- *Do first because structural breakage is the most common regression.*

**Step 2: Navigation liveness** — "you can always go back"
- Back buttons exist on every detail view
- Navigation converges (multiple paths → same destination)
- Browser back/forward work correctly
- *Do second because navigation is the primary user interaction pattern.*

**Step 3: State coherence** — "URL, view, and sidebar agree"
- Active sidebar link matches current route
- URL pathname is well-formed (no trailing slashes, no double slashes)
- Route is always a known view (no unknown paths)
- *Do third because state desync is a silent, hard-to-catch class of bugs.*

**Step 4: Input safety** — "no crashes on interaction"
- Search inputs are interactive (have placeholders, accept input)
- Form buttons respect validation (disabled when required params empty)
- No uncaught exceptions on any click
- *Do fourth because input safety catches the widest class of crashers.*

**Step 5: View integrity** — "content loads, nothing blank"
- Main content area is never empty
- No stale "Loading..." without a spinner
- No blank screens after navigation
- *Do fifth because blank screens are the most visible user-facing bug.*

**Step 6: Cross-link consistency** — "same entity → same destination"
- Table chips lead to the correct detail view
- Clicking the same entity from different paths reaches the same view
- *Do sixth because cross-link bugs are real but less common than structural bugs.*

**Step 7: Rapid interaction resilience**
- State remains consistent under fast clicking, scrolling, navigation
- No race conditions between navigation and rendering
- *Do last because this requires all previous properties to be in place.*

---

### 4. Property Taxonomy

Choose the right property type for the invariant you're checking.

#### 4.1 Safety (`always`)
Most properties are safety properties. They assert something must NEVER be violated.

```typescript
// Good safety property: clear invariant, binary check
export const exactlyOneActiveLink: Formula = always(() =>
  activeNavCount.current === 1,
);
```

Use when: the invariant should hold at every single state the UI can be in.

#### 4.2 Liveness (`eventually` + `within`)
Something must EVENTUALLY become true within a time bound.

```typescript
export const loadingAlwaysTerminates: Formula = always(() =>
  now(loadingSpinners.current > 0).implies(
    eventually(() => loadingSpinners.current === 0).within(10, "seconds")
  )
);
```

Use when: the invariant is "this bad state is temporary." **Use sparingly** — false positives from backend latency degrade signal-to-noise.

#### 4.3 Frame Conditions
A safety property that asserts some state does NOT change when an unrelated action occurs.

```typescript
export const themeAlwaysSet: Formula = always(() => {
  const t = bodyTheme.current;
  return t === "dark" || t === "light";
});
```

This isn't just "theme exists" — it's "theme is not cleared by navigation." The frame is: navigation actions should not affect theme.

Use when: some piece of global state (theme, user session, sidebar state) should persist across unrelated actions.

#### 4.4 State Machine (`now` → next)
Checks that the next state satisfies some condition given the current state.

Use when: you need to verify transition validity — "after action X, state Y must hold." Requires extractors that capture both pre- and post-action state.

#### 4.5 Mutual Exclusion
Never two things visible at the same time.

```typescript
// Conceptual: error panel and success panel should never both be visible
export const errorAndSuccessNeverBothVisible: Formula = always(() => {
  return !(errorPanel.current.visible && successPanel.current.visible);
});
```

Use when: two UI elements are logically contradictory (error + success, loading + content, modal + background interaction).

---

## PART 3: WRITE PROPERTIES

---

### 5. Tutorial: Writing a Property from Scratch

#### 5.1 Simple Safety: "sidebar always has N items"

**Thought process:**
1. What's the invariant? The sidebar always shows exactly 5 navigation items.
2. What DOM element? `.sidebar-nav a` — the navigation links.
3. What do I extract? The count of links.
4. What do I assert? Count === 5.

**Implementation:**

```typescript
// Step 1: Write the extractor
const sidebarNavLinks = extract((state) => {
  const links = state.document.querySelectorAll(".sidebar-nav a");
  return Array.from(links).map((a) => ({
    label: a.textContent?.trim() ?? "",
    isActive: a.classList.contains("active"),
  }));
});

// Step 2: Write the formula
export const sidebarHasCorrectCount: Formula = always(() =>
  sidebarNavLinks.current.length === 5,
);

// Step 3: Export it — Bombadil discovers exports automatically
```

**Mutation test:** Remove a sidebar item in the UI source. Run Bombadil. Confirm the property fires. Restore. Confirm clean run.

---

#### 5.2 Conditional Safety: "back button exists on every detail view"

**Thought process:**
1. What's the invariant? Every detail view has a back button.
2. What's a "detail view"? URL contains `/objects/...`, `/datawindows/...`, `/tables/...`.
3. What DOM element? `.back-btn`.
4. What's the condition? Only check when on a detail view.

**Implementation:**

```typescript
// Step 1: Extract current view (re-derive from URL)
const currentView = extract((state) => {
  const path = state.window.location.pathname;
  if (!path || path === "/") return "dashboard";
  const segs = path.split("/").filter(Boolean);
  if (segs[0] === "objects") return segs[1] ? "objectDetail" : "objects";
  if (segs[0] === "datawindows") return segs[1] ? "dwDetail" : "datawindows";
  if (segs[0] === "tables") return segs[1] ? "tableDetail" : "tables";
  return segs[0] ?? "dashboard";
});

// Step 2: Extract back buttons with visibility check
const backButtons = extract((state) => {
  const btns = state.document.querySelectorAll(".back-btn");
  return Array.from(btns).map((b) => {
    const rect = b.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      visible: rect.width > 0 && rect.height > 0,
    };
  });
});

// Step 3: Conditional formula — only check on detail views
const DETAIL_VIEWS = ["objectDetail", "procedureDetail", "dwDetail", "tableDetail"];

export const detailViewsAlwaysHaveBackButton: Formula = always(() => {
  if (!DETAIL_VIEWS.includes(currentView.current)) return true;
  return backButtons.current.length > 0;
});
```

**Key insight:** The guard clause (`if (!DETAIL_VIEWS.includes(...)) return true`) prevents false positives on list views where back buttons aren't expected.

**Mutation test:** Remove the back button from one detail view component. Run Bombadil. Confirm the property fires when navigating to that view. Restore.

---

#### 5.3 Liveness: "loading eventually resolves"

**Thought process:**
1. What's the invariant? If a loading spinner is showing, it eventually disappears.
2. What DOM element? `.loading` or `[class*=spinner]`.
3. What time bound? 10 seconds (generous for backend latency).
4. What's the risk? Slow backend → false positive.

**Implementation:**

```typescript
// Step 1: Extract loading spinner count
const loadingSpinners = extract((state) =>
  state.document.querySelectorAll(".loading, [class*=spinner]").length
);

// Step 2: Liveness formula with time bound
export const loadingAlwaysTerminates: Formula = always(() =>
  now(loadingSpinners.current > 0).implies(
    eventually(() => loadingSpinners.current === 0).within(10, "seconds")
  )
);
```

**Key insight:** `now().implies(eventually().within())` means "if loading is showing NOW, it must resolve within 10 seconds." Without `.within()`, a permanently stuck spinner would never trigger the violation.

**Risk:** Backend latency > 10s causes false positive. Mitigation: increase the bound, or accept this as a known false-positive risk.

---

### 6. Good vs. Weak vs. Too-Strong Properties

#### 6.1 Strong Properties

| Property | Why it's strong |
|----------|----------------|
| `pathnameAlwaysWellFormed` | Specific, binary, catches real URL corruption bugs |
| `exactlyOneActiveLink` | Clear invariant, easy to verify, catches sidebar desync |
| `mainContentNeverEmpty` | Catches the most visible user-facing bug (blank screen) |
| `detailViewsAlwaysHaveBackButton` | Found a real bug in B2 (back button inside `<Show when={data}>`) |
| `themeAlwaysSet` | Frame condition that catches theme loss on navigation |

**Characteristics:** Concrete, testable, catches a real class of bugs, no false positives in practice.

#### 6.2 Weak Properties

| Property | Why it's weak |
|----------|---------------|
| `noConsoleErrors` | Dead extractor — creates new `[]` every check, always returns 0 |
| `activeLinkGroupConsistent` | Redundant — weaker duplicate of `activeLinkMatchesRoute` |
| `y > -1000` bound | Useless — passes for anything not 1000px off-screen top |
| Properties checking `.length > 0` without visibility | Element exists in DOM but is hidden — not a real invariant |

**Characteristics:** Always passes, covers nothing new, or is a weaker version of an existing property.

#### 6.3 Too-Strong Properties

| Property | Why it's too strong |
|----------|---------------------|
| `loadingAlwaysTerminates` without `.within()` | Backend latency → false positive |
| `urlMatchesDetailHeading` | Display name ≠ URL slug in many cases |
| Properties requiring exact pixel positions | Layout shifts, font rendering → flaky |

**Characteristics:** Catches real bugs but also fires on harmless states. False positives erode trust in the test suite.

---

## PART 4: VALIDATE

---

### 7. Extractor Design Patterns

#### 7.1 DOM Selectors: Specificity vs. Fragility

| Priority | Selector type | Example | Notes |
|----------|--------------|---------|-------|
| 1st | `data-*` attributes | `[data-query]` | Immune to CSS/class changes |
| 2nd | Semantic HTML | `button`, `input`, `nav` | Stable across refactors |
| 3rd | BEM-style classes | `.sidebar-nav` | Stable if naming is consistent |
| 4th | Compound classes | `.table-chip` | Fragile if CSS modules rename |
| 5th | Structural selectors | `.main-content > div:first-child` | Very fragile |

**Document validation status:** Track which selectors have been confirmed working. Use ✅ validated, ⬜ pending, ❌ broken.

#### 7.2 Bounding Boxes

Three levels of "element exists":

| Level | Check | Use when |
|-------|-------|----------|
| **Exists** | Element is in DOM | Counting elements, checking structure |
| **Visible** | `width > 0 && height > 0` | Click targets, interactive elements |
| **In-viewport** | Visible + within window bounds | Elements that must be on-screen |

```typescript
// Visible check (most common)
visible: rect.width > 0 && rect.height > 0

// In-viewport check (for elements that must be scrollable-to)
visible: rect.width > 0 && rect.height > 0
  && rect.top >= 0 && rect.bottom <= winH
  && rect.left >= 0 && rect.right <= winW
```

**Pick the right level:** Too strict (in-viewport when visible suffices) → false positives when element is scrolled off-screen. Too loose (exists when visible is needed) → asserts on hidden DOM.

#### 7.3 Compound Extractors

Single `extract()` returning multiple fields is better than multiple extractors:

```typescript
// Good: one DOM query, multiple fields
const backButtons = extract((state) => {
  const btns = state.document.querySelectorAll(".back-btn");
  return Array.from(btns).map((b) => ({
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
    text: b.textContent?.trim() ?? "",
    visible: rect.width > 0 && rect.height > 0,
  }));
});

// Bad: three separate extractors, three DOM queries
const backBtnX = extract((state) => { /* query */ });
const backBtnY = extract((state) => { /* same query */ });
const backBtnVisible = extract((state) => { /* same query again */ });
```

#### 7.4 When to Split vs. Merge

**Merge** when properties share the same data (back button position + visibility + text).

**Split** when extractors serve different properties (sidebar links for count vs. sidebar links for active state — same DOM, different formulas, different mutation targets).

---

### 8. Action Generator Design

#### 8.1 Weight Distribution Strategy

| Weight | Category | Rationale |
|--------|----------|-----------|
| 15 | Primary navigation | Most common user action, drives state changes |
| 8 | Detail navigation | List → detail is the second most common pattern |
| 5 | Back navigation | Tests back button liveness |
| 4 | Cross-link | Tests chip/link consistency |
| 3 | Catch-all buttons | Catches anything not covered by specific generators |
| 3 | Browser nav | Tests popstate handler (Back/Forward) |
| 2 | Scroll | Tests scroll behavior, off-screen elements |
| 2 | Feature-specific | Tree nodes, search, sort, pagination |

**Rule:** Navigation actions should dominate (>50% of total weight) because they drive the most state variety.

#### 8.2 Multi-Step Actions

Some actions require a sequence: focus → input → verify.

```typescript
export const typeIntoSearch = actions(() => {
  const inputs = searchInputs.current.filter((i) => i.visible);
  if (inputs.length === 0) return [];  // Guard: no visible inputs → no action
  const inp = inputs[0]!;
  return [
    { Click: { name: "search-focus", point: { x: inp.x, y: inp.y } } },
    { TypeText: { text: "test", delayMillis: 30 } },
  ];
});
```

**Pattern:** Guard with early return (empty array) when the target doesn't exist. This prevents Bombadil from trying to type into a nonexistent input.

#### 8.3 Defaults: What to Import and Skip

```typescript
// Selective import — avoids PressKey
export {
  noUncaughtExceptions,
  noUnhandledPromiseRejections,
} from "@antithesishq/bombadil/browser/defaults";

// DO NOT: export * from defaults (includes PressKey)
```

**Why:** `PressKey` hangs headless Chrome in Bombadil 0.6.0 + chromiumoxide. Always use selective imports.

#### 8.4 Known Bombadil Bugs

| Bug | Version | Workaround |
|-----|---------|------------|
| PressKey hangs headless Chrome | 0.6.0 | Selective import from defaults; test in headed mode first |

---

## PART 5: DEBUG

---

### 9. Mutation Testing: Proving Properties Catch Bugs

#### 9.1 Why Mutation Testing Matters

A property that always passes is not a test — it's decoration. You must prove the property fires when the invariant is broken. Without mutation testing, you can write 50 properties that all pass but catch nothing.

#### 9.2 The Mutation Workflow

1. **Break** — Introduce a targeted regression in the UI source code
   - Remove a sidebar item, hide a back button, blank the main content
   - Make the change minimal and reversible
2. **Verify** — Run Bombadil, confirm the property fires
   - The correct property should violation-report with meaningful extractor values
   - If a DIFFERENT property fires first, your property may need adjustment
3. **Restore** — Undo the break, confirm clean run
   - 0 violations on a 5-minute run confirms the property doesn't false-positive

#### 9.3 Mutation Targets by Property Type

| Property type | What to break | Example |
|---------------|---------------|---------|
| Structural | Remove/reorder DOM elements | Delete a sidebar `<a>` |
| Navigation | Remove back button, break route | Delete `.back-btn` from detail view |
| State coherence | Desync URL from view, remove active class | Remove `active` class from sidebar link |
| Input safety | Disable event handlers, remove elements | Delete `button[data-query]` |
| Liveness | Add permanent loading spinner | Change loading state to never resolve |
| Frame conditions | Clear theme class, reset state | Remove `data-theme` attribute on navigation |

#### 9.4 When to Skip Mutation Testing

Only when the property checks something Bombadil's action generators can't influence:

- `noUncaughtExceptions` — you can't easily trigger a JS exception via random clicks
- `noUnhandledPromiseRejections` — same reasoning

For everything else: mutation test it.

---

### 10. Debugging Violations

#### 10.1 Reading the Trace

After a violation, the output directory contains:

```bash
# See which property violated and extractor values
tail -50 /tmp/pb-bombadil-run.log

# Find violation entries in the trace
grep '"violation"' /tmp/bombadil-pb/trace.jsonl | head -5 | jq .

# See the last 20 actions before the violation
tail -20 /tmp/bombadil-pb/trace.jsonl | jq -r '.action // "check"'
```

The violation entry in `trace.jsonl` includes: property name, extractor values at the moment of violation, and timestamp.

#### 10.2 Bisecting the Action Sequence

```bash
# Extract action sequence (non-null actions only)
jq -r 'select(.action != null) | .action | if type == "string" then . else keys[0] end' \
  /tmp/bombadil-pb/trace.jsonl | tail -30
```

Look for: the transition from "all properties passing" to "one property failing." The action immediately before the first failure is the trigger.

#### 10.3 Real Bug vs. False Positive Triage

**Real bug:** The UI is actually broken. The property correctly identified a problem.
- Fix the UI code
- Add a targeted regression property (see 10.4)

**False positive:** The property is too strong, the selector is wrong, or the bound is too tight.
- Adjust the property (widen bounds, add guard clause, check visibility)
- Document the false-positive risk in the property's comment

#### 10.4 Adding Targeted Regression Properties

After finding a real bug, write a property that specifically guards against that scenario:

```typescript
// After finding: back buttons disappear inside <Show when={data}>
// Regression property: specifically checks back button existence on detail views
export const detailViewsAlwaysHaveBackButton: Formula = always(() => {
  if (!DETAIL_VIEWS.includes(currentView.current)) return true;
  return backButtons.current.length > 0;
});
```

**Key:** Targeted regression properties are more specific than generic invariants. They answer "could this exact bug recur?" not just "is the UI generally okay?"

#### 10.5 Adjusting Bounds and Selectors

Common fixes:

| Problem | Fix |
|---------|-----|
| Element scrolled off-screen triggers false positive | Change from in-viewport to visible check |
| Numeric bound too tight | Widen: `y > -1000` → `y > 0 && y < 2000` |
| Selector matches wrong elements | Make more specific: `.back-btn` → `.detail-view .back-btn` |
| Property fires on valid state | Add guard clause for conditional views |
| Liveness fires on slow backend | Add `.within(N, "seconds")` time bound |

---

## PART 6: MAINTAIN

---

### 11. Action Distribution Analysis

#### 11.1 Reading the Action Distribution

After a 5-minute `bombadil:long` run:

```bash
jq -r 'select(.action != null) | .action | if type == "string" then . else keys[0] end' \
  /tmp/bombadil-pb/trace.jsonl | sort | uniq -c | sort -rn
```

**Reference distributions:**

| Run | Top actions |
|-----|-------------|
| B1 (5m headed) | Click 4612, TypeText 379, ScrollDown 158, PressKey 9, ScrollUp 3 |
| B2 (5m headless) | Click 930, Back 144, Forward 131, ScrollDown 128, ScrollUp 113, TypeText 83 |

#### 11.2 Identifying Coverage Gaps

| Red flag | Meaning | Action |
|----------|---------|--------|
| One action >60% of total | Other paths aren't explored | Rebalance weights |
| Single element dominates clicks | Generator too narrow | Broaden selector or increase variety |
| Expected action at 0 count | Generator broken or elements don't exist | Debug the generator |
| Navigation <10% of total | Not enough route variety | Increase navigation weights |

#### 11.3 Rebalancing Weights

```typescript
// Before: navigation is only 20% of total weight
weighted([[5, clickNavLinks], [15, scrollActions]])

// After: rebalance to prioritize navigation
weighted([[15, clickNavLinks], [2, scrollActions]])
```

#### 11.4 When to Add New Action Generators

Add a new generator when:
- Distribution shows a UI path is never explored
- A new feature was added that needs testing
- An existing property can only be validated by a specific action sequence

---

### 12. Anti-Patterns (from B1-B5 Experience)

#### 12.1 Dead Extractors

```typescript
// BAD: accumulator resets every check — always returns 0
const errs: string[] = [];
window.onerror = (msg) => { errs.push(String(msg)); };
const errorCount = extract(() => errs.length);  // always 0

// GOOD: read from a persistent source
const errorCount = extract((state) =>
  state.window.__errorCount ?? 0  // read from a persistent accumulator
);
```

**Lesson:** Extractors run fresh each check. No state carries over. If your extractor creates local state, it's dead.

#### 12.2 Redundant Properties

```typescript
// BAD: weaker duplicate — already covered by activeLinkMatchesRoute
export const activeLinkGroupConsistent: Formula = always(() => {
  const idx = activeNavIndex.current;
  if (idx < 0) return false;
  const itemPath = NAV_LABELS[idx]!.toLowerCase();
  return VIEW_GROUPS[itemPath]?.includes(currentView.current) ?? false;
});

// GOOD: the original is strictly stronger
export const activeLinkMatchesRoute: Formula = always(() => {
  const idx = activeNavIndex.current;
  if (idx < 0 || idx >= NAV_LABELS.length) return false;
  const itemPath = NAV_LABELS[idx]!.toLowerCase();
  return isActiveFor(itemPath, currentView.current);
});
```

**Lesson:** Before adding a property, check if an existing one already covers the invariant. Redundant properties add maintenance cost without coverage.

#### 12.3 Overly Loose Bounds

```typescript
// BAD: y > -1000 passes for anything not 1000px off-screen top
visible: b.y > -1000

// GOOD: bounds that fail for meaningful bad states
visible: b.x > 0 && b.y > 0 && b.y < 2000
```

**Lesson:** Bounds should fail for a meaningful fraction of bad states. If your bound passes for 99.9% of states, it's not a test.

#### 12.4 Selector Fragility

```typescript
// BAD: class name that changes with CSS modules
state.document.querySelectorAll(".sc-bdVTJa")

// GOOD: semantic or data attribute
state.document.querySelectorAll("[data-sidebar-nav]")
state.document.querySelectorAll("nav a")
```

**Lesson:** Prefer selectors that survive refactoring. Document which selectors are validated.

#### 12.5 Missing Visible Checks

```typescript
// BAD: asserts on hidden element
export const backButtonExists: Formula = always(() =>
  backButtons.current.length > 0  // button exists in DOM but is display:none
);

// GOOD: checks visibility
export const backButtonsAreClickable: Formula = always(() =>
  backButtons.current.every((b) => !b.visible || (b.x > 0 && b.y > 0))
);
```

**Lesson:** An element existing in the DOM is not the same as it being usable. Always check visibility when the invariant is about user-facing state.

#### 12.6 Liveness Without Time Bound

```typescript
// BAD: no time bound — permanently stuck spinner never triggers
export const loadingResolves: Formula = always(() =>
  now(loadingSpinners.current > 0).implies(
    eventually(() => loadingSpinners.current === 0)
  )
);

// GOOD: bounded liveness
export const loadingResolves: Formula = always(() =>
  now(loadingSpinners.current > 0).implies(
    eventually(() => loadingSpinners.current === 0).within(10, "seconds")
  )
);
```

**Lesson:** Every `eventually()` needs a `.within()` bound. Without it, a permanently stuck state never triggers the violation.

---

### 13. What Bombadil Can't Test

| Limitation | Impact | Alternative |
|------------|--------|-------------|
| Chromium only | No Firefox/Safari testing | Playwright multi-browser |
| No iframe interaction | Can't test embedded content | Playwright frame API |
| No drag-and-drop | Can't test DnD UIs | Playwright drag API |
| No file upload | Can't test upload flows | Playwright file chooser API |
| No cross-origin | Can't test CORS issues | Manual testing |
| No timing assertions | Can't test <100ms transitions | Playwright timing |
| No visual regression | Can't test pixel-perfect layout | Percy, Chromatic |

**Set expectations:** Bombadil is excellent for structural/navigation/state-coherence testing. It is not a replacement for cross-browser, visual, or performance testing.

---

## PART 7: CHECKLISTS

---

### 14. Pre-flight Checklist

#### Before writing a property:

- [ ] Identify the invariant in plain English ("the sidebar always shows 5 items")
- [ ] Classify: safety / liveness / frame / state-machine / mutual-exclusion
- [ ] Confirm the target selector exists and is validated (or validate it first)
- [ ] Check for duplicate coverage (does an existing property already catch this?)

#### During implementation:

- [ ] Write the extractor first — verify `.current` values are correct in isolation
- [ ] Write the formula — add to exports with correct section header
- [ ] Name it: `<noun><Assertion>` (e.g., `sidebarHasCorrectCount`)
- [ ] Guard conditional properties with view/state checks to prevent false positives

#### After adding to spec:

- [ ] Run Bombadil clean — 0 violations on existing properties
- [ ] Mutation test — break UI, confirm new property fires
- [ ] Restore — 0 violations after undo
- [ ] Update `doc/bombadil.md` property inventory
- [ ] Update selector validation table if new selectors added

---

### 15. Naming Conventions

**Property names:** `<noun><Assertion>` pattern

| Pattern | Example |
|---------|---------|
| `<element>Has<Count>` | `sidebarHasCorrectCount` |
| `<element>Is<Adjective>` | `sidebarHeaderVisible` |
| `<element>Matches<Route>` | `activeLinkMatchesRoute` |
| `<element>AreClickable` | `backButtonsAreClickable` |
| `<view>Always<Has>` | `detailViewsAlwaysHaveBackButton` |
| `no<BadThing>` | `noStaleLoadingIndicator` |
| `<thing>Always<Set>` | `themeAlwaysSet` |
| `<path>Always<WellFormed>` | `pathnameAlwaysWellFormed` |

**Section numbering:** Group by concern (structural, navigation, state, input, view, cross-link, scroll, badge, query, theme).

**Selector validation:** Track status per selector — ✅ validated, ⬜ pending, ❌ broken.

---

### 16. Known False-Positive Risks

| Property | Risk | Mitigation |
|----------|------|------------|
| `loadingAlwaysTerminates` | Backend slow | Use `.within(10, "seconds")` |
| `noOverlappingSpinnerAndContent` | Transition frames during render | Guard with `.loading:not(.hidden)` |
| `urlMatchesDetailHeading` | Display name ≠ URL slug | Confirm by reading component source |

---

*Last updated: 2026-06-18. Based on Bombadil 0.6.0 and pb-explorer B1-B5 sessions.*
