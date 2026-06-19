// features/analysis/CFGDiagram.tsx — CFG Analysis View: pan/zoom SVG, node interaction, colour patching.

import { Show, For, createResource, createSignal, onMount, onCleanup } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { createPanZoom } from "../../components/diagram/usePanZoom.js";
import { AnalysisView } from "./AnalysisView.js";

interface NodeState {
  blockId: string;
  state: string;
}

interface BlockDetail {
  blockId: string;
  firstLine: number | null;
  lastLine: number | null;
  stmts: string[];
}

interface CfgResponse {
  svg: string;
  nodeStates: NodeState[];
  blocks: BlockDetail[];
}

// Hex values matching CSS design tokens — SVG attributes cannot use CSS vars.
// default: no patching needed (Graphviz fills already neutral).
const CFG_STATE_FILL: Record<string, string | undefined> = {
  "unreachable":    "#facc15",   // --yellow
};
const CFG_STATE_FILL_OPACITY: Record<string, string | undefined> = {
  "unreachable": "0.4",
};
const CFG_STATE_STROKE: Record<string, string | undefined> = {
  "taint-entering": "#f59e0b",   // --phase-p3
  "proven-safe":    "#6366f1",   // --phase-p4
};
const CFG_STATE_STROKE_DASHARRAY: Record<string, string | undefined> = {
  "unreachable": "4 2",
};

function patchSvgNodeStates(container: Element, nodeStates: NodeState[]): void {
  for (const { blockId, state } of nodeStates) {
    if (state === "default") continue;
    const g = container.querySelector(`[id="${blockId}"]`);
    if (!g) continue;
    const shape = g.querySelector("polygon, ellipse, path");
    if (!shape) continue;
    const fill = CFG_STATE_FILL[state];
    if (fill) shape.setAttribute("fill", fill);
    const fillOp = CFG_STATE_FILL_OPACITY[state];
    if (fillOp) shape.setAttribute("fill-opacity", fillOp);
    const stroke = CFG_STATE_STROKE[state];
    if (stroke) {
      shape.setAttribute("stroke", stroke);
      shape.setAttribute("stroke-width", "2");
    }
    const dash = CFG_STATE_STROKE_DASHARRAY[state];
    if (dash) shape.setAttribute("stroke-dasharray", dash);
  }
}

// ── Selected-block detail panel ──────────────────────────────────────────────

function BlockPanel(props: {
  block: BlockDetail | null;
  onGoto: () => void;
}): JSX.Element {
  return (
    <div class="cfg-block-panel">
      <div class="cfg-block-panel-header">
        {props.block ? `Block ${props.block.blockId}` : "Selected block"}
      </div>
      <div class="cfg-block-panel-body">
        <Show
          when={props.block}
          fallback={<p class="cfg-block-empty">Click a node to inspect it.</p>}
        >
          {(b) => (
            <>
              <p class="cfg-block-meta">
                Lines {b().firstLine ?? "?"}&ndash;{b().lastLine ?? "?"}
              </p>
              <For each={b().stmts}>
                {(s) => <div class="cfg-block-stmt">{s}</div>}
              </For>
              <button class="cfg-block-goto" onClick={props.onGoto}>
                ↗ Open in source (line {b().firstLine ?? "?"})
              </button>
            </>
          )}
        </Show>
      </div>
    </div>
  );
}

// ── Main component ───────────────────────────────────────────────────────────

export function CFGDiagram(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();

  const object = (): string => {
    const r = snap().nav.route;
    return r.view === "cfgDiagram" ? r.object : "";
  };
  const proc = (): string => {
    const r = snap().nav.route;
    return r.view === "cfgDiagram" ? r.proc : "";
  };

  const [selectedBlock, setSelectedBlock] = createSignal<BlockDetail | null>(null);
  let viewportEl!: HTMLDivElement;
  let svgWrapEl!: HTMLDivElement;

  const pan = createPanZoom({ dismissTooltip: () => {} });

  onCleanup(() => {
    pan.cleanup();
    pan.removeViewportRef();
  });

  const key = () => `${object()}::${proc()}`;
  const [data] = createResource(key, async (): Promise<CfgResponse> => {
    const url = `/api/diagrams/cfg/${encodeURIComponent(object())}/${encodeURIComponent(proc())}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<CfgResponse>;
  });

  function gotoProc(): void {
    props.store.dispatch({
      tag: "nav",
      action: { tag: "navigate", route: { view: "procedureDetail", name: object(), proc: proc() } },
    });
  }

  function handleSvgClick(e: MouseEvent): void {
    if (pan.state.dragging() || pan.state.momentum()) return;
    const g = (e.target as Element).closest("g[id]") as SVGGElement | null;
    if (!g) { setSelectedBlock(null); return; }
    const d = data();
    if (!d) return;
    setSelectedBlock(d.blocks.find((b) => b.blockId === g.id) ?? null);
  }

  function handleSvgDblClick(e: MouseEvent): void {
    const g = (e.target as Element).closest("g[id]") as SVGGElement | null;
    if (!g) return;
    gotoProc();
  }

  function fitView(): void {
    if (!viewportEl || !svgWrapEl) return;
    const vw = viewportEl.clientWidth;
    const vh = viewportEl.clientHeight;
    const cw = svgWrapEl.scrollWidth;
    const ch = svgWrapEl.scrollHeight;
    if (cw <= 0 || ch <= 0) return;
    const scale = Math.min(vw / cw, vh / ch, 1) * 0.9;
    pan.actions.setView(scale, (vw - cw * scale) / 2, (vh - ch * scale) / 2);
  }

  // F/R keyboard — scoped to when this view is active.
  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      if (snap().nav.route.view !== "cfgDiagram") return;
      if (e.key === "f" || e.key === "F") { e.preventDefault(); fitView(); }
      if (e.key === "r" || e.key === "R") { e.preventDefault(); pan.actions.resetView(); }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  return (
    <AnalysisView
      title={`${object()}.${proc()}`}
      contextLabel="Control Flow Graph"
      assumptions="CFG is constructed from the parsed AST body. Loop back-edges and exception paths are approximated. Dynamic dispatch is not resolved."
    >
      <Show when={data.loading}>
        <div class="diagram-container">
          <div class="loading-overlay"><div class="spinner" /> Loading CFG…</div>
        </div>
      </Show>
      <Show when={data.error}>
        <div class="diagram-container">
          <div class="loading-overlay" style={{ color: "var(--red)" }}>
            CFG unavailable — procedure not found or has no body.
          </div>
        </div>
      </Show>
      <Show when={!data.loading && !data.error && data()}>
        {(d) => (
          <div class="cfg-split">
            <div class="cfg-diagram-pane">
              <div
                ref={(el) => { viewportEl = el; pan.setViewportRef(el); }}
                class={pan.state.dragging() ? "diagram-viewport grabbing" : "diagram-viewport"}
                onMouseDown={pan.handlers.onMouseDown}
                onMouseMove={pan.handlers.onMouseMove}
                onMouseUp={pan.handlers.onMouseUp}
                onMouseLeave={pan.handlers.onMouseLeave}
              >
                <div class="diagram-toolbar">
                  <button class="icon-btn" onClick={pan.actions.zoomOut} title="Zoom out">
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                      <path d="M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                    </svg>
                  </button>
                  <span class="diagram-zoom-label">{Math.round(pan.state.scale() * 100)}%</span>
                  <button class="icon-btn" onClick={pan.actions.zoomIn} title="Zoom in">
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                      <path d="M8 4v8M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                    </svg>
                  </button>
                  <button class="icon-btn reset-btn" onClick={fitView} title="Fit to viewport (F)">Fit</button>
                  <button class="icon-btn reset-btn" onClick={pan.actions.resetView} title="Reset zoom (R)">1:1</button>
                </div>
                <div
                  ref={(el) => {
                    svgWrapEl = el;
                    // Patch SVG colours after innerHTML is set by SolidJS.
                    requestAnimationFrame(() => patchSvgNodeStates(el, d().nodeStates));
                  }}
                  class="diagram-svg-wrap"
                  style={{ transform: `translate(${pan.state.offset().x}px, ${pan.state.offset().y}px) scale(${pan.state.scale()})` }}
                  innerHTML={d().svg}
                  onClick={handleSvgClick}
                  onDblClick={handleSvgDblClick}
                />
              </div>
            </div>
            <BlockPanel
              block={selectedBlock()}
              onGoto={gotoProc}
            />
          </div>
        )}
      </Show>
    </AnalysisView>
  );
}
