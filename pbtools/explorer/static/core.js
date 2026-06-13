/* core.js — Pure state management for pb explore.
 *
 * No DOM, no side effects, no imports. Fully testable.
 *
 * Architecture:
 *   State   — single immutable object
 *   Action  — { type, ...payload }
 *   Effect  — (dispatch, env) => Promise<void>
 *   Reducer — (state, action) -> [newState, Effect | null]
 */

// ── State ──────────────────────────────────────────────────────────────────

export function initialState() {
    return {
        view: "dashboard",
        stats: null,
        objects: {
            items: [], total: 0,
            q: "", kind: "", sort: "name", order: "asc",
            offset: 0, loading: false,
        },
        objectDetail: null,
        procedureDetail: null,
        datawindows: { items: [], total: 0, q: "", loading: false },
        dwDetail: null,
        diagrams: { active: "inheritance", svg: null, loading: false, params: {} },
        queries: { items: [], results: null, resultsName: "", loading: false },
        search: { term: "", results: null, loading: false },
    };
}

// ── Effects ────────────────────────────────────────────────────────────────
// Each effect is (dispatch, env) => Promise<void>.
// The store calls effect(dispatch, env) after reducer returns it.

export async function fetchObjectsEffect(dispatch, env) {
    const s = dispatch._getState();
    const p = {
        q: s.objects.q, kind: s.objects.kind,
        sort: s.objects.sort, order: s.objects.order,
        limit: 100, offset: s.objects.offset,
    };
    try {
        const data = await env.api.getObjects(p);
        dispatch({ type: "OBJECTS_LOADED", data });
    } catch (e) { console.error("objects fetch failed:", e); }
}

export async function fetchDWListEffect(dispatch, env) {
    const s = dispatch._getState();
    const p = { q: s.datawindows.q, kind: "datawindow", limit: 200 };
    try {
        const data = await env.api.getObjects(p);
        dispatch({ type: "DW_LOADED", data });
    } catch (e) { console.error("dw fetch failed:", e); }
}

export async function doSearchEffect(dispatch, env) {
    const s = dispatch._getState();
    const q = s.search.term;
    if (!q || q.length < 2) return;
    try {
        const data = await env.api.search(q);
        dispatch({ type: "SEARCH_LOADED", data });
    } catch (e) { console.error("search failed:", e); }
}

// Generic async fetch effect — calls apiMethod, dispatches loadedAction on success
function asyncFetch(apiCall, loadedType, errorType) {
    return async (dispatch, env) => {
        try {
            const data = await apiCall(env.api);
            dispatch({ type: loadedType, data });
        } catch (e) {
            dispatch({ type: errorType, error: e.message });
        }
    };
}

// ── Reducer ────────────────────────────────────────────────────────────────

export function reducer(state, action) {
    switch (action.type) {

    // Navigation
    case "NAVIGATE":
        return [{ ...state, view: action.view }, null];

    // Stats
    case "STATS_LOAD":
        return [state, async (dispatch, env) => {
            try {
                const stats = await env.api.getStats();
                dispatch({ type: "STATS_LOADED", stats });
            } catch (e) { console.error("stats load failed:", e); }
        }];
    case "STATS_LOADED":
        return [{ ...state, stats: action.stats }, null];

    // Objects
    case "OBJECTS_SEARCH":
        return [{
            ...state,
            objects: { ...state.objects, q: action.q, offset: 0, loading: true },
        }, fetchObjectsEffect];

    case "OBJECTS_FILTER_KIND":
        return [{
            ...state,
            objects: { ...state.objects, kind: action.kind, offset: 0, loading: true },
        }, fetchObjectsEffect];

    case "OBJECTS_SORT":
        return [{
            ...state,
            objects: {
                ...state.objects,
                sort: action.col,
                order: state.objects.sort === action.col
                    ? (state.objects.order === "asc" ? "desc" : "asc")
                    : "asc",
                offset: 0, loading: true,
            },
        }, fetchObjectsEffect];

    case "OBJECTS_PAGE":
        return [{
            ...state,
            objects: { ...state.objects, offset: action.offset, loading: true },
        }, fetchObjectsEffect];

    case "OBJECTS_LOADED":
        return [{
            ...state,
            objects: { ...state.objects, items: action.data.items, total: action.data.total, loading: false },
        }, null];

    // Object detail
    case "OBJECT_SELECTED":
        return [{ ...state, objectDetail: null, view: "objectDetail" },
            asyncFetch(api => api.getObject(action.name), "OBJECT_LOADED", "OBJECT_LOAD_ERROR")];
    case "OBJECT_LOADED":
        return [{ ...state, objectDetail: { ...action.data, loading: false } }, null];
    case "OBJECT_LOAD_ERROR":
        return [{ ...state, objectDetail: { error: action.error } }, null];

    // Procedure detail
    case "PROCEDURE_SELECTED":
        return [{ ...state, procedureDetail: null, view: "procedureDetail" },
            asyncFetch(
                api => api.getProcedure(action.objectName, action.procName),
                "PROCEDURE_LOADED", "PROCEDURE_LOAD_ERROR",
            )];
    case "PROCEDURE_LOADED":
        return [{ ...state, procedureDetail: { ...action.data, activeTab: "original", loading: false } }, null];
    case "PROCEDURE_LOAD_ERROR":
        return [{ ...state, procedureDetail: { error: action.error } }, null];
    case "PROCEDURE_TAB":
        return [{
            ...state,
            procedureDetail: state.procedureDetail
                ? { ...state.procedureDetail, activeTab: action.tab }
                : null,
        }, null];

    // DataWindows
    case "DW_SEARCH":
        return [{
            ...state,
            datawindows: { ...state.datawindows, q: action.q, loading: true },
        }, fetchDWListEffect];

    case "DW_LOADED":
        return [{
            ...state,
            datawindows: { ...state.datawindows, items: action.data.items, total: action.data.total, loading: false },
        }, null];

    case "DW_SELECTED":
        return [{ ...state, dwDetail: null, view: "dwDetail" },
            asyncFetch(api => api.getDW(action.name), "DW_LOADED_DETAIL", "DW_LOAD_ERROR")];
    case "DW_LOADED_DETAIL":
        return [{ ...state, dwDetail: { ...action.data, loading: false } }, null];
    case "DW_LOAD_ERROR":
        return [{ ...state, dwDetail: { error: action.error } }, null];

    // Diagrams
    case "DIAGRAM_SELECT":
        return [{
            ...state,
            diagrams: { ...state.diagrams, active: action.kind, svg: null, loading: false },
        }, null];

    case "DIAGRAM_PARAMS":
        return [{
            ...state,
            diagrams: { ...state.diagrams, params: action.params },
        }, null];

    case "DIAGRAM_GENERATE":
        return [{ ...state, diagrams: { ...state.diagrams, loading: true } },
            async (dispatch, env) => {
                try {
                    const kind = state.diagrams.active;
                    const svg = await env.api.getDiagram(kind, state.diagrams.params);
                    dispatch({ type: "DIAGRAM_LOADED", svg });
                } catch (e) {
                    dispatch({ type: "DIAGRAM_ERROR", error: e.message });
                }
            }];
    case "DIAGRAM_LOADED":
        return [{ ...state, diagrams: { ...state.diagrams, svg: action.svg, loading: false } }, null];
    case "DIAGRAM_ERROR":
        return [{ ...state, diagrams: { ...state.diagrams, svg: null, loading: false, error: action.error } }, null];

    // Queries
    case "QUERIES_LOAD":
        return [{ ...state, queries: { ...state.queries, loading: true } }, async (dispatch, env) => {
            try {
                const data = await env.api.getQueries();
                dispatch({ type: "QUERIES_LOADED", items: data.queries });
            } catch (e) { console.error("queries load failed:", e); }
        }];
    case "QUERIES_LOADED":
        return [{ ...state, queries: { ...state.queries, items: action.items, loading: false } }, null];

    case "QUERY_RUN":
        return [{ ...state, queries: { ...state.queries, results: null, resultsName: action.name } },
            asyncFetch(api => api.runQuery(action.name, action.params), "QUERY_LOADED", "QUERY_ERROR")];
    case "QUERY_LOADED":
        return [{ ...state, queries: { ...state.queries, results: action.data, loading: false } }, null];
    case "QUERY_ERROR":
        return [{ ...state, queries: { ...state.queries, results: { error: action.error }, loading: false } }, null];

    // Search
    case "SEARCH_TERM":
        return [{
            ...state,
            search: { ...state.search, term: action.term },
        }, action.term.length >= 2 ? doSearchEffect : null];

    case "SEARCH_LOADED":
        return [{ ...state, search: { ...state.search, results: action.data, loading: false } }, null];

    default:
        return [state, null];
    }
}
