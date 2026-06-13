/* reducer.test.js — Tests for pb explore core state management. */
import { describe, it, expect, vi } from "vitest";
import { initialState, reducer } from "../pbtools/explorer/static/core.js";

// ── Helpers ────────────────────────────────────────────────────────────────

function run(reducer, state, ...actions) {
    let s = state;
    const effects = [];
    for (const a of actions) {
        const [next, effect] = reducer(s, a);
        s = next;
        if (effect) effects.push(effect);
    }
    return { state: s, effects };
}

function effectNames(effects) {
    return effects.map(e => e.name || "<anonymous>");
}

const mockEnv = {
    api: {
        getStats: vi.fn(),
        getObjects: vi.fn(),
        getObject: vi.fn(),
        getProcedure: vi.fn(),
        search: vi.fn(),
        getDW: vi.fn(),
        getDiagram: vi.fn(),
        getQueries: vi.fn(),
        runQuery: vi.fn(),
    },
};

// ── initialState ───────────────────────────────────────────────────────────

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
    });

    it("returns fresh object each call", () => {
        const a = initialState();
        const b = initialState();
        expect(a).not.toBe(b);
        expect(a.objects).not.toBe(b.objects);
    });
});

// ── Navigation ─────────────────────────────────────────────────────────────

describe("NAVIGATE", () => {
    it("sets view", () => {
        const s0 = initialState();
        const [s1] = reducer(s0, { type: "NAVIGATE", view: "objects" });
        expect(s1.view).toBe("objects");
    });

    it("does not mutate original state", () => {
        const s0 = initialState();
        const [s1] = reducer(s0, { type: "NAVIGATE", view: "objects" });
        expect(s0.view).toBe("dashboard");
        expect(s1).not.toBe(s0);
    });
});

// ── Stats ──────────────────────────────────────────────────────────────────

describe("STATS_LOAD", () => {
    it("returns fetch effect", () => {
        const s0 = initialState();
        const [s, effect] = reducer(s0, { type: "STATS_LOAD" });
        expect(s).toBe(s0); // same reference — state unchanged
        expect(effect).toBeTypeOf("function");
    });
});

describe("STATS_LOADED", () => {
    it("sets stats", () => {
        const stats = { objects: 10, procedures: 20 };
        const [s] = reducer(initialState(), { type: "STATS_LOADED", stats });
        expect(s.stats).toEqual(stats);
    });
});

// ── Objects ────────────────────────────────────────────────────────────────

describe("OBJECTS_SEARCH", () => {
    it("sets q, resets offset, sets loading", () => {
        const s0 = initialState();
        s0.objects.offset = 200;
        const [s1] = reducer(s0, { type: "OBJECTS_SEARCH", q: "fn_" });
        expect(s1.objects.q).toBe("fn_");
        expect(s1.objects.offset).toBe(0);
        expect(s1.objects.loading).toBe(true);
    });

    it("returns fetchObjectsEffect", () => {
        const [, effect] = reducer(initialState(), { type: "OBJECTS_SEARCH", q: "x" });
        expect(effect).toBeTypeOf("function");
    });
});

describe("OBJECTS_FILTER_KIND", () => {
    it("sets kind, resets offset", () => {
        const s0 = initialState();
        s0.objects.offset = 100;
        const [s1] = reducer(s0, { type: "OBJECTS_FILTER_KIND", kind: "datawindow" });
        expect(s1.objects.kind).toBe("datawindow");
        expect(s1.objects.offset).toBe(0);
        expect(s1.objects.loading).toBe(true);
    });
});

describe("OBJECTS_SORT", () => {
    it("sets sort col, asc by default", () => {
        const [s] = reducer(initialState(), { type: "OBJECTS_SORT", col: "kind" });
        expect(s.objects.sort).toBe("kind");
        expect(s.objects.order).toBe("asc");
    });

    it("toggles order when same col", () => {
        const s0 = initialState();
        s0.objects.sort = "name";
        s0.objects.order = "asc";
        const [s1] = reducer(s0, { type: "OBJECTS_SORT", col: "name" });
        expect(s1.objects.order).toBe("desc");
    });

    it("resets to asc when different col", () => {
        const s0 = initialState();
        s0.objects.sort = "name";
        s0.objects.order = "desc";
        const [s1] = reducer(s0, { type: "OBJECTS_SORT", col: "kind" });
        expect(s1.objects.sort).toBe("kind");
        expect(s1.objects.order).toBe("asc");
    });
});

describe("OBJECTS_PAGE", () => {
    it("sets offset", () => {
        const [s] = reducer(initialState(), { type: "OBJECTS_PAGE", offset: 100 });
        expect(s.objects.offset).toBe(100);
        expect(s.objects.loading).toBe(true);
    });
});

describe("OBJECTS_LOADED", () => {
    it("sets items, total, clears loading", () => {
        const s0 = initialState();
        s0.objects.loading = true;
        const data = { items: [{ name: "foo" }], total: 42 };
        const [s1] = reducer(s0, { type: "OBJECTS_LOADED", data });
        expect(s1.objects.items).toEqual([{ name: "foo" }]);
        expect(s1.objects.total).toBe(42);
        expect(s1.objects.loading).toBe(false);
    });
});

// ── Object detail ──────────────────────────────────────────────────────────

describe("OBJECT_SELECTED", () => {
    it("clears detail, sets view, returns fetch effect", () => {
        const s0 = initialState();
        s0.objectDetail = { name: "old" };
        const [s1, effect] = reducer(s0, { type: "OBJECT_SELECTED", name: "foo" });
        expect(s1.view).toBe("objectDetail");
        expect(s1.objectDetail).toBeNull();
        expect(effect).toBeTypeOf("function");
    });
});

describe("OBJECT_LOADED", () => {
    it("sets objectDetail", () => {
        const data = { name: "foo", kind: "powerscript" };
        const [s] = reducer(initialState(), { type: "OBJECT_LOADED", data });
        expect(s.objectDetail.name).toBe("foo");
        expect(s.objectDetail.loading).toBe(false);
    });
});

describe("OBJECT_LOAD_ERROR", () => {
    it("sets error on objectDetail", () => {
        const [s] = reducer(initialState(), { type: "OBJECT_LOAD_ERROR", error: "not found" });
        expect(s.objectDetail.error).toBe("not found");
    });
});

// ── Procedure detail ───────────────────────────────────────────────────────

describe("PROCEDURE_SELECTED", () => {
    it("clears detail, sets view", () => {
        const [s, effect] = reducer(initialState(), {
            type: "PROCEDURE_SELECTED", objectName: "obj", procName: "proc",
        });
        expect(s.view).toBe("procedureDetail");
        expect(s.procedureDetail).toBeNull();
        expect(effect).toBeTypeOf("function");
    });
});

describe("PROCEDURE_LOADED", () => {
    it("sets procedureDetail with activeTab", () => {
        const data = { object: "obj", name: "proc", source_original: "code" };
        const [s] = reducer(initialState(), { type: "PROCEDURE_LOADED", data });
        expect(s.procedureDetail.activeTab).toBe("original");
        expect(s.procedureDetail.loading).toBe(false);
        expect(s.procedureDetail.source_original).toBe("code");
    });
});

describe("PROCEDURE_TAB", () => {
    it("switches activeTab", () => {
        const s0 = initialState();
        s0.procedureDetail = { activeTab: "original" };
        const [s1] = reducer(s0, { type: "PROCEDURE_TAB", tab: "rendered" });
        expect(s1.procedureDetail.activeTab).toBe("rendered");
    });

    it("no-op when procedureDetail is null", () => {
        const [s] = reducer(initialState(), { type: "PROCEDURE_TAB", tab: "rendered" });
        expect(s.procedureDetail).toBeNull();
    });
});

// ── DataWindows ────────────────────────────────────────────────────────────

describe("DW_SEARCH", () => {
    it("sets q, sets loading", () => {
        const [s] = reducer(initialState(), { type: "DW_SEARCH", q: "dw_" });
        expect(s.datawindows.q).toBe("dw_");
        expect(s.datawindows.loading).toBe(true);
    });
});

describe("DW_LOADED", () => {
    it("sets items, total, clears loading", () => {
        const data = { items: [{ name: "dw1" }], total: 5 };
        const [s] = reducer(initialState(), { type: "DW_LOADED", data });
        expect(s.datawindows.items).toEqual([{ name: "dw1" }]);
        expect(s.datawindows.total).toBe(5);
        expect(s.datawindows.loading).toBe(false);
    });
});

describe("DW_SELECTED", () => {
    it("clears detail, sets view", () => {
        const [s] = reducer(initialState(), { type: "DW_SELECTED", name: "dw1" });
        expect(s.view).toBe("dwDetail");
        expect(s.dwDetail).toBeNull();
    });
});

describe("DW_LOADED_DETAIL", () => {
    it("sets dwDetail", () => {
        const data = { name: "dw1", controls: [] };
        const [s] = reducer(initialState(), { type: "DW_LOADED_DETAIL", data });
        expect(s.dwDetail.name).toBe("dw1");
        expect(s.dwDetail.loading).toBe(false);
    });
});

// ── Diagrams ───────────────────────────────────────────────────────────────

describe("DIAGRAM_SELECT", () => {
    it("sets active, clears svg", () => {
        const s0 = initialState();
        s0.diagrams.svg = "<svg>old</svg>";
        const [s1] = reducer(s0, { type: "DIAGRAM_SELECT", kind: "calls" });
        expect(s1.diagrams.active).toBe("calls");
        expect(s1.diagrams.svg).toBeNull();
    });
});

describe("DIAGRAM_PARAMS", () => {
    it("merges params", () => {
        const [s] = reducer(initialState(), { type: "DIAGRAM_PARAMS", params: { root: "foo" } });
        expect(s.diagrams.params).toEqual({ root: "foo" });
    });
});

describe("DIAGRAM_GENERATE", () => {
    it("sets loading, returns effect", () => {
        const [s, effect] = reducer(initialState(), { type: "DIAGRAM_GENERATE" });
        expect(s.diagrams.loading).toBe(true);
        expect(effect).toBeTypeOf("function");
    });
});

describe("DIAGRAM_LOADED", () => {
    it("sets svg, clears loading", () => {
        const s0 = initialState();
        s0.diagrams.loading = true;
        const [s1] = reducer(s0, { type: "DIAGRAM_LOADED", svg: "<svg>ok</svg>" });
        expect(s1.diagrams.svg).toBe("<svg>ok</svg>");
        expect(s1.diagrams.loading).toBe(false);
    });
});

describe("DIAGRAM_ERROR", () => {
    it("clears loading, sets error", () => {
        const [s] = reducer(initialState(), { type: "DIAGRAM_ERROR", error: "timeout" });
        expect(s.diagrams.loading).toBe(false);
        expect(s.diagrams.error).toBe("timeout");
    });
});

// ── Queries ────────────────────────────────────────────────────────────────

describe("QUERIES_LOADED", () => {
    it("sets items", () => {
        const items = [{ name: "top", description: "Most complex" }];
        const [s] = reducer(initialState(), { type: "QUERIES_LOADED", items });
        expect(s.queries.items).toEqual(items);
        expect(s.queries.loading).toBe(false);
    });
});

describe("QUERY_RUN", () => {
    it("clears results, sets resultsName", () => {
        const s0 = initialState();
        s0.queries.results = { rows: [1, 2, 3] };
        const [s1] = reducer(s0, { type: "QUERY_RUN", name: "top", params: { n: 5 } });
        expect(s1.queries.results).toBeNull();
        expect(s1.queries.resultsName).toBe("top");
    });
});

describe("QUERY_LOADED", () => {
    it("sets results", () => {
        const data = { columns: ["obj"], rows: [{ obj: "foo" }] };
        const [s] = reducer(initialState(), { type: "QUERY_LOADED", name: "top", data });
        expect(s.queries.results).toEqual(data);
        expect(s.queries.loading).toBe(false);
    });
});

// ── Search ─────────────────────────────────────────────────────────────────

describe("SEARCH_TERM", () => {
    it("sets term", () => {
        const [s] = reducer(initialState(), { type: "SEARCH_TERM", term: "fn_" });
        expect(s.search.term).toBe("fn_");
    });

    it("returns search effect when term >= 2 chars", () => {
        const [, effect] = reducer(initialState(), { type: "SEARCH_TERM", term: "fn" });
        expect(effect).toBeTypeOf("function");
    });

    it("no effect when term < 2 chars", () => {
        const [, effect] = reducer(initialState(), { type: "SEARCH_TERM", term: "f" });
        expect(effect).toBeNull();
    });
});

describe("SEARCH_LOADED", () => {
    it("sets results, clears loading", () => {
        const data = { objects: [], procedures: [], datawindows: [] };
        const s0 = initialState();
        s0.search.loading = true;
        const [s1] = reducer(s0, { type: "SEARCH_LOADED", data });
        expect(s1.search.results).toEqual(data);
        expect(s1.search.loading).toBe(false);
    });
});

// ── Unknown action ─────────────────────────────────────────────────────────

describe("unknown action", () => {
    it("returns state unchanged, no effect", () => {
        const s0 = initialState();
        const [s1, effect] = reducer(s0, { type: "UNKNOWN_ACTION_XYZ" });
        expect(s1).toBe(s0);
        expect(effect).toBeNull();
    });
});

// ── Immutability ───────────────────────────────────────────────────────────

describe("immutability", () => {
    it("never mutates input state", () => {
        const s0 = initialState();
        const actions = [
            { type: "NAVIGATE", view: "objects" },
            { type: "OBJECTS_SEARCH", q: "test" },
            { type: "OBJECTS_SORT", col: "kind" },
            { type: "OBJECTS_LOADED", data: { items: [], total: 0 } },
            { type: "OBJECT_SELECTED", name: "foo" },
            { type: "PROCEDURE_TAB", tab: "rendered" },
            { type: "STATS_LOADED", stats: {} },
            { type: "DW_SEARCH", q: "x" },
            { type: "DIAGRAM_SELECT", kind: "calls" },
            { type: "SEARCH_TERM", term: "ab" },
        ];
        const original = JSON.stringify(s0);
        for (const a of actions) {
            reducer(s0, a);
        }
        expect(JSON.stringify(s0)).toBe(original);
    });
});
