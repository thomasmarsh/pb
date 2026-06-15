// Explore.tsx — Interactive AST tree explorer (layout + wiring).

import { Show, For, onMount, createMemo, createEffect, createSignal } from "solid-js";
import { useSnapshot } from "../core/store.js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";
import { ExploreStoreContext, useExploreStore } from "./ExploreContext.js";
import { highlightPowerScript } from "../highlight.js";
import type { ExploreLibrary, ExploreObject, ExploreProcedure, DwExploreDetail, ExploreProcDetail, SqlStatementRow } from "../types/api.js";
import { TreeNode } from "./TreeNode.js";
import { AstNode } from "./ast-node.js";
import { DetailShell } from "./DetailShell.js";
import { SqlBlock } from "./CodeBlock.js";
import { DwDetailTree } from "./DwDetailTree.js";
import { TableList, TableDetailPanel } from "./Tables.js";

// ── Node IDs ──────────────────────────────────────────────────────────────────

function libId(name: string): string { return `lib:${name}`; }
function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }
function dwId(name: string): string { return `dw:${name}`; }

// ── Helpers ───────────────────────────────────────────────────────────────────

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "…" : s;
}

const KIND_BADGES: Record<string, string> = {
  powerscript: "badge-ps", datawindow: "badge-dw", project: "badge-proj",
};
const PROC_BADGES: Record<string, string> = {
  function: "badge-func", subroutine: "badge-sub", event: "badge-event", on: "badge-on",
};

function kindBadge(kind: string): string { return KIND_BADGES[kind] ?? "badge-proj"; }
function procBadge(t: string): string { return PROC_BADGES[t] ?? "badge-func"; }

// ── Procedure Tree Node ───────────────────────────────────────────────────────

function ProcNode(props: { objName: string; proc: ExploreProcedure; depth: number }) {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const nodeId = () => procId(props.objName, props.proc.name);
  const isSelected = () => snap().explore.selectedProc === nodeId();

  const summary = createMemo(() => {
    const p = props.proc;
    const parts: string[] = [];
    if (p.params) parts.push(truncate(p.params, 50));
    if (p.return_type) parts.push(`: ${p.return_type}`);
    if (p.cyclomatic != null) parts.push(`cc=${p.cyclomatic}`);
    return parts.join(" ");
  });

  return (
    <TreeNode
      nodeId={nodeId()}
      depth={props.depth}
      badge={{ text: props.proc.proc_type, cls: procBadge(props.proc.proc_type) }}
      name={props.proc.name}
      summary={summary()}
      selected={isSelected()}
      onClick={() => store.dispatch({
        tag: "explore",
        action: { type: "proc-select", objectName: props.objName, procName: props.proc.name, nodeId: nodeId() },
      })}
    />
  );
}

// ── DataWindow Tree Node ──────────────────────────────────────────────────────

function DwNode(props: { name: string; depth: number }) {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const nodeId = () => dwId(props.name);
  const isSelected = () => snap().explore.selectedDw === nodeId();

  return (
    <TreeNode
      nodeId={nodeId()}
      depth={props.depth}
      badge={{ text: "datawindow", cls: "badge-dw" }}
      name={props.name}
      selected={isSelected()}
      onClick={() => store.dispatch({ tag: "explore", action: { type: "dw-select", dwName: props.name, nodeId: nodeId() } })}
    />
  );
}

// ── Object Tree Node ──────────────────────────────────────────────────────────

function ObjectNode(props: { lib: string; obj: ExploreObject; depth: number }) {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const nodeId = () => objId(props.lib, props.obj.name);
  const isDw = () => props.obj.kind === "datawindow";

  const treeFilter = () => snap().explore.treeFilter.toLowerCase();

  const visibleProcs = createMemo(() => {
    const q = treeFilter();
    if (!q) return props.obj.procedures;
    return props.obj.procedures.filter(p => p.name.toLowerCase().includes(q));
  });

  const isVisible = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    if (props.obj.name.toLowerCase().includes(q)) return true;
    if (isDw()) return false;
    return visibleProcs().length > 0;
  });

  const procCount = createMemo(() => {
    if (isDw()) return "";
    const count = props.obj.procedures.length;
    return `${count} procedure${count !== 1 ? "s" : ""}`;
  });

  return (
    <Show when={isVisible()}>
      <TreeNode
        nodeId={nodeId()}
        depth={props.depth}
        badge={{ text: props.obj.kind, cls: kindBadge(props.obj.kind) }}
        name={props.obj.name}
        summary={isDw() ? undefined : procCount()}
      >
        <Show when={isDw()} fallback={
          <Show when={visibleProcs().length > 0} fallback={<div class="tree-empty">No procedures</div>}>
            <For each={visibleProcs()}>
              {(proc) => <ProcNode objName={props.obj.name} proc={proc} depth={props.depth + 1} />}
            </For>
          </Show>
        }>
          <DwNode name={props.obj.name} depth={props.depth + 1} />
        </Show>
      </TreeNode>
    </Show>
  );
}

// ── Library Tree Node ─────────────────────────────────────────────────────────

function LibraryNode(props: { lib: ExploreLibrary; depth: number }) {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const nodeId = () => libId(props.lib.name);

  const treeFilter = () => snap().explore.treeFilter.toLowerCase();

  const hasVisibleObjects = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    return props.lib.objects.some(obj => {
      if (obj.name.toLowerCase().includes(q)) return true;
      if (obj.kind === "datawindow") return false;
      return obj.procedures.some(p => p.name.toLowerCase().includes(q));
    });
  });

  return (
    <Show when={hasVisibleObjects()}>
      <TreeNode
        nodeId={nodeId()}
        depth={props.depth}
        icon={"▣"}
        name={props.lib.name}
        summary={`${props.lib.objects.length} objects`}
      >
        <For each={props.lib.objects}>
          {(obj) => <ObjectNode lib={props.lib.name} obj={obj} depth={props.depth + 1} />}
        </For>
      </TreeNode>
    </Show>
  );
}

// ── Proc Detail Panel ─────────────────────────────────────────────────────────

function ProcDetailPanel(props: { nodeId: string }) {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const entry = () => snap().explore.procCache[props.nodeId];
  const procName = () => props.nodeId.split(":")[2] ?? "";

  const activeTab = () => snap().explore.activeTab;

  return (
    <DetailShell<ExploreProcDetail> entry={entry()} loadingMsg="Loading...">
      {(d) => {
        const lines = createMemo(() => d.source_rendered ? d.source_rendered.split("\n") : []);
        const highlighted = createMemo(() => d.source_rendered ? highlightPowerScript(d.source_rendered) : "");

        const highlightIdx = createMemo(() => {
          const hl = snap().explore.highlightedLine;
          if (hl == null) return null;
          const idx = hl - (d.start_line ?? 1);
          if (idx < 0 || idx >= lines().length) return null;
          return idx;
        });

        const [sourceViewerEl, setSourceViewerEl] = createSignal<HTMLDivElement | null>(null);
        createEffect(() => {
          const idx = highlightIdx();
          const el = sourceViewerEl();
          if (idx == null || !el) return;
          el.scrollTop = Math.max(0, idx * 20.8 - 80);
        });

        return (
          <>
            <div class="explore-right-header">
              <span class={`badge ${procBadge(d.proc_type)}`}>{d.proc_type}</span>
              <span class="proc-name">{procName()}</span>
              <Show when={d.params}>
                <span class="proc-params">({d.params})</span>
              </Show>
              <Show when={d.return_type}>
                <span class="proc-params">{"→"} {d.return_type}</span>
              </Show>
              <Show when={d.cyclomatic != null}>
                <span class="badge badge-cc">CC: {d.cyclomatic}</span>
              </Show>
              <div class="explore-tabs" style={{ "margin-left": "auto" }}>
                <button
                  class={`explore-tab-btn${activeTab() === "source" ? " active" : ""}`}
                  onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "source" } })}
                >Source</button>
                <button
                  class={`explore-tab-btn${activeTab() === "ast" ? " active" : ""}`}
                  onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "ast" } })}
                >AST</button>
                <Show when={d.sql_statements.length > 0}>
                  <button
                    class={`explore-tab-btn${activeTab() === "sql" ? " active" : ""}`}
                    onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "sql" } })}
                  >SQL ({d.sql_statements.length})</button>
                </Show>
              </div>
            </div>
            <div class="explore-right-body">
              <Show when={activeTab() === "source"}>
                <div class="source-viewer" ref={setSourceViewerEl}>
                  <div class="source-gutter">
                    <For each={lines()}>
                      {(_, i) => (
                        <div
                          class="source-gutter-line"
                          style={i() === highlightIdx() ? {
                            color: "#fb923c", "font-weight": "600",
                            background: "rgba(251, 146, 60, 0.12)",
                          } : undefined}
                        >
                          {(d.start_line ?? 1) + i()}
                        </div>
                      )}
                    </For>
                  </div>
                  <div class="source-code-area">
                    <Show when={highlightIdx() != null}>
                      <div class="ast-line-highlight" style={{
                        top: `${highlightIdx()! * 20.8}px`,
                        height: "20.8px",
                      }} />
                    </Show>
                    <pre innerHTML={highlighted()} />
                  </div>
                </div>
              </Show>
              <Show when={activeTab() === "ast"}>
                <AstNode node={d.ast} nodeId={props.nodeId + ".ast"} depth={0} />
              </Show>
              <Show when={activeTab() === "sql"}>
                <div class="sql-tab-body">
                  <For each={d.sql_statements}>
                    {(stmt: SqlStatementRow) => (
                      <div class="sql-stmt-block">
                        <div class="sql-stmt-header">
                          <span class="badge badge-sql">{stmt.operation}</span>
                          <Show when={stmt.tables && stmt.tables.length > 0}>
                            <span class="sql-tables-label">{stmt.tables!.join(", ")}</span>
                          </Show>
                          <Show when={!stmt.parse_ok}>
                            <span class="badge badge-warn">unparsed</span>
                          </Show>
                        </div>
                        <SqlBlock code={stmt.formatted_sql} />
                      </div>
                    )}
                  </For>
                </div>
              </Show>
            </div>
          </>
        );
      }}
    </DetailShell>
  );
}

// ── DW Detail Panel ───────────────────────────────────────────────────────────

function DwDetailPanel(props: { nodeId: string }) {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const entry = () => snap().explore.dwCache[props.nodeId];
  const dwName = () => props.nodeId.replace(/^dw:/, "");

  return (
    <DetailShell<DwExploreDetail> entry={entry()} loadingMsg="Loading DataWindow...">
      {(d) => (
        <>
          <div class="explore-right-header">
            <span class="badge badge-dw">datawindow</span>
            <span class="proc-name">{dwName()}</span>
            <span class="proc-params">{d.controls.length} controls</span>
          </div>
          <div class="explore-right-body">
            <DwDetailTree data={d} />
          </div>
        </>
      )}
    </DetailShell>
  );
}

// ── Detail Panel ──────────────────────────────────────────────────────────────

function ObjectsDetailPanel() {
  const store = useExploreStore();
  const snap = useSnapshot(store.state);
  const selectedProc = () => snap().explore.selectedProc;
  const selectedDw = () => snap().explore.selectedDw;

  return (
    <Show when={selectedProc()} fallback={
      <Show when={selectedDw()} fallback={
        <div class="explore-empty">Select a procedure or DataWindow</div>
      }>
        {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
      </Show>
    }>
      {(nodeId) => <ProcDetailPanel nodeId={nodeId()} />}
    </Show>
  );
}

function TablesRightPanel(props: { store: Store<AppState, AppAction> }) {
  const snap = useSnapshot(props.store.state);
  const selectedDw = () => snap().explore.selectedDw;

  return (
    <Show when={selectedDw()} fallback={<TableDetailPanel store={props.store} />}>
      {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
    </Show>
  );
}

// ── Main Explore Component ────────────────────────────────────────────────────

export function Explore(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", view: "explore" } });
    if (snap().explore.libraries.length === 0 && !snap().explore.loading) {
      store.dispatch({ tag: "explore", action: { type: "load" } });
    }
  });

  const totalObjects = createMemo(() =>
    snap().explore.libraries.reduce((sum: number, lib: ExploreLibrary) => sum + lib.objects.length, 0)
  );

  const totalProcs = createMemo(() =>
    snap().explore.libraries.reduce(
      (sum: number, lib: ExploreLibrary) => sum + lib.objects.reduce((s: number, obj: ExploreObject) => s + obj.procedures.length, 0),
      0
    )
  );

  const leftTab = () => snap().explore.leftTab;

  return (
    <ExploreStoreContext.Provider value={store}>
      <div class="explore-split">
        <div class="explore-left">
          <div class="explore-left-header">
            <h2>AST Explorer</h2>
            <div class="explore-tabs" style={{ "margin-bottom": "6px" }}>
              <button
                class={`explore-tab-btn${leftTab() === "objects" ? " active" : ""}`}
                onClick={() => store.dispatch({ tag: "explore", action: { type: "left-tab", tab: "objects" } })}
              >Objects</button>
              <button
                class={`explore-tab-btn${leftTab() === "tables" ? " active" : ""}`}
                onClick={() => store.dispatch({ tag: "explore", action: { type: "left-tab", tab: "tables" } })}
              >Tables</button>
            </div>
            <Show when={leftTab() === "objects"}>
              <div class="explore-meta">
                <span>{snap().explore.libraries.length} libraries</span>
                <span>{totalObjects()} objects</span>
                <span>{totalProcs()} procedures</span>
              </div>
              <div class="explore-left-actions">
                <button class="filter-pill" onClick={() => store.dispatch({ tag: "explore", action: { type: "expand-all" } })}>
                  Expand All
                </button>
                <button class="filter-pill" onClick={() => store.dispatch({ tag: "explore", action: { type: "collapse-all" } })}>
                  Collapse All
                </button>
              </div>
              <input
                class="explore-filter-input"
                placeholder="Filter…"
                value={snap().explore.treeFilter}
                onInput={(e) => store.dispatch({ tag: "explore", action: { type: "filter", q: e.currentTarget.value } })}
              />
            </Show>
          </div>
          <div class="explore-left-tree">
            <Show when={leftTab() === "objects"} fallback={<TableList store={store} />}>
              <Show
                when={!snap().explore.loading}
                fallback={<div class="loading-overlay"><div class="spinner" /> Loading AST tree...</div>}
              >
                <Show
                  when={snap().explore.libraries.length > 0}
                  fallback={<div class="tree-empty">No data. Run <code>pb ingest</code> first.</div>}
                >
                  <For each={snap().explore.libraries}>
                    {(lib) => <LibraryNode lib={lib} depth={0} />}
                  </For>
                </Show>
              </Show>
            </Show>
          </div>
        </div>
        <div class="explore-right">
          <Show when={leftTab() === "objects"} fallback={<TablesRightPanel store={store} />}>
            <ObjectsDetailPanel />
          </Show>
        </div>
      </div>
    </ExploreStoreContext.Provider>
  );
}
