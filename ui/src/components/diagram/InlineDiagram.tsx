// components/InlineDiagram.tsx — Self-fetching inline SVG diagram with zoom/pan.

import { Show, createEffect, createSignal, onCleanup } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { type DiagramKind, parsePbUrl, getPbHref } from "@pb/platform";
import { stripSvgTitles, computeTooltipPosition } from "./diagramMath.js";
import { createPanZoom } from "./usePanZoom.js";
import { DiagramTooltip } from "./DiagramTooltip.js";

// Re-export pure functions for tests
export { computeZoom, smoothVelocity, stripSvgTitles, computeTooltipPosition, releaseVelocity, runMomentum, ZOOM_MIN, ZOOM_MAX } from "./diagramMath.js";

interface InlineDiagramProps {
  kind: DiagramKind;
  params?: Record<string, string | number>;
  store: Store<AppState, AppAction>;
  compact?: boolean;
}

function inlineDiagramKey(kind: DiagramKind, params?: Record<string, string | number>): string {
  return JSON.stringify({ kind, params });
}

export function InlineDiagram(props: InlineDiagramProps) {
  const [tooltip, setTooltip] = createSignal<{ x: number; y: number; kind: "object" | "table"; name: string; meta: Record<string, string> } | null>(null);
  let hideTimer: ReturnType<typeof setTimeout> | null = null;
  let viewportRef!: HTMLDivElement;

  const pan = createPanZoom({ dismissTooltip: () => setTooltip(null) });

  const [copied, setCopied] = createSignal(false);

  onCleanup(() => {
    if (hideTimer) clearTimeout(hideTimer);
    pan.cleanup();
    pan.removeViewportRef();
  });

  function navigateTo(kind: "object" | "table", name: string) {
    const tag = kind === "object" ? "objects" : "datawindows";
    props.store.dispatch({ tag, action: { tag: "select", name } });
  }

  const key = () => inlineDiagramKey(props.kind, props.params);

  createEffect(() => {
    const k = key();
    props.store.dispatch({
      tag: "inlineDiagram",
      action: { tag: "request", key: k, kind: props.kind, params: props.params ?? {} },
    });
  });

  const snap = props.store.getState();
  const entry = () => snap().inlineDiagrams[key()];
  const loading = () => entry()?.loading ?? false;
  const error = () => entry()?.error ?? null;
  const svg = () => {
    const raw = entry()?.svg;
    return raw ? stripSvgTitles(raw) : null;
  };

  function copySvg() {
    const s = svg();
    if (!s) return;
    navigator.clipboard.writeText(s).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }

  function downloadSvg() {
    const s = svg();
    if (!s) return;
    const blob = new Blob([s], { type: "image/svg+xml" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${props.kind}.svg`;
    a.click();
    URL.revokeObjectURL(url);
  }

  function handleClick(e: MouseEvent) {
    const anchor = (e.target as HTMLElement).closest("a");
    if (!anchor) return;
    const parsed = parsePbUrl(getPbHref(anchor));
    if (!parsed) return;
    e.preventDefault();
    e.stopPropagation();
    navigateTo(parsed.kind, parsed.name);
  }

  function handleSvgMouseOver(e: MouseEvent) {
    if (pan.state.dragging() || pan.state.momentum()) return;
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    const anchor = (e.target as HTMLElement).closest("a");
    if (!anchor) return;
    const href = getPbHref(anchor);
    const parsed = parsePbUrl(href);
    if (!parsed) { setTooltip(null); return; }
    const containerRect = viewportRef!.closest(".diagram-container")!.getBoundingClientRect();
    const rect = anchor.getBoundingClientRect();
    const pos = computeTooltipPosition(rect, containerRect);
    setTooltip({ ...pos, kind: parsed.kind, name: parsed.name, meta: parsed.meta });
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

  function viewportCb(el: HTMLDivElement) {
    viewportRef = el;
    pan.setViewportRef(el);
  }

  return (
    <div class={props.compact ? "diagram-container compact" : "diagram-container"}>
      <Show when={loading()}>
        <div class="loading-overlay">
          <div class="spinner" /> Loading diagram…
        </div>
      </Show>
      <Show when={error()}>
        <div class="loading-overlay" style={{ color: "var(--red)" }}>
          Diagram unavailable
        </div>
      </Show>
      <Show when={!loading() && !error() && svg()}>
        <div
          ref={viewportCb}
          class={pan.state.dragging() ? "diagram-viewport grabbing" : "diagram-viewport"}
          onMouseDown={pan.handlers.onMouseDown}
          onMouseMove={pan.handlers.onMouseMove}
          onMouseUp={pan.handlers.onMouseUp}
          onMouseLeave={pan.handlers.onMouseLeave}
        >
          <div class="diagram-toolbar">
            <button class="icon-btn" onClick={pan.actions.zoomOut} title="Zoom out">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
            </button>
            <span class="diagram-zoom-label">{Math.round(pan.state.scale() * 100)}%</span>
            <button class="icon-btn" onClick={pan.actions.zoomIn} title="Zoom in">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M8 4v8M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
            </button>
            <button class="icon-btn reset-btn" onClick={pan.actions.resetView} title="Reset zoom">1:1</button>
            <span class="diagram-toolbar-sep" />
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
            class="diagram-svg-wrap"
            style={{ transform: `translate(${pan.state.offset().x}px, ${pan.state.offset().y}px) scale(${pan.state.scale()})` }}
            innerHTML={svg()!}
            onClick={handleClick}
            onMouseOver={handleSvgMouseOver}
            onMouseOut={handleSvgMouseOut}
          />
        </div>
      </Show>
      <Show when={tooltip()}>
        <DiagramTooltip
          x={tooltip()!.x}
          y={tooltip()!.y}
          name={tooltip()!.name}
          kind={tooltip()!.meta["kind"]}
          meta={tooltip()!.meta}
          actions={[{
            label: "detail",
            onClick: () => {
              const t = tooltip()!;
              setTooltip(null);
              navigateTo(t.kind, t.name);
            },
          }]}
          onMouseOver={handleTooltipMouseOver}
          onMouseOut={handleTooltipMouseOut}
        />
      </Show>
    </div>
  );
}
