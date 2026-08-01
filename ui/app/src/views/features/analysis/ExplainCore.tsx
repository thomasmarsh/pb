// features/analysis/ExplainCore.tsx — Embeddable Explain rendering core (no
// AnalysisView wrapper). Left pane: one card per region (Plan 222's
// "each Region is its own function"), signature header + statement list.
// Right pane: SourceView, hover/click-driven highlighting.

import { Show, For, createEffect, createSignal, createMemo } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import {
  SourceView,
  collectRegionCards, sourceLinesForStmt,
  formatInferredSignature, formatDeclaredSig, regionDisplayLabel,
  highlightPowerScript,
  type NormalizedStmt, type RegionCard,
} from "@pb/platform";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

export interface ExplainCoreProps {
  object: string;
  proc: string;
  store: Store<AppState, AppAction>;
  onGoto: () => void;
  gotoLabel?: string;
}

// How long a jump-chip's target card stays visually flashed after a click.
const FLASH_MS = 900;

function StmtRow(props: {
  stmt: NormalizedStmt;
  depth: number;
  isActive: (stmt: NormalizedStmt) => boolean;
  onHover: (stmt: NormalizedStmt | null) => void;
  onPin: (stmt: NormalizedStmt) => void;
  onJump: (regionId: string) => void;
}): JSX.Element {
  const indent = { "padding-left": `${props.depth * 16}px` };

  return (
    <>
      <Show
        when={props.stmt.kind === "regionRef"}
        fallback={
          <div
            class="explain-stmt"
            classList={{ "explain-stmt--active": props.isActive(props.stmt) }}
            style={indent}
            onMouseEnter={() => props.onHover(props.stmt)}
            onMouseLeave={() => props.onHover(null)}
            onClick={() => props.onPin(props.stmt)}
          >
            <code innerHTML={highlightPowerScript(props.stmt.text)} />
          </div>
        }
      >
        <div
          class="explain-stmt explain-stmt--region-ref"
          classList={{ "explain-stmt--active": props.isActive(props.stmt) }}
          style={indent}
          onMouseEnter={() => props.onHover(props.stmt)}
          onMouseLeave={() => props.onHover(null)}
          onClick={() => {
            props.onPin(props.stmt);
            if (props.stmt.kind === "regionRef") props.onJump(props.stmt.regionId);
          }}
        >
          <code innerHTML={highlightPowerScript(props.stmt.text)} />
        </div>
      </Show>
      <Show when={props.stmt.kind === "branch"}>
        {(() => {
          const s = props.stmt as Extract<NormalizedStmt, { kind: "branch" }>;
          return (
            <>
              <For each={s.then}>
                {(child) => <StmtRow stmt={child} depth={props.depth + 1} isActive={props.isActive} onHover={props.onHover} onPin={props.onPin} onJump={props.onJump} />}
              </For>
              <For each={s.else}>
                {(child) => <StmtRow stmt={child} depth={props.depth + 1} isActive={props.isActive} onHover={props.onHover} onPin={props.onPin} onJump={props.onJump} />}
              </For>
            </>
          );
        })()}
      </Show>
      <Show when={props.stmt.kind === "loop"}>
        {(() => {
          const s = props.stmt as Extract<NormalizedStmt, { kind: "loop" }>;
          return (
            <For each={s.body}>
              {(child) => <StmtRow stmt={child} depth={props.depth + 1} isActive={props.isActive} onHover={props.onHover} onPin={props.onPin} onJump={props.onJump} />}
            </For>
          );
        })()}
      </Show>
    </>
  );
}

function RegionCardView(props: {
  card: RegionCard;
  declaredSig: string | null;
  flashed: boolean;
  isActive: (stmt: NormalizedStmt) => boolean;
  onHover: (stmt: NormalizedStmt | null) => void;
  onPin: (stmt: NormalizedStmt) => void;
  onJump: (regionId: string) => void;
}): JSX.Element {
  const label = () => regionDisplayLabel(props.card.regionId, props.card.lineRange);
  const header = () => (props.card.sig ? formatInferredSignature(label(), props.card.sig) : label());

  return (
    <div
      id={`region-card-${props.card.regionId}`}
      class="explain-region-card"
      classList={{ "explain-region-card--flash": props.flashed }}
    >
      <Show when={props.declaredSig}>
        <div class="explain-region-header explain-region-header--declared">declared {props.declaredSig}</div>
      </Show>
      <div class="explain-region-header">inferred {header()}</div>
      <div class="explain-region-body">
        <For each={props.card.stmts}>
          {(stmt) => <StmtRow stmt={stmt} depth={0} isActive={props.isActive} onHover={props.onHover} onPin={props.onPin} onJump={props.onJump} />}
        </For>
      </div>
    </div>
  );
}

export function ExplainCore(props: ExplainCoreProps): JSX.Element {
  const [hovered, setHovered] = createSignal<NormalizedStmt | null>(null);
  const [pinned, setPinned] = createSignal<NormalizedStmt | null>(null);
  const [flashedRegion, setFlashedRegion] = createSignal<string | null>(null);

  let leftPaneEl: HTMLDivElement | undefined;

  const key = () => `${props.object}::${props.proc}`;

  createEffect(() => {
    const k = key();
    setHovered(null);
    setPinned(null);
    props.store.dispatch({
      tag: "explain",
      action: { tag: "request", key: k, object: props.object, proc: props.proc },
    });
  });

  const snap = props.store.getState();
  const entry = () => snap().explainPseudocodes[key()];
  const loading = () => entry()?.data === null || entry() === undefined;
  const error = () => {
    const d = entry()?.data;
    return d && "error" in d ? d.error : null;
  };
  const data = () => {
    const d = entry()?.data;
    return d && !("error" in d) ? d : null;
  };

  const cards = createMemo(() => {
    const d = data();
    return d ? collectRegionCards(d) : [];
  });

  const declaredSigText = createMemo(() => {
    const d = data();
    return d?.declaredSig ? formatDeclaredSig(d.declaredSig) : null;
  });

  const sourceLines = createMemo((): string[] => {
    const d = data();
    return d?.sourceOriginal ? d.sourceOriginal.split("\n") : [];
  });
  const procStartLine = createMemo((): number => data()?.procStartLine ?? 1);

  const activeStmt = createMemo(() => hovered() ?? pinned());
  const activeLines = createMemo(() => {
    const s = activeStmt();
    return s ? sourceLinesForStmt(s) : null;
  });
  const scrollToLine = createMemo(() => {
    const lines = activeLines();
    return lines && lines.size > 0 ? Math.min(...lines) : null;
  });

  function isActive(stmt: NormalizedStmt): boolean {
    return activeStmt() === stmt;
  }

  function handleJump(regionId: string): void {
    const el = leftPaneEl?.querySelector(`#region-card-${regionId}`);
    el?.scrollIntoView({ behavior: "smooth", block: "start" });
    setFlashedRegion(regionId);
    setTimeout(() => setFlashedRegion((cur) => (cur === regionId ? null : cur)), FLASH_MS);
  }

  return (
    <>
      <Show when={loading()}>
        <div class="diagram-container">
          <div class="loading-overlay"><div class="spinner" /> Loading Explain…</div>
        </div>
      </Show>
      <Show when={error()}>
        <div class="diagram-container">
          <div class="loading-overlay" style={{ color: "var(--red)" }}>
            Explain unavailable — procedure not found or has no pseudocode.
          </div>
        </div>
      </Show>
      <Show when={!loading() && !error() && data()}>
        <div class="explain-split">
          <div class="explain-region-pane" ref={leftPaneEl}>
            <For each={cards()}>
              {(card) => (
                <RegionCardView
                  card={card}
                  declaredSig={card.isRoot ? declaredSigText() : null}
                  flashed={flashedRegion() === card.regionId}
                  isActive={isActive}
                  onHover={setHovered}
                  onPin={setPinned}
                  onJump={handleJump}
                />
              )}
            </For>
          </div>
          <div class="explain-source-pane">
            <SourceView
              lines={sourceLines()}
              baseLine={procStartLine()}
              highlightLines={activeLines()}
              dimLines={activeLines()}
              scrollToLine={scrollToLine()}
            />
          </div>
        </div>
        <button class="cfg-block-goto" onClick={props.onGoto}>
          ↗ {props.gotoLabel ?? "View full procedure"}
        </button>
      </Show>
    </>
  );
}
