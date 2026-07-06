// features/analysis/WiringCore.tsx — Embeddable wiring-diagram rendering core (Plan 149 Phase 3).
//
// Experimental: renders the term the categorical (CatOp/LowCat) compiler
// produces, which Plan 146 is still verifying against the old compiler via
// --dual-trace. A mislowered term shows up here as a wrong-looking diagram —
// that is signal for 146, not a bug in this renderer.
//
// Data flows through the objects feature's env/reducer (CLAUDE.md Rule 1/2)
// — no fetch here, unlike CFGCore.tsx, which predates the AppEnv
// architecture and must not be copied.

import { Show, For, createMemo, createEffect, onMount, onCleanup, createSignal } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import { createPanZoom } from "@pb/platform";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { layoutWiring, type LayoutBox, type WiringLayout } from "./wiring-layout.js";

export interface WiringCoreProps {
  store: Store<AppState, AppAction>;
  object: string;
  proc: string;
}

const PANEL_MIN = 180;
const PANEL_MAX = 600;
const PANEL_DEFAULT = 280;

export function WiringCore(props: WiringCoreProps): JSX.Element {
  const snap = props.store.getState();
  const [focusedBox, setFocusedBox] = createSignal<LayoutBox | null>(null);
  const [panelWidth, setPanelWidth] = createSignal(PANEL_DEFAULT);

  let viewportEl!: HTMLDivElement;

  const pan = createPanZoom({ dismissTooltip: () => setFocusedBox(null) });
  onCleanup(() => {
    pan.cleanup();
    pan.removeViewportRef();
  });

  onMount(() => {
    props.store.dispatch({
      tag: "objects",
      action: { tag: "wiring-load", objectName: props.object, procName: props.proc },
    });
  });

  const entry = createMemo(() => snap().objects.wiringDiagram);
  const loading = createMemo(() => snap().objects.wiringDiagramLoading);

  const layout = createMemo((): WiringLayout | null => {
    const e = entry();
    if (!e || "error" in e) return null;
    if (e.object !== props.object || e.proc !== props.proc) return null;
    return layoutWiring({ term: e.term, sharedBlocks: e.sharedBlocks });
  });

  function fitView(): void {
    const l = layout();
    if (!viewportEl || !l || l.width <= 0 || l.height <= 0) return;
    const vw = viewportEl.clientWidth;
    const vh = viewportEl.clientHeight;
    // The panel can still be mid-layout (e.g. a ContextualPanel open
    // transition) when this first fires — a 0-size viewport would compute
    // scale=0 and permanently "fit" the diagram to nothing. Skip and let the
    // ResizeObserver below retry once real dimensions exist.
    if (vw <= 0 || vh <= 0) return;
    const scale = Math.min(vw / l.width, vh / l.height, 1) * 0.9;
    pan.actions.setView(scale, (vw - l.width * scale) / 2, (vh - l.height * scale) / 2);
  }

  createEffect(() => {
    if (layout()) requestAnimationFrame(fitView);
  });

  let resizeObserver: ResizeObserver | undefined;
  function observeViewport(el: HTMLDivElement): void {
    viewportEl = el;
    pan.setViewportRef(el);
    resizeObserver = new ResizeObserver(() => fitView());
    resizeObserver.observe(el);
  }
  onCleanup(() => resizeObserver?.disconnect());

  function startResize(e: MouseEvent): void {
    e.preventDefault();
    const startX = e.clientX;
    const startW = panelWidth();
    function onMove(ev: MouseEvent): void {
      setPanelWidth(Math.max(PANEL_MIN, Math.min(PANEL_MAX, startW - (ev.clientX - startX))));
    }
    function onUp(): void {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    }
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  }

  return (
    <>
      <Show when={loading() && !layout()}>
        <div class="diagram-container">
          <div class="loading-overlay"><div class="spinner" /> Loading wiring diagram…</div>
        </div>
      </Show>
      <Show when={!loading() && entry() && "error" in entry()!}>
        <div class="diagram-container">
          <div class="loading-overlay" style={{ color: "var(--red)" }}>
            Wiring diagram unavailable — procedure not found or has no compiled term.
          </div>
        </div>
      </Show>
      <Show when={!loading() && layout()}>
        {(l) => (
          <div class="cfg-split">
            <div class="cfg-diagram-pane">
              <div class="wiring-badge">Experimental — CatOp lowering under verification (Plan 146)</div>
              <div
                ref={observeViewport}
                class={pan.state.dragging() ? "diagram-viewport grabbing" : "diagram-viewport"}
                onMouseDown={pan.handlers.onMouseDown}
                onMouseMove={pan.handlers.onMouseMove}
                onMouseUp={pan.handlers.onMouseUp}
                onMouseLeave={pan.handlers.onMouseLeave}
              >
                <div class="diagram-toolbar">
                  <button class="icon-btn" onClick={pan.actions.zoomOut} title="Zoom out">
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                      <path d="M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
                    </svg>
                  </button>
                  <span class="diagram-zoom-label">{Math.round(pan.state.scale() * 100)}%</span>
                  <button class="icon-btn" onClick={pan.actions.zoomIn} title="Zoom in">
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                      <path d="M8 4v8M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
                    </svg>
                  </button>
                  <button class="icon-btn reset-btn" onClick={fitView} title="Fit to viewport">Fit</button>
                  <button class="icon-btn reset-btn" onClick={pan.actions.resetView} title="Reset zoom">1:1</button>
                </div>
                <div
                  class="wiring-svg-wrap"
                  style={{ transform: `translate(${pan.state.offset().x}px, ${pan.state.offset().y}px) scale(${pan.state.scale()})` }}
                >
                  <svg width={l().width} height={l().height} viewBox={`0 0 ${l().width} ${l().height}`}>
                    <For each={l().regions}>
                      {(r) => (
                        <g class={`wiring-region wiring-region-${r.kind}`}>
                          <rect x={r.x} y={r.y} width={r.width} height={r.height} rx={8} />
                          <text x={r.x + 6} y={r.y + 14}>{r.label}</text>
                        </g>
                      )}
                    </For>
                    <For each={l().wires}>
                      {(w) => (
                        <polyline class="wiring-wire" points={w.points.map((p) => `${p.x},${p.y}`).join(" ")} />
                      )}
                    </For>
                    <For each={l().boxes}>
                      {(b) => (
                        <g
                          class={`wiring-box wiring-box-${b.kind}${focusedBox()?.id === b.id ? " wiring-box-focused" : ""}`}
                          onMouseEnter={() => setFocusedBox(b)}
                          onClick={() => setFocusedBox(b)}
                        >
                          <rect x={b.x} y={b.y} width={b.width} height={b.height} rx={4} />
                          <text x={b.x + b.width / 2} y={b.y + b.height / 2 + 4} text-anchor="middle">{b.label}</text>
                        </g>
                      )}
                    </For>
                  </svg>
                </div>
              </div>
            </div>
            <div class="cfg-resize-handle" onMouseDown={startResize} />
            <div style={{ width: `${panelWidth()}px`, "flex-shrink": "0", display: "flex", "flex-direction": "column", "min-height": "0" }}>
              <div class="cfg-block-panel">
                <div class="cfg-block-panel-header">
                  {focusedBox() ? focusedBox()!.kind : "Hover a box"}
                </div>
                <div class="cfg-block-panel-body">
                  <Show when={focusedBox()} fallback={<p class="cfg-block-empty">Hover or click a box to inspect it.</p>}>
                    {(b) => <div class="cfg-block-stmt">{b().label}</div>}
                  </Show>
                </div>
              </div>
            </div>
          </div>
        )}
      </Show>
    </>
  );
}
