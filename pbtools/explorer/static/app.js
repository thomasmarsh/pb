/* app.js — pb explore UI. Imports core.js for state management. */
import { initialState, reducer } from "./core.js";

// ── DOM helpers ────────────────────────────────────────────────────────────

const $ = (sel, ctx) => (ctx || document).querySelector(sel);
const el = (tag, attrs, ...children) => {
    const e = document.createElement(tag);
    if (attrs) Object.entries(attrs).forEach(([k, v]) => {
        if (k === "className") e.className = v;
        else if (k === "html") e.innerHTML = v;
        else if (k === "dataset") Object.entries(v).forEach(([dk, dv]) => e.dataset[dk] = dv);
        else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
        else e.setAttribute(k, v);
    });
    children.forEach(c => {
        if (typeof c === "string") e.appendChild(document.createTextNode(c));
        else if (c) e.appendChild(c);
    });
    return e;
};

// ── Utilities ──────────────────────────────────────────────────────────────

function procBadge(t) {
    return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] || "func";
}

function shortFile(f) {
    if (!f) return "";
    return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

function debounce(fn, ms) {
    let timer;
    return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); };
}

function apiParams(obj) {
    const p = new URLSearchParams();
    Object.entries(obj).forEach(([k, v]) => {
        if (v !== "" && v !== null && v !== undefined) p.set(k, String(v));
    });
    return p;
}

// ── Environment ────────────────────────────────────────────────────────────

const env = {
    api: {
        async getStats() {
            const r = await fetch("/api/stats");
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async getObjects(params) {
            const r = await fetch("/api/objects?" + apiParams(params));
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async getObject(name) {
            const r = await fetch("/api/objects/" + encodeURIComponent(name));
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async getProcedure(obj, proc) {
            const r = await fetch(`/api/procedures/${encodeURIComponent(obj)}/${encodeURIComponent(proc)}`);
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async search(q) {
            const r = await fetch("/api/search?q=" + encodeURIComponent(q));
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async getDW(name) {
            const r = await fetch("/api/dw/" + encodeURIComponent(name));
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async getDiagram(kind, params) {
            const r = await fetch(`/api/diagram/${kind}?` + apiParams(params));
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            return r.text();
        },
        async getQueries() {
            const r = await fetch("/api/queries");
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
        async runQuery(name, params) {
            const r = await fetch(`/api/queries/${name}/run?` + apiParams(params));
            if (!r.ok) throw new Error(`API ${r.status}`);
            return r.json();
        },
    },
};

// ── Store ──────────────────────────────────────────────────────────────────

let state = initialState();
const listeners = new Set();

function dispatch(action) {
    const [next, effect] = reducer(state, action);
    state = next;
    listeners.forEach(fn => fn(state));
    if (effect) {
        // Attach _getState so effects can read current state without closure
        dispatch._getState = () => state;
        effect(dispatch, env);
    }
}
dispatch._getState = () => state;

const store = {
    getState: () => state,
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    dispatch,
};

// ── Render ─────────────────────────────────────────────────────────────────

function render(state) {
    const main = $("#main-content");
    main.innerHTML = "";

    // Update sidebar active state
    $$("[data-view]").forEach(a => {
        const view = a.dataset.view;
        const isActive = view === a.dataset.view
            || (state.view === "objectDetail" && a.dataset.view === "objects")
            || (state.view === "procedureDetail" && a.dataset.view === "objects")
            || (state.view === "dwDetail" && a.dataset.view === "datawindows");
        a.classList.toggle("active", isActive);
    });

    const v = state.view;
    if (v === "dashboard")       return renderDashboard(state, main);
    if (v === "objects")         return renderObjects(state, main);
    if (v === "objectDetail")    return renderObjectDetail(state, main);
    if (v === "procedureDetail") return renderProcedureDetail(state, main);
    if (v === "datawindows")     return renderDataWindows(state, main);
    if (v === "dwDetail")        return renderDWDetail(state, main);
    if (v === "diagrams")        return renderDiagrams(state, main);
    if (v === "queries")         return renderQueries(state, main);
    if (v === "search")          return renderSearch(state, main);
}

function $$(sel, ctx) { return [...(ctx || document).querySelectorAll(sel)]; }

// ── Dashboard ──────────────────────────────────────────────────────────────

function renderDashboard(state, root) {
    const s = state.stats || {};
    const grid = el("div", { className: "metric-grid" });
    [
        ["Objects", s.objects],
        ["Procedures", s.procedures],
        ["DataWindows", (s.by_kind || []).find(k => k.kind === "datawindow")?.count || 0],
        ["Inheritance edges", s.inherits],
        ["Call edges", s.calls],
        ["DW Controls", s.dw_controls],
    ].forEach(([label, val]) => {
        grid.appendChild(el("div", { className: "metric-card" },
            el("div", { className: "label" }, label),
            el("div", { className: "value" }, String(val ?? "–"))));
    });
    root.appendChild(grid);

    if (s.by_kind && s.by_kind.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h2", null, "Object Types")));
        const table = el("table", { className: "data-table" });
        table.appendChild(el("thead", null, el("tr", null, el("th", null, "Kind"), el("th", null, "Count"))));
        const tbody = el("tbody");
        s.by_kind.forEach(k => {
            const bc = k.kind === "powerscript" ? "ps" : k.kind === "datawindow" ? "dw" : "proj";
            tbody.appendChild(el("tr", null,
                el("td", { className: "name-cell" }, el("span", { className: "badge badge-" + bc }, k.kind)),
                el("td", null, String(k.count))));
        });
        table.appendChild(tbody);
        card.appendChild(table);
        root.appendChild(card);
    }

    if (s.top_complex && s.top_complex.length)
        root.appendChild(_procedureTable("Most Complex Procedures", s.top_complex));
    if (s.top_pagerank && s.top_pagerank.length)
        root.appendChild(_objectTable("Most Important Objects (PageRank)", s.top_pagerank));
}

function _procedureTable(title, procs) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h2", null, title)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null,
        el("tr", null, el("th", null, "Object"), el("th", null, "Procedure"),
           el("th", null, "Type"), el("th", null, "Cyclomatic"))));
    const tbody = el("tbody");
    procs.forEach(p => {
        tbody.appendChild(el("tr", {
            className: "clickable",
            onClick: () => store.dispatch({ type: "PROCEDURE_SELECTED", objectName: p.object, procName: p.name }),
        },
            el("td", { className: "name-cell" }, p.object),
            el("td", null, p.name),
            el("td", null, el("span", { className: "badge badge-" + procBadge(p.proc_type) }, p.proc_type)),
            el("td", null, p.cyclomatic != null ? el("span", { className: "badge badge-cc" }, String(p.cyclomatic)) : "–")));
    });
    table.appendChild(tbody);
    card.appendChild(table);
    return card;
}

function _objectTable(title, objs) {
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h2", null, title)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null,
        el("tr", null, el("th", null, "Object"), el("th", null, "PageRank"),
           el("th", null, "In"), el("th", null, "Out"))));
    const tbody = el("tbody");
    objs.forEach(p => {
        tbody.appendChild(el("tr", {
            className: "clickable",
            onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: p.object }),
        },
            el("td", { className: "name-cell" }, p.object),
            el("td", null, String(p.pagerank)),
            el("td", null, String(p.in_degree)),
            el("td", null, String(p.out_degree))));
    });
    table.appendChild(tbody);
    card.appendChild(table);
    return card;
}

// ── Objects list ───────────────────────────────────────────────────────────

function renderObjects(state, root) {
    const os = state.objects;

    const search = el("div", { className: "search-bar" });
    const input = el("input", {
        className: "search-input", placeholder: "Search objects...", value: os.q,
    });
    input.addEventListener("input", debounce(() => {
        store.dispatch({ type: "OBJECTS_SEARCH", q: input.value });
    }, 300));
    search.appendChild(input);
    root.appendChild(search);

    const pills = el("div", { className: "filter-pills" });
    ["", "powerscript", "datawindow", "project", "pipeline"].forEach(k => {
        pills.appendChild(el("button", {
            className: "filter-pill" + (os.kind === k ? " active" : ""),
            onClick: () => store.dispatch({ type: "OBJECTS_FILTER_KIND", kind: k }),
        }, k || "All"));
    });
    root.appendChild(pills);

    if (os.loading && !os.items.length) {
        root.appendChild(el("div", { className: "loading-overlay" },
            el("div", { className: "spinner" }), " Loading..."));
        return;
    }

    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h2", null, `Objects (${os.total})`)));

    const sortIcon = (col) => os.sort === col ? (os.order === "asc" ? " ▲" : " ▼") : "";
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null,
        el("tr", null,
            el("th", { className: os.sort === "name" ? "sorted" : "",
                onClick: () => store.dispatch({ type: "OBJECTS_SORT", col: "name" }) }, "Name" + sortIcon("name")),
            el("th", { className: os.sort === "kind" ? "sorted" : "",
                onClick: () => store.dispatch({ type: "OBJECTS_SORT", col: "kind" }) }, "Kind" + sortIcon("kind")),
            el("th", null, "File"), el("th", null, "Ancestor"))));

    const tbody = el("tbody");
    os.items.forEach(obj => {
        const bc = obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj";
        tbody.appendChild(el("tr", {
            className: "clickable",
            onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: obj.name }),
        },
            el("td", { className: "name-cell" }, obj.name),
            el("td", null, el("span", { className: "badge badge-" + bc }, obj.kind)),
            el("td", { style: "font-size:11px;color:var(--text-muted);max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, shortFile(obj.file)),
            el("td", null, obj.ancestor || "")));
    });
    table.appendChild(tbody);
    card.appendChild(table);

    if (os.total > 100) {
        const pages = el("div", { style: "display:flex;gap:8px;margin-top:12px;justify-content:center" });
        if (os.offset > 0)
            pages.appendChild(el("button", { className: "filter-pill",
                onClick: () => store.dispatch({ type: "OBJECTS_PAGE", offset: Math.max(0, os.offset - 100) }),
            }, "← Previous"));
        pages.appendChild(el("span", { style: "color:var(--text-muted);font-size:12px;padding:4px 8px" },
            `${os.offset + 1}–${Math.min(os.offset + 100, os.total)} of ${os.total}`));
        if (os.offset + 100 < os.total)
            pages.appendChild(el("button", { className: "filter-pill",
                onClick: () => store.dispatch({ type: "OBJECTS_PAGE", offset: os.offset + 100 }),
            }, "Next →"));
        card.appendChild(pages);
    }
    root.appendChild(card);
}

// ── Object detail ──────────────────────────────────────────────────────────

function renderObjectDetail(state, root) {
    const obj = state.objectDetail;
    if (!obj) return root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading..."));
    if (obj.error) return root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--red)" }, "Error: " + obj.error)));

    root.appendChild(el("button", { className: "back-btn",
        onClick: () => store.dispatch({ type: "NAVIGATE", view: "objects" }) }, "← Back to Objects"));

    const bc = obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj";
    root.appendChild(el("h2", { style: "margin-bottom:16px;font-size:20px" },
        obj.name, " ", el("span", { className: "badge badge-" + bc }, obj.kind)));

    if (obj.metrics) {
        const m = obj.metrics;
        const grid = el("div", { className: "metric-grid" });
        [["In Degree", m.in_degree], ["Out Degree", m.out_degree], ["Max CC", m.max_cyclomatic],
         ["Avg CC", m.avg_cyclomatic ? parseFloat(m.avg_cyclomatic).toFixed(1) : "–"],
         ["PageRank", m.pagerank ? parseFloat(m.pagerank).toFixed(4) : "–"],
         ["DIT", m.dit ?? "–"]].forEach(([l, v]) => {
            grid.appendChild(el("div", { className: "metric-card" },
                el("div", { className: "label" }, l), el("div", { className: "value" }, String(v ?? "–"))));
        });
        root.appendChild(grid);
    }

    if (obj.ancestors && obj.ancestors.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Inheritance")));
        const list = el("div", { style: "display:flex;flex-wrap:wrap;gap:6px" });
        list.appendChild(el("span", { className: "badge badge-ps", style: "cursor:pointer",
            onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: obj.name }) }, obj.name));
        obj.ancestors.forEach(a => {
            list.appendChild(el("span", { style: "color:var(--text-muted)" }, " → "));
            list.appendChild(el("span", { className: "badge badge-ps", style: "cursor:pointer",
                onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: a }) }, a));
        });
        card.appendChild(list);
        root.appendChild(card);
    }

    if ((obj.callers && obj.callers.length) || (obj.callees && obj.callees.length)) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Call Graph")));
        const grid = el("div", { style: "display:grid;grid-template-columns:1fr 1fr;gap:16px" });
        [["CALLERS", obj.callers], ["CALLEES", obj.callees]].forEach(([label, items]) => {
            if (!items || !items.length) return;
            const col = el("div");
            col.appendChild(el("div", { style: "font-size:11px;color:var(--text-muted);margin-bottom:4px" }, `${label} (${items.length})`));
            const list = el("div", { style: "display:flex;flex-wrap:wrap;gap:4px" });
            items.forEach(c => list.appendChild(el("span", { className: "badge badge-func", style: "cursor:pointer",
                onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: c }) }, c)));
            col.appendChild(list);
            grid.appendChild(col);
        });
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
        obj.procedures.forEach(p => {
            tbody.appendChild(el("tr", {
                className: "clickable",
                onClick: () => store.dispatch({ type: "PROCEDURE_SELECTED", objectName: obj.name, procName: p.name }),
            },
                el("td", { className: "name-cell" }, p.name),
                el("td", null, el("span", { className: "badge badge-" + procBadge(p.proc_type) }, p.proc_type)),
                el("td", { style: "font-size:12px" }, p.modifiers || ""),
                el("td", { style: "font-size:12px;max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }, p.params || ""),
                el("td", null, p.cyclomatic != null ? el("span", { className: "badge badge-cc" }, String(p.cyclomatic)) : "–"),
                el("td", { style: "font-size:12px;color:var(--text-muted)" },
                    p.start_line && p.end_line ? `${p.start_line}–${p.end_line}` : "–")));
        });
        table.appendChild(tbody);
        card.appendChild(table);
        root.appendChild(card);
    }

    if (obj.file) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Source File")));
        card.appendChild(el("div", { style: "font-size:12px;color:var(--text-muted);word-break:break-all" }, obj.file));
        root.appendChild(card);
    }
}

// ── Procedure detail ───────────────────────────────────────────────────────

function renderProcedureDetail(state, root) {
    const proc = state.procedureDetail;
    if (!proc) return root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading..."));
    if (proc.error) return root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--red)" }, "Error: " + proc.error)));

    root.appendChild(el("button", { className: "back-btn",
        onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: proc.object }) }, "← Back to " + proc.object));

    const bc = procBadge(proc.proc_type);
    root.appendChild(el("h2", { style: "margin-bottom:4px;font-size:18px" },
        proc.object + ".", el("span", { style: "color:var(--accent)" }, proc.name),
        " ", el("span", { className: "badge badge-" + bc }, proc.proc_type)));

    const meta = el("div", { style: "font-size:12px;color:var(--text-muted);margin-bottom:16px" });
    if (proc.modifiers) meta.appendChild(el("span", null, proc.modifiers + " "));
    if (proc.params) meta.appendChild(el("span", null, "(" + proc.params + ") "));
    if (proc.return_type) meta.appendChild(el("span", null, "returns " + proc.return_type + " "));
    if (proc.cyclomatic != null) meta.appendChild(el("span", { className: "badge badge-cc", style: "margin-left:8px" }, "CC: " + proc.cyclomatic));
    root.appendChild(meta);

    const tabs = [];
    if (proc.source_original) tabs.push({ id: "original", label: "Original Source" });
    if (proc.source_rendered) tabs.push({ id: "rendered", label: "Rendered" });
    if (!tabs.length) return root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--text-muted)" }, "No source available")));

    const activeTab = proc.activeTab || tabs[0].id;
    const tabBar = el("div", { className: "tab-bar" });
    tabs.forEach(t => {
        tabBar.appendChild(el("button", {
            className: "tab-btn" + (t.id === activeTab ? " active" : ""),
            onClick: () => store.dispatch({ type: "PROCEDURE_TAB", tab: t.id }),
        }, t.label));
    });
    root.appendChild(tabBar);

    const code = activeTab === "original" ? proc.source_original : proc.source_rendered;
    if (code) {
        const viewer = el("div", { className: "code-viewer" });
        code.split("\n").forEach((line, i) => {
            const lineNum = activeTab === "original" ? (proc.start_line || 1) + i : i + 1;
            viewer.appendChild(el("div", { className: "code-line" },
                el("span", { className: "code-line-num" }, String(lineNum)),
                el("span", { className: "code-line-content" }, line)));
        });
        root.appendChild(viewer);
        if (activeTab === "original" && proc.file)
            root.appendChild(el("div", { style: "font-size:11px;color:var(--text-muted);margin-top:8px" },
                proc.file + ":" + (proc.start_line || "") + "-" + (proc.end_line || "")));
    }
}

// ── DataWindows list ───────────────────────────────────────────────────────

function renderDataWindows(state, root) {
    const dw = state.datawindows;
    const search = el("div", { className: "search-bar" });
    const input = el("input", { className: "search-input", placeholder: "Search DataWindows...", value: dw.q });
    input.addEventListener("input", debounce(() => store.dispatch({ type: "DW_SEARCH", q: input.value }), 300));
    search.appendChild(input);
    root.appendChild(search);

    if (dw.loading && !dw.items.length)
        return root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading..."));

    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h2", null, `DataWindows (${dw.total})`)));
    const table = el("table", { className: "data-table" });
    table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "File"))));
    const tbody = el("tbody");
    dw.items.forEach(d => {
        tbody.appendChild(el("tr", {
            className: "clickable",
            onClick: () => store.dispatch({ type: "DW_SELECTED", name: d.name }),
        },
            el("td", { className: "name-cell" }, d.name),
            el("td", { style: "font-size:11px;color:var(--text-muted)" }, shortFile(d.file))));
    });
    table.appendChild(tbody);
    card.appendChild(table);
    root.appendChild(card);
}

// ── DataWindow detail ──────────────────────────────────────────────────────

function renderDWDetail(state, root) {
    const dw = state.dwDetail;
    if (!dw) return root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading..."));
    if (dw.error) return root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--red)" }, "Error: " + dw.error)));

    root.appendChild(el("button", { className: "back-btn",
        onClick: () => store.dispatch({ type: "NAVIGATE", view: "datawindows" }) }, "← Back to DataWindows"));
    root.appendChild(el("h2", { style: "margin-bottom:16px;font-size:20px" },
        dw.name, " ", el("span", { className: "badge badge-dw" }, "datawindow")));

    const grid = el("div", { className: "metric-grid" });
    [["Controls", dw.controls.length], ["DB Tables", dw.retrieve_tables.length],
     ["Columns", dw.retrieve_columns.length], ["Arguments", dw.arguments.length]].forEach(([l, v]) => {
        grid.appendChild(el("div", { className: "metric-card" },
            el("div", { className: "label" }, l), el("div", { className: "value" }, String(v))));
    });
    root.appendChild(grid);

    if (dw.retrieve_tables.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Retrieve Tables")));
        const list = el("div", { style: "display:flex;flex-wrap:wrap;gap:6px" });
        dw.retrieve_tables.forEach(t => list.appendChild(el("span", { className: "badge badge-dw" }, t)));
        card.appendChild(list);
        root.appendChild(card);
    }

    if (dw.arguments.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, "Arguments")));
        const table = el("table", { className: "data-table" });
        table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "Type"))));
        const tbody = el("tbody");
        dw.arguments.forEach(a => tbody.appendChild(el("tr", null,
            el("td", { className: "name-cell" }, a.arg_name), el("td", null, a.arg_type || ""))));
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
        dw.retrieve_where.forEach(w => tbody.appendChild(el("tr", null,
            el("td", null, String(w.idx)), el("td", null, w.exp1 || ""),
            el("td", null, el("span", { className: "badge badge-event" }, w.op || "")),
            el("td", null, w.exp2 || ""),
            el("td", null, el("span", { className: "badge badge-func" }, w.logic || "")))));
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
        dw.controls.forEach(c => tbody.appendChild(el("tr", null,
            el("td", { className: "name-cell" }, c.control_name || "–"),
            el("td", null, c.control_type || ""),
            el("td", null, el("span", { className: "badge badge-on" }, c.band || "")),
            el("td", null, c.x != null ? String(c.x) : ""),
            el("td", null, c.y != null ? String(c.y) : ""),
            el("td", null, c.width != null ? String(c.width) : ""),
            el("td", null, c.height != null ? String(c.height) : ""),
            el("td", { style: "max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px" },
                c.expression || ""))));
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

// ── Diagrams ───────────────────────────────────────────────────────────────

function renderDiagrams(state, root) {
    const dg = state.diagrams;
    const tabBar = el("div", { className: "tab-bar" });
    ["inheritance", "calls", "dw-tables", "heatmap"].forEach(kind => {
        tabBar.appendChild(el("button", {
            className: "tab-btn" + (dg.active === kind ? " active" : ""),
            onClick: () => {
                store.dispatch({ type: "DIAGRAM_SELECT", kind });
                if (kind === "heatmap" || kind === "inheritance")
                    store.dispatch({ type: "DIAGRAM_GENERATE" });
            },
        }, kind));
    });
    root.appendChild(tabBar);

    const controls = el("div", { className: "card", style: "padding:12px 20px" });
    const row = el("div", { style: "display:flex;gap:8px;align-items:center" });

    if (dg.active === "inheritance") {
        const inp = el("input", { className: "search-input", placeholder: "Root object (optional)", style: "max-width:300px" });
        row.appendChild(inp);
        row.appendChild(el("button", { className: "filter-pill active", onClick: () => {
            store.dispatch({ type: "DIAGRAM_PARAMS", params: { root: inp.value } });
            store.dispatch({ type: "DIAGRAM_GENERATE" });
        } }, "Generate"));
    } else if (dg.active === "calls") {
        const focal = el("input", { className: "search-input", placeholder: "Focal object", style: "max-width:300px" });
        const depth = el("input", { className: "search-input", type: "number", value: "2", min: "1", max: "5", style: "max-width:80px" });
        row.appendChild(focal); row.appendChild(depth);
        row.appendChild(el("button", { className: "filter-pill active", onClick: () => {
            store.dispatch({ type: "DIAGRAM_PARAMS", params: { focal: focal.value, depth: depth.value } });
            store.dispatch({ type: "DIAGRAM_GENERATE" });
        } }, "Generate"));
    } else if (dg.active === "dw-tables") {
        const tbl = el("input", { className: "search-input", placeholder: "Filter table (optional)", style: "max-width:300px" });
        row.appendChild(tbl);
        row.appendChild(el("button", { className: "filter-pill active", onClick: () => {
            store.dispatch({ type: "DIAGRAM_PARAMS", params: { table: tbl.value } });
            store.dispatch({ type: "DIAGRAM_GENERATE" });
        } }, "Generate"));
    } else {
        row.appendChild(el("button", { className: "filter-pill active",
            onClick: () => store.dispatch({ type: "DIAGRAM_GENERATE" }) }, "Generate"));
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

// ── Queries ────────────────────────────────────────────────────────────────

function renderQueries(state, root) {
    const q = state.queries;
    const card = el("div", { className: "card" });
    card.appendChild(el("div", { className: "card-header" }, el("h2", null, "SQL Queries")));

    q.items.forEach(query => {
        const section = el("div", { style: "margin-bottom:16px;padding-bottom:16px;border-bottom:1px solid var(--border)" });
        section.appendChild(el("div", { style: "font-weight:600;margin-bottom:4px" }, query.name));
        section.appendChild(el("div", { style: "font-size:12px;color:var(--text-muted);margin-bottom:8px" }, query.description));
        const form = el("div", { style: "display:flex;gap:6px;align-items:center;flex-wrap:wrap" });
        const inputs = {};
        query.params.forEach(p => {
            const inp = el("input", { className: "search-input",
                placeholder: p.name + (p.default ? ` (${p.default})` : ""),
                style: "max-width:160px;padding:6px 10px;font-size:12px" });
            inputs[p.name] = inp;
            form.appendChild(inp);
        });
        form.appendChild(el("button", { className: "filter-pill active", onClick: () => {
            const params = {};
            query.params.forEach(p => {
                if (inputs[p.name].value) params[p.name] = inputs[p.name].value;
                else if (p.default) params[p.name] = p.default;
            });
            store.dispatch({ type: "QUERY_RUN", name: query.name, params });
        } }, "Run"));
        section.appendChild(form);
        card.appendChild(section);
    });

    const resultsDiv = el("div", { id: "query-results" });
    if (q.results) {
        if (q.results.error) {
            resultsDiv.appendChild(el("p", { style: "color:var(--red);padding:8px" }, q.results.error));
        } else if (q.results.rows && q.results.rows.length) {
            const rc = el("div", { className: "card" });
            rc.appendChild(el("div", { className: "card-header" },
                el("h3", null, `${q.resultsName} — ${q.results.rows.length} rows`)));
            const t = el("table", { className: "data-table" });
            t.appendChild(el("thead", null, el("tr", null, ...q.results.columns.map(c => el("th", null, c)))));
            const tb = el("tbody");
            q.results.rows.forEach(row => {
                tb.appendChild(el("tr", null, ...q.results.columns.map(c => el("td", null, row[c] != null ? String(row[c]) : ""))));
            });
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

// ── Search ─────────────────────────────────────────────────────────────────

function renderSearch(state, root) {
    const se = state.search;
    const search = el("div", { className: "search-bar" });
    const input = el("input", { className: "search-input", placeholder: "Search everything...", value: se.term });
    input.addEventListener("keydown", e => { if (e.key === "Enter") store.dispatch({ type: "SEARCH_TERM", term: input.value }); });
    input.addEventListener("input", debounce(() => store.dispatch({ type: "SEARCH_TERM", term: input.value }), 400));
    search.appendChild(input);
    root.appendChild(search);

    const container = el("div");
    if (se.loading) {
        container.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Searching..."));
    } else if (se.results) {
        _renderSearchResults(container, se.results);
    }
    root.appendChild(container);
}

function _renderSearchResults(container, data) {
    const total = data.objects.length + data.procedures.length + data.datawindows.length;
    if (total === 0) return container.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--text-muted)" }, "No results found")));

    if (data.objects.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, `Objects (${data.objects.length})`)));
        const table = el("table", { className: "data-table" });
        table.appendChild(el("thead", null, el("tr", null, el("th", null, "Name"), el("th", null, "Kind"), el("th", null, "File"))));
        const tbody = el("tbody");
        data.objects.forEach(o => {
            const bc = o.kind === "powerscript" ? "ps" : "dw";
            tbody.appendChild(el("tr", { className: "clickable",
                onClick: () => store.dispatch({ type: "OBJECT_SELECTED", name: o.name }) },
                el("td", { className: "name-cell" }, o.name),
                el("td", null, el("span", { className: "badge badge-" + bc }, o.kind)),
                el("td", { style: "font-size:11px;color:var(--text-muted)" }, shortFile(o.file))));
        });
        table.appendChild(tbody); card.appendChild(table); container.appendChild(card);
    }

    if (data.procedures.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, `Procedures (${data.procedures.length})`)));
        const table = el("table", { className: "data-table" });
        table.appendChild(el("thead", null, el("tr", null, el("th", null, "Object"), el("th", null, "Name"),
            el("th", null, "Type"), el("th", null, "Line"))));
        const tbody = el("tbody");
        data.procedures.forEach(p => {
            tbody.appendChild(el("tr", { className: "clickable",
                onClick: () => store.dispatch({ type: "PROCEDURE_SELECTED", objectName: p.object, procName: p.name }) },
                el("td", null, p.object), el("td", { className: "name-cell" }, p.name),
                el("td", null, el("span", { className: "badge badge-" + procBadge(p.proc_type) }, p.proc_type)),
                el("td", { style: "font-size:11px;color:var(--text-muted)" }, p.start_line ? String(p.start_line) : "")));
        });
        table.appendChild(tbody); card.appendChild(table); container.appendChild(card);
    }

    if (data.datawindows.length) {
        const card = el("div", { className: "card" });
        card.appendChild(el("div", { className: "card-header" }, el("h3", null, `DataWindow Controls (${data.datawindows.length})`)));
        const table = el("table", { className: "data-table" });
        table.appendChild(el("thead", null, el("tr", null, el("th", null, "DW"), el("th", null, "Control"), el("th", null, "Type"))));
        const tbody = el("tbody");
        data.datawindows.forEach(d => {
            tbody.appendChild(el("tr", { className: "clickable",
                onClick: () => store.dispatch({ type: "DW_SELECTED", name: d.dw_name }) },
                el("td", { className: "name-cell" }, d.dw_name),
                el("td", null, d.control_name || "–"), el("td", null, d.control_type || "")));
        });
        table.appendChild(tbody); card.appendChild(table); container.appendChild(card);
    }
}

// ── Sidebar wiring ─────────────────────────────────────────────────────────

$$("[data-nav]").forEach(a => {
    a.addEventListener("click", e => {
        e.preventDefault();
        const view = a.dataset.view;
        store.dispatch({ type: "NAVIGATE", view });
        if (view === "dashboard" && !state.stats) store.dispatch({ type: "STATS_LOAD" });
        else if (view === "objects") store.dispatch({ type: "OBJECTS_SEARCH", q: state.objects.q });
        else if (view === "datawindows") store.dispatch({ type: "DW_SEARCH", q: state.datawindows.q });
        else if (view === "diagrams" && (state.diagrams.active === "heatmap" || state.diagrams.active === "inheritance"))
            store.dispatch({ type: "DIAGRAM_GENERATE" });
        else if (view === "queries" && !state.queries.items.length)
            store.dispatch({ type: "QUERIES_LOAD" });
    });
});

// ── Bootstrap ──────────────────────────────────────────────────────────────

store.subscribe(render);
store.dispatch({ type: "STATS_LOAD" });
store.dispatch({ type: "NAVIGATE", view: "dashboard" });
