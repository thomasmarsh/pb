// features/analysis/LinearTrace.tsx — Step-list component for taint paths and program slices.

import { createSignal, Show, For, onMount, onCleanup } from "solid-js";
import type { JSX } from "solid-js";
import type { TaintStep } from "../../types/api.js";

// Step type can be taint paths or forward/backward slices.
export type TraceType = "taint" | "slice-backward" | "slice-forward";

export interface LinearTraceProps {
  steps: TaintStep[];
  traceType: TraceType;
  traversedProcs: string[];
  // Multi-path navigation callbacks (optional).
  pathIndex?: number;
  totalPaths?: number;
  onPrevPath?: () => void;
  onNextPath?: () => void;
  // Navigate to a procedure (optional; uses window.location if not provided).
  onNavigateToProc?: (object: string, proc: string, line?: number) => void;
}

// ── Step type badge ───────────────────────────────────────────────────────────

function stepLabel(stepKind: string, traceType: TraceType): string {
  if (traceType === "slice-backward") return "AFFECTED";
  if (traceType === "slice-forward")  return "AFFECTING";
  if (stepKind === "source") return "SOURCE";
  if (stepKind === "sink")   return "SINK";
  return "TRANSFORM";
}

function stepBadgeClass(stepKind: string, traceType: TraceType): string {
  if (traceType === "slice-backward") return "badge step-badge step-badge-affected";
  if (traceType === "slice-forward")  return "badge step-badge step-badge-affecting";
  if (stepKind === "source") return "badge step-badge step-badge-source";
  if (stepKind === "sink")   return "badge step-badge step-badge-sink";
  return "badge step-badge step-badge-transform";
}

// ── Collapse logic ────────────────────────────────────────────────────────────

const ALWAYS_VISIBLE_HEAD = 4;
const ALWAYS_VISIBLE_TAIL = 4;
const COLLAPSE_THRESHOLD  = 20;

interface StepItem {
  index: number;  // 0-based index in props.steps
  step: TaintStep;
}

function computeVisible(
  steps: TaintStep[],
  expanded: boolean,
): { visible: StepItem[]; hiddenCount: number } {
  if (steps.length <= COLLAPSE_THRESHOLD || expanded) {
    return {
      visible: steps.map((step, i) => ({ index: i, step })),
      hiddenCount: 0,
    };
  }
  const head = steps.slice(0, ALWAYS_VISIBLE_HEAD).map((step, i) => ({ index: i, step }));
  const tail = steps.slice(-ALWAYS_VISIBLE_TAIL).map((step, i) => ({
    index: steps.length - ALWAYS_VISIBLE_TAIL + i,
    step,
  }));
  return {
    visible: [...head, ...tail],
    hiddenCount: steps.length - ALWAYS_VISIBLE_HEAD - ALWAYS_VISIBLE_TAIL,
  };
}

// ── Main component ────────────────────────────────────────────────────────────

export function LinearTrace(props: LinearTraceProps): JSX.Element {
  const [expanded, setExpanded] = createSignal(false);

  // E key: expand all collapsed steps. ←/→ for path navigation.
  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      if (e.key === "e" || e.key === "E") {
        e.preventDefault();
        setExpanded(true);
      }
      if (e.key === "ArrowLeft"  && props.onPrevPath) { e.preventDefault(); props.onPrevPath(); }
      if (e.key === "ArrowRight" && props.onNextPath) { e.preventDefault(); props.onNextPath(); }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  const derived = () => computeVisible(props.steps, expanded());

  return (
    <div class="linear-trace">
      {/* Path navigation header */}
      <Show when={(props.totalPaths ?? 0) > 1}>
        <div class="trace-path-nav">
          <button
            class="icon-btn"
            onClick={() => props.onPrevPath?.()}
            disabled={(props.pathIndex ?? 0) === 0}
            title="Previous path (←)"
          >
            ←
          </button>
          <span class="trace-path-counter">
            Path {(props.pathIndex ?? 0) + 1} of {props.totalPaths}
          </span>
          <button
            class="icon-btn"
            onClick={() => props.onNextPath?.()}
            disabled={(props.pathIndex ?? 0) >= (props.totalPaths ?? 1) - 1}
            title="Next path (→)"
          >
            →
          </button>
        </div>
      </Show>

      <div class="linear-trace-layout">
        {/* Step list */}
        <div class="linear-trace-steps">
          {/* Head steps */}
          <For each={derived().visible.slice(0, props.steps.length <= COLLAPSE_THRESHOLD || expanded() ? undefined : ALWAYS_VISIBLE_HEAD)}>
            {({ index, step }) => (
              <TraceStep
                stepNum={index + 1}
                step={step}
                traceType={props.traceType}
                onNavigate={props.onNavigateToProc}
              />
            )}
          </For>

          {/* Collapse toggle (between head and tail when collapsed) */}
          <Show when={derived().hiddenCount > 0}>
            <div
              class="trace-collapse-toggle"
              data-testid="trace-collapse-toggle"
              onClick={() => setExpanded(true)}
            >
              ▸ {derived().hiddenCount} intermediate step{derived().hiddenCount === 1 ? "" : "s"} — click to expand (or press E)
            </div>
          </Show>

          {/* Tail steps (only when collapsed) */}
          <Show when={!expanded() && derived().hiddenCount > 0}>
            <For each={derived().visible.slice(ALWAYS_VISIBLE_HEAD)}>
              {({ index, step }) => (
                <TraceStep
                  stepNum={index + 1}
                  step={step}
                  traceType={props.traceType}
                  onNavigate={props.onNavigateToProc}
                />
              )}
            </For>
          </Show>
        </div>

        {/* Mini call graph panel */}
        <Show when={props.traversedProcs.length > 0}>
          <MiniCallGraph procs={props.traversedProcs} onNavigate={props.onNavigateToProc} />
        </Show>
      </div>
    </div>
  );
}

// ── Individual step row ───────────────────────────────────────────────────────

function TraceStep(props: {
  stepNum: number;
  step: TaintStep;
  traceType: TraceType;
  onNavigate?: (object: string, proc: string, line?: number) => void;
}): JSX.Element {
  const s = props.step;
  return (
    <div class="linear-trace-step" data-testid="trace-step">
      <div class="trace-step-left-border" />
      <div class="trace-step-body">
        <div class="trace-step-header">
          <span class="trace-step-num">{props.stepNum}</span>
          <span class={stepBadgeClass(s.step_kind, props.traceType)}>
            {stepLabel(s.step_kind, props.traceType)}
          </span>
          <button
            class="trace-step-proc link-btn"
            onClick={() => props.onNavigate?.(s.object, s.proc_name, s.line ?? undefined)}
          >
            {s.object}.{s.proc_name}
          </button>
          <Show when={s.line != null}>
            <span class="trace-step-line">:{s.line}</span>
          </Show>
        </div>
        <div class="trace-step-stmt">{s.description}</div>
        <Show when={s.var_name}>
          <div class="trace-step-annotation">via {s.var_name}</div>
        </Show>
      </div>
    </div>
  );
}

// ── Mini call graph ───────────────────────────────────────────────────────────

function MiniCallGraph(props: {
  procs: string[];
  onNavigate?: (object: string, proc: string) => void;
}): JSX.Element {
  return (
    <div class="trace-callgraph" data-testid="trace-callgraph">
      <div class="trace-callgraph-label section-label">Procedures traversed</div>
      <div class="trace-callgraph-chain">
        <For each={props.procs}>
          {(proc, i) => (
            <>
              <Show when={i() > 0}>
                <span class="trace-callgraph-arrow">→</span>
              </Show>
              <ProcChip procKey={proc} onNavigate={props.onNavigate} />
            </>
          )}
        </For>
      </div>
    </div>
  );
}

function ProcChip(props: {
  procKey: string;  // "object.proc" or just "proc"
  onNavigate?: (object: string, proc: string) => void;
}): JSX.Element {
  const parts = () => {
    const dot = props.procKey.indexOf(".");
    if (dot === -1) return { object: "", proc: props.procKey };
    return { object: props.procKey.slice(0, dot), proc: props.procKey.slice(dot + 1) };
  };

  return (
    <button
      class="trace-callgraph-proc link-btn"
      onClick={() => {
        const { object, proc } = parts();
        props.onNavigate?.(object, proc);
      }}
      title={props.procKey}
    >
      {parts().proc}
    </button>
  );
}
