// core.test.ts — Tests for pb explore core state management.

import { describe, it, expect } from "vitest";
import { Effect, initialState, reducer } from "../src/core.js";
import type { Env } from "../src/core.js";
import type { AppState } from "../src/types/state.js";
import type { AppAction } from "../src/types/actions.js";
import { defaultMockEnv, createTestStore } from "./test-utils.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

function run(
  state: AppState,
  env: Env,
  ...actions: AppAction[]
): { state: AppState; effects: Array<Effect<AppAction>> } {
  let s = state;
  const effects: Array<Effect<AppAction>> = [];
  for (const a of actions) {
    const [next, effect] = reducer(s, a, env);
    s = next;
    if (effect) effects.push(effect);
  }
  return { state: s, effects };
}

// ── initialState ─────────────────────────────────────────────────────────────

describe("initialState", () => {
  it("returns correct shape", () => {
    const s = initialState();
    expect(s.view).toBe("dashboard");
    expect(s.stats).toBeNull();
    expect(s.objects).toEqual({
      items: [], total: 0, q: "", kind: "", sort: "name", order: "asc",
      offset: 0, loading: false,
    });
    expect(s.objectDetail).toBeNull();
    expect(s.procedureDetail).toBeNull();
    expect(s.datawindows).toEqual({ items: [], total: 0, q: "", loading: false });
    expect(s.dwDetail).toBeNull();
    expect(s.diagrams).toEqual({ active: "inheritance", svg: null, loading: false, params: {} });
    expect(s.queries).toEqual({ items: [], results: null, resultsName: "", loading: false });
    expect(s.search).toEqual({ term: "", results: null, loading: false });
    expect(s.explore).toEqual({
      libraries: [], expandedNodes: expect.any(Set), selectedProc: null,
      selectedDw: null, procCache: {}, dwCache: {}, loading: false,
      activeTab: "source", treeFilter: "",
    });
  });

  it("returns fresh object each call", () => {
    const a = initialState();
    const b = initialState();
    expect(a).not.toBe(b);
    expect(a.objects).not.toBe(b.objects);
  });
});

// ── Navigation ───────────────────────────────────────────────────────────────

describe("NAVIGATE", () => {
  it("sets view", () => {
    const [s1] = reducer(initialState(), { type: "NAVIGATE", view: "objects" }, defaultMockEnv);
    expect(s1.view).toBe("objects");
  });

  it("does not mutate original state", () => {
    const s0 = initialState();
    const [s1] = reducer(s0, { type: "NAVIGATE", view: "objects" }, defaultMockEnv);
    expect(s0.view).toBe("dashboard");
    expect(s1).not.toBe(s0);
  });
});

// ── Stats ─────────────────────────────────────────────────────────────────────

describe("STATS_LOAD", () => {
  it("returns an Effect and leaves state unchanged", () => {
    const s0 = initialState();
    const [s1, effect] = reducer(s0, { type: "STATS_LOAD" }, defaultMockEnv);
    expect(s1).toBe(s0);
    expect(effect).toBeInstanceOf(Effect);
  });

  it("dispatches STATS_LOADED with env response", async () => {
    const mockStats = { objects: 5, procedures: 10, dw_controls: 0, dw_retrieve_tables: 0, dw_retrieve_columns: 0, inherits: 0, calls: 0, object_metrics: 0, by_kind: [], top_complex: [], top_pagerank: [] };
    const ts = createTestStore({ getStats: () => Effect.send(mockStats) });
    await ts.send({ type: "STATS_LOAD" });
    ts.receive({ type: "STATS_LOADED", stats: mockStats });
  });
});

describe("STATS_LOADED", () => {
  it("sets stats", () => {
    const stats = { objects: 10, procedures: 20 } as AppState["stats"];
    const [s] = reducer(initialState(), { type: "STATS_LOADED", stats: stats! }, defaultMockEnv);
    expect(s.stats).toEqual(stats);
  });
});

// ── Objects ──────────────────────────────────────────────────────────────────

describe("OBJECTS_SEARCH", () => {
  it("sets q, resets offset, sets loading", () => {
    const s0 = { ...initialState(), objects: { ...initialState().objects, offset: 200 } };
    const [s1] = reducer(s0, { type: "OBJECTS_SEARCH", q: "fn_" }, defaultMockEnv);
    expect(s1.objects.q).toBe("fn_");
    expect(s1.objects.offset).toBe(0);
    expect(s1.objects.loading).toBe(true);
  });

  it("returns an Effect", () => {
    const [, effect] = reducer(initialState(), { type: "OBJECTS_SEARCH", q: "x" }, defaultMockEnv);
    expect(effect).toBeInstanceOf(Effect);
  });

  it("passes current sort/order/kind params to env", async () => {
    const mockData = { items: [], total: 0, offset: 0, limit: 100 };
    let capturedParams: Record<string, string | number> = {};
    const ts = createTestStore({
      getObjects: (p) => { capturedParams = p; return Effect.send(mockData); },
    });
    const s0 = { ...initialState(), objects: { ...initialState().objects, kind: "datawindow", sort: "kind", order: "desc" as const } };
    await (new (await import("../src/core.js")).Effect === undefined
      // workaround: use TestStore with initial state
      ? ts.send({ type: "OBJECTS_SEARCH", q: "x" })
      : Promise.resolve());
    // Direct reducer test for param capture
    const [, effect] = reducer(s0, { type: "OBJECTS_SEARCH", q: "foo" }, {
      ...defaultMockEnv,
      getObjects: (p) => { capturedParams = p; return Effect.send(mockData); },
    });
    await effect!.execute(() => {});
    expect(capturedParams).toMatchObject({ q: "foo", kind: "datawindow", sort: "kind", order: "desc" });
  });
});

describe("OBJECTS_FILTER_KIND", () => {
  it("sets kind, resets offset", () => {
    const s0 = { ...initialState(), objects: { ...initialState().objects, offset: 100 } };
    const [s1] = reducer(s0, { type: "OBJECTS_FILTER_KIND", kind: "datawindow" }, defaultMockEnv);
    expect(s1.objects.kind).toBe("datawindow");
    expect(s1.objects.offset).toBe(0);
    expect(s1.objects.loading).toBe(true);
  });
});

describe("OBJECTS_SORT", () => {
  it("sets sort col, asc by default", () => {
    const [s] = reducer(initialState(), { type: "OBJECTS_SORT", col: "kind" }, defaultMockEnv);
    expect(s.objects.sort).toBe("kind");
    expect(s.objects.order).toBe("asc");
  });

  it("toggles order when same col", () => {
    const s0 = { ...initialState(), objects: { ...initialState().objects, sort: "name", order: "asc" as const } };
    const [s1] = reducer(s0, { type: "OBJECTS_SORT", col: "name" }, defaultMockEnv);
    expect(s1.objects.order).toBe("desc");
  });

  it("resets to asc when different col", () => {
    const s0 = { ...initialState(), objects: { ...initialState().objects, sort: "name", order: "desc" as const } };
    const [s1] = reducer(s0, { type: "OBJECTS_SORT", col: "kind" }, defaultMockEnv);
    expect(s1.objects.sort).toBe("kind");
    expect(s1.objects.order).toBe("asc");
  });
});

describe("OBJECTS_PAGE", () => {
  it("sets offset", () => {
    const [s] = reducer(initialState(), { type: "OBJECTS_PAGE", offset: 100 }, defaultMockEnv);
    expect(s.objects.offset).toBe(100);
    expect(s.objects.loading).toBe(true);
  });
});

describe("OBJECTS_LOADED", () => {
  it("sets items, total, clears loading", () => {
    const s0 = { ...initialState(), objects: { ...initialState().objects, loading: true } };
    const data = { items: [{ name: "foo", kind: "powerscript", file: "x", ancestor: null }], total: 42, offset: 0, limit: 100 };
    const [s1] = reducer(s0, { type: "OBJECTS_LOADED", data }, defaultMockEnv);
    expect(s1.objects.items).toHaveLength(1);
    expect(s1.objects.total).toBe(42);
    expect(s1.objects.loading).toBe(false);
  });
});

// ── Object detail ─────────────────────────────────────────────────────────────

describe("OBJECT_SELECTED", () => {
  it("clears detail, sets view, returns Effect", () => {
    const s0 = { ...initialState(), objectDetail: { name: "old", kind: "powerscript" as const, file: "x", ancestor: null, metrics: null, procedures: [], ancestors: [], descendants: [], callers: [], callees: [] } };
    const [s1, effect] = reducer(s0, { type: "OBJECT_SELECTED", name: "foo" }, defaultMockEnv);
    expect(s1.view).toBe("objectDetail");
    expect(s1.objectDetail).toBeNull();
    expect(effect).toBeInstanceOf(Effect);
  });

  it("dispatches OBJECT_LOADED and SOURCE_LOADED", async () => {
    const data = { name: "foo", kind: "powerscript" as const, file: "x", ancestor: null, metrics: null, procedures: [], ancestors: [], descendants: [], callers: [], callees: [] };
    const source = { name: "foo", source: "code" };
    const ts = createTestStore({
      getObject: () => Effect.send(data),
      getObjectSource: () => Effect.send(source),
    });
    await ts.send({ type: "OBJECT_SELECTED", name: "foo" });
    // Both actions arrive; order depends on Promise.all resolution — check both present
    const state = ts.getState();
    expect(state.view).toBe("objectDetail");
    // Consume both dispatched actions (order may vary)
    ts.receive({ type: "OBJECT_LOADED", data }).receive({ type: "SOURCE_LOADED", data: source });
  });
});

describe("OBJECT_LOADED", () => {
  it("sets objectDetail", () => {
    const data = { name: "foo", kind: "powerscript" as const, file: "x", ancestor: null, metrics: null, procedures: [], ancestors: [], descendants: [], callers: [], callees: [] };
    const [s] = reducer(initialState(), { type: "OBJECT_LOADED", data }, defaultMockEnv);
    expect(s.objectDetail).not.toBeNull();
    if (s.objectDetail && "name" in s.objectDetail) {
      expect(s.objectDetail.name).toBe("foo");
    }
  });
});

describe("OBJECT_LOAD_ERROR", () => {
  it("sets error on objectDetail", () => {
    const [s] = reducer(initialState(), { type: "OBJECT_LOAD_ERROR", error: "not found" }, defaultMockEnv);
    expect(s.objectDetail).toEqual({ error: "not found" });
  });
});

// ── Procedure detail ──────────────────────────────────────────────────────────

describe("PROCEDURE_SELECTED", () => {
  it("clears detail, sets view, returns Effect", () => {
    const [s, effect] = reducer(initialState(), {
      type: "PROCEDURE_SELECTED", objectName: "obj", procName: "proc",
    }, defaultMockEnv);
    expect(s.view).toBe("procedureDetail");
    expect(s.procedureDetail).toBeNull();
    expect(effect).toBeInstanceOf(Effect);
  });
});

describe("PROCEDURE_LOADED", () => {
  it("sets procedureDetail with activeTab", () => {
    const data = { object: "obj", name: "proc", proc_type: "function" as const, modifiers: null, params: null, return_type: null, start_line: 1, end_line: 10, cyclomatic: 1, source_original: "code", source_rendered: "code" };
    const [s] = reducer(initialState(), { type: "PROCEDURE_LOADED", data }, defaultMockEnv);
    expect(s.procedureDetail).not.toBeNull();
    if (s.procedureDetail && "activeTab" in s.procedureDetail) {
      expect(s.procedureDetail.activeTab).toBe("original");
    }
  });
});

describe("PROCEDURE_TAB", () => {
  it("switches activeTab", () => {
    const s0 = { ...initialState(), procedureDetail: { activeTab: "original" } as AppState["procedureDetail"] };
    const [s1] = reducer(s0, { type: "PROCEDURE_TAB", tab: "rendered" }, defaultMockEnv);
    expect(s1.procedureDetail).not.toBeNull();
    if (s1.procedureDetail && "activeTab" in s1.procedureDetail) {
      expect(s1.procedureDetail.activeTab).toBe("rendered");
    }
  });

  it("no-op when procedureDetail is null", () => {
    const [s] = reducer(initialState(), { type: "PROCEDURE_TAB", tab: "rendered" }, defaultMockEnv);
    expect(s.procedureDetail).toBeNull();
  });
});

// ── DataWindows ───────────────────────────────────────────────────────────────

describe("DW_SEARCH", () => {
  it("sets q, sets loading", () => {
    const [s] = reducer(initialState(), { type: "DW_SEARCH", q: "dw_" }, defaultMockEnv);
    expect(s.datawindows.q).toBe("dw_");
    expect(s.datawindows.loading).toBe(true);
  });
});

describe("DW_LOADED", () => {
  it("sets items, total, clears loading", () => {
    const data = { items: [{ name: "dw1", kind: "datawindow" as const, file: "x", ancestor: null }], total: 5, offset: 0, limit: 200 };
    const [s] = reducer(initialState(), { type: "DW_LOADED", data }, defaultMockEnv);
    expect(s.datawindows.items).toHaveLength(1);
    expect(s.datawindows.total).toBe(5);
    expect(s.datawindows.loading).toBe(false);
  });
});

describe("DW_SELECTED", () => {
  it("clears detail, sets view", () => {
    const [s] = reducer(initialState(), { type: "DW_SELECTED", name: "dw1" }, defaultMockEnv);
    expect(s.view).toBe("dwDetail");
    expect(s.dwDetail).toBeNull();
  });
});

describe("DW_LOADED_DETAIL", () => {
  it("sets dwDetail", () => {
    const data = { name: "dw1", file: "x", controls: [], retrieve_tables: [], retrieve_columns: [], retrieve_where: [], arguments: [], source: null };
    const [s] = reducer(initialState(), { type: "DW_LOADED_DETAIL", data }, defaultMockEnv);
    expect(s.dwDetail).not.toBeNull();
    if (s.dwDetail && "name" in s.dwDetail) {
      expect(s.dwDetail.name).toBe("dw1");
    }
  });
});

// ── Diagrams ──────────────────────────────────────────────────────────────────

describe("DIAGRAM_SELECT", () => {
  it("sets active, clears svg", () => {
    const s0 = { ...initialState(), diagrams: { ...initialState().diagrams, svg: "<svg>old</svg>" } };
    const [s1] = reducer(s0, { type: "DIAGRAM_SELECT", kind: "calls" }, defaultMockEnv);
    expect(s1.diagrams.active).toBe("calls");
    expect(s1.diagrams.svg).toBeNull();
  });
});

describe("DIAGRAM_PARAMS", () => {
  it("merges params", () => {
    const [s] = reducer(initialState(), { type: "DIAGRAM_PARAMS", params: { root: "foo" } }, defaultMockEnv);
    expect(s.diagrams.params).toEqual({ root: "foo" });
  });
});

describe("DIAGRAM_GENERATE", () => {
  it("sets loading, returns Effect", () => {
    const [s, effect] = reducer(initialState(), { type: "DIAGRAM_GENERATE" }, defaultMockEnv);
    expect(s.diagrams.loading).toBe(true);
    expect(effect).toBeInstanceOf(Effect);
  });

  it("dispatches DIAGRAM_LOADED with svg", async () => {
    const ts = createTestStore({ getDiagram: () => Effect.send("<svg/>") });
    await ts.send({ type: "DIAGRAM_GENERATE" });
    ts.receive({ type: "DIAGRAM_LOADED", svg: "<svg/>" });
  });

  it("dispatches DIAGRAM_ERROR on failure", async () => {
    const ts = createTestStore({
      getDiagram: () => Effect.fromPromise(() => Promise.reject(new Error("timeout"))),
    });
    await ts.send({ type: "DIAGRAM_GENERATE" });
    ts.receive({ type: "DIAGRAM_ERROR", error: "timeout" });
  });
});

describe("DIAGRAM_LOADED", () => {
  it("sets svg, clears loading", () => {
    const s0 = { ...initialState(), diagrams: { ...initialState().diagrams, loading: true } };
    const [s1] = reducer(s0, { type: "DIAGRAM_LOADED", svg: "<svg>ok</svg>" }, defaultMockEnv);
    expect(s1.diagrams.svg).toBe("<svg>ok</svg>");
    expect(s1.diagrams.loading).toBe(false);
  });
});

describe("DIAGRAM_ERROR", () => {
  it("clears loading, sets error", () => {
    const [s] = reducer(initialState(), { type: "DIAGRAM_ERROR", error: "timeout" }, defaultMockEnv);
    expect(s.diagrams.loading).toBe(false);
    expect(s.diagrams.error).toBe("timeout");
  });
});

// ── Queries ───────────────────────────────────────────────────────────────────

describe("QUERIES_LOADED", () => {
  it("sets items", () => {
    const items = [{ name: "top", description: "Most complex", params: [] }];
    const [s] = reducer(initialState(), { type: "QUERIES_LOADED", items }, defaultMockEnv);
    expect(s.queries.items).toEqual(items);
    expect(s.queries.loading).toBe(false);
  });
});

describe("QUERY_RUN", () => {
  it("clears results, sets resultsName", () => {
    const s0 = { ...initialState(), queries: { ...initialState().queries, results: { columns: [], rows: [{ x: 1 }] } } };
    const [s1] = reducer(s0, { type: "QUERY_RUN", name: "top", params: { n: "5" } }, defaultMockEnv);
    expect(s1.queries.results).toBeNull();
    expect(s1.queries.resultsName).toBe("top");
  });
});

describe("QUERY_LOADED", () => {
  it("sets results", () => {
    const data = { columns: ["obj"], rows: [{ obj: "foo" }] };
    const [s] = reducer(initialState(), { type: "QUERY_LOADED", data }, defaultMockEnv);
    expect(s.queries.results).toEqual(data);
    expect(s.queries.loading).toBe(false);
  });
});

// ── Search ────────────────────────────────────────────────────────────────────

describe("SEARCH_TERM", () => {
  it("sets term", () => {
    const [s] = reducer(initialState(), { type: "SEARCH_TERM", term: "fn_" }, defaultMockEnv);
    expect(s.search.term).toBe("fn_");
  });

  it("returns search Effect when term >= 2 chars", () => {
    const [, effect] = reducer(initialState(), { type: "SEARCH_TERM", term: "fn" }, defaultMockEnv);
    expect(effect).toBeInstanceOf(Effect);
  });

  it("no effect when term < 2 chars", () => {
    const [, effect] = reducer(initialState(), { type: "SEARCH_TERM", term: "f" }, defaultMockEnv);
    expect(effect).toBeNull();
  });
});

describe("SEARCH_LOADED", () => {
  it("sets results, clears loading", () => {
    const data = { objects: [], procedures: [], datawindows: [] };
    const s0 = { ...initialState(), search: { ...initialState().search, loading: true } };
    const [s1] = reducer(s0, { type: "SEARCH_LOADED", data }, defaultMockEnv);
    expect(s1.search.results).toEqual(data);
    expect(s1.search.loading).toBe(false);
  });
});

// ── Explore ───────────────────────────────────────────────────────────────────

describe("EXPLORE_LOAD", () => {
  it("sets loading, returns Effect", () => {
    const [s, effect] = reducer(initialState(), { type: "EXPLORE_LOAD" }, defaultMockEnv);
    expect(s.explore.loading).toBe(true);
    expect(effect).toBeInstanceOf(Effect);
  });

  it("dispatches EXPLORE_LOADED with tree data", async () => {
    const data = { libraries: [{ name: "lib.pbl", objects: [] }] };
    const ts = createTestStore({ getExploreTree: () => Effect.send(data) });
    await ts.send({ type: "EXPLORE_LOAD" });
    ts.receive({ type: "EXPLORE_LOADED", data });
  });

  it("dispatches empty EXPLORE_LOADED on error", async () => {
    const ts = createTestStore({
      getExploreTree: () => Effect.fromPromise(() => Promise.reject(new Error("net"))),
    });
    await ts.send({ type: "EXPLORE_LOAD" });
    ts.receive({ type: "EXPLORE_LOADED", data: { libraries: [] } });
  });
});

describe("EXPLORE_LOADED", () => {
  it("sets libraries, clears loading", () => {
    const data = { libraries: [{ name: "lib1.pbl", objects: [] }] };
    const s0 = { ...initialState(), explore: { ...initialState().explore, loading: true } };
    const [s1] = reducer(s0, { type: "EXPLORE_LOADED", data }, defaultMockEnv);
    expect(s1.explore.libraries).toHaveLength(1);
    expect(s1.explore.libraries[0].name).toBe("lib1.pbl");
    expect(s1.explore.loading).toBe(false);
  });
});

describe("EXPLORE_TOGGLE", () => {
  it("adds node to expanded set", () => {
    const [s] = reducer(initialState(), { type: "EXPLORE_TOGGLE", nodeId: "lib:foo" }, defaultMockEnv);
    expect(s.explore.expandedNodes.has("lib:foo")).toBe(true);
  });

  it("removes node if already expanded", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, expandedNodes: new Set(["lib:foo"]) } };
    const [s1] = reducer(s0, { type: "EXPLORE_TOGGLE", nodeId: "lib:foo" }, defaultMockEnv);
    expect(s1.explore.expandedNodes.has("lib:foo")).toBe(false);
  });
});

describe("EXPLORE_PROC_SELECT", () => {
  const mockDetail = { ast: null, source_rendered: "", proc_type: "event", params: null, return_type: null, modifiers: null, start_line: null, end_line: null, cyclomatic: null };

  it("sets selectedProc, clears selectedDw, returns Effect when not cached", () => {
    const [s, effect] = reducer(initialState(), {
      type: "EXPLORE_PROC_SELECT", objectName: "o", procName: "p", nodeId: "proc:o:p",
    }, defaultMockEnv);
    expect(s.explore.selectedProc).toBe("proc:o:p");
    expect(s.explore.selectedDw).toBeNull();
    expect(effect).toBeInstanceOf(Effect);
  });

  it("no effect when proc already cached", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, procCache: { "proc:o:p": mockDetail } } };
    const [s1, effect] = reducer(s0, {
      type: "EXPLORE_PROC_SELECT", objectName: "o", procName: "p", nodeId: "proc:o:p",
    }, defaultMockEnv);
    expect(s1.explore.selectedProc).toBe("proc:o:p");
    expect(effect).toBeNull();
  });

  it("does not toggle expandedNodes", () => {
    const [s] = reducer(initialState(), {
      type: "EXPLORE_PROC_SELECT", objectName: "o", procName: "p", nodeId: "proc:o:p",
    }, defaultMockEnv);
    expect(s.explore.expandedNodes.has("proc:o:p")).toBe(false);
  });

  it("dispatches EXPLORE_PROC_LOADED with fetched data", async () => {
    const data = { ast: null, source_rendered: "return", proc_type: "event", params: null, return_type: null, modifiers: null, start_line: 1, end_line: 2, cyclomatic: 1 };
    const ts = createTestStore({ getExploreProcedure: () => Effect.send(data) });
    await ts.send({ type: "EXPLORE_PROC_SELECT", objectName: "o", procName: "p", nodeId: "proc:o:p" });
    ts.receive({ type: "EXPLORE_PROC_LOADED", nodeId: "proc:o:p", data });
  });
});

describe("EXPLORE_PROC_LOADED", () => {
  it("caches proc detail", () => {
    const data = { ast: null, source_rendered: "", proc_type: "event", params: null, return_type: null, modifiers: null, start_line: null, end_line: null, cyclomatic: null };
    const [s] = reducer(initialState(), { type: "EXPLORE_PROC_LOADED", nodeId: "proc:o:p", data }, defaultMockEnv);
    expect(s.explore.procCache["proc:o:p"]).toEqual(data);
  });
});

describe("EXPLORE_PROC_ERROR", () => {
  it("caches error", () => {
    const [s] = reducer(initialState(), { type: "EXPLORE_PROC_ERROR", nodeId: "proc:o:p", error: "not found" }, defaultMockEnv);
    expect(s.explore.procCache["proc:o:p"]).toEqual({ error: "not found" });
  });
});

describe("EXPLORE_EXPAND_ALL", () => {
  it("expands all libraries and objects", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, libraries: [
      { name: "a.pbl", objects: [{ name: "o1", kind: "powerscript" as const, file: "f", procedures: [] }] },
      { name: "b.pbl", objects: [] },
    ]}};
    const [s1] = reducer(s0, { type: "EXPLORE_EXPAND_ALL" }, defaultMockEnv);
    expect(s1.explore.expandedNodes.has("lib:a.pbl")).toBe(true);
    expect(s1.explore.expandedNodes.has("lib:b.pbl")).toBe(true);
    expect(s1.explore.expandedNodes.has("obj:a.pbl:o1")).toBe(true);
  });
});

describe("EXPLORE_COLLAPSE_ALL", () => {
  it("clears all expanded nodes", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, expandedNodes: new Set(["lib:x", "obj:x:y"]) } };
    const [s1] = reducer(s0, { type: "EXPLORE_COLLAPSE_ALL" }, defaultMockEnv);
    expect(s1.explore.expandedNodes.size).toBe(0);
  });
});

describe("EXPLORE_TAB", () => {
  it("sets activeTab to ast", () => {
    const [s] = reducer(initialState(), { type: "EXPLORE_TAB", tab: "ast" }, defaultMockEnv);
    expect(s.explore.activeTab).toBe("ast");
  });

  it("sets activeTab back to source", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, activeTab: "ast" as const } };
    const [s1] = reducer(s0, { type: "EXPLORE_TAB", tab: "source" }, defaultMockEnv);
    expect(s1.explore.activeTab).toBe("source");
  });
});

describe("EXPLORE_FILTER", () => {
  it("sets treeFilter", () => {
    const [s] = reducer(initialState(), { type: "EXPLORE_FILTER", q: "fn_" }, defaultMockEnv);
    expect(s.explore.treeFilter).toBe("fn_");
  });

  it("empty string clears treeFilter", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, treeFilter: "old" } };
    const [s1] = reducer(s0, { type: "EXPLORE_FILTER", q: "" }, defaultMockEnv);
    expect(s1.explore.treeFilter).toBe("");
  });
});

describe("EXPLORE_PROC_SELECT resets activeTab", () => {
  it("resets activeTab to source when selecting a new proc", () => {
    const s0 = { ...initialState(), explore: { ...initialState().explore, activeTab: "ast" as const } };
    const [s1] = reducer(s0, {
      type: "EXPLORE_PROC_SELECT", objectName: "o", procName: "p", nodeId: "proc:o:p",
    }, defaultMockEnv);
    expect(s1.explore.activeTab).toBe("source");
  });
});

// ── Unknown action ────────────────────────────────────────────────────────────

describe("unknown action", () => {
  it("returns state unchanged, no effect", () => {
    const s0 = initialState();
    const [s1, effect] = reducer(s0, { type: "UNKNOWN_ACTION_XYZ" as AppAction["type"] }, defaultMockEnv);
    expect(s1).toBe(s0);
    expect(effect).toBeNull();
  });
});

// ── Immutability ──────────────────────────────────────────────────────────────

describe("immutability", () => {
  it("never mutates input state", () => {
    const s0 = initialState();
    const actions: AppAction[] = [
      { type: "NAVIGATE", view: "objects" },
      { type: "OBJECTS_SEARCH", q: "test" },
      { type: "OBJECTS_SORT", col: "kind" },
      { type: "OBJECTS_LOADED", data: { items: [], total: 0, offset: 0, limit: 100 } },
      { type: "OBJECT_SELECTED", name: "foo" },
      { type: "PROCEDURE_TAB", tab: "rendered" },
      { type: "STATS_LOADED", stats: { objects: 0, procedures: 0, dw_controls: 0, dw_retrieve_tables: 0, dw_retrieve_columns: 0, inherits: 0, calls: 0, object_metrics: 0, by_kind: [], top_complex: [], top_pagerank: [] } },
      { type: "DW_SEARCH", q: "x" },
      { type: "DIAGRAM_SELECT", kind: "calls" },
      { type: "SEARCH_TERM", term: "ab" },
      { type: "EXPLORE_TOGGLE", nodeId: "lib:x" },
      { type: "EXPLORE_COLLAPSE_ALL" },
    ];
    const original = JSON.stringify(s0);
    for (const a of actions) {
      reducer(s0, a, defaultMockEnv);
    }
    expect(JSON.stringify(s0)).toBe(original);
  });
});

// ── Effect class ──────────────────────────────────────────────────────────────

describe("Effect", () => {
  it("none() emits nothing", async () => {
    const received: number[] = [];
    await Effect.none<number>().execute(a => received.push(a));
    expect(received).toEqual([]);
  });

  it("send() emits immediately", async () => {
    const received: number[] = [];
    await Effect.send(42).execute(a => received.push(a));
    expect(received).toEqual([42]);
  });

  it("map() transforms emitted value", async () => {
    const received: string[] = [];
    await Effect.send(1).map(n => `n=${n}`).execute(a => received.push(a));
    expect(received).toEqual(["n=1"]);
  });

  it("catch() converts rejection to sent value", async () => {
    const received: string[] = [];
    const effect = Effect.fromPromise<string>(() => Promise.reject(new Error("boom")))
      .catch(e => `err:${(e as Error).message}`);
    await effect.execute(a => received.push(a));
    expect(received).toEqual(["err:boom"]);
  });

  it("merge() runs all effects and collects all emissions", async () => {
    const received: number[] = [];
    await Effect.merge(Effect.send(1), Effect.send(2), Effect.send(3))
      .execute(a => received.push(a));
    expect(received.sort()).toEqual([1, 2, 3]);
  });
});

// ── run() helper usage ────────────────────────────────────────────────────────

describe("run helper", () => {
  it("accumulates effects across multiple actions", () => {
    const { state, effects } = run(initialState(), defaultMockEnv,
      { type: "NAVIGATE", view: "objects" },
      { type: "STATS_LOAD" },
    );
    expect(state.view).toBe("objects");
    expect(effects).toHaveLength(1);
    expect(effects[0]).toBeInstanceOf(Effect);
  });
});
