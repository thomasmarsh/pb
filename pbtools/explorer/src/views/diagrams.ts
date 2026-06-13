// diagrams.ts — Diagrams view renderer.

import { el } from "../dom.js";
import { createTypeahead } from "../components/typeahead.js";
import type { AppState } from "../types/state.js";
import type { Dispatch } from "../core.js";

export function renderDiagrams(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const dg = state.diagrams;
  const tabBar = el("div", { className: "tab-bar" });
  for (const kind of ["inheritance", "calls", "dw-tables", "heatmap"] as const) {
    tabBar.appendChild(el("button", {
      className: "tab-btn" + (dg.active === kind ? " active" : ""),
      onClick: () => {
        dispatch({ type: "DIAGRAM_SELECT", kind });
        if (kind === "heatmap" || kind === "inheritance")
          dispatch({ type: "DIAGRAM_GENERATE" });
      },
    }, kind));
  }
  root.appendChild(tabBar);

  const controls = el("div", { className: "card", style: "padding:12px 20px" });
  const row = el("div", { style: "display:flex;gap:8px;align-items:center" });

  const allNames = (state.allObjects ?? []).map(o => o.name);
  const allMeta = new Map<string, typeof state.allObjects[0]>();
  for (const o of state.allObjects) allMeta.set(o.name, o);
  const dwNames = allNames.filter(n => allMeta.get(n)?.kind === "datawindow");

  if (dg.active === "inheritance") {
    const ta = createTypeahead({
      id: "diag-root", options: allNames, value: "",
      placeholder: "Root object (optional)",
      formatItem: (n) => ({ name: n, kind: allMeta.get(n)?.kind?.charAt(0).toUpperCase() ?? "" }),
      onSelect: () => {},
    });
    row.appendChild(ta.element);
    row.appendChild(el("button", { className: "filter-pill active", onClick: () => {
      dispatch({ type: "DIAGRAM_PARAMS", params: { root: ta.getValue() } });
      dispatch({ type: "DIAGRAM_GENERATE" });
    } }, "Generate"));
  } else if (dg.active === "calls") {
    const ta = createTypeahead({
      id: "diag-focal", options: allNames, value: "",
      placeholder: "Focal object",
      formatItem: (n) => ({ name: n, kind: allMeta.get(n)?.kind?.charAt(0).toUpperCase() ?? "" }),
      onSelect: () => {},
    });
    const depth = el("input", { className: "search-input", type: "number", value: "2", min: "1", max: "5", style: "max-width:80px" }) as HTMLInputElement;
    row.appendChild(ta.element); row.appendChild(depth);
    row.appendChild(el("button", { className: "filter-pill active", onClick: () => {
      dispatch({ type: "DIAGRAM_PARAMS", params: { focal: ta.getValue(), depth: depth.value } });
      dispatch({ type: "DIAGRAM_GENERATE" });
    } }, "Generate"));
  } else if (dg.active === "dw-tables") {
    const ta = createTypeahead({
      id: "diag-table", options: dwNames, value: "",
      placeholder: "Filter table (optional)",
      formatItem: (n) => ({ name: n, kind: "DW" }),
      onSelect: () => {},
    });
    row.appendChild(ta.element);
    row.appendChild(el("button", { className: "filter-pill active", onClick: () => {
      dispatch({ type: "DIAGRAM_PARAMS", params: { table: ta.getValue() } });
      dispatch({ type: "DIAGRAM_GENERATE" });
    } }, "Generate"));
  } else {
    row.appendChild(el("button", { className: "filter-pill active",
      onClick: () => dispatch({ type: "DIAGRAM_GENERATE" }) }, "Generate"));
  }
  controls.appendChild(row);
  root.appendChild(controls);

  const container = el("div", { className: "card" });
  if (dg.loading) {
    container.appendChild(el("div", { className: "diagram-container" },
      el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Generating diagram...")));
  } else if (dg.svg) {
    container.appendChild(el("div", { className: "diagram-container", html: dg.svg }));
  } else if (dg.error) {
    container.appendChild(el("div", { className: "diagram-container" },
      el("div", { className: "loading-overlay", style: "color:var(--red)" }, "Error: " + dg.error)));
  } else {
    container.appendChild(el("div", { className: "diagram-container" },
      el("div", { className: "loading-overlay" }, "Select options and click Generate")));
  }
  root.appendChild(container);
}
