// Explore.tsx — Interactive AST tree explorer (layout + wiring).

import { Show, For, onMount, createMemo, createEffect, createSignal } from "solid-js";
import { useStore } from "../context.js";
import { highlightPowerScript } from "../highlight.js";
import type { ExploreLibrary, ExploreObject, ExploreProcedure, DwExploreDetail, ExploreProcDetail } from "../types/api.js";
import { TreeNode } from "./TreeNode.js";
import { AstNode } from "./ast-node.js";
import { DetailShell } from "./DetailShell.js";
import { DwDetailTree } from "./DwDetailTree.js";

// ── Node IDs ──────────────────────────────────────────────────────────────────

function libId(name: string): string { return `lib:${name}`; }
function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }
function dwId(name: string): string { return `dw:${name}`; }

// ── Helpers ───────────────────────────────────────────────────────────────────

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "\u2026" : s;
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
  const store = useStore();
  const nodeId = () => procId(props.objName, props.proc.name);
  const isSelected = () => store.state.explore.selectedProc === nodeId();

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
        type: "EXPLORE_PROC_SELECT",
        objectName: props.objName,
        procName: props.proc.name,
        nodeId: nodeId(),
      })}
    />
  );
}

// ── DataWindow Tree Node ──────────────────────────────────────────────────────

function DwNode(props: { name: string; depth: number }) {
  const store = useStore();
  const nodeId = () => dwId(props.name);
  const isSelected = () => store.state.explore.selectedDw === nodeId();

  return (
    <TreeNode
      nodeId={nodeId()}
      depth={props.depth}
      badge={{ text: "datawindow", cls: "badge-dw" }}
      name={props.name}
      selected={isSelected()}
      onClick={() => store.dispatch({ type: "EXPLORE_DW_SELECT", dwName: props.name, nodeId: nodeId() })}
    />
  );
}

// ── Object Tree Node ──────────────────────────────────────────────────────────

function ObjectNode(props: { lib: string; obj: ExploreObject; depth: number }) {
  const store = useStore();
  const nodeId = () => objId(props.lib, props.obj.name);
  const isDw = () => props.obj.kind === "datawindow";

  const treeFilter = () => store.state.explore.treeFilter.toLowerCase();

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
  const store = useStore();
  const nodeId = () => libId(props.lib.name);

  const treeFilter = () => store.state.explore.treeFilter.toLowerCase();

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
        icon={"\u25A3"}
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
  const store = useStore();
  const entry = () => store.state.explore.procCache[props.nodeId];
  const procName = () => props.nodeId.split(":")[2] ?? "";

  const activeTab = () => store.state.explore.activeTab;

  return (
    <DetailShell<ExploreProcDetail> entry={entry()} loadingMsg="Loading...">
      {(d) => {
        const lines = createMemo(() => d.source_rendered ? d.source_rendered.split("\n") : []);
        const highlighted = createMemo(() => d.source_rendered ? highlightPowerScript(d.source_rendered) : "");

        const highlightIdx = createMemo(() => {
          const hl = store.state.explore.highlightedLine;
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
                <span class="proc-params">{"\u2192"} {d.return_type}</span>
              </Show>
              <Show when={d.cyclomatic != null}>
                <span class="badge badge-cc">CC: {d.cyclomatic}</span>
              </Show>
              <div class="explore-tabs" style={{ "margin-left": "auto" }}>
                <button
                  class={`explore-tab-btn${activeTab() === "source" ? " active" : ""}`}
                  onClick={() => store.dispatch({ type: "EXPLORE_TAB", tab: "source" })}
                >Source</button>
                <button
                  class={`explore-tab-btn${activeTab() === "ast" ? " active" : ""}`}
                  onClick={() => store.dispatch({ type: "EXPLORE_TAB", tab: "ast" })}
                >AST</button>
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
            </div>
          </>
        );
      }}
    </DetailShell>
  );
}

// ── DW Detail Panel ───────────────────────────────────────────────────────────

function DwDetailPanel(props: { nodeId: string }) {
  const store = useStore();
  const entry = () => store.state.explore.dwCache[props.nodeId];
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

function DetailPanel() {
  const store = useStore();
  const selectedProc = () => store.state.explore.selectedProc;
  const selectedDw = () => store.state.explore.selectedDw;

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

// ── Main Explore Component ────────────────────────────────────────────────────

export function Explore() {
  const store = useStore();

  onMount(() => {
    store.dispatch({ type: "NAVIGATE", view: "explore" });
    if (store.state.explore.libraries.length === 0 && !store.state.explore.loading) {
      store.dispatch({ type: "EXPLORE_LOAD" });
    }
  });

  const totalObjects = createMemo(() =>
    store.state.explore.libraries.reduce((sum, lib) => sum + lib.objects.length, 0)
  );

  const totalProcs = createMemo(() =>
    store.state.explore.libraries.reduce(
      (sum, lib) => sum + lib.objects.reduce((s, obj) => s + obj.procedures.length, 0),
      0
    )
  );

  return (
    <div class="explore-split">
      <div class="explore-left">
        <div class="explore-left-header">
          <h2>AST Explorer</h2>
          <div class="explore-meta">
            <span>{store.state.explore.libraries.length} libraries</span>
            <span>{totalObjects()} objects</span>
            <span>{totalProcs()} procedures</span>
          </div>
          <div class="explore-left-actions">
            <button class="filter-pill" onClick={() => store.dispatch({ type: "EXPLORE_EXPAND_ALL" })}>
              Expand All
            </button>
            <button class="filter-pill" onClick={() => store.dispatch({ type: "EXPLORE_COLLAPSE_ALL" })}>
              Collapse All
            </button>
          </div>
          <input
            class="explore-filter-input"
            placeholder="Filter\u2026"
            value={store.state.explore.treeFilter}
            onInput={(e) => store.dispatch({ type: "EXPLORE_FILTER", q: e.currentTarget.value })}
          />
        </div>
        <div class="explore-left-tree">
          <Show
            when={!store.state.explore.loading}
            fallback={<div class="loading-overlay"><div class="spinner" /> Loading AST tree...</div>}
          >
            <Show
              when={store.state.explore.libraries.length > 0}
              fallback={<div class="tree-empty">No data. Run <code>pb ingest</code> first.</div>}
            >
              <For each={store.state.explore.libraries}>
                {(lib) => <LibraryNode lib={lib} depth={0} />}
              </For>
            </Show>
          </Show>
        </div>
      </div>
      <div class="explore-right">
        <DetailPanel />
      </div>
    </div>
  );
}
