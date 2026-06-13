// queries.ts — Queries view renderer.

import { el } from "../dom.js";
import type { AppState } from "../types/state.js";
import type { Dispatch } from "../core.js";

export function renderQueries(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const q = state.queries;
  const card = el("div", { className: "card" });
  card.appendChild(el("div", { className: "card-header" }, el("h2", null, "SQL Queries")));

  for (const query of q.items) {
    const section = el("div", { style: "margin-bottom:16px;padding-bottom:16px;border-bottom:1px solid var(--border)" });
    section.appendChild(el("div", { style: "font-weight:600;margin-bottom:4px" }, query.name));
    section.appendChild(el("div", { style: "font-size:12px;color:var(--text-muted);margin-bottom:8px" }, query.description));
    const form = el("div", { style: "display:flex;gap:6px;align-items:center;flex-wrap:wrap" });
    const inputs = new Map<string, HTMLInputElement>();
    for (const p of query.params) {
      const inp = el("input", { className: "search-input",
        placeholder: p.name + (p.default ? ` (${p.default})` : ""),
        style: "max-width:160px;padding:6px 10px;font-size:12px" }) as HTMLInputElement;
      inputs.set(p.name, inp);
      form.appendChild(inp);
    }
    form.appendChild(el("button", { className: "filter-pill active", onClick: () => {
      const params: Record<string, string> = {};
      for (const p of query.params) {
        const inp = inputs.get(p.name);
        if (inp?.value) params[p.name] = inp.value;
        else if (p.default) params[p.name] = p.default;
      }
      dispatch({ type: "QUERY_RUN", name: query.name, params });
    } }, "Run"));
    section.appendChild(form);
    card.appendChild(section);
  }

  const resultsDiv = el("div", { id: "query-results" });
  if (q.results) {
    if ("error" in q.results) {
      resultsDiv.appendChild(el("p", { style: "color:var(--red);padding:8px" }, q.results.error));
    } else if (q.results.rows && q.results.rows.length) {
      const rc = el("div", { className: "card" });
      rc.appendChild(el("div", { className: "card-header" },
        el("h3", null, `${q.resultsName} \u2014 ${q.results.rows.length} rows`)));
      const t = el("table", { className: "data-table" });
      t.appendChild(el("thead", null, el("tr", null, ...q.results.columns.map(c => el("th", null, c)))));
      const tb = el("tbody");
      for (const row of q.results.rows) {
        tb.appendChild(el("tr", null, ...q.results.columns.map(c => el("td", null, row[c] != null ? String(row[c]) : ""))));
      }
      t.appendChild(tb);
      rc.appendChild(t);
      resultsDiv.appendChild(rc);
    } else {
      resultsDiv.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--text-muted)" }, "(no results)")));
    }
  }
  card.appendChild(resultsDiv);
  root.appendChild(card);
}
