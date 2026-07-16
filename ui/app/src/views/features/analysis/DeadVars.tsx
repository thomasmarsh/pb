// DeadVars.tsx — Dead Variables report (Plan 174 T0-1 promotion): unused
// locals/params and dead stores found by PB.Analysis.DeadVars.

import { Show, For, onMount, createSignal } from "solid-js";
import { Code2, AnalysisExplainer, type AnalysisExplainerContent } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

const KIND_LABELS: Record<string, string> = {
  "never-read": "Never read",
  "overwritten-before-read": "Overwritten before read",
  "unused-param": "Unused param",
};

const DEAD_VARS_EXPLAINER: AnalysisExplainerContent = {
  title: "Dead Variables",
  whatItIs:
    "A query over the same def-use and live-variable dataflow the compiler " +
    "already computes for every procedure, reporting three kinds of finding: " +
    "a declared local that's never read, a parameter that's never read, and " +
    "a value that's assigned and then overwritten before anything reads it.",
  howItsUsed:
    "Use this to spot leftover or mistaken assignments — a variable that " +
    "looks load-bearing but is actually discarded, or a parameter nothing " +
    "in the procedure body ever consults. Click a row to open that " +
    "procedure's detail page.",
  tips: [
    "A bare declaration immediately followed by its first real assignment, and an unused for-loop counter, are both idiomatic PB — neither is ever flagged.",
    "A struct-field write (item.label = x) never counts as overwriting a prior write to a sibling field of the same variable.",
    "Findings from synthetic builtin-class stubs (the PB standard library shim) are excluded — only real corpus code is reported.",
  ],
  example: () => (
    <table class="data-table" style={{ "font-size": "12px", margin: "10px 0" }}>
      <thead>
        <tr>
          <th>Variable</th>
          <th>Kind</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>li_temp</td>
          <td>Never read</td>
        </tr>
        <tr>
          <td>ai_unused_param</td>
          <td>Unused param</td>
        </tr>
        <tr>
          <td>ll_count</td>
          <td>Overwritten before read</td>
        </tr>
      </tbody>
    </table>
  ),
};

export function DeadVars(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const [showHelp, setShowHelp] = createSignal(false);

  onMount(() => {
    store.dispatch({ tag: "analysis", action: { tag: "load-dead-vars" } });
  });

  return (
    <div class="card">
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
        <h2 style={{ flex: 1 }}>Dead Variables</h2>
        <Show when={snap().analysis.deadVarsLoaded}>
          <span style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            {snap().analysis.deadVars.length} finding{snap().analysis.deadVars.length === 1 ? "" : "s"}
          </span>
        </Show>
        <button
          onClick={() => setShowHelp(true)}
          aria-label="What is this?"
          title="What is this?"
          style={{
            background: "none",
            border: "none",
            cursor: "pointer",
            color: "var(--text-muted)",
            "font-size": "14px",
            padding: "0 4px",
            "line-height": "1",
          }}
        >
          ⓘ
        </button>
      </div>

      <AnalysisExplainer open={showHelp()} onClose={() => setShowHelp(false)} content={DEAD_VARS_EXPLAINER} />

      <Show when={!snap().analysis.deadVarsLoaded}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>Loading…</div>
      </Show>

      <Show when={snap().analysis.deadVarsLoaded}>
        <Show when={snap().analysis.deadVars.length === 0}>
          <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>
            No dead-variable findings.
          </div>
        </Show>

        <Show when={snap().analysis.deadVars.length > 0}>
          <table class="data-table" style={{ "font-size": "13px" }}>
            <thead>
              <tr>
                <th>Object</th>
                <th>Procedure</th>
                <th>Variable</th>
                <th>Line</th>
                <th>Kind</th>
              </tr>
            </thead>
            <tbody>
              <For each={snap().analysis.deadVars}>
                {(item) => (
                  <tr
                    class="clickable"
                    onClick={() => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: item.object, procName: item.proc_name } })}
                  >
                    <td style={{ color: "var(--text-muted)", "font-size": "12px" }}>{item.object}</td>
                    <td>
                      <span class="entity-card-icon" style={{ "margin-right": "4px" }}><Code2 size={13} /></span>
                      {item.proc_name}
                    </td>
                    <td>{item.var_name}</td>
                    <td style={{ color: "var(--text-muted)" }}>{item.line ?? "—"}</td>
                    <td>{KIND_LABELS[item.kind] ?? item.kind}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </Show>
      </Show>
    </div>
  );
}
