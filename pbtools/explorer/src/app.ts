// app.ts — pb explore UI entry point. Wires sidebar, bootstrap store.

import { $, $$ } from "./dom.js";
import { initialState, reducer } from "./core.js";
import type { AppState } from "./types/state.js";
import { createStore } from "./store.js";
import { createApiClient } from "./api-client.js";
import { renderDashboard } from "./views/dashboard.js";
import { renderObjects, renderObjectDetail } from "./views/objects.js";
import { renderProcedureDetail } from "./views/procedures.js";
import { renderDataWindows, renderDWDetail } from "./views/datawindows.js";
import { renderDiagrams } from "./views/diagrams.js";
import { renderQueries } from "./views/queries.js";
import { renderSearch } from "./views/search.js";

const env = { api: createApiClient() };
const store = createStore(initialState(), reducer, env);

function render(state: AppState): void {
  const main = $("#main-content");
  if (!main) return;
  main.innerHTML = "";

  // Update sidebar active state
  for (const a of $$("[data-view]")) {
    const view = a.dataset.view;
    const isActive = view === state.view
      || (state.view === "objectDetail" && view === "objects")
      || (state.view === "procedureDetail" && view === "objects")
      || (state.view === "dwDetail" && view === "datawindows");
    a.classList.toggle("active", isActive);
  }

  const v = state.view;
  if (v === "dashboard")       { renderDashboard(state, main, store.dispatch); return; }
  if (v === "objects")         { renderObjects(state, main, store.dispatch); return; }
  if (v === "objectDetail")    { renderObjectDetail(state, main, store.dispatch); return; }
  if (v === "procedureDetail") { renderProcedureDetail(state, main, store.dispatch); return; }
  if (v === "datawindows")     { renderDataWindows(state, main, store.dispatch); return; }
  if (v === "dwDetail")        { renderDWDetail(state, main, store.dispatch); return; }
  if (v === "diagrams")        { renderDiagrams(state, main, store.dispatch); return; }
  if (v === "queries")         { renderQueries(state, main, store.dispatch); return; }
  if (v === "search")          { renderSearch(state, main, store.dispatch); return; }
}

// ── Sidebar wiring ──────────────────────────────────────────────────────────

for (const a of $$("[data-view]")) {
  a.addEventListener("click", (e: Event) => {
    e.preventDefault();
    const view = a.dataset.view as AppState["view"];
    store.dispatch({ type: "NAVIGATE", view });
    const state = store.getState();
    if (view === "dashboard" && !state.stats) store.dispatch({ type: "STATS_LOAD" });
    else if (view === "objects") store.dispatch({ type: "OBJECTS_SEARCH", q: state.objects.q });
    else if (view === "datawindows") store.dispatch({ type: "DW_SEARCH", q: state.datawindows.q });
    else if (view === "diagrams") {
      if (!state.allObjects.length) {
        env.api.getAllObjects().then(data => {
          store.dispatch({ type: "ALL_OBJECTS_LOADED", data: data.items ?? [] });
        }).catch(() => {});
      }
      if (state.diagrams.active === "heatmap" || state.diagrams.active === "inheritance")
        store.dispatch({ type: "DIAGRAM_GENERATE" });
    }
    else if (view === "queries" && !state.queries.items.length)
      store.dispatch({ type: "QUERIES_LOAD" });
  });
}

// ── Bootstrap ───────────────────────────────────────────────────────────────

store.subscribe(render);
store.dispatch({ type: "STATS_LOAD" });
store.dispatch({ type: "NAVIGATE", view: "dashboard" });
