// dashboard.ts — Dashboard view renderer.

import { el } from "../dom.js";
import type { AppState } from "../types/state.js";
import type { ProcedureRow } from "../types/api.js";
import type { Dispatch } from "../core.js";

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

function procedureTable(title: string, procs: ProcedureRow[], dispatch: Dispatch): HTMLElement {
  const card = el("div", { className: "card" });
  card.appendChild(el("div", { className: "card-header" }, el("h2", null, title)));
  const table = el("table", { className: "data-table" });
  table.appendChild(el("thead", null,
    el("tr", null, el("th", null, "Object"), el("th", null, "Procedure"),
       el("th", null, "Type"), el("th", null, "Cyclomatic"))));
  const tbody = el("tbody");
  for (const p of procs) {
    tbody.appendChild(el("tr", {
      className: "clickable",
      onClick: () => dispatch({ type: "PROCEDURE_SELECTED", objectName: p.object, procName: p.name }),
    },
      el("td", { className: "name-cell" }, p.object),
      el("td", null, p.name),
      el("td", null, el("span", { className: "badge badge-" + procBadge(p.proc_type) }, p.proc_type)),
      el("td", null, p.cyclomatic != null ? el("span", { className: "badge badge-cc" }, String(p.cyclomatic)) : "\u2013")));
  }
  table.appendChild(tbody);
  card.appendChild(table);
  return card;
}

function objectTable(title: string, objs: { object: string; pagerank: number; in_degree: number; out_degree: number }[], dispatch: Dispatch): HTMLElement {
  const card = el("div", { className: "card" });
  card.appendChild(el("div", { className: "card-header" }, el("h2", null, title)));
  const table = el("table", { className: "data-table" });
  table.appendChild(el("thead", null,
    el("tr", null, el("th", null, "Object"), el("th", null, "PageRank"),
       el("th", null, "In"), el("th", null, "Out"))));
  const tbody = el("tbody");
  for (const p of objs) {
    tbody.appendChild(el("tr", {
      className: "clickable",
      onClick: () => dispatch({ type: "OBJECT_SELECTED", name: p.object }),
    },
      el("td", { className: "name-cell" }, p.object),
      el("td", null, String(p.pagerank)),
      el("td", null, String(p.in_degree)),
      el("td", null, String(p.out_degree))));
  }
  table.appendChild(tbody);
  card.appendChild(table);
  return card;
}

export function renderDashboard(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const s = state.stats;
  if (!s) {
    root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading..."));
    return;
  }
  const grid = el("div", { className: "metric-grid" });
  const metrics: [string, number | undefined][] = [
    ["Objects", s.objects],
    ["Procedures", s.procedures],
    ["DataWindows", s.by_kind?.find(k => k.kind === "datawindow")?.count],
    ["Inheritance edges", s.inherits],
    ["Call edges", s.calls],
    ["DW Controls", s.dw_controls],
  ];
  for (const [label, val] of metrics) {
    grid.appendChild(el("div", { className: "metric-card" },
      el("div", { className: "label" }, label),
      el("div", { className: "value" }, String(val ?? "\u2013"))));
  }
  root.appendChild(grid);

  if (s.by_kind && s.by_kind.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h2", null, "Object Types")));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "Kind"), el("th", null, "Count"))));
    const tbody = el("tbody");
    for (const k of s.by_kind) {
      const bc = k.kind === "powerscript" ? "ps" : k.kind === "datawindow" ? "dw" : "proj";
      tbody.appendChild(el("tr", null,
        el("td", { className: "name-cell" }, el("span", { className: "badge badge-" + bc }, k.kind)),
        el("td", null, String(k.count))));
    }
    table.appendChild(tbody);
    card.appendChild(table);
    root.appendChild(card);
  }

  if (s.top_complex && s.top_complex.length)
    root.appendChild(procedureTable("Most Complex Procedures", s.top_complex, dispatch));
  if (s.top_pagerank && s.top_pagerank.length)
    root.appendChild(objectTable("Most Important Objects (PageRank)", s.top_pagerank, dispatch));
}
