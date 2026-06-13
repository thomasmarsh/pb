// datawindows.ts — DataWindows list and detail view renderers.

import { el } from "../dom.js";
import { createTypeahead } from "../components/typeahead.js";
import type { AppState } from "../types/state.js";
import type { Dispatch } from "../core.js";

function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

export function renderDataWindows(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const dw = state.datawindows;

  const dwNames = (dw.items ?? []).map(d => d.name);
  const dwMeta = new Map<string, typeof dw.items[0]>();
  for (const d of dw.items) dwMeta.set(d.name, d);

  const search = el("div", { className: "search-bar" });
  const ta = createTypeahead({
    id: "dw-search",
    options: dwNames,
    value: dw.q,
    placeholder: "Search DataWindows \u2014 type to filter or jump to...",
    formatItem: (name) => ({
      name,
      kind: "DW",
      sub: dwMeta.has(name) ? shortFile(dwMeta.get(name)!.file) : "",
    }),
    onSelect: (name) => dispatch({ type: "DW_SELECTED", name }),
  });
  search.appendChild(ta.element);
  root.appendChild(search);

  if (dw.loading && !dw.items.length) {
    root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading..."));
    return;
  }

  const card = el("div", { className: "card" });
  card.appendChild(el("div", { className: "card-header" }, el("h2", null, `DataWindows (${dw.total})`)));
  const table = el("table", { className: "data-table" });
  table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "File"))));
  const tbody = el("tbody");
  for (const d of dw.items) {
    tbody.appendChild(el("tr", {
      className: "clickable",
      onClick: () => dispatch({ type: "DW_SELECTED", name: d.name }),
    },
      el("td", { className: "name-cell" }, d.name),
      el("td", { style: "font-size:11px;color:var(--text-muted)" }, shortFile(d.file))));
  }
  table.appendChild(tbody);
  card.appendChild(table);
  root.appendChild(card);
}

export function renderDWDetail(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const dw = state.dwDetail;
  if (!dw) { root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading...")); return; }
  if ("error" in dw) { root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--red)" }, "Error: " + dw.error))); return; }

  root.appendChild(el("button", { className: "back-btn",
    onClick: () => dispatch({ type: "NAVIGATE", view: "datawindows" }) }, "\u2190 Back to DataWindows"));
  root.appendChild(el("h2", { style: "margin-bottom:16px;font-size:20px" },
    dw.name, " ", el("span", { className: "badge badge-dw" }, "datawindow")));

  const grid = el("div", { className: "metric-grid" });
  const metrics: [string, number][] = [
    ["Controls", dw.controls.length],
    ["DB Tables", dw.retrieve_tables.length],
    ["Columns", dw.retrieve_columns.length],
    ["Arguments", dw.arguments.length],
  ];
  for (const [l, v] of metrics) {
    grid.appendChild(el("div", { className: "metric-card" },
      el("div", { className: "label" }, l), el("div", { className: "value" }, String(v))));
  }
  root.appendChild(grid);

  if (dw.retrieve_tables.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Retrieve Tables")));
    const list = el("div", { style: "display:flex;flex-wrap:wrap;gap:6px" });
    for (const t of dw.retrieve_tables) list.appendChild(el("span", { className: "badge badge-dw" }, t));
    card.appendChild(list);
    root.appendChild(card);
  }

  if (dw.arguments.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Arguments")));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "Type"))));
    const tbody = el("tbody");
    for (const a of dw.arguments) tbody.appendChild(el("tr", null,
      el("td", { className: "name-cell" }, a.arg_name), el("td", null, a.arg_type ?? "")));
    table.appendChild(tbody);
    card.appendChild(table);
    root.appendChild(card);
  }

  if (dw.retrieve_where.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, "WHERE Clauses")));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "#"), el("th", null, "Exp1"),
      el("th", null, "Op"), el("th", null, "Exp2"), el("th", null, "Logic"))));
    const tbody = el("tbody");
    for (const w of dw.retrieve_where) tbody.appendChild(el("tr", null,
      el("td", null, String(w.idx)), el("td", null, w.exp1 ?? ""),
      el("td", null, el("span", { className: "badge badge-event" }, w.op ?? "")),
      el("td", null, w.exp2 ?? ""),
      el("td", null, el("span", { className: "badge badge-func" }, w.logic ?? ""))));
    table.appendChild(tbody);
    card.appendChild(table);
    root.appendChild(card);
  }

  if (dw.controls.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, `Controls (${dw.controls.length})`)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "Type"),
      el("th", null, "Band"), el("th", null, "X"), el("th", null, "Y"),
      el("th", null, "W"), el("th", null, "H"), el("th", null, "Expr"))));
    const tbody = el("tbody");
    for (const c of dw.controls) {
      tbody.appendChild(el("tr", null,
        el("td", { className: "name-cell" }, c.control_name ?? "\u2013"),
        el("td", null, c.control_type ?? ""),
        el("td", null, el("span", { className: "badge badge-on" }, c.band ?? "")),
        el("td", null, c.x != null ? String(c.x) : ""),
        el("td", null, c.y != null ? String(c.y) : ""),
        el("td", null, c.width != null ? String(c.width) : ""),
        el("td", null, c.height != null ? String(c.height) : ""),
        el("td", { style: "max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px" },
            c.expression ?? "")));
    }
    table.appendChild(tbody);
    card.appendChild(table);
    root.appendChild(card);
  }

  if (dw.source) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Source")));
    const viewer = el("div", { className: "code-viewer" });
    dw.source.split("\n").forEach((line, i) => {
      viewer.appendChild(el("div", { className: "code-line" },
        el("span", { className: "code-line-num" }, String(i + 1)),
        el("span", { className: "code-line-content" }, line)));
    });
    card.appendChild(viewer);
    root.appendChild(card);
  }
}
