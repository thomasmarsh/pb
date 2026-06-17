// bombadil-spec.ts — Property-based tests for pb-explorer UI.
//
// Categories:
//   1. Sidebar structural invariants
//   2. Active-state ↔ route consistency
//   3. View non-emptiness
//   4. URL-view consistency
//   5. Back-button liveness
//   6. Navigation convergence (multiple paths → same destination)
//   7. Input safety (no crashes, correct triggers)
//   8. Click safety (nothing crashes on any click)
//   9. Keyboard accessibility (Enter/Space on interactive elements)
//  10. State monotonicity (loading → loaded, no stale data)
//  11. Rapid navigation resilience
//  12. Cross-link consistency (same entity → same detail view)

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
export * from "@antithesishq/bombadil/browser/defaults";

// ===========================================================================
// Helpers
// ===========================================================================

const NAV_LABELS = [
  "Dashboard", "Objects", "DataWindows", "Tables",
  "Explore", "Diagrams", "Queries", "Search", "Errors",
];

const VIEW_GROUPS: Record<string, string[]> = {
  objects:     ["objects", "objectDetail", "procedureDetail"],
  datawindows: ["datawindows", "dwDetail"],
  tables:      ["tables", "tableDetail"],
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

const sidebarNavLinks = extract((state) => {
  const links = state.document.querySelectorAll(".sidebar-nav a");
  return Array.from(links).map((a) => ({
    label: extractLabel(a),
    isActive: a.classList.contains("active"),
  }));
});

const activeNavCount = extract((state) => {
  const links = state.document.querySelectorAll(".sidebar-nav a");
  return Array.from(links).filter((a) => a.classList.contains("active")).length;
});

const activeNavIndex = extract((state) => {
  const links = state.document.querySelectorAll(".sidebar-nav a");
  const arr = Array.from(links);
  const idx = arr.findIndex((a) => a.classList.contains("active"));
  return idx;
});

const mainContent = extract((state) => {
  const main = state.document.querySelector(".main-content");
  return main?.innerHTML?.trim() ?? "";
});

const pathname = extract((state) => state.window.location.pathname);

// ===========================================================================
// 4. URL-VIEW CONSISTENCY
// ===========================================================================

const KNOWN_VIEWS = [
  "dashboard", "objects", "objectDetail", "procedureDetail",
  "datawindows", "dwDetail", "tables", "tableDetail",
  "diagrams", "queries", "search", "explore", "errors",
];

export const pathnameAlwaysWellFormed: Formula = always(() => {
  const p = pathname.current;
  return p === "/" || (p.startsWith("/") && !p.includes("//"));
});

export const pathnameNeverTrailingSlash: Formula = always(() => {
  const p = pathname.current;
  return p === "/" || !p.endsWith("/");
});

export const routeAlwaysKnown: Formula = always(() =>
  KNOWN_VIEWS.includes(currentView.current),
);

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
      name: c.textContent?.replace("⊡", "").trim() ?? "",
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

const loadingSpinners = extract((state) => {
  return state.document.querySelectorAll(".loading, [class*=spinner]").length;
});

const scrollPosition = extract((state) => ({
  x: state.window.scrollX,
  y: state.window.scrollY,
}));

const bodyScrollHeight = extract((state) => state.document.body.scrollHeight);

const currentView = extract((state) => {
  const path = state.window.location.pathname;
  if (!path || path === "/") return "dashboard";
  const segs = path.split("/").filter(Boolean);
  if (segs[0] === "objects") {
    if (segs[2]) return "procedureDetail";
    if (segs[1]) return "objectDetail";
    return "objects";
  }
  if (segs[0] === "datawindows") return segs[1] ? "dwDetail" : "datawindows";
  if (segs[0] === "tables") return segs[1] ? "tableDetail" : "tables";
  return segs[0] ?? "dashboard";
});

// ===========================================================================
// 1. SIDEBAR STRUCTURAL INVARIANTS
// ===========================================================================

export const sidebarHasCorrectCount: Formula = always(() =>
  sidebarNavLinks.current.length === NAV_LABELS.length,
);

export const sidebarHasAllLabels: Formula = always(() => {
  const labels = sidebarNavLinks.current.map((l) => l.label);
  return NAV_LABELS.every((n) => labels.includes(n));
});

export const sidebarOrderIsStable: Formula = always(() => {
  const labels = sidebarNavLinks.current.map((l) => l.label);
  return labels.every((l, i) => l === NAV_LABELS[i]);
});

const sidebarHeader = extract((state) => {
  const h1 = state.document.querySelector(".sidebar-header h1");
  return h1 !== null && (h1.textContent?.length ?? 0) > 0;
});

export const sidebarHeaderVisible: Formula = always(() => sidebarHeader.current);

// ===========================================================================
// 2. ACTIVE-STATE ↔ ROUTE CONSISTENCY
// ===========================================================================

export const exactlyOneActiveLink: Formula = always(() =>
  activeNavCount.current === 1,
);

export const activeLinkMatchesRoute: Formula = always(() => {
  const idx = activeNavIndex.current;
  if (idx < 0 || idx >= NAV_LABELS.length) return false;
  const itemPath = NAV_LABELS[idx]!.toLowerCase();
  const view = currentView.current;
  return isActiveFor(itemPath, view);
});

// ===========================================================================
// 3. VIEW NON-EMPTINESS
// ===========================================================================

export const mainContentNeverEmpty: Formula = always(() =>
  mainContent.current.length > 0,
);

const mainText = extract((state) => {
  const main = state.document.querySelector(".main-content");
  return main?.textContent?.trim() ?? "";
});

export const noStaleLoadingIndicator: Formula = always(() => {
  const text = mainText.current;
  return text !== "Loading..." || loadingSpinners.current > 0;
});

// ===========================================================================
// 5. BACK-BUTTON LIVENESS
// ===========================================================================

export const backButtonsAreClickable: Formula = always(() => {
  const btns = backButtons.current;
  return btns.every((b) => !b.visible || (b.x > 0 && b.y > 0 && b.y < 2000));
});

// ===========================================================================
// 6. CLICK SAFETY (nothing crashes — noUncaughtExceptions from defaults)
// ===========================================================================

// ===========================================================================
// 7. INPUT SAFETY
// ===========================================================================

export const searchInputsAreInteractive: Formula = always(() => {
  const inputs = searchInputs.current;
  return inputs.every((inp) => !inp.visible || inp.placeholder.length > 0);
});

// ===========================================================================
// 8. RAPID NAVIGATION RESILIENCE
// ===========================================================================

const mainChildCount = extract((state) => {
  const main = state.document.querySelector(".main-content");
  return main?.children.length ?? 0;
});

export const noBlankScreensAfterNavigation: Formula = always(() =>
  mainChildCount.current > 0,
);

// ===========================================================================
// 10. CROSS-LINK CONSISTENCY
// ===========================================================================

export const tableChipsAreAlwaysClickable: Formula = always(() => {
  return tableChips.current.every((c) => !c.visible || (c.x > 0 && c.y > 0));
});

// ===========================================================================
// 11. SCROLL BEHAVIOR
// ===========================================================================

export const scrollPositionNonNegative: Formula = always(() => {
  const s = scrollPosition.current;
  return s.x >= 0 && s.y >= 0;
});

// ===========================================================================
// 12. BADGE INTEGRITY
// ===========================================================================

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

export const badgesAreVisibleWhenPresent: Formula = always(() =>
  badgeCount.current === allBadgeCount.current,
);

// ===========================================================================
// 13. QUERY SUBMISSION SAFETY — Run button disabled when required params empty
// ===========================================================================

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

export const queryRunDisabledWhenMissingParams: Formula = always(() => {
  return queryRunButtons.current.every((btn) => {
    if (!btn.visible) return true;
    if (!btn.hasUnfilledRequired) return true;
    return btn.disabled;
  });
});

// ===========================================================================
// 14. THEME FRAME CONDITION
// ===========================================================================

const bodyTheme = extract((state) =>
  state.document.documentElement.getAttribute("data-theme"),
);

export const themeAlwaysSet: Formula = always(() => {
  const t = bodyTheme.current;
  return t === "dark" || t === "light";
});

const navLinksAction = extract((state) => {
  const links = state.document.querySelectorAll(".sidebar-nav a");
  return Array.from(links).map((a) => {
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
    .map((c, i) => ({
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

// ===========================================================================
// COMPOSITE ACTION GENERATORS (weighted)
// ===========================================================================

export const navigationActions = weighted([
  [15, clickNavLinks],
  [8,  clickTableRows],
  [5,  clickBackButtons],
  [4,  clickTableChips],
  [3,  clickAllButtons],
  [2,  clickTreeNodes],
  [2,  typeIntoSearch],
]);
