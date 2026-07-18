// SourceView.tsx — Shared, cross-linked source viewer.
//
// Used by BOTH the whole-file SourceViewer (app) and the narrowed CodeBlock
// (platform) so they render identical code: a line-numbered gutter plus
// syntax-highlighted, identifier-linked source, with hover tooltips, a
// per-procedure gutter bar, and per-line highlights.
//
// Alignment safety: the gutter numbers and every highlight/overlay (error
// lines, the selected-procedure range, the per-procedure bar, slice dimming)
// are computed per source line and rendered from the SAME per-line `<For>`
// loop — never from a pixel-offset overlay driven by a hardcoded line-height
// constant. A row's highlight is that row's own DOM node, so it can't drift
// regardless of font size, zoom, or line-height.

import { Show, For, createSignal, createMemo, createEffect } from "solid-js";
import type { JSX } from "solid-js";
import {
  highlightPowerScript,
  linkIdentifiers,
  buildObjectMap, buildProcMap, buildVarMap, buildProcCountMap, buildProcRangeMap,
  buildObjectTooltip, buildProcTooltip, buildVarTooltip, buildProcBarTooltip,
  PROC_COLORS, PROC_BADGE_COLORS, SourceTooltip,
  type ProcedureInfo, type KnownProcInfo, type LocalSymbolInfo,
} from "@pb/platform";

export interface SourceViewProps {
  lines: string[];
  baseLine?: number;
  knownObjects?: { name: string; kind: string }[];
  knownProcs?: KnownProcInfo[];
  procedures?: ProcedureInfo[];
  localSymbols?: LocalSymbolInfo[];
  objectName?: string;
  link?: boolean;
  // Absolute (1-based) source line numbers to highlight.
  highlightLines?: Set<number> | null;
  // Absolute source line numbers inside the selected procedure's range.
  rangeLines?: Set<number> | null;
  procFirstLine?: Map<number, ProcedureInfo> | null;
  // Lines to keep bright during a slice highlight; every other line dims.
  // null means slice-dim mode is inactive (nothing dims).
  dimLines?: Set<number> | null;
  onLineClick?: (line: number) => void;
  onLinkClick?: (linkType: "object" | "procedure" | "var", linkName: string) => void;
  onLinkContextMenu?: (
    e: MouseEvent,
    linkType: "object" | "procedure" | "var",
    linkName: string,
    sourceLine: number,
  ) => void;
  onProcBarClick?: (proc: ProcedureInfo) => void;
  selectedProcName?: string;
  scrollToLine?: number | null;
}

export function SourceView(props: SourceViewProps): JSX.Element {
  const [tooltip, setTooltip] = createSignal<{ html: string; x: number; y: number } | null>(null);
  let codeArea: HTMLDivElement | undefined;

  const base = () => props.baseLine ?? 1;
  const doLink = () => props.link ?? true;

  const objectMap = createMemo(() => buildObjectMap(props.knownObjects ?? []));
  const procMap = createMemo(() => buildProcMap(props.knownProcs ?? [], props.procedures ?? [], props.objectName ?? ""));
  const varMap = createMemo(() => buildVarMap(props.localSymbols ?? []));
  const procCountMap = createMemo(() => buildProcCountMap(props.procedures ?? []));
  const procRangeMap = createMemo(() => buildProcRangeMap(props.procedures ?? []));

  // Highlight + link each line. Line count is preserved by the highlighter, so
  // the gutter (which iterates props.lines) and the code stay 1:1.
  const rendered = createMemo(() => {
    const raw = highlightPowerScript(props.lines.join("\n")).split("\n");
    if (!doLink()) return raw;
    const self = props.objectName ?? "";
    return raw.map((line) => linkIdentifiers(line, objectMap(), procMap(), varMap(), self));
  });

  const isError = (i: number) => props.highlightLines?.has(base() + i) ?? false;
  const isRange = (i: number) => props.rangeLines?.has(base() + i) ?? false;
  const isDim = (i: number) => props.dimLines != null && !props.dimLines.has(base() + i);

  function findLink(e: MouseEvent): HTMLElement | null {
    return (e.target as HTMLElement).closest("[data-link-type]") as HTMLElement | null;
  }

  function handleMouseOver(e: MouseEvent) {
    const link = findLink(e);
    if (!link) { setTooltip(null); return; }
    const { linkType, linkName } = link.dataset;
    if (!linkType || !linkName) return;
    const lower = linkName.toLowerCase();
    if (linkType === "object") {
      const t = buildObjectTooltip(linkName, objectMap().get(lower));
      link.style.color = t.color;
      setTooltip({ html: t.html, x: e.clientX + 12, y: e.clientY + 12 });
    } else if (linkType === "procedure") {
      const t = buildProcTooltip(linkName, procMap().get(lower), procCountMap().get(lower));
      link.style.color = t.color;
      setTooltip({ html: t.html, x: e.clientX + 12, y: e.clientY + 12 });
    } else if (linkType === "var") {
      const sym = varMap().get(lower);
      link.style.color = sym?.is_parameter ? "#4fc1ff" : "#9cdcfe";
      const t = buildVarTooltip(linkName, sym);
      if (t) setTooltip({ html: t.html, x: e.clientX + 12, y: e.clientY + 12 });
    }
  }

  function handleMouseOut(e: MouseEvent) {
    const link = findLink(e);
    if (link) link.style.color = "";
    if (!(e.relatedTarget as HTMLElement | null)?.closest?.("[data-link-type]")) setTooltip(null);
  }

  function handleClick(e: MouseEvent) {
    const link = findLink(e);
    if (!link) return;
    const { linkType, linkName } = link.dataset;
    if (linkType && linkName) props.onLinkClick?.(linkType as "object" | "procedure" | "var", linkName);
  }

  function handleContextMenu(e: MouseEvent) {
    e.preventDefault();
    const link = findLink(e);
    if (!link) return;
    const linkType = (link.dataset.linkType ?? "var") as "object" | "procedure" | "var";
    const linkName = link.dataset.linkName;
    if (!linkName) return;
    const lineEl = (e.target as HTMLElement).closest("[data-line]") as HTMLElement | null;
    const sourceLine = lineEl ? Number(lineEl.dataset.line) : base();
    props.onLinkContextMenu?.(e, linkType, linkName, sourceLine);
  }

  function handleProcBarEnter(e: MouseEvent, p: ProcedureInfo) {
    setTooltip({
      html: buildProcBarTooltip(
        p,
        procCountMap().get(p.name.toLowerCase()),
        PROC_BADGE_COLORS[p.proc_type ?? ""] ?? "#fff",
        props.objectName ?? "",
      ),
      x: e.clientX + 12,
      y: e.clientY + 12,
    });
  }

  function handleProcBarClick(e: MouseEvent, p: ProcedureInfo) {
    e.stopPropagation();
    props.onProcBarClick?.(p);
  }

  // Scroll the selected procedure's first line into view.
  createEffect(() => {
    const n = props.scrollToLine;
    if (n == null || !codeArea) return;
    const el = codeArea.querySelector(`[data-line="${n}"]`);
    el?.scrollIntoView({ behavior: "instant" as ScrollBehavior, block: "start" });
  });

  return (
    <div class="source-viewer">
      <div class="source-gutter">
        <For each={props.lines}>{(_line, i) => {
          const lineNum = base() + i();
          const proc = props.procFirstLine?.get(lineNum);
          const rangeProc = procRangeMap().get(lineNum);
          return (
            <div
              class="source-gutter-line"
              data-line={lineNum}
              classList={{
                "source-gutter-line--error": isError(i()),
                "source-gutter-line--range": isRange(i()),
                "source-gutter-line--clickable": props.onLineClick != null,
              }}
              style={proc ? {
                color: PROC_BADGE_COLORS[proc.proc_type ?? ""] ?? "var(--text-muted)",
                "font-weight": "600",
              } : undefined}
              onClick={() => props.onLineClick?.(lineNum)}
            >
              <Show when={rangeProc}>
                {(rp) => (
                  <div
                    class={`source-proc-bar ${PROC_COLORS[rp().proc_type ?? ""] ?? ""}${rp().name === props.selectedProcName ? " selected" : ""}`}
                    onMouseEnter={(e) => handleProcBarEnter(e, rp())}
                    onMouseLeave={() => setTooltip(null)}
                    onClick={(e) => handleProcBarClick(e, rp())}
                  />
                )}
              </Show>
              {String(lineNum)}
            </div>
          );
        }}</For>
      </div>
      <div
        class="source-code-area"
        ref={codeArea}
        onMouseOver={handleMouseOver}
        onMouseOut={handleMouseOut}
        onClick={handleClick}
        onContextMenu={handleContextMenu}
      >
        <pre><For each={rendered()}>{(line, i) => (
          <>
            <span
              class="source-code-line"
              data-line={base() + i()}
              classList={{
                "source-code-line--error": isError(i()),
                "source-code-line--range": isRange(i()),
                "source-code-line--dim": isDim(i()),
              }}
              innerHTML={line}
            />
            {i() < rendered().length - 1 ? "\n" : ""}
          </>
        )}</For></pre>
        <SourceTooltip tooltip={tooltip()} />
      </div>
    </div>
  );
}
