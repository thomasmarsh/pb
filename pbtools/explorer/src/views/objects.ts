// objects.ts — Objects list and detail view renderers.

import { el } from "../dom.js";
import { createTypeahead } from "../components/typeahead.js";
import { createSourceViewer } from "../components/source-viewer.js";
import type { AppState } from "../types/state.js";
import type { Dispatch } from "../core.js";

function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

export function renderObjects(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const os = state.objects;

  const allObjNames = (os.items ?? []).map(o => o.name);
  const objMeta = new Map<string, typeof os.items[0]>();
  for (const o of os.items) objMeta.set(o.name, o);

  const search = el("div", { className: "search-bar" });
  const ta = createTypeahead({
    id: "objects-search",
    options: allObjNames,
    value: os.q,
    placeholder: "Search objects \u2014 type to filter or jump to...",
    formatItem: (name) => {
      const o = objMeta.get(name);
      return {
        name,
        kind: o?.kind ? o.kind.charAt(0).toUpperCase() : "",
        sub: o?.ancestor ?? (o?.file ? shortFile(o.file) : ""),
      };
    },
    onSelect: (name) => dispatch({ type: "OBJECT_SELECTED", name }),
  });
  search.appendChild(ta.element);
  root.appendChild(search);

  const pills = el("div", { className: "filter-pills" });
  for (const k of ["", "powerscript", "datawindow", "project", "pipeline"]) {
    pills.appendChild(el("button", {
      className: "filter-pill" + (os.kind === k ? " active" : ""),
      onClick: () => dispatch({ type: "OBJECTS_FILTER_KIND", kind: k }),
    }, k || "All"));
  }
  root.appendChild(pills);

  if (os.loading && !os.items.length) {
    root.appendChild(el("div", { className: "loading-overlay" },
      el("div", { className: "spinner" }), " Loading..."));
    return;
  }

  const card = el("div", { className: "card" });
  card.appendChild(el("div", { className: "card-header" }, el("h2", null, `Objects (${os.total})`)));

  const sortIcon = (col: string) => os.sort === col ? (os.order === "asc" ? " \u25B2" : " \u25BC") : "";
  const table = el("table", { className: "data-table" });
  table.appendChild(el("thead", null,
    el("tr", null,
      el("th", { className: os.sort === "name" ? "sorted" : "",
        onClick: () => dispatch({ type: "OBJECTS_SORT", col: "name" }) }, "Name" + sortIcon("name")),
      el("th", { className: os.sort === "kind" ? "sorted" : "",
        onClick: () => dispatch({ type: "OBJECTS_SORT", col: "kind" }) }, "Kind" + sortIcon("kind")),
      el("th", null, "File"), el("th", null, "Ancestor"))));

  const tbody = el("tbody");
  for (const obj of os.items) {
    const bc = obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj";
    tbody.appendChild(el("tr", {
      className: "clickable",
      onClick: () => dispatch({ type: "OBJECT_SELECTED", name: obj.name }),
    },
      el("td", { className: "name-cell" }, obj.name),
      el("td", null, el("span", { className: "badge badge-" + bc }, obj.kind)),
      el("td", { style: "font-size:11px;color:var(--text-muted);max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, shortFile(obj.file)),
      el("td", null, obj.ancestor ?? "")));
  }
  table.appendChild(tbody);
  card.appendChild(table);

  if (os.total > 100) {
    const pages = el("div", { style: "display:flex;gap:8px;margin-top:12px;justify-content:center" });
    if (os.offset > 0)
      pages.appendChild(el("button", { className: "filter-pill",
        onClick: () => dispatch({ type: "OBJECTS_PAGE", offset: Math.max(0, os.offset - 100) }),
      }, "\u2190 Previous"));
    pages.appendChild(el("span", { style: "color:var(--text-muted);font-size:12px;padding:4px 8px" },
      `${os.offset + 1}\u2013${Math.min(os.offset + 100, os.total)} of ${os.total}`));
    if (os.offset + 100 < os.total)
      pages.appendChild(el("button", { className: "filter-pill",
        onClick: () => dispatch({ type: "OBJECTS_PAGE", offset: os.offset + 100 }),
      }, "Next \u2192"));
    card.appendChild(pages);
  }
  root.appendChild(card);
}

export function renderObjectDetail(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const obj = state.objectDetail;
  if (!obj) { root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading...")); return; }
  if ("error" in obj) { root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--red)" }, "Error: " + obj.error))); return; }

  root.appendChild(el("button", { className: "back-btn",
    onClick: () => dispatch({ type: "NAVIGATE", view: "objects" }) }, "\u2190 Back to Objects"));

  const bc = obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj";
  root.appendChild(el("h2", { style: "margin-bottom:16px;font-size:20px" },
    obj.name, " ", el("span", { className: "badge badge-" + bc }, obj.kind)));

  if (obj.metrics) {
    const m = obj.metrics;
    const grid = el("div", { className: "metric-grid" });
    const metrics: [string, string | number | null | undefined][] = [
      ["In Degree", m.in_degree], ["Out Degree", m.out_degree], ["Max CC", m.max_cyclomatic],
      ["Avg CC", m.avg_cyclomatic ? parseFloat(String(m.avg_cyclomatic)).toFixed(1) : "\u2013"],
      ["PageRank", m.pagerank ? parseFloat(String(m.pagerank)).toFixed(4) : "\u2013"],
      ["DIT", m.dit ?? "\u2013"],
    ];
    for (const [l, v] of metrics) {
      grid.appendChild(el("div", { className: "metric-card" },
        el("div", { className: "label" }, l), el("div", { className: "value" }, String(v ?? "\u2013"))));
    }
    root.appendChild(grid);
  }

  if (obj.ancestors && obj.ancestors.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Inheritance")));
    const list = el("div", { style: "display:flex;flex-wrap:wrap;gap:6px" });
    list.appendChild(el("span", { className: "badge badge-ps", style: "cursor:pointer",
      onClick: () => dispatch({ type: "OBJECT_SELECTED", name: obj.name }) }, obj.name));
    for (const a of obj.ancestors) {
      list.appendChild(el("span", { style: "color:var(--text-muted)" }, " \u2192 "));
      list.appendChild(el("span", { className: "badge badge-ps", style: "cursor:pointer",
        onClick: () => dispatch({ type: "OBJECT_SELECTED", name: a }) }, a));
    }
    card.appendChild(list);
    root.appendChild(card);
  }

  if ((obj.callers && obj.callers.length) || (obj.callees && obj.callees.length)) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Call Graph")));
    const grid = el("div", { style: "display:grid;grid-template-columns:1fr 1fr;gap:16px" });
    for (const [label, items] of [["CALLERS", obj.callers], ["CALLEES", obj.callees]] as [string, string[]][]) {
      if (!items || !items.length) continue;
      const col = el("div");
      col.appendChild(el("div", { style: "font-size:11px;color:var(--text-muted);margin-bottom:4px" }, `${label} (${items.length})`));
      const list = el("div", { style: "display:flex;flex-wrap:wrap;gap:4px" });
      for (const c of items) list.appendChild(el("span", { className: "badge badge-func", style: "cursor:pointer",
        onClick: () => dispatch({ type: "OBJECT_SELECTED", name: c }) }, c));
      col.appendChild(list);
      grid.appendChild(col);
    }
    card.appendChild(grid);
    root.appendChild(card);
  }

  if (obj.procedures && obj.procedures.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, `Procedures (${obj.procedures.length})`)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null,
      el("tr", null, el("th", null, "Name"), el("th", null, "Type"),
         el("th", null, "Modifiers"), el("th", null, "Params"),
         el("th", null, "CC"), el("th", null, "Lines"))));
    const tbody = el("tbody");
    for (const p of obj.procedures) {
      tbody.appendChild(el("tr", {
        className: "clickable",
        onClick: () => dispatch({ type: "PROCEDURE_SELECTED", objectName: obj.name, procName: p.name }),
      },
        el("td", { className: "name-cell" }, p.name),
        el("td", null, el("span", { className: "badge badge-" + procBadge(p.proc_type) }, p.proc_type)),
        el("td", { style: "font-size:12px" }, p.modifiers ?? ""),
        el("td", { style: "font-size:12px;max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, p.params ?? ""),
        el("td", null, p.cyclomatic != null ? el("span", { className: "badge badge-cc" }, String(p.cyclomatic)) : "\u2013"),
        el("td", { style: "font-size:12px;color:var(--text-muted)" },
            p.start_line && p.end_line ? `${p.start_line}\u2013${p.end_line}` : "\u2013")));
    }
    table.appendChild(tbody);
    card.appendChild(table);
    root.appendChild(card);
  }

  if (obj.file) {
    const src = state.sourceDetail;
    const card = el("div", { className: "card" });
    const header = el("div", { className: "source-file-header" });
    header.appendChild(el("div", { className: "card-header" }, el("h3", null, "Source")));
    header.appendChild(el("div", { className: "source-file-path" }, obj.file));
    card.appendChild(header);

    if (src && !("error" in src) && src.lines && src.lines.length) {
      card.appendChild(createSourceViewer(src, obj.name, dispatch));
    } else if (src && "error" in src) {
      card.appendChild(el("p", { style: "color:var(--red);font-size:12px" }, src.error));
    } else {
      card.appendChild(el("div", { className: "loading-overlay" },
        el("div", { className: "spinner" }), " Loading source..."));
    }
    root.appendChild(card);
  }
}
