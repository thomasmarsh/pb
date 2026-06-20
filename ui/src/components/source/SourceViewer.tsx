// SourceViewer.tsx — Source code viewer with cross-linked identifiers.

import { Show, createSignal, createMemo } from "solid-js";
import { highlightPowerScript } from "../../utils/highlight.js";
import type { ProcedureInfo, KnownProcInfo, LocalSymbolInfo } from "../../types/api.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { SourceContextMenu } from "./SourceContextMenu.js";
import type { ContextMenuTarget, ContextActions } from "./SourceContextMenu.js";
import { SourceGutter } from "./SourceGutter.js";
import { ProcOverlayBars } from "./ProcOverlayBars.js";
import { SourceTooltip } from "./SourceTooltip.js";
import { linkIdentifiers } from "./pure/identifiers.js";
import { buildObjectMap, buildProcMap, buildVarMap, buildProcCountMap, buildProcFirstLine } from "./pure/lookup.js";
import { buildObjectTooltip, buildProcTooltip, buildVarTooltip, buildProcBarTooltip, PROC_BADGE_COLORS } from "./pure/tooltip.js";
import { lineFromY, overlayTop, overlayHeight, procSelectedRange } from "./pure/line.js";

interface SourceViewerProps {
  lines: string[];
  procedures: ProcedureInfo[];
  knownObjects: { name: string; kind: string }[];
  knownProcs: KnownProcInfo[];
  localSymbols?: LocalSymbolInfo[];
  objectName: string;
  selectedProcName?: string;
  onProcBarClick?: (proc: ProcedureInfo) => void;
  contextActions?: ContextActions;
}

export function SourceViewer(props: { store: Store<AppState, AppAction> } & SourceViewerProps) {
  const store = props.store;
  const [tooltip, setTooltip] = createSignal<{ html: string; x: number; y: number } | null>(null);
  const [menuTarget, setMenuTarget] = createSignal<ContextMenuTarget | null>(null);

  const objectMap = createMemo(() => buildObjectMap(props.knownObjects));
  const procMap = createMemo(() => buildProcMap(props.knownProcs, props.procedures, props.objectName));
  const varMap = createMemo(() => buildVarMap(props.localSymbols ?? []));
  const procCountMap = createMemo(() => buildProcCountMap(props.procedures));
  const procFirstLine = createMemo(() => buildProcFirstLine(props.procedures));
  const selectedRange = createMemo(() => procSelectedRange(props.procedures, props.selectedProcName));
  const fullHtml = createMemo(() =>
    highlightPowerScript(props.lines.join("\n"))
      .split("\n")
      .map((line) => linkIdentifiers(line, objectMap(), procMap(), varMap(), props.objectName))
      .join("\n")
  );

  function handleMouseOver(e: MouseEvent) {
    const link = (e.target as HTMLElement).closest("[data-link-type]") as HTMLElement | null;
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
    const link = (e.target as HTMLElement).closest("[data-link-type]") as HTMLElement | null;
    if (link) link.style.color = "";
    if (!(e.relatedTarget as HTMLElement | null)?.closest("[data-link-type]")) setTooltip(null);
  }

  function handleClick(e: MouseEvent) {
    const link = (e.target as HTMLElement).closest("[data-link-type]") as HTMLElement | null;
    if (!link) return;
    const { linkType, linkName } = link.dataset;
    if (!linkType || !linkName) return;
    if (linkType === "object") {
      store.dispatch({ tag: "objects", action: { tag: "select", name: linkName } });
    } else if (linkType === "procedure") {
      const proc = procMap().get(linkName.toLowerCase());
      store.dispatch(proc
        ? { tag: "objects", action: { tag: "proc-select", objectName: proc.object, procName: proc.name } }
        : { tag: "objects", action: { tag: "select", name: linkName } }
      );
    }
  }

  function handleContextMenu(e: MouseEvent) {
    e.preventDefault();
    const link = (e.target as HTMLElement).closest("[data-link-type]") as HTMLElement | null;
    if (!link) { setMenuTarget(null); return; }
    const linkType = (link.dataset.linkType ?? "var") as ContextMenuTarget["linkType"];
    const linkName = link.dataset.linkName;
    if (!linkName) return;
    const lower = linkName.toLowerCase();
    const proc = linkType === "procedure" ? procMap().get(lower) : undefined;
    const counts = linkType === "procedure" ? procCountMap().get(lower) : undefined;
    const el = e.currentTarget as HTMLElement;
    setMenuTarget({
      linkType, linkName, x: e.clientX, y: e.clientY,
      sourceLine: lineFromY(e.clientY, el.getBoundingClientRect().top, el.scrollTop),
      callerCount: counts?.caller_count,
      calleeCount: counts?.callee_count,
      procObject: proc?.object,
    });
  }

  return (
    <div class="source-viewer">
      <SourceGutter lines={props.lines} procFirstLine={procFirstLine()} />
      <div
        class="source-code-area"
        onMouseOver={handleMouseOver}
        onMouseOut={handleMouseOut}
        onClick={handleClick}
        onContextMenu={handleContextMenu}
      >
        <Show when={selectedRange()}>
          <div
            class="source-proc-range-bg"
            style={{
              top: `${overlayTop(selectedRange()!.start)}px`,
              height: `${overlayHeight(selectedRange()!.start, selectedRange()!.end)}px`,
            }}
          />
        </Show>
        <pre innerHTML={fullHtml()} />
        <ProcOverlayBars
          procedures={props.procedures}
          selectedProcName={props.selectedProcName}
          procCountMap={procCountMap()}
          onBarEnter={(p, e) => setTooltip({
            html: buildProcBarTooltip(p, procCountMap().get(p.name.toLowerCase()), PROC_BADGE_COLORS[p.proc_type ?? ""] ?? "#fff", props.objectName),
            x: e.clientX + 12, y: e.clientY + 12,
          })}
          onBarLeave={() => setTooltip(null)}
          onClick={(p) => props.onProcBarClick
            ? props.onProcBarClick(p)
            : store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: props.objectName, procName: p.name } })
          }
        />
      </div>
      <SourceTooltip tooltip={tooltip()} />
      <SourceContextMenu
        target={menuTarget()}
        store={store}
        objectName={props.objectName}
        contextActions={props.contextActions}
        onClose={() => setMenuTarget(null)}
      />
    </div>
  );
}
