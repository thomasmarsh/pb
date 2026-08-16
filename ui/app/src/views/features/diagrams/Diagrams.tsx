// Diagrams.tsx — Diagrams view with tabs, controls, interactive SVG, and toolbar.

import { Show, For, createSignal, createEffect, onMount, onCleanup } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { ComboboxInput, SvgToolbar, DiagramTooltip, createPanZoom, parsePbUrl, getPbHref, HAS_FOCUS, AUTO_GENERATE, DIAGRAM_KINDS } from "@pb/platform";
import type { DiagramKind } from "@pb/platform";

// The Hasse diagram stacks one rank per concept, so it is far taller than it
// is wide -- fitted into the standard viewport it collapses to an unreadable
// ribbon. Everything else is roughly square once oversized graphs switch to a
// force-directed layout.
const TALL_KINDS = new Set<DiagramKind>(["window-table-lattice"]);

export function Diagrams(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const dg = () => snap().diagrams;
  const [activeTab, setActiveTab] = createSignal(snap().diagrams.active);
  const [focalInput, setFocalInput] = createSignal("");
  const [depthInput, setDepthInput] = createSignal("2");
  const [tableInput, setTableInput] = createSignal("");
  const [focusQuery, setFocusQuery] = createSignal("");
  const [focusHits, setFocusHits] = createSignal<number | null>(null);
  let svgWrapEl: HTMLDivElement | undefined;

  // Hover tooltip state
  const [tooltip, setTooltip] = createSignal<{ x: number; y: number; kind: "object" | "table"; name: string; meta: Record<string, string> } | null>(null);
  let hideTimer: ReturnType<typeof setTimeout> | null = null;

  const pan = createPanZoom({ dismissTooltip: () => setTooltip(null) });

  onCleanup(() => {
    if (hideTimer) clearTimeout(hideTimer);
    pan.cleanup();
    pan.removeViewportRef();
  });

  // A fresh render is a fresh graph: carrying the previous zoom over lands the
  // viewer somewhere arbitrary in a diagram they have not seen yet.
  createEffect((prev) => {
    const svg = dg().job.result;
    if (svg && svg !== prev) pan.actions.resetView();
    return svg;
  });

  function viewportCb(el: HTMLDivElement) {
    pan.setViewportRef(el);
  }

  onMount(() => {
    const route = snap().nav.route;
    const deepLinkKind = route.view === "diagrams" ? route.kind : undefined;
    store.dispatch({ tag: "nav", action: { tag: "navigate", route: deepLinkKind ? { view: "diagrams", kind: deepLinkKind } : { view: "diagrams" } } });
    if (deepLinkKind && deepLinkKind !== dg().active) {
      setActiveTab(deepLinkKind);
      store.dispatch({ tag: "diagrams", action: { tag: "select", kind: deepLinkKind } });
      if (AUTO_GENERATE.has(deepLinkKind)) store.dispatch({ tag: "diagrams", action: { tag: "generate" } });
    }
    if (!dg().itemsLoaded) {
      store.dispatch({ tag: "diagrams", action: { tag: "loadItems" } });
    }
  });

  function handleGenerate() {
    const kind = activeTab();
    if (kind === "calls") {
      store.dispatch({ tag: "diagrams", action: { tag: "params", params: { focal: focalInput(), depth: depthInput() } } });
    } else if (kind === "dw-tables") {
      store.dispatch({ tag: "diagrams", action: { tag: "params", params: { table: tableInput() } } });
    } else if (kind === "sql-lineage") {
      store.dispatch({ tag: "diagrams", action: { tag: "params", params: { focal: focalInput() } } });
    } else if (kind === "table-lineage") {
      store.dispatch({ tag: "diagrams", action: { tag: "params", params: { table: tableInput() } } });
    } else if (kind === "proc-tables") {
      store.dispatch({ tag: "diagrams", action: { tag: "params", params: { table: tableInput(), focal: focalInput() } } });
    }
    store.dispatch({ tag: "diagrams", action: { tag: "generate" } });
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
      if (kind === "object") {
        store.dispatch({ tag: "objects", action: { tag: "select", name } });
      } else {
        store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "tableDetail", name } } });
      }
    } else if (target === "focus") {
      if (kind === "object") {
        setFocalInput(name);
        store.dispatch({ tag: "diagrams", action: { tag: "params", params: { focal: name } } });
      } else {
        setTableInput(name);
        store.dispatch({ tag: "diagrams", action: { tag: "params", params: { table: name } } });
      }
      store.dispatch({ tag: "diagrams", action: { tag: "generate" } });
    }
  }

  function downloadSvg() {
    const svg = dg().job.result;
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
    const svg = dg().job.result;
    if (!svg) return;
    navigator.clipboard.writeText(svg);
  }

  // --- Focus search: dim everything not adjacent to the match ---------------
  //
  // Graphviz writes the graph's structure into the SVG it emits: every node is
  // a <g class="node"> whose <title> is the node name, and every edge a
  // <g class="edge"> whose <title> is "from->to". That is enough to rebuild
  // adjacency in the browser, with no extra request and no server support.
  //
  // At the sizes these diagrams reach, reading them is limited by everything
  // that is NOT relevant being drawn at full strength. Dimming is preferred to
  // filtering because the surrounding shape stays visible as context.

  const titleOf = (g: Element) => g.querySelector("title")?.textContent?.trim() ?? "";

  // Digraph edges render as "a->b", undirected as "a--b".
  const edgeEnds = (g: Element): [string, string] | null => {
    const parts = titleOf(g).split(/->|--/);
    const [from, to] = parts;
    if (parts.length !== 2 || from === undefined || to === undefined) return null;
    return [from.trim(), to.trim()];
  };

  function applyFocus(query: string) {
    const root = svgWrapEl;
    if (!root) return;
    const nodes = Array.from(root.querySelectorAll("g.node"));
    const edges = Array.from(root.querySelectorAll("g.edge"));
    const clear = () => {
      for (const g of [...nodes, ...edges]) g.classList.remove("diagram-dim", "diagram-hit");
    };

    const needle = query.trim().toLowerCase();
    if (!needle) { clear(); setFocusHits(null); return; }

    const matched = new Set<string>();
    for (const g of nodes) {
      const name = titleOf(g);
      if (name.toLowerCase().includes(needle)) matched.add(name);
    }
    setFocusHits(matched.size);
    if (!matched.size) { clear(); return; }

    // Keep the matches plus anything one hop away, so a match is shown with
    // the context that explains it rather than stranded on its own.
    const keep = new Set(matched);
    for (const g of edges) {
      const ends = edgeEnds(g);
      if (!ends) continue;
      const [a, b] = ends;
      if (matched.has(a)) keep.add(b);
      if (matched.has(b)) keep.add(a);
    }

    for (const g of nodes) {
      const name = titleOf(g);
      g.classList.toggle("diagram-dim", !keep.has(name));
      g.classList.toggle("diagram-hit", matched.has(name));
    }
    for (const g of edges) {
      const ends = edgeEnds(g);
      const live = !!ends && (matched.has(ends[0]) || matched.has(ends[1]));
      g.classList.toggle("diagram-dim", !live);
    }
  }

  // Re-apply whenever the query changes or a new diagram arrives. The SVG is
  // replaced wholesale by innerHTML, so the classes have to be re-stamped.
  createEffect(() => {
    const q = focusQuery();
    dg().job.result;
    queueMicrotask(() => applyFocus(q));
  });

  const needsGenerate = () => !AUTO_GENERATE.has(activeTab());

  return (
    <>
      <Tabs value={activeTab()} onChange={(v) => {
        setActiveTab(v as DiagramKind);
        store.dispatch({ tag: "diagrams", action: { tag: "select", kind: v as DiagramKind } });
        if (AUTO_GENERATE.has(v as DiagramKind)) store.dispatch({ tag: "diagrams", action: { tag: "generate" } });
      }}>
        <Tabs.List class="tab-bar">
          <For each={DIAGRAM_KINDS}>
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

      <Show when={dg().job.result}>
        <div class="card" style={{ padding: "10px 20px" }}>
          <div style={{ display: "flex", gap: "8px", "align-items": "center" }}>
            <input
              class="search-input"
              type="search"
              placeholder="Focus\u2026 dim everything not connected"
              value={focusQuery()}
              style={{ flex: "1", "max-width": "26rem" }}
              onInput={(e) => setFocusQuery(e.currentTarget.value)}
            />
            <Show when={focusHits() !== null}>
              <span style={{ color: "var(--text-secondary)", "font-size": ".85rem" }}>
                {focusHits() === 0 ? "no match" : `${focusHits()} match${focusHits() === 1 ? "" : "es"} + neighbours`}
              </span>
            </Show>
            <Show when={focusQuery()}>
              <button class="filter-pill" onClick={() => setFocusQuery("")}>clear</button>
            </Show>
          </div>
        </div>
      </Show>

      <div class="card">
        <Show when={dg().job.status === "pending"}>
          <div class="diagram-container">
            <div class="loading-overlay"><div class="spinner" /> Generating diagram...</div>
          </div>
        </Show>
        <Show when={dg().job.result}>
          <div class="diagram-container">
            <div
              ref={viewportCb}
              class={`diagram-viewport${TALL_KINDS.has(activeTab()) ? " tall" : ""}${pan.state.dragging() ? " grabbing" : ""}`}
              onMouseDown={pan.handlers.onMouseDown}
              onMouseMove={pan.handlers.onMouseMove}
              onMouseUp={pan.handlers.onMouseUp}
              onMouseLeave={pan.handlers.onMouseLeave}
            >
              <SvgToolbar
                onZoomIn={pan.actions.zoomIn}
                onZoomOut={pan.actions.zoomOut}
                onResetView={pan.actions.resetView}
                scale={pan.state.scale}
                onCopy={copySvg}
                onDownload={downloadSvg}
              />
              <div
                ref={(el) => { svgWrapEl = el; }}
                class="diagram-svg-wrap"
                style={{ transform: `translate(${pan.state.offset().x}px, ${pan.state.offset().y}px) scale(${pan.state.scale()})` }}
                innerHTML={dg().job.result!}
                onClick={handleSvgClick}
                onMouseOver={handleSvgMouseOver}
                onMouseOut={handleSvgMouseOut}
              />
            </div>
          </div>
        </Show>
        <Show when={dg().job.error}>
          <div class="diagram-container">
            <div class="loading-overlay" style={{ color: "var(--red)" }}>Error: {dg().job.error}</div>
          </div>
        </Show>
        <Show when={dg().job.status === "idle"}>
          <div class="diagram-container">
            <div class="loading-overlay">Select options and click Generate</div>
          </div>
        </Show>
      </div>

      <Show when={tooltip()}>
        <DiagramTooltip
          x={tooltip()!.x}
          y={tooltip()!.y}
          name={tooltip()!.name}
          kind={tooltip()!.meta["kind"]}
          meta={tooltip()!.meta}
          actions={[
            { label: "detail", onClick: () => navigateTo(tooltip()!.kind, tooltip()!.name, "detail") },
            ...(HAS_FOCUS.has(activeTab()) ? [{ label: "focus", onClick: () => navigateTo(tooltip()!.kind, tooltip()!.name, "focus") }] : []),
          ]}
          onMouseOver={handleTooltipMouseOver}
          onMouseOut={handleTooltipMouseOut}
        />
      </Show>
    </>
  );
}
