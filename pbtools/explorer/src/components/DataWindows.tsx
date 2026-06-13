// DataWindows.tsx — DataWindows list and detail views.

import { Show, For, onMount } from "solid-js";
import { useNavigate } from "@solidjs/router";
import { useStore } from "../context.js";

function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

function Loading() {
  return <div class="loading-overlay"><div class="spinner" /> Loading...</div>;
}

export function DataWindows() {
  const store = useStore();
  const dw = () => store.state.datawindows;

  onMount(() => {
    store.dispatch({ type: "DW_SEARCH", q: dw().q });
  });

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search DataWindows..."
          value={dw().q}
          onInput={(e) => store.dispatch({ type: "DW_SEARCH", q: e.currentTarget.value })}
        />
      </div>

      <Show when={!dw().loading || dw().items.length > 0} fallback={<Loading />}>
        <div class="card">
          <div class="card-header"><h2>DataWindows ({dw().total})</h2></div>
          <table class="data-table">
            <thead><tr><th>Name</th><th>File</th></tr></thead>
            <tbody>
              <For each={dw().items}>
                {(d) => (
                  <tr class="clickable"
                      onClick={() => store.dispatch({ type: "DW_SELECTED", name: d.name })}>
                    <td class="name-cell">{d.name}</td>
                    <td style={{ "font-size": "11px", color: "var(--text-muted)" }}>{shortFile(d.file)}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>
    </>
  );
}

export function DWDetail() {
  const store = useStore();
  const navigate = useNavigate();
  const dw = () => store.state.dwDetail;

  return (
    <Show when={dw()} fallback={<Loading />}>
      <Show when={!("error" in dw()!)} fallback={<div class="card"><p style={{ color: "var(--red)" }}>Error: {(dw() as { error: string }).error}</p></div>}>
        {(() => {
          const d = dw()!;
          if ("error" in d) return null;
          return (
            <>
              <button class="back-btn" onClick={() => navigate("/datawindows")}>
                {"\u2190"} Back to DataWindows
              </button>
              <h2 style={{ "margin-bottom": "16px", "font-size": "20px" }}>
                {d.name} <span class="badge badge-dw">datawindow</span>
              </h2>

              <div class="metric-grid">
                <For each={[
                  ["Controls", d.controls.length],
                  ["DB Tables", d.retrieve_tables.length],
                  ["Columns", d.retrieve_columns.length],
                  ["Arguments", d.arguments.length],
                ] as [string, number][]}>
                  {([l, v]) => (
                    <div class="metric-card">
                      <div class="label">{l}</div>
                      <div class="value">{String(v)}</div>
                    </div>
                  )}
                </For>
              </div>

              <Show when={d.retrieve_tables.length > 0}>
                <div class="card">
                  <div class="card-header"><h3>Retrieve Tables</h3></div>
                  <div style={{ display: "flex", "flex-wrap": "wrap", gap: "6px" }}>
                    <For each={d.retrieve_tables}>
                      {(t) => <span class="badge badge-dw">{t}</span>}
                    </For>
                  </div>
                </div>
              </Show>

              <Show when={d.arguments.length > 0}>
                <div class="card">
                  <div class="card-header"><h3>Arguments</h3></div>
                  <table class="data-table">
                    <thead><tr><th>Name</th><th>Type</th></tr></thead>
                    <tbody>
                      <For each={d.arguments}>
                        {(a) => <tr><td class="name-cell">{a.arg_name}</td><td>{a.arg_type ?? ""}</td></tr>}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>

              <Show when={d.retrieve_where.length > 0}>
                <div class="card">
                  <div class="card-header"><h3>WHERE Clauses</h3></div>
                  <table class="data-table">
                    <thead><tr><th>#</th><th>Exp1</th><th>Op</th><th>Exp2</th><th>Logic</th></tr></thead>
                    <tbody>
                      <For each={d.retrieve_where}>
                        {(w) => (
                          <tr>
                            <td>{String(w.idx)}</td>
                            <td>{w.exp1 ?? ""}</td>
                            <td><span class="badge badge-event">{w.op ?? ""}</span></td>
                            <td>{w.exp2 ?? ""}</td>
                            <td><span class="badge badge-func">{w.logic ?? ""}</span></td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>

              <Show when={d.controls.length > 0}>
                <div class="card">
                  <div class="card-header"><h3>Controls ({d.controls.length})</h3></div>
                  <table class="data-table">
                    <thead>
                      <tr><th>Name</th><th>Type</th><th>Band</th><th>X</th><th>Y</th><th>W</th><th>H</th><th>Expr</th></tr>
                    </thead>
                    <tbody>
                      <For each={d.controls}>
                        {(c) => (
                          <tr>
                            <td class="name-cell">{c.control_name ?? "\u2013"}</td>
                            <td>{c.control_type ?? ""}</td>
                            <td><span class="badge badge-on">{c.band ?? ""}</span></td>
                            <td>{c.x != null ? String(c.x) : ""}</td>
                            <td>{c.y != null ? String(c.y) : ""}</td>
                            <td>{c.width != null ? String(c.width) : ""}</td>
                            <td>{c.height != null ? String(c.height) : ""}</td>
                            <td style={{ "max-width": "200px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap", "font-size": "11px" }}>
                              {c.expression ?? ""}
                            </td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>

              <Show when={d.source}>
                <div class="card">
                  <div class="card-header"><h3>Source</h3></div>
                  <div class="code-viewer">
                    {d.source!.split("\n").map((line, i) => (
                      <div class="code-line">
                        <span class="code-line-num">{String(i + 1)}</span>
                        <span class="code-line-content">{line}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </Show>
            </>
          );
        })()}
      </Show>
    </Show>
  );
}
