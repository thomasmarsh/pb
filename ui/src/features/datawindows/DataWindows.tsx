// DataWindows.tsx — DataWindows list and detail views.

import { Show, For, onMount, createSignal } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { CodeBlock } from "../../components/CodeBlock.js";
import { TableChip } from "../../components/TableChip.js";
import { InlineDiagram } from "../../components/InlineDiagram.js";
import { shortFile } from "../../utils/format.js";
import { Loading } from "../../components/Loading.js";

export function DataWindows(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const dw = () => snap().datawindows;

  onMount(() => {
    store.dispatch({ tag: "datawindows", action: { type: "search", q: dw().q } });
  });

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search DataWindows..."
          value={dw().q}
          onInput={(e) => store.dispatch({ tag: "datawindows", action: { type: "search", q: e.currentTarget.value } })}
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
                      onClick={() => store.dispatch({ tag: "datawindows", action: { type: "select", name: d.name } })}>
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

export function DWDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const dw = () => snap().datawindows.dwDetail;

  return (
    <>
      <button class="back-btn" onClick={() => store.dispatch({ tag: "datawindows", action: { type: "back-to-datawindows" } })}>
        {"←"} Back to DataWindows
      </button>
      <Show when={dw()} fallback={<Loading />}>
        <Show when={!("error" in dw()!)} fallback={<div class="card"><p style={{ color: "var(--red)" }}>Error: {(dw() as { error: string }).error}</p></div>}>
          {(() => {
            const d = dw()!;
            if ("error" in d) return null;

            const [tab, setTab] = createSignal<"overview" | "controls" | "diagram" | "source">("overview");

            return (
              <>
              <h2 style={{ "margin-bottom": "16px", "font-size": "20px" }}>
                {d.name} <span class="badge badge-dw">datawindow</span>
              </h2>

              <div class="tab-bar" style={{ "margin-bottom": "16px" }}>
                <button class={tab() === "overview" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("overview")}>Overview</button>
                <Show when={d.controls.length > 0}>
                  <button class={tab() === "controls" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("controls")}>
                    Controls ({d.controls.length})
                  </button>
                </Show>
                <Show when={d.retrieve_tables.length > 0}>
                  <button class={tab() === "diagram" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("diagram")}>Diagram</button>
                </Show>
                <Show when={d.source}>
                  <button class={tab() === "source" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("source")}>Source</button>
                </Show>
              </div>

              <Show when={tab() === "overview"}>
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
                        {(t) => <TableChip name={t} store={store} />}
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
              </Show>

              <Show when={tab() === "controls"}>
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
                              <td class="name-cell">{c.control_name ?? "–"}</td>
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
              </Show>

              <Show when={tab() === "diagram"}>
                <div class="card">
                  <div class="card-header"><h3>DW → Table Relationships</h3></div>
                  <InlineDiagram kind="dw-tables" params={{ dw: d.name }} store={store} />
                </div>
              </Show>

              <Show when={tab() === "source"}>
                <Show when={d.source}>
                  <div class="card">
                    <div class="card-header"><h3>Source</h3></div>
                    <CodeBlock code={d.source!} />
                  </div>
                </Show>
              </Show>
              </>
            );
          })()}
        </Show>
      </Show>
    </>
  );
}
