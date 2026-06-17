// components/InlineDiagram.tsx — Self-fetching inline SVG diagram.

import { Show, createResource, createSignal, onCleanup } from "solid-js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";
import { type DiagramKind, diagramUrl, parsePbUrl, getPbHref } from "../utils/diagram.js";

interface InlineDiagramProps {
  kind: DiagramKind;
  params?: Record<string, string | number>;
  store: Store<AppState, AppAction>;
  compact?: boolean;
}

export function InlineDiagram(props: InlineDiagramProps) {
  const [tooltip, setTooltip] = createSignal<{ x: number; y: number; kind: "object" | "table"; name: string; meta: Record<string, string> } | null>(null);
  let hideTimer: ReturnType<typeof setTimeout> | null = null;

  onCleanup(() => { if (hideTimer) clearTimeout(hideTimer); });

  function navigateTo(kind: "object" | "table", name: string) {
    const tag = kind === "object" ? "objects" : "datawindows";
    props.store.dispatch({ tag, action: { type: "select", name } });
  }

  const key = () => JSON.stringify({ kind: props.kind, params: props.params });
  const [svg] = createResource(key, async () => {
    const url = diagramUrl(props.kind, props.params);
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.text();
  });

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

  return (
    <div class={props.compact ? "diagram-container compact" : "diagram-container"}>
      <Show when={svg.loading}>
        <div class="loading-overlay">
          <div class="spinner" /> Loading diagram…
        </div>
      </Show>
      <Show when={svg.error}>
        <div class="loading-overlay" style={{ color: "var(--red)" }}>
          Diagram unavailable
        </div>
      </Show>
      <Show when={!svg.loading && !svg.error && svg()}>
        <div
          innerHTML={svg()!}
          onClick={handleClick}
          onMouseOver={handleSvgMouseOver}
          onMouseOut={handleSvgMouseOut}
        />
      </Show>
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
            <a class="diagram-tooltip-link" onClick={() => {
              const t = tooltip()!;
              setTooltip(null);
              navigateTo(t.kind, t.name);
            }}>detail</a>
          </div>
        </div>
      </Show>
    </div>
  );
}
