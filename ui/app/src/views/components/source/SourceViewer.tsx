// SourceViewer.tsx — Source code viewer with cross-linked identifiers.

import { Show, For, createSignal, createMemo, createEffect } from "solid-js";
import { highlightPowerScript, type ProcedureInfo, type KnownProcInfo, type LocalSymbolInfo } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { SourceContextMenu } from "./SourceContextMenu.js";
import type { ContextMenuTarget, ContextActions } from "./SourceContextMenu.js";
import {
  SourceGutter, ProcOverlayBars, SourceTooltip,
  linkIdentifiers,
  buildObjectMap, buildProcMap, buildVarMap, buildProcCountMap, buildProcFirstLine,
  buildObjectTooltip, buildProcTooltip, buildVarTooltip, buildProcBarTooltip, PROC_BADGE_COLORS,
  lineFromY, overlayTop, overlayHeight, procSelectedRange, dimmedRanges, procedureAtLine,
} from "@pb/platform";

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
  sliceHighlight?: { lines: Set<number>; label: string } | null;
  onClearSliceHighlight?: () => void;
}

export function SourceViewer(props: { store: Store<AppState, AppAction> } & SourceViewerProps) {
  const store = props.store;
  const [tooltip, setTooltip] = createSignal<{ html: string; x: number; y: number } | null>(null);
  const [menuTarget, setMenuTarget] = createSignal<ContextMenuTarget | null>(null);
  let procRangeBg: HTMLDivElement | undefined;

  createEffect(() => {
    const range = selectedRange();
    if (!range || !procRangeBg) return;
    procRangeBg.scrollIntoView({ behavior: "instant" as ScrollBehavior, block: "start" });
  });

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
    const sourceLine = lineFromY(e.clientY, el.getBoundingClientRect().top, el.scrollTop);
    setMenuTarget({
      linkType, linkName, x: e.clientX, y: e.clientY,
      sourceLine,
      callerCount: counts?.caller_count,
      calleeCount: counts?.callee_count,
      procObject: proc?.object,
      viewedProcName: procedureAtLine(props.procedures, sourceLine)?.name,
    });
  }

  return (
    <div class="source-viewer-wrapper">
      <Show when={props.sliceHighlight}>
        {(sh) => (
          <div class="source-slice-banner">
            <span>{sh().label}</span>
            <button onClick={() => props.onClearSliceHighlight?.()}>Clear</button>
          </div>
        )}
      </Show>
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
              ref={procRangeBg}
              class="source-proc-range-bg"
              style={{
                top: `${overlayTop(selectedRange()!.start)}px`,
                height: `${overlayHeight(selectedRange()!.start, selectedRange()!.end)}px`,
              }}
            />
          </Show>
          <Show when={props.sliceHighlight}>
            {(sh) => (
              <For each={dimmedRanges(props.lines.length, sh().lines)}>
                {(r) => (
                  <div
                    class="source-dim-overlay"
                    style={{ top: `${overlayTop(r.start)}px`, height: `${overlayHeight(r.start, r.end)}px` }}
                  />
                )}
              </For>
            )}
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
    </div>
  );
}
