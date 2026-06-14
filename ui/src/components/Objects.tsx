// Objects.tsx — Objects list and detail views.

import { Show, For, onMount } from "solid-js";
import { useStore } from "../context.js";
import { SourceViewer } from "./SourceViewer.js";

function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

function Loading() {
  return <div class="loading-overlay"><div class="spinner" /> Loading...</div>;
}

export function Objects() {
  const store = useStore();
  const os = () => store.state.objects;

  onMount(() => {
    store.dispatch({ type: "NAVIGATE", view: "objects" });
    store.dispatch({ type: "OBJECTS_SEARCH", q: os().q });
  });

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search objects..."
          value={os().q}
          onInput={(e) => store.dispatch({ type: "OBJECTS_SEARCH", q: e.currentTarget.value })}
        />
      </div>

      <div class="filter-pills">
        <For each={["", "powerscript", "datawindow", "project", "pipeline"]}>
          {(k) => (
            <button
              class={`filter-pill${os().kind === k ? " active" : ""}`}
              onClick={() => store.dispatch({ type: "OBJECTS_FILTER_KIND", kind: k })}
            >
              {k || "All"}
            </button>
          )}
        </For>
      </div>

      <Show when={!os().loading || os().items.length > 0} fallback={<Loading />}>
        <div class="card">
          <div class="card-header"><h2>Objects ({os().total})</h2></div>
          <table class="data-table">
            <thead>
              <tr>
                <th class={os().sort === "name" ? "sorted" : ""}
                    onClick={() => store.dispatch({ type: "OBJECTS_SORT", col: "name" })}>
                  Name{os().sort === "name" ? (os().order === "asc" ? " \u25B2" : " \u25BC") : ""}
                </th>
                <th class={os().sort === "kind" ? "sorted" : ""}
                    onClick={() => store.dispatch({ type: "OBJECTS_SORT", col: "kind" })}>
                  Kind{os().sort === "kind" ? (os().order === "asc" ? " \u25B2" : " \u25BC") : ""}
                </th>
                <th>File</th><th>Ancestor</th>
              </tr>
            </thead>
            <tbody>
              <For each={os().items}>
                {(obj) => {
                  const bc = obj.kind === "powerscript" ? "ps" : obj.kind === "datawindow" ? "dw" : "proj";
                  return (
                    <tr class="clickable"
                        onClick={() => store.dispatch({ type: "OBJECT_SELECTED", name: obj.name })}>
                      <td class="name-cell">{obj.name}</td>
                      <td><span class={`badge badge-${bc}`}>{obj.kind}</span></td>
                      <td style={{ "font-size": "11px", color: "var(--text-muted)", "max-width": "300px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}>
                        {shortFile(obj.file)}
                      </td>
                      <td>{obj.ancestor ?? ""}</td>
                    </tr>
                  );
                }}
              </For>
            </tbody>
          </table>

          <Show when={os().total > 100}>
            <div style={{ display: "flex", gap: "8px", "margin-top": "12px", "justify-content": "center" }}>
              <Show when={os().offset > 0}>
                <button class="filter-pill"
                    onClick={() => store.dispatch({ type: "OBJECTS_PAGE", offset: Math.max(0, os().offset - 100) })}>
                  \u2190 Previous
                </button>
              </Show>
              <span style={{ color: "var(--text-muted)", "font-size": "12px", padding: "4px 8px" }}>
                {os().offset + 1}\u2013{Math.min(os().offset + 100, os().total)} of {os().total}
              </span>
              <Show when={os().offset + 100 < os().total}>
                <button class="filter-pill"
                    onClick={() => store.dispatch({ type: "OBJECTS_PAGE", offset: os().offset + 100 })}>
                  Next \u2192
                </button>
              </Show>
            </div>
          </Show>
        </div>
      </Show>
    </>
  );
}

export function ObjectDetail() {
  const store = useStore();
  const obj = () => store.state.objectDetail;
  const src = () => store.state.sourceDetail;

  onMount(() => {
    store.dispatch({ type: "NAVIGATE", view: "objectDetail" });
  });

  return (
    <Show when={obj()} fallback={<Loading />}>
      <Show when={!("error" in obj()!)} fallback={<div class="card"><p style={{ color: "var(--red)" }}>Error: {"error" in obj()! ? (obj() as { error: string }).error : ""}</p></div>}>
        <button class="back-btn" onClick={() => store.dispatch({ type: "NAVIGATE", view: "objects" })}>{"\u2190"} Back to Objects</button>

        {(() => {
          const o = obj()!;
          if ("error" in o) return null;
          const bc = o.kind === "powerscript" ? "ps" : o.kind === "datawindow" ? "dw" : "proj";
          return (
            <>
              <h2 style={{ "margin-bottom": "16px", "font-size": "20px" }}>
                {o.name} <span class={`badge badge-${bc}`}>{o.kind}</span>
              </h2>

              <Show when={o.metrics}>
                <div class="metric-grid">
                  <For each={[
                    ["In Degree", o.metrics!.in_degree],
                    ["Out Degree", o.metrics!.out_degree],
                    ["Max CC", o.metrics!.max_cyclomatic],
                    ["Avg CC", o.metrics!.avg_cyclomatic ? parseFloat(String(o.metrics!.avg_cyclomatic)).toFixed(1) : "\u2013"],
                    ["PageRank", o.metrics!.pagerank ? parseFloat(String(o.metrics!.pagerank)).toFixed(4) : "\u2013"],
                    ["DIT", o.metrics!.dit ?? "\u2013"],
                  ] as [string, string | number | null | undefined][]}>
                    {([l, v]) => (
                      <div class="metric-card">
                        <div class="label">{l}</div>
                        <div class="value">{String(v ?? "\u2013")}</div>
                      </div>
                    )}
                  </For>
                </div>
              </Show>

              <Show when={o.ancestors && o.ancestors.length > 0}>
                <div class="card">
                  <div class="card-header"><h3>Inheritance</h3></div>
                  <div style={{ display: "flex", "flex-wrap": "wrap", gap: "6px" }}>
                    <span class="badge badge-ps" style={{ cursor: "pointer" }}
                          onClick={() => store.dispatch({ type: "OBJECT_SELECTED", name: o.name })}>
                      {o.name}
                    </span>
                    <For each={o.ancestors}>
                      {(a) => (
                        <>
                          <span style={{ color: "var(--text-muted)" }}>{"\u2192"}</span>
                          <span class="badge badge-ps" style={{ cursor: "pointer" }}
                                onClick={() => store.dispatch({ type: "OBJECT_SELECTED", name: a })}>
                            {a}
                          </span>
                        </>
                      )}
                    </For>
                  </div>
                </div>
              </Show>

              <Show when={(o.callers?.length ?? 0) > 0 || (o.callees?.length ?? 0) > 0}>
                <div class="card">
                  <div class="card-header"><h3>Call Graph</h3></div>
                  <div style={{ display: "grid", "grid-template-columns": "1fr 1fr", gap: "16px" }}>
                    <For each={[["CALLERS", o.callers], ["CALLEES", o.callees]] as [string, string[] | undefined][]}>
                      {([label, items]) => (
                        <Show when={items && items.length > 0}>
                          <div>
                            <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "4px" }}>
                              {label} ({items!.length})
                            </div>
                            <div style={{ display: "flex", "flex-wrap": "wrap", gap: "4px" }}>
                              <For each={items!}>
                                {(c) => (
                                  <span class="badge badge-func" style={{ cursor: "pointer" }}
                                        onClick={() => store.dispatch({ type: "OBJECT_SELECTED", name: c })}>
                                    {c}
                                  </span>
                                )}
                              </For>
                            </div>
                          </div>
                        </Show>
                      )}
                    </For>
                  </div>
                </div>
              </Show>

              <Show when={o.procedures && o.procedures.length > 0}>
                <div class="card">
                  <div class="card-header"><h3>Procedures ({o.procedures!.length})</h3></div>
                  <table class="data-table">
                    <thead>
                      <tr><th>Name</th><th>Type</th><th>Modifiers</th><th>Params</th><th>CC</th><th>Lines</th></tr>
                    </thead>
                    <tbody>
                      <For each={o.procedures!}>
                        {(p) => (
                          <tr class="clickable"
                              onClick={() => store.dispatch({ type: "PROCEDURE_SELECTED", objectName: o.name, procName: p.name })}>
                            <td class="name-cell">{p.name}</td>
                            <td><span class={`badge badge-${procBadge(p.proc_type)}`}>{p.proc_type}</span></td>
                            <td style={{ "font-size": "12px" }}>{p.modifiers ?? ""}</td>
                            <td style={{ "font-size": "12px", "max-width": "200px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}>{p.params ?? ""}</td>
                            <td>{p.cyclomatic != null ? <span class="badge badge-cc">{String(p.cyclomatic)}</span> : "\u2013"}</td>
                            <td style={{ "font-size": "12px", color: "var(--text-muted)" }}>
                              {p.start_line && p.end_line ? `${p.start_line}\u2013${p.end_line}` : "\u2013"}
                            </td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>

              <Show when={o.file}>
                <div class="card">
                  <div class="source-file-header">
                    <div class="card-header"><h3>Source</h3></div>
                    <div class="source-file-path">{o.file}</div>
                  </div>
                  <Show
                    when={src() && "lines" in (src() ?? {}) && (src() as { lines?: string[] }).lines && (src() as { lines: string[] }).lines!.length > 0}
                    fallback={<Show when={src() && "error" in (src() ?? {})}><p style={{ color: "var(--red)", "font-size": "12px" }}>{(src() as { error: string }).error}</p></Show>}
                  >
                    <SourceViewer
                      lines={(src() as { lines: string[] }).lines}
                      procedures={(src() as { procedures: import("../types/api.js").ProcedureInfo[] }).procedures}
                      knownObjects={(src() as { knownObjects: { name: string; kind: string }[] }).knownObjects}
                      knownProcs={(src() as { knownProcs: { name: string; object: string; proc_type: string }[] }).knownProcs}
                      objectName={o.name}
                    />
                  </Show>
                </div>
              </Show>
            </>
          );
        })()}
      </Show>
    </Show>
  );
}
