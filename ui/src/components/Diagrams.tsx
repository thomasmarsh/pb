// Diagrams.tsx — Diagrams view with tabs and controls.

import { Show, For, createSignal, onMount } from "solid-js";
import type { DiagramsState } from "../features/diagrams/types.js";

type DiagramKind = DiagramsState["active"];
import { Tabs } from "@kobalte/core/tabs";
import { useSnapshot } from "../core/store.js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";

export function Diagrams(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const dg = () => snap().diagrams;
  const [activeTab, setActiveTab] = createSignal("inheritance");
  const [focalInput, setFocalInput] = createSignal("");
  const [depthInput, setDepthInput] = createSignal("2");
  const [rootInput, setRootInput] = createSignal("");
  const [tableInput, setTableInput] = createSignal("");

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", view: "diagrams" } });
  });

  function handleGenerate() {
    const kind = activeTab();
    if (kind === "calls") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { focal: focalInput(), depth: depthInput() } } });
    } else if (kind === "inheritance") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { root: rootInput() } } });
    } else if (kind === "dw-tables") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { table: tableInput() } } });
    } else if (kind === "sql-lineage") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { focal: focalInput() } } });
    } else if (kind === "table-lineage") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { table: tableInput() } } });
    }
    store.dispatch({ tag: "diagrams", action: { type: "generate" } });
  }

  return (
    <>
      <Tabs value={activeTab()} onChange={(v) => {
        setActiveTab(v);
        store.dispatch({ tag: "diagrams", action: { type: "select", kind: v as DiagramKind } });
        if (v === "heatmap" || v === "inheritance" || v === "sql-lineage") store.dispatch({ tag: "diagrams", action: { type: "generate" } });
      }}>
        <Tabs.List class="tab-bar">
          <For each={["inheritance", "calls", "dw-tables", "heatmap", "sql-lineage", "table-lineage"] as DiagramKind[]}>
            {(kind) => <Tabs.Trigger value={kind} class="tab-btn">{kind}</Tabs.Trigger>}
          </For>
        </Tabs.List>
      </Tabs>

      <div class="card" style={{ padding: "12px 20px" }}>
        <div style={{ display: "flex", gap: "8px", "align-items": "center" }}>
          <Show when={activeTab() === "inheritance"}>
            <input class="search-input" placeholder="Root object (optional)" value={rootInput()}
                   onInput={(e) => setRootInput(e.currentTarget.value)} />
          </Show>
          <Show when={activeTab() === "calls"}>
            <input class="search-input" placeholder="Focal object" value={focalInput()}
                   onInput={(e) => setFocalInput(e.currentTarget.value)} />
            <input class="search-input" type="number" value={depthInput()} min="1" max="5"
                   style={{ "max-width": "80px" }}
                   onInput={(e) => setDepthInput(e.currentTarget.value)} />
          </Show>
          <Show when={activeTab() === "dw-tables"}>
            <input class="search-input" placeholder="Filter table (optional)" value={tableInput()}
                   onInput={(e) => setTableInput(e.currentTarget.value)} />
          </Show>
          <Show when={activeTab() === "sql-lineage"}>
            <input class="search-input" placeholder="Focal object (optional)" value={focalInput()}
                   onInput={(e) => setFocalInput(e.currentTarget.value)} />
          </Show>
          <Show when={activeTab() === "table-lineage"}>
            <input class="search-input" placeholder="Table name (required)" value={tableInput()}
                   onInput={(e) => setTableInput(e.currentTarget.value)} />
          </Show>
          <button class="filter-pill active" onClick={handleGenerate}>Generate</button>
        </div>
      </div>

      <div class="card">
        <Show when={dg().loading}>
          <div class="diagram-container">
            <div class="loading-overlay"><div class="spinner" /> Generating diagram...</div>
          </div>
        </Show>
        <Show when={dg().svg}>
          <div class="diagram-container" innerHTML={dg().svg!} />
        </Show>
        <Show when={dg().error}>
          <div class="diagram-container">
            <div class="loading-overlay" style={{ color: "var(--red)" }}>Error: {dg().error}</div>
          </div>
        </Show>
        <Show when={!dg().loading && !dg().svg && !dg().error}>
          <div class="diagram-container">
            <div class="loading-overlay">Select options and click Generate</div>
          </div>
        </Show>
      </div>
    </>
  );
}
