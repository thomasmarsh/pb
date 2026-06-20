// SourceViewer.tsx — Source code viewer with cross-linked identifiers.

import { For, Show, createSignal, createMemo } from "solid-js";
import { highlightPowerScript, PB_KEYWORDS } from "../../utils/highlight.js";
import type { ProcedureInfo, KnownProcInfo, LocalSymbolInfo } from "../../types/api.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";

const PROC_COLORS: Record<string, string> = {
  function: "proc-function",
  subroutine: "proc-subroutine",
  event: "proc-event",
  on: "proc-on",
};

const PROC_BADGE_COLORS: Record<string, string> = {
  function: "#a78bfa",
  subroutine: "#fb923c",
  event: "#facc15",
  on: "#4ade80",
};

type KnownProc = KnownProcInfo;

interface SourceViewerProps {
  lines: string[];
  procedures: ProcedureInfo[];
  knownObjects: { name: string; kind: string }[];
  knownProcs: KnownProcInfo[];
  localSymbols?: LocalSymbolInfo[];
  objectName: string;
  selectedProcName?: string;
  onProcBarClick?: (proc: ProcedureInfo) => void;
}

function linkIdentifiers(
  html: string,
  objectMap: Map<string, { name: string; kind: string }>,
  procMap: Map<string, KnownProc>,
  varMap: Map<string, LocalSymbolInfo>,
  selfName: string,
): string {
  return html.replace(/\b([A-Za-z_][\w$#%-]*)\b/g, (match, word) => {
    const lower = word.toLowerCase();
    // Skip HTML tags from highlight spans
    if (match.startsWith("<") || match.startsWith("/")) return match;
    // Skip self-references
    if (lower === selfName.toLowerCase()) return match;
    // Skip keywords
    if (PB_KEYWORDS.has(lower)) return match;
    // Link to known procedures
    if (procMap.has(lower)) {
      return `<span class="src-link src-link-proc" data-link-type="procedure" data-link-name="${word}">${match}</span>`;
    }
    // Link to local variables / parameters
    if (varMap.has(lower)) {
      const sym = varMap.get(lower)!;
      const cls = sym.is_parameter ? "src-link-param" : "src-link-var";
      return `<span class="src-link ${cls}" data-link-type="var" data-link-name="${word}">${match}</span>`;
    }
    // Link to known objects
    if (objectMap.has(lower)) {
      return `<span class="src-link src-link-obj" data-link-type="object" data-link-name="${word}">${match}</span>`;
    }
    return match;
  });
}

export function SourceViewer(props: { store: Store<AppState, AppAction> } & SourceViewerProps) {
  const store = props.store;
  const [tooltip, setTooltip] = createSignal<{ html: string; x: number; y: number } | null>(null);

  // Build lookup maps
  const objectMap = createMemo(() => {
    const map = new Map<string, { name: string; kind: string }>();
    for (const o of props.knownObjects) map.set(o.name.toLowerCase(), o);
    return map;
  });

  const procMap = createMemo(() => {
    const map = new Map<string, KnownProc>();
    for (const p of props.knownProcs) map.set(p.name.toLowerCase(), p);
    for (const p of props.procedures) {
      map.set(p.name.toLowerCase(), {
        name: p.name,
        object: props.objectName,
        proc_type: p.proc_type,
        modifiers: p.modifiers,
        params: p.params,
        return_type: p.return_type,
        start_line: p.start_line,
        end_line: p.end_line,
        cyclomatic: p.cyclomatic,
      });
    }
    return map;
  });

  // var_name_lower → first symbol with that name (across all procs)
  const varMap = createMemo(() => {
    const map = new Map<string, LocalSymbolInfo>();
    for (const s of props.localSymbols ?? []) {
      const key = s.var_name.toLowerCase();
      if (!map.has(key)) map.set(key, s);
    }
    return map;
  });

  // Map of start_line → procedure
  const procFirstLine = createMemo(() => {
    const map = new Map<number, ProcedureInfo>();
    for (const p of props.procedures) {
      if (p.start_line != null) map.set(p.start_line, p);
    }
    return map;
  });

  // Full HTML as a single block — plain text only, no block elements inside <pre> (causes drift)
  const fullHtml = createMemo(() => {
    const code = props.lines.join("\n");
    const highlighted = highlightPowerScript(code);
    return highlighted.split("\n").map((line) =>
      linkIdentifiers(line, objectMap(), procMap(), varMap(), props.objectName)
    ).join("\n");
  });

  // Selected proc range for the overlay highlight
  const selectedRange = createMemo(() => {
    const name = props.selectedProcName;
    if (!name) return null;
    const proc = props.procedures.find(p => p.name === name);
    if (!proc || proc.start_line == null || proc.end_line == null) return null;
    return { start: proc.start_line, end: proc.end_line };
  });

  // Handle mouse events for tooltips and clicks
  function handleMouseOver(e: MouseEvent) {
    const target = e.target as HTMLElement;
    const link = target.closest("[data-link-type]") as HTMLElement | null;
    if (!link) {
      setTooltip(null);
      return;
    }

    const linkType = link.dataset.linkType;
    const linkName = link.dataset.linkName;
    if (!linkType || !linkName) return;

    const lower = linkName.toLowerCase();

    if (linkType === "object") {
      const obj = objectMap().get(lower);
      const kind = obj?.kind ?? "object";
      const color = kind === "datawindow" ? "#56A85D" : "#5B8DD9";
      link.style.color = color;
      setTooltip({
        html: `<div class="tt-name" style="color:${color}">${linkName}</div><div class="tt-meta">${kind}</div>`,
        x: e.clientX + 12,
        y: e.clientY + 12,
      });
    } else if (linkType === "procedure") {
      const proc = procMap().get(lower);
      const color = proc ? (PROC_BADGE_COLORS[proc.proc_type] ?? "#a78bfa") : "#a78bfa";
      link.style.color = color;

      let html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
      if (proc) {
        const ret = proc.return_type ? ` → ${proc.return_type}` : "";
        html += `<div class="tt-meta">${proc.proc_type}${ret}</div>`;
        if (proc.params) html += `<div class="tt-meta">(${proc.params})</div>`;
        html += `<div class="tt-meta">${proc.object}</div>`;
        if (proc.cyclomatic != null) {
          html += `<div class="tt-cc"><span class="badge badge-cc">CC: ${proc.cyclomatic}</span></div>`;
        }
      }
      setTooltip({ html, x: e.clientX + 12, y: e.clientY + 12 });
    } else if (linkType === "var") {
      const sym = varMap().get(lower);
      const color = sym?.is_parameter ? "#4fc1ff" : "#9cdcfe";
      link.style.color = color;
      if (sym) {
        const badge = sym.is_parameter
          ? `<span class="badge badge-param">param</span>`
          : `<span class="badge badge-var">local</span>`;
        const kindColor = sym.resolved_kind === "object" ? "#5B8DD9"
          : sym.resolved_kind === "primitive" ? "#4ec9b0"
          : "#9cdcfe";
        let html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
        html += `<div class="tt-meta" style="color:${kindColor}">${sym.raw_type}</div>`;
        html += `<div class="tt-cc">${badge}</div>`;
        if (sym.resolved_target) {
          html += `<div class="tt-meta" style="color:#5B8DD9">${sym.resolved_target}</div>`;
        }
        setTooltip({ html, x: e.clientX + 12, y: e.clientY + 12 });
      }
    }
  }

  function handleMouseOut(e: MouseEvent) {
    const target = e.target as HTMLElement;
    const link = target.closest("[data-link-type]") as HTMLElement | null;
    if (link) {
      link.style.color = "";
    }
    // Only clear tooltip if we're not moving to another link
    const related = e.relatedTarget as HTMLElement | null;
    if (!related?.closest("[data-link-type]")) {
      setTooltip(null);
    }
  }

  function handleClick(e: MouseEvent) {
    const target = e.target as HTMLElement;
    const link = target.closest("[data-link-type]") as HTMLElement | null;
    if (!link) return;

    const linkType = link.dataset.linkType;
    const linkName = link.dataset.linkName;
    if (!linkType || !linkName) return;

    if (linkType === "object") {
      store.dispatch({ tag: "objects", action: { tag: "select", name: linkName } });
    } else if (linkType === "procedure") {
      const proc = procMap().get(linkName.toLowerCase());
      if (proc) {
        store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: proc.object, procName: proc.name } });
      } else {
        store.dispatch({ tag: "objects", action: { tag: "select", name: linkName } });
      }
    }
  }

  return (
    <div class="source-viewer">
      <div class="source-gutter">
        <For each={props.lines}>
          {(_line, i) => {
            const lineNum = i() + 1;
            const proc = procFirstLine().get(lineNum);
            return (
              <div
                class="source-gutter-line"
                style={proc ? {
                  color: PROC_BADGE_COLORS[proc.proc_type ?? ""] ?? "var(--text-muted)",
                  "font-weight": "600",
                } : undefined}
              >
                {String(lineNum)}
              </div>
            );
          }}
        </For>
      </div>

      <div
        class="source-code-area"
        onMouseOver={handleMouseOver}
        onMouseOut={handleMouseOut}
        onClick={handleClick}
      >
        {/* Selected proc range background — absolutely positioned, never inside <pre> */}
        <Show when={selectedRange()}>
          <div
            class="source-proc-range-bg"
            style={{
              top: `${(selectedRange()!.start - 1) * 20.8}px`,
              height: `${(selectedRange()!.end - selectedRange()!.start + 1) * 20.8}px`,
            }}
          />
        </Show>

        <pre innerHTML={fullHtml()} />

        {/* Procedure overlay bars */}
        <For each={props.procedures}>
          {(p) => {
            if (p.start_line == null || p.end_line == null) return null;
            const barTop = (p.start_line - 1) * 20.8;
            const barHeight = (p.end_line - p.start_line + 1) * 20.8;
            const color = PROC_COLORS[p.proc_type ?? ""] ?? "";
            const badgeColor = PROC_BADGE_COLORS[p.proc_type ?? ""] ?? "#fff";

            return (
              <div
                class={`source-proc-bar ${color}${p.name === props.selectedProcName ? " selected" : ""}`}
                style={{ top: `${barTop}px`, height: `${barHeight}px` }}
                onMouseEnter={(e) => {
                  const cc = p.cyclomatic != null ? `CC: ${p.cyclomatic}` : "";
                  const ret = p.return_type ? ` → ${p.return_type}` : "";
                  setTooltip({
                    html: `<div class="tt-name" style="color:${badgeColor}">${p.name}</div>` +
                      `<div class="tt-meta">${p.proc_type} ${p.modifiers ?? ""}${ret}</div>` +
                      (p.params ? `<div class="tt-meta">(${p.params})</div>` : "") +
                      `<div class="tt-meta">Lines ${p.start_line}–${p.end_line}</div>` +
                      (cc ? `<div class="tt-cc"><span class="badge badge-cc">${cc}</span></div>` : ""),
                    x: e.clientX + 12,
                    y: e.clientY + 12,
                  });
                }}
                onMouseLeave={() => setTooltip(null)}
                onClick={() => {
                  if (props.onProcBarClick) {
                    props.onProcBarClick(p);
                  } else {
                    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: props.objectName, procName: p.name } });
                  }
                }}
              />
            );
          }}
        </For>
      </div>

      {/* Tooltip portal */}
      <Show when={tooltip()}>
        <div
          class="source-proc-tooltip visible"
          style={{
            left: `${Math.min(tooltip()!.x, window.innerWidth - 420)}px`,
            top: `${Math.min(tooltip()!.y, window.innerHeight - 140)}px`,
          }}
          innerHTML={tooltip()!.html}
        />
      </Show>
    </div>
  );
}
