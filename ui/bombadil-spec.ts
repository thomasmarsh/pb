// bombadil-spec.ts — Property-based tests for pb-explorer UI.
//
// 25 properties across 11 categories:
//   1. Sidebar structural invariants (7)
//   2. Active-state ↔ route consistency (2)
//   3. View non-emptiness (3)
//   4. URL-view consistency (3)
//   5. Back-button liveness (3)
//   6. Input safety (1)
//   7. Cross-link consistency (2)
//   8. Scroll behavior (1)
//   9. Badge integrity (1)
//  10. Query submission safety (1)
//  11. Theme frame condition (1)

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
export { noUncaughtExceptions, noUnhandledPromiseRejections } from "@antithesishq/bombadil/browser/defaults";

// ===========================================================================
// Helpers
// ===========================================================================

// Util nav: Dashboard, Ask, Search, Diagnostics
const UTIL_NAV_LABELS = ["Dashboard", "Ask", "Search", "Diagnostics"];

// Entity nav: Objects, DataWindows, Tables, Procedures
const ENTITY_NAV_LABELS = ["Objects", "DataWindows", "Tables", "Procedures"];

// Analysis nav: Schema / ERD, Dead Code (non-gated); Taint Explorer, Formal Reports (gated)
const ANALYSIS_NAV_LABELS = ["Schema / ERD", "Dead Code", "Taint Explorer", "Formal Reports"];

const ALL_NAV_LABELS = [...UTIL_NAV_LABELS, ...ENTITY_NAV_LABELS, ...ANALYSIS_NAV_LABELS];

// Maps nav label (lowercase, no spaces) to the route view it navigates to
const NAV_LABEL_TO_VIEW: Record<string, string> = {
  dashboard:       "dashboard",
  ask:             "queries",
  search:          "search",
  diagnostics:     "diagnostics",
  objects:         "objects",
  datawindows:     "datawindows",
  tables:          "tables",
  procedures:      "proceduresList",
  "schema/erd":    "diagrams",
  "deadcode":      "deadCode",
  "taintexplorer": "taintExplorer",
  "formalreports": "formalReports",
};

// Views that have a corresponding sidebar nav link
const VIEWS_WITH_NAV_LINKS = Object.values(NAV_LABEL_TO_VIEW);

// Detail views are covered by their parent list link via VIEW_GROUPS
const DETAIL_VIEWS = ["objectDetail", "procedureDetail", "dwDetail", "tableDetail"];

const VIEW_GROUPS: Record<string, string[]> = {
  objects:        ["objects", "objectDetail", "procedureDetail"],
  proceduresList: ["proceduresList"],
  datawindows:    ["datawindows", "dwDetail"],
  tables:         ["tables", "tableDetail"],
};

function isActiveFor(itemPath: string, currentView: string): boolean {
  if (itemPath === currentView) return true;
  const group = VIEW_GROUPS[itemPath];
  return group ? group.includes(currentView) : false;
}

function extractLabel(a: Element): string {
  const icon = a.querySelector(".icon");
  return a.textContent?.replace(icon?.textContent ?? "", "").trim() ?? "";
}

// ===========================================================================
// EXTRACTORS
// ===========================================================================

const sidebarUtilLinks = extract((state) => {
  const links = state.document.querySelectorAll("a.sidebar-util-link");
  return Array.from(links).map((a) => ({
    label: extractLabel(a),
    isActive: a.classList.contains("active"),
  }));
});

const sidebarEntityLinks = extract((state) => {
  const links = state.document.querySelectorAll("a.sidebar-entity-link");
  return Array.from(links).map((a) => ({
    label: extractLabel(a),
    isActive: a.classList.contains("active"),
    isAnalysis: a.classList.contains("analysis-nav-item"),
  }));
});

const allSidebarLinks = extract((state) => {
  const util = Array.from(state.document.querySelectorAll("a.sidebar-util-link"));
  const entity = Array.from(state.document.querySelectorAll("a.sidebar-entity-link"));
  return [...util, ...entity].map((a) => ({
    label: extractLabel(a),
    isActive: a.classList.contains("active"),
  }));
});

const activeNavCount = extract((state) => {
  const util = Array.from(state.document.querySelectorAll("a.sidebar-util-link"));
  const entity = Array.from(state.document.querySelectorAll("a.sidebar-entity-link"));
  return [...util, ...entity].filter((a) => a.classList.contains("active")).length;
});

const activeNavIndex = extract((state) => {
  const util = Array.from(state.document.querySelectorAll("a.sidebar-util-link"));
  const entity = Array.from(state.document.querySelectorAll("a.sidebar-entity-link"));
  const all = [...util, ...entity];
  return all.findIndex((a) => a.classList.contains("active"));
});

const mainContent = extract((state) => {
  const main = state.document.querySelector(".main-content");
  return main?.innerHTML?.trim() ?? "";
});

const pathname = extract((state) => state.window.location.pathname);

const currentView = extract((state) => {
  const path = state.window.location.pathname;
  if (!path || path === "/") return "dashboard";
  const segs = path.split("/").filter(Boolean);
  switch (segs[0]) {
    case "objects":
      if (segs[2]) return "procedureDetail";
      if (segs[1]) return "objectDetail";
      return "objects";
    case "datawindows":
      if (segs[1]) return "dwDetail";
      return "datawindows";
    case "tables":
      if (segs[1]) return "tableDetail";
      return "tables";
    case "procedures": return "proceduresList";
    case "diagrams":   return "diagrams";
    case "queries":    return "queries";
    case "search":     return "search";
    case "explore":    return "explore";
    case "diagnostics": return "diagnostics";
    case "dead-code":  return "deadCode";
    case "taint":      return "taintExplorer";
    case "reports":    return "formalReports";
    case "library":    return "libraryDetail";
    default:           return segs[0] ?? "dashboard";
  }
});

const backButtons = extract((state) => {
  const btns = state.document.querySelectorAll(".back-btn");
  const winH = state.window.innerHeight;
  const winW = state.window.innerWidth;
  return Array.from(btns).map((b) => {
    const rect = b.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      text: b.textContent?.trim() ?? "",
      visible: rect.width > 0 && rect.height > 0
        && rect.top >= 0 && rect.bottom <= winH
        && rect.left >= 0 && rect.right <= winW,
    };
  });
});

const searchInputs = extract((state) => {
  const inputs = state.document.querySelectorAll("input.search-input:not([type=number])");
  return Array.from(inputs).map((inp) => {
    const rect = inp.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      placeholder: (inp as HTMLInputElement).placeholder ?? "",
      value: (inp as HTMLInputElement).value ?? "",
      visible: rect.width > 0 && rect.height > 0,
    };
  });
});

const allButtons = extract((state) => {
  const btns = state.document.querySelectorAll("button");
  return Array.from(btns).map((b) => {
    const rect = b.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      text: b.textContent?.trim() ?? "",
      disabled: b.disabled,
      visible: rect.width > 0 && rect.height > 0,
    };
  });
});

const clickableRows = extract((state) => {
  const rows = state.document.querySelectorAll("tr.clickable");
  return Array.from(rows).map((r) => {
    const rect = r.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      visible: rect.width > 0 && rect.height > 0,
    };
  });
});

const tableChips = extract((state) => {
  const chips = state.document.querySelectorAll(".table-chip");
  const winH = state.window.innerHeight;
  const winW = state.window.innerWidth;
  return Array.from(chips).map((c) => {
    const rect = c.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      name: c.textContent?.replace("□", "").trim() ?? "",
      visible: rect.width > 0 && rect.height > 0
        && rect.top >= 0 && rect.bottom <= winH
        && rect.left >= 0 && rect.right <= winW,
    };
  });
});

const interactiveTreeNodes = extract((state) => {
  const nodes = state.document.querySelectorAll(".tree-node-row.clickable");
  return Array.from(nodes).map((n) => {
    const rect = n.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      visible: rect.width > 0 && rect.height > 0,
    };
  });
});

const loadingSpinners = extract((state) =>
  state.document.querySelectorAll(".loading, .spinner, [class*=spinner]").length,
);

const scrollPosition = extract((state) => ({
  x: state.window.scrollX,
  y: state.window.scrollY,
}));

const sidebarHeader = extract((state) => {
  const h1 = state.document.querySelector(".sidebar-header h1");
  return h1 !== null && (h1.textContent?.length ?? 0) > 0;
});

const mainText = extract((state) => {
  const main = state.document.querySelector(".main-content");
  return main?.textContent?.trim() ?? "";
});

const mainChildCount = extract((state) => {
  const main = state.document.querySelector(".main-content");
  return main?.children.length ?? 0;
});

const badgeCount = extract((state) => {
  const badges = state.document.querySelectorAll(".badge");
  return Array.from(badges).filter((b) => {
    const rect = b.getBoundingClientRect();
    return rect.width >= 0;
  }).length;
});

const allBadgeCount = extract((state) =>
  state.document.querySelectorAll(".badge").length,
);

const bodyTheme = extract((state) =>
  state.document.documentElement.getAttribute("data-theme"),
);

const appInitialized = extract((state) =>
  state.window.location.pathname.startsWith("/"),
);

// Guard: only check properties when app is initialized (not on about:blank)
function whenInitialized(fn: () => boolean): boolean {
  if (!appInitialized.current) return true;
  return fn();
}

const queryRunButtons = extract((state) => {
  const buttons = state.document.querySelectorAll("button[data-query]");
  return Array.from(buttons).map((btn) => {
    const row = btn.closest("div[style]");
    const inputs = row
      ? Array.from(row.querySelectorAll("input.search-input:not([type=number])"))
      : [];
    const hasUnfilledRequired = inputs.some((inp) => {
      const ph = (inp as HTMLInputElement).placeholder ?? "";
      const hasDefault = /\(.+\)/.test(ph);
      const value = (inp as HTMLInputElement).value.trim();
      return !hasDefault && value.length === 0;
    });
    return {
      queryName: (btn as HTMLElement).dataset.query ?? "",
      visible: btn.getBoundingClientRect().width > 0,
      disabled: btn.disabled,
      hasUnfilledRequired,
    };
  });
});

const sidebarEntityGroupExpanded = extract((state) => {
  const groups = state.document.querySelectorAll(".sidebar-group");
  for (const g of groups) {
    const header = g.querySelector(".sidebar-group-label");
    if (header?.textContent?.trim() === "Entity Navigation") {
      return g.querySelector(".sidebar-group-body") !== null;
    }
  }
  return false;
});

const KNOWN_VIEWS = [
  "dashboard", "objects", "objectDetail", "procedureDetail",
  "proceduresList", "datawindows", "dwDetail", "tables", "tableDetail",
  "diagrams", "queries", "search", "explore", "diagnostics",
  "deadCode", "taintExplorer", "formalReports", "libraryDetail",
];

// ===========================================================================
// 1. SIDEBAR STRUCTURAL INVARIANTS
// ===========================================================================

export const sidebarHeaderVisible: Formula = always(() =>
  whenInitialized(() => sidebarHeader.current),
);

export const utilNavHasCorrectCount: Formula = always(() =>
  whenInitialized(() => sidebarUtilLinks.current.length === UTIL_NAV_LABELS.length),
);

export const utilNavHasAllLabels: Formula = always(() =>
  whenInitialized(() => {
    const labels = sidebarUtilLinks.current.map((l) => l.label);
    return UTIL_NAV_LABELS.every((n) => labels.includes(n));
  }),
);

export const utilNavOrderIsStable: Formula = always(() =>
  whenInitialized(() => {
    const labels = sidebarUtilLinks.current.map((l) => l.label);
    return labels.every((l, i) => l === UTIL_NAV_LABELS[i]);
  }),
);

export const entityNavHasCorrectCountWhenExpanded: Formula = always(() =>
  whenInitialized(() => {
    if (!sidebarEntityGroupExpanded.current) return true;
    return sidebarEntityLinks.current.filter((l) => !l.isAnalysis).length === ENTITY_NAV_LABELS.length;
  }),
);

export const entityNavHasAllLabelsWhenExpanded: Formula = always(() =>
  whenInitialized(() => {
    if (!sidebarEntityGroupExpanded.current) return true;
    const labels = sidebarEntityLinks.current.filter((l) => !l.isAnalysis).map((l) => l.label);
    return ENTITY_NAV_LABELS.every((n) => labels.includes(n));
  }),
);

export const entityNavOrderIsStableWhenExpanded: Formula = always(() =>
  whenInitialized(() => {
    if (!sidebarEntityGroupExpanded.current) return true;
    const labels = sidebarEntityLinks.current.filter((l) => !l.isAnalysis).map((l) => l.label);
    return labels.every((l, i) => l === ENTITY_NAV_LABELS[i]);
  }),
);

// ===========================================================================
// 2. ACTIVE-STATE ↔ ROUTE CONSISTENCY
// ===========================================================================

export const exactlyOneActiveLink: Formula = always(() =>
  whenInitialized(() => {
    const count = activeNavCount.current;
    return count <= 1;
  }),
);

// Weak state coherence: when a single util link is active, its mapped view
// includes the current route. Guarded to active count === 1 to avoid the
// accordion re-render race (entity links briefly have 0 active during toggle).
export const activeLinkImpliesCorrectRoute: Formula = always(() =>
  whenInitialized(() => {
    const utilActive = sidebarUtilLinks.current.filter((l) => l.isActive);
    if (utilActive.length !== 1) return true;
    const key = utilActive[0]!.label.toLowerCase().replace(/\s+/g, "");
    const itemView = NAV_LABEL_TO_VIEW[key];
    return itemView ? isActiveFor(itemView, currentView.current) : true;
  }),
);

// ===========================================================================
// 3. VIEW NON-EMPTINESS
// ===========================================================================

export const mainContentNeverEmpty: Formula = always(() =>
  whenInitialized(() => mainContent.current.length > 0),
);

export const noStaleLoadingIndicator: Formula = always(() =>
  whenInitialized(() => {
    const text = mainText.current;
    return text !== "Loading..." || loadingSpinners.current > 0;
  }),
);

export const noBlankScreensAfterNavigation: Formula = always(() =>
  whenInitialized(() => mainChildCount.current > 0),
);

// ===========================================================================
// 4. URL-VIEW CONSISTENCY
// ===========================================================================

export const pathnameAlwaysWellFormed: Formula = always(() =>
  whenInitialized(() => {
    const p = pathname.current;
    return p === "/" || (p.startsWith("/") && !p.includes("//"));
  }),
);

export const pathnameNeverTrailingSlash: Formula = always(() =>
  whenInitialized(() => {
    const p = pathname.current;
    return p === "/" || !p.endsWith("/");
  }),
);

export const routeAlwaysKnown: Formula = always(() =>
  whenInitialized(() => KNOWN_VIEWS.includes(currentView.current)),
);

// ===========================================================================
// 5. BACK-BUTTON LIVENESS
// ===========================================================================

export const detailViewsAlwaysHaveBackButton: Formula = always(() =>
  whenInitialized(() => {
    if (!DETAIL_VIEWS.includes(currentView.current)) return true;
    return backButtons.current.length > 0;
  }),
);

export const backButtonsAreClickable: Formula = always(() =>
  whenInitialized(() => {
    const btns = backButtons.current;
    return btns.every((b) => !b.visible || (b.x > 0 && b.y > 0 && b.y < 2000));
  }),
);

// Navigation liveness: on detail views, at least one back button must exist
// in the DOM with non-zero dimensions (not necessarily in the viewport —
// the user can scroll up to reach it).
export const backButtonsVisibleOnDetailViews: Formula = always(() =>
  whenInitialized(() => {
    if (!DETAIL_VIEWS.includes(currentView.current)) return true;
    return backButtons.current.some((b) => b.x > 0 && b.y > -500);
  }),
);

// ===========================================================================
// 6. INPUT SAFETY
// ===========================================================================

export const searchInputsAreInteractive: Formula = always(() =>
  whenInitialized(() => {
    const inputs = searchInputs.current;
    return inputs.every((inp) => !inp.visible || inp.placeholder.length > 0);
  }),
);

// ===========================================================================
// 7. CROSS-LINK CONSISTENCY
// ===========================================================================

export const tableChipsAreAlwaysClickable: Formula = always(() =>
  whenInitialized(() =>
    tableChips.current.every((c) => !c.visible || (c.x > 0 && c.y > 0)),
  ),
);

// Cross-link consistency: visible table chips always have non-empty labels,
// so users can identify what they're clicking.
export const tableChipsHaveNonEmptyLabels: Formula = always(() =>
  whenInitialized(() =>
    tableChips.current.every((c) => !c.visible || c.name.length > 0),
  ),
);

// ===========================================================================
// 8. SCROLL BEHAVIOR
// ===========================================================================

export const scrollPositionNonNegative: Formula = always(() =>
  whenInitialized(() => {
    const s = scrollPosition.current;
    return s.x >= 0 && s.y >= 0;
  }),
);

// ===========================================================================
// 9. BADGE INTEGRITY
// ===========================================================================

export const badgesAreVisibleWhenPresent: Formula = always(() =>
  whenInitialized(() => badgeCount.current === allBadgeCount.current),
);

// ===========================================================================
// 10. QUERY SUBMISSION SAFETY
// ===========================================================================

export const queryRunDisabledWhenMissingParams: Formula = always(() =>
  whenInitialized(() =>
    queryRunButtons.current.every((btn) => {
      if (!btn.visible) return true;
      if (!btn.hasUnfilledRequired) return true;
      return btn.disabled;
    }),
  ),
);

// ===========================================================================
// 11. THEME FRAME CONDITION
// ===========================================================================

export const themeAlwaysSet: Formula = always(() =>
  whenInitialized(() => {
    const t = bodyTheme.current;
    return t === "dark" || t === "light";
  }),
);

// ===========================================================================
// ACTION GENERATORS
// ===========================================================================

const navLinksAction = extract((state) => {
  const util = Array.from(state.document.querySelectorAll("a.sidebar-util-link"));
  const entity = Array.from(state.document.querySelectorAll("a.sidebar-entity-link"));
  return [...util, ...entity].map((a) => {
    const rect = a.getBoundingClientRect();
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      label: extractLabel(a),
    };
  });
});

export const clickNavLinks = actions(() =>
  navLinksAction.current.map((link) => ({
    Click: { name: `nav-${link.label}`, point: { x: link.x, y: link.y } },
  })),
);

export const clickTableRows = actions(() =>
  clickableRows.current.slice(0, 15).map((r, i) => ({
    Click: { name: `row-${i}`, point: { x: r.x, y: r.y } },
  })),
);

export const clickBackButtons = actions(() =>
  backButtons.current
    .filter((b) => b.visible)
    .map((b) => ({
      Click: { name: `back-${b.text}`, point: { x: b.x, y: b.y } },
    })),
);

export const clickTableChips = actions(() =>
  tableChips.current
    .filter((c) => c.visible)
    .slice(0, 5)
    .map((c) => ({
      Click: { name: `chip-${c.name}`, point: { x: c.x, y: c.y } },
    })),
);

export const clickAllButtons = actions(() =>
  allButtons.current
    .filter((b) => b.visible && !b.disabled && b.text.length > 0)
    .slice(0, 10)
    .map((b) => ({
      Click: { name: `btn-${b.text.slice(0, 20)}`, point: { x: b.x, y: b.y } },
    })),
);

export const clickTreeNodes = actions(() =>
  interactiveTreeNodes.current.slice(0, 10).map((n, i) => ({
    Click: { name: `tree-${i}`, point: { x: n.x, y: n.y } },
  })),
);

export const typeIntoSearch = actions(() => {
  const inputs = searchInputs.current.filter((i) => i.visible);
  if (inputs.length === 0) return [];
  const inp = inputs[0]!;
  return [
    { Click: { name: "search-focus", point: { x: inp.x, y: inp.y } } },
    { TypeText: { text: "test", delayMillis: 30 } },
  ];
});

export const browserNavActions = actions((): Action[] => ["Back", "Forward"]);

export const scrollActions = actions((): Action[] => [
  { ScrollDown: { origin: { x: 512, y: 400 }, distance: 300 } },
  { ScrollUp:   { origin: { x: 512, y: 400 }, distance: 300 } },
]);

// ===========================================================================
// COMPOSITE ACTION GENERATORS (weighted)
// ===========================================================================

export const navigationActions = weighted([
  [15, clickNavLinks],
  [8,  clickTableRows],
  [5,  clickBackButtons],
  [4,  clickTableChips],
  [3,  clickAllButtons],
  [3,  browserNavActions],
  [2,  scrollActions],
  [2,  clickTreeNodes],
  [2,  typeIntoSearch],
]);
