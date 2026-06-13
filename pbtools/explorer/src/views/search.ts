// search.ts — Search view renderer.

import { el } from "../dom.js";
import type { AppState } from "../types/state.js";
import type { Dispatch } from "../core.js";

function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

function debounce<T extends (...args: unknown[]) => void>(fn: T, ms: number): T {
  let timer: ReturnType<typeof setTimeout>;
  return ((...args: unknown[]) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); }) as T;
}

function renderSearchResults(container: HTMLElement, data: AppState["search"]["results"] & object, dispatch: Dispatch): void {
  const total = data.objects.length + data.procedures.length + data.datawindows.length;
  if (total === 0) { container.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--text-muted)" }, "No results found"))); return; }

  if (data.objects.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, `Objects (${data.objects.length})`)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "Kind"), el("th", null, "File"))));
    const tbody = el("tbody");
    for (const o of data.objects) {
      const bc = o.kind === "powerscript" ? "ps" : "dw";
      tbody.appendChild(el("tr", { className: "clickable",
        onClick: () => dispatch({ type: "OBJECT_SELECTED", name: o.name }) },
        el("td", { className: "name-cell" }, o.name),
        el("td", null, el("span", { className: "badge badge-" + bc }, o.kind)),
        el("td", { style: "font-size:11px;color:var(--text-muted)" }, shortFile(o.file))));
    }
    table.appendChild(tbody); card.appendChild(table); container.appendChild(card);
  }

  if (data.procedures.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, `Procedures (${data.procedures.length})`)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "Object"), el("th", null, "Name"),
      el("th", null, "Type"), el("th", null, "Line"))));
    const tbody = el("tbody");
    for (const p of data.procedures) {
      tbody.appendChild(el("tr", { className: "clickable",
        onClick: () => dispatch({ type: "PROCEDURE_SELECTED", objectName: p.object, procName: p.name }) },
        el("td", null, p.object), el("td", { className: "name-cell" }, p.name),
        el("td", null, el("span", { className: "badge badge-" + procBadge(p.proc_type) }, p.proc_type)),
        el("td", { style: "font-size:11px;color:var(--text-muted)" }, p.start_line ? String(p.start_line) : "")));
    }
    table.appendChild(tbody); card.appendChild(table); container.appendChild(card);
  }

  if (data.datawindows.length) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h3", null, `DataWindow Controls (${data.datawindows.length})`)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "DW"), el("th", null, "Control"), el("th", null, "Type"))));
    const tbody = el("tbody");
    for (const d of data.datawindows) {
      tbody.appendChild(el("tr", { className: "clickable",
        onClick: () => dispatch({ type: "DW_SELECTED", name: d.dw_name }) },
        el("td", { className: "name-cell" }, d.dw_name),
        el("td", null, d.control_name ?? "\u2013"), el("td", null, d.control_type ?? "")));
    }
    table.appendChild(tbody); card.appendChild(table); container.appendChild(card);
  }
}

export function renderSearch(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const se = state.search;
  const search = el("div", { className: "search-bar" });
  const input = el("input", { className: "search-input", placeholder: "Search everything..." }) as HTMLInputElement;
  if (se.term) input.value = se.term;
  const doSearch = debounce(() => {
    const val = input.value.trim();
    if (val.length >= 2) dispatch({ type: "SEARCH_TERM", term: val });
  }, 300);
  input.addEventListener("input", doSearch);
  input.addEventListener("keydown", (e: KeyboardEvent) => {
    if (e.key === "Enter") {
      const val = input.value.trim();
      if (val.length >= 1) dispatch({ type: "SEARCH_TERM", term: val });
    }
  });
  search.appendChild(input);
  root.appendChild(search);

  const container = el("div");
  if (se.loading) {
    container.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Searching..."));
  } else if (se.results) {
    renderSearchResults(container, se.results, dispatch);
  }
  root.appendChild(container);
}
