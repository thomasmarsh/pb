// Diagrams.tsx — Diagrams view with tabs, controls, interactive SVG, and toolbar.

import { Show, For, createSignal, onMount, onCleanup } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { ComboboxInput } from "../../components/ComboboxInput.js";
import { parsePbUrl, getPbHref, HAS_FOCUS, AUTO_GENERATE, type DiagramKind } from "../../utils/diagram.js";

export function Diagrams(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const dg = () => snap().diagrams;
  const [activeTab, setActiveTab] = createSignal(snap().diagrams.active);
  const [focalInput, setFocalInput] = createSignal("");
  const [depthInput, setDepthInput] = createSignal("2");
  const [tableInput, setTableInput] = createSignal("");
  const [copied, setCopied] = createSignal(false);

  // Hover tooltip state
  const [tooltip, setTooltip] = createSignal<{ x: number; y: number; kind: "object" | "table"; name: string; meta: Record<string, string> } | null>(null);
  let hideTimer: ReturnType<typeof setTimeout> | null = null;

  onCleanup(() => { if (hideTimer) clearTimeout(hideTimer); });

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", route: { view: "diagrams" } } });
    if (!dg().itemsLoaded) {
      store.dispatch({ tag: "diagrams", action: { type: "loadItems" } } as any);
    }
  });

  function handleGenerate() {
    const kind = activeTab();
    if (kind === "calls") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { focal: focalInput(), depth: depthInput() } } });
    } else if (kind === "dw-tables") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { table: tableInput() } } });
    } else if (kind === "sql-lineage") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { focal: focalInput() } } });
    } else if (kind === "table-lineage") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { table: tableInput() } } });
    } else if (kind === "proc-tables") {
      store.dispatch({ tag: "diagrams", action: { type: "params", params: { table: tableInput(), focal: focalInput() } } });
    }
    store.dispatch({ tag: "diagrams", action: { type: "generate" } });
  }

  // Click handler: intercept pb:// links and navigate
  function handleSvgClick(e: MouseEvent) {
    const anchor = (e.target as HTMLElement).closest("a");
    if (!anchor) return;
    const href = getPbHref(anchor);
    const parsed = parsePbUrl(href);
    if (!parsed) return;
    e.preventDefault();
    e.stopPropagation();
    navigateTo(parsed.kind, parsed.name, "detail");
  }

  // Hover handler: show tooltip with Detail | Focus | Explore links
  function handleSvgMouseOver(e: MouseEvent) {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    const anchor = (e.target as HTMLElement).closest("a");
    if (!anchor) return;
    const href = getPbHref(anchor);
    const parsed = parsePbUrl(href);
    if (!parsed) { setTooltip(null); return; }
    const rect = anchor.getBoundingClientRect();
    setTooltip({ x: rect.left + rect.width / 2, y: rect.top - 8, kind: parsed.kind, name: parsed.name, meta: parsed.meta });
  }

  function handleSvgMouseOut(e: MouseEvent) {
    const related = e.relatedTarget as HTMLElement | null;
    if (related && (related.closest("a") || related.closest(".diagram-tooltip"))) return;
    hideTimer = setTimeout(() => setTooltip(null), 150);
  }

  function handleTooltipMouseOver() {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
  }

  function handleTooltipMouseOut(e: MouseEvent) {
    const related = e.relatedTarget as HTMLElement | null;
    if (related && related.closest("a")) return;
    hideTimer = setTimeout(() => setTooltip(null), 150);
  }

  function navigateTo(kind: "object" | "table", name: string, target: "detail" | "focus") {
    setTooltip(null);
    if (target === "detail") {
      const view = kind === "object" ? "objectDetail" : "tableDetail";
      store.dispatch({ tag: "nav", action: { type: "navigate", route: { view, name } } });
    } else if (target === "focus") {
      if (kind === "object") {
        setFocalInput(name);
        store.dispatch({ tag: "diagrams", action: { type: "params", params: { focal: name } } });
      } else {
        setTableInput(name);
        store.dispatch({ tag: "diagrams", action: { type: "params", params: { table: name } } });
      }
      store.dispatch({ tag: "diagrams", action: { type: "generate" } });
    }
  }

  function downloadSvg() {
    const svg = dg().svg;
    if (!svg) return;
    const blob = new Blob([svg], { type: "image/svg+xml" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${activeTab()}.svg`;
    a.click();
    URL.revokeObjectURL(url);
  }

  function copySvg() {
    const svg = dg().svg;
    if (!svg) return;
    navigator.clipboard.writeText(svg).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }

  const needsGenerate = () => !AUTO_GENERATE.has(activeTab());

  return (
    <>
      <Tabs value={activeTab()} onChange={(v) => {
        setActiveTab(v as DiagramKind);
        store.dispatch({ tag: "diagrams", action: { type: "select", kind: v as DiagramKind } });
        if (AUTO_GENERATE.has(v as DiagramKind)) store.dispatch({ tag: "diagrams", action: { type: "generate" } });
      }}>
        <Tabs.List class="tab-bar">
          <For each={["inheritance", "calls", "dw-tables", "heatmap", "sql-lineage", "table-lineage", "proc-tables"] as DiagramKind[]}>
            {(kind) => <Tabs.Trigger value={kind} class="tab-btn">{kind}</Tabs.Trigger>}
          </For>
        </Tabs.List>
      </Tabs>

      <Show when={needsGenerate()}>
        <div class="card" style={{ padding: "12px 20px" }}>
          <div style={{ display: "flex", gap: "8px", "align-items": "center" }}>
            <Show when={activeTab() === "calls"}>
              <ComboboxInput value={focalInput()} onChange={setFocalInput} options={dg().objectNames} placeholder="Focal object" onEnter={handleGenerate} />
              <input class="search-input" type="number" value={depthInput()} min="1" max="5"
                     style={{ "max-width": "80px" }}
                     onInput={(e) => setDepthInput(e.currentTarget.value)}
                     onKeyDown={(e) => { if (e.key === "Enter") handleGenerate(); }} />
            </Show>
            <Show when={activeTab() === "dw-tables"}>
              <ComboboxInput value={tableInput()} onChange={setTableInput} options={dg().tableNames} placeholder="Filter table (optional)" onEnter={handleGenerate} />
            </Show>
            <Show when={activeTab() === "table-lineage"}>
              <ComboboxInput value={tableInput()} onChange={setTableInput} options={dg().tableNames} placeholder="Table name (required)" onEnter={handleGenerate} />
            </Show>
            <Show when={activeTab() === "proc-tables"}>
              <ComboboxInput value={tableInput()} onChange={setTableInput} options={dg().tableNames} placeholder="Table name (optional)" onEnter={handleGenerate} />
              <ComboboxInput value={focalInput()} onChange={setFocalInput} options={dg().objectNames} placeholder="Focal object (optional)" onEnter={handleGenerate} />
            </Show>
            <button class="filter-pill active" onClick={handleGenerate}>Generate</button>
          </div>
        </div>
      </Show>

      <div class="card">
        <Show when={dg().loading}>
          <div class="diagram-container">
            <div class="loading-overlay"><div class="spinner" /> Generating diagram...</div>
          </div>
        </Show>
        <Show when={dg().svg}>
          <div class="diagram-toolbar">
            <button class="icon-btn" onClick={copySvg} title="Copy SVG">
              {copied() ? (
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8.5l3 3 7-7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
              ) : (
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><rect x="5" y="5" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.2"/><path d="M3 11V3.5A.5.5 0 013.5 3H11" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>
              )}
            </button>
            <button class="icon-btn" onClick={downloadSvg} title="Download SVG">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M8 2v8m0 0l-3-3m3 3l3-3M3 12.5h10" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></svg>
            </button>
          </div>
          <div
            class="diagram-container"
            innerHTML={dg().svg!}
            onClick={handleSvgClick}
            onMouseOver={handleSvgMouseOver}
            onMouseOut={handleSvgMouseOut}
          />
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

      {/* Hover tooltip */}
      <Show when={tooltip()}>
        <div
          class="diagram-tooltip"
          style={{
            left: `${tooltip()!.x}px`,
            top: `${tooltip()!.y}px`,
          }}
          onMouseOver={handleTooltipMouseOver}
          onMouseOut={handleTooltipMouseOut}
        >
          <div class="diagram-tooltip-header">
            <span class="diagram-tooltip-name">{tooltip()!.name}</span>
            <Show when={tooltip()!.meta["kind"]}>
              <span class="diagram-tooltip-badge">{tooltip()!.meta["kind"]}</span>
            </Show>
          </div>
          <Show when={Object.keys(tooltip()!.meta).length > 0 && !tooltip()!.meta["kind"]}>
            <div class="diagram-tooltip-meta">
              {Object.entries(tooltip()!.meta).map(([k, v]) => `${k}=${v}`).join(" · ")}
            </div>
          </Show>
          <div class="diagram-tooltip-actions">
            <a class="diagram-tooltip-link" onClick={() => navigateTo(tooltip()!.kind, tooltip()!.name, "detail")}>detail</a>
            <Show when={HAS_FOCUS.has(activeTab())}>
              <span class="diagram-tooltip-sep">&middot;</span>
              <a class="diagram-tooltip-link" onClick={() => navigateTo(tooltip()!.kind, tooltip()!.name, "focus")}>focus</a>
            </Show>
          </div>
        </div>
      </Show>
    </>
  );
}
