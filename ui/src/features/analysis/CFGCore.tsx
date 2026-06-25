// features/analysis/CFGCore.tsx — Embeddable CFG rendering core (no AnalysisView wrapper).

import { Show, For, createResource, createSignal, createMemo, onMount, onCleanup } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";
import { createPanZoom } from "../../components/diagram/usePanZoom.js";
import { highlightPowerScript } from "@pb/platform";

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
  sourceOriginal: string | null;
  procStartLine: number | null;
}

interface Tooltip {
  html: string;
  x: number;
  y: number;
}

export interface CFGCoreProps {
  object: string;
  proc: string;
  store: Store<AppState, AppAction>;
  onGoto: () => void;
  gotoLabel?: string;
}

// Hex values matching CSS design tokens — SVG attributes cannot use CSS vars.
const CFG_STATE_FILL: Record<string, string | undefined> = {
  "unreachable": "#facc15",
};
const CFG_STATE_FILL_OPACITY: Record<string, string | undefined> = {
  "unreachable": "0.4",
};
const CFG_STATE_STROKE: Record<string, string | undefined> = {
  "taint-entering": "#f59e0b",
  "proven-safe":    "#6366f1",
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

// ── Source excerpt ───────────────────────────────────────────────────────────

const CONTEXT_LINES = 3;

function CfgSourceExcerpt(props: {
  block: BlockDetail | null;
  sourceLines: string[];
  procStartLine: number;
}): JSX.Element {
  const window = createMemo(() => {
    const b = props.block;
    const lines = props.sourceLines;
    if (!b || !b.firstLine || !b.lastLine || lines.length === 0) return null;

    const rel0 = b.firstLine - props.procStartLine;
    const rel1 = b.lastLine  - props.procStartLine;
    if (rel0 < 0 || rel0 >= lines.length) return null;

    const winStart = Math.max(0, rel0 - CONTEXT_LINES);
    const winEnd   = Math.min(lines.length - 1, rel1 + CONTEXT_LINES);
    const slice    = lines.slice(winStart, winEnd + 1);
    const highlighted = highlightPowerScript(slice.join("\n")).split("\n");

    return { lines: highlighted, winStart, highlightRel0: rel0, highlightRel1: rel1 };
  });

  return (
    <Show when={window()}>
      {(w) => (
        <div class="cfg-source-excerpt">
          <div class="cfg-excerpt-gutter">
            <For each={w().lines}>
              {(_, i) => {
                const absLine = props.procStartLine + w().winStart + i();
                return <div class="cfg-excerpt-gutter-line">{absLine}</div>;
              }}
            </For>
          </div>
          <div class="cfg-excerpt-code">
            <pre>
              <For each={w().lines}>
                {(html, i) => {
                  const relIdx = w().winStart + i();
                  const hi = relIdx >= w().highlightRel0 && relIdx <= w().highlightRel1;
                  return (
                    <div
                      class={hi ? "cfg-excerpt-line cfg-excerpt-highlight" : "cfg-excerpt-line cfg-excerpt-context"}
                      innerHTML={html}
                    />
                  );
                }}
              </For>
            </pre>
          </div>
        </div>
      )}
    </Show>
  );
}

// ── Block panel ──────────────────────────────────────────────────────────────

function BlockPanel(props: {
  block: BlockDetail | null;
  sourceLines: string[];
  procStartLine: number;
  onGoto: () => void;
  gotoLabel: string;
}): JSX.Element {
  return (
    <div class="cfg-block-panel">
      <div class="cfg-block-panel-header">
        {props.block ? `Block ${props.block.blockId}` : "Hover a node"}
      </div>
      <div class="cfg-block-panel-body">
        <Show
          when={props.block}
          fallback={<p class="cfg-block-empty">Hover or click a node to inspect it.</p>}
        >
          {(b) => (
            <>
              <p class="cfg-block-meta">
                Lines {b().firstLine ?? "?"}&ndash;{b().lastLine ?? "?"}
              </p>
              <For each={b().stmts}>
                {(s) => <div class="cfg-block-stmt">{s}</div>}
              </For>
              <CfgSourceExcerpt
                block={b()}
                sourceLines={props.sourceLines}
                procStartLine={props.procStartLine}
              />
              <button class="cfg-block-goto" onClick={props.onGoto}>
                ↗ {props.gotoLabel}
              </button>
            </>
          )}
        </Show>
      </div>
    </div>
  );
}

// ── Core ─────────────────────────────────────────────────────────────────────

const PANEL_MIN = 180;
const PANEL_MAX = 600;
const PANEL_DEFAULT = 300;

export function CFGCore(props: CFGCoreProps): JSX.Element {
  const [focusedBlock, setFocusedBlock] = createSignal<BlockDetail | null>(null);
  const [svgTooltip, setSvgTooltip] = createSignal<Tooltip | null>(null);
  const [panelWidth, setPanelWidth] = createSignal(PANEL_DEFAULT);

  let viewportEl!: HTMLDivElement;
  let svgWrapEl!: HTMLDivElement;

  const pan = createPanZoom({ dismissTooltip: () => {} });

  onCleanup(() => {
    pan.cleanup();
    pan.removeViewportRef();
  });

  const key = () => `${props.object}::${props.proc}`;
  const [data] = createResource(key, async (): Promise<CfgResponse> => {
    setFocusedBlock(null);
    const url = `/api/diagrams/cfg/${encodeURIComponent(props.object)}/${encodeURIComponent(props.proc)}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<CfgResponse>;
  });

  const sourceLines = createMemo((): string[] => {
    const d = data();
    if (!d?.sourceOriginal) return [];
    return d.sourceOriginal.split("\n");
  });

  const procStartLine = createMemo((): number => data()?.procStartLine ?? 1);

  function blockById(id: string): BlockDetail | null {
    return data()?.blocks.find((b) => b.blockId === id) ?? null;
  }

  function handleSvgClick(e: MouseEvent): void {
    if (pan.state.dragging() || pan.state.momentum()) return;
    const g = (e.target as Element).closest("g[id]") as SVGGElement | null;
    if (!g) { setFocusedBlock(null); return; }
    setFocusedBlock(blockById(g.id));
  }

  function handleSvgDblClick(e: MouseEvent): void {
    const g = (e.target as Element).closest("g[id]") as SVGGElement | null;
    if (!g) return;
    props.onGoto();
  }

  function handleSvgMouseMove(e: MouseEvent): void {
    if (pan.state.dragging() || pan.state.momentum()) {
      setSvgTooltip(null);
      return;
    }
    const g = (e.target as Element).closest("g[id]") as SVGGElement | null;
    if (!g) { setSvgTooltip(null); return; }
    const block = blockById(g.id);
    if (block) setFocusedBlock(block);
    if (block) {
      const stmtHtml = block.stmts
        .map((s) => `<div class="tt-meta">${s}</div>`)
        .join("") || `<div class="tt-meta">(empty block)</div>`;
      setSvgTooltip({
        html: `<div class="tt-name">Block ${block.blockId}</div>` +
              `<div class="tt-meta" style="margin-bottom:4px">L${block.firstLine ?? "?"}–L${block.lastLine ?? "?"}</div>` +
              stmtHtml,
        x: e.clientX + 14,
        y: e.clientY + 14,
      });
    } else {
      setSvgTooltip(null);
    }
  }

  function handleSvgMouseLeave(): void {
    setSvgTooltip(null);
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

  function startResize(e: MouseEvent): void {
    e.preventDefault();
    const startX = e.clientX;
    const startW = panelWidth();
    function onMove(ev: MouseEvent): void {
      const w = Math.max(PANEL_MIN, Math.min(PANEL_MAX, startW - (ev.clientX - startX)));
      setPanelWidth(w);
    }
    function onUp(): void {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    }
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  }

  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      if (e.key === "f" || e.key === "F") { e.preventDefault(); fitView(); }
      if (e.key === "r" || e.key === "R") { e.preventDefault(); pan.actions.resetView(); }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  return (
    <>
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
                    requestAnimationFrame(() => {
                      patchSvgNodeStates(el, d().nodeStates);
                      fitView();
                    });
                  }}
                  class="diagram-svg-wrap"
                  style={{ transform: `translate(${pan.state.offset().x}px, ${pan.state.offset().y}px) scale(${pan.state.scale()})` }}
                  innerHTML={d().svg}
                  onClick={handleSvgClick}
                  onDblClick={handleSvgDblClick}
                  onMouseMove={handleSvgMouseMove}
                  onMouseLeave={handleSvgMouseLeave}
                />
              </div>
            </div>
            <div class="cfg-resize-handle" onMouseDown={startResize} />
            <div style={{ width: `${panelWidth()}px`, "flex-shrink": "0", display: "flex", "flex-direction": "column", "min-height": "0" }}>
              <BlockPanel
                block={focusedBlock()}
                sourceLines={sourceLines()}
                procStartLine={procStartLine()}
                onGoto={props.onGoto}
                gotoLabel={props.gotoLabel ?? "View full procedure"}
              />
            </div>
            <Show when={svgTooltip()}>
              <div
                class="source-proc-tooltip visible"
                style={{
                  left: `${Math.min(svgTooltip()!.x, window.innerWidth - 300)}px`,
                  top:  `${Math.min(svgTooltip()!.y, window.innerHeight - 160)}px`,
                }}
                innerHTML={svgTooltip()!.html}
              />
            </Show>
          </div>
        )}
      </Show>
    </>
  );
}
