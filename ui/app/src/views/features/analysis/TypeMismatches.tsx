// TypeMismatches.tsx — Type Mismatches report (Plan 177 Phase 4b promotion):
// assignment/return/call-argument type mismatches found by PB.Analysis.TypeCheck.

import { Show, For, onMount, createSignal } from "solid-js";
import { Code2, AnalysisExplainer, type AnalysisExplainerContent } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

const KIND_LABELS: Record<string, string> = {
  "assign-mismatch": "Assignment",
  "return-mismatch": "Return",
  "call-arg-mismatch": "Call argument",
};

const TYPE_MISMATCHES_EXPLAINER: AnalysisExplainerContent = {
  title: "Type Mismatches",
  whatItIs:
    "A single decorating walk over every procedure body that resolves each " +
    "expression's statically-known type (declared variable, call return " +
    "type, member-chain resolution) and reports where an assignment, a " +
    "return, or a call argument's expected type is incompatible with what " +
    "the expression actually evaluates to.",
  howItsUsed:
    "Use this to spot a value flowing into the wrong shape — a string " +
    "assigned where a number is declared, a function returning the wrong " +
    "type, or a call argument that doesn't match the callee's declared " +
    "parameter type. Click a row to open that procedure's detail page.",
  tips: [
    "Only statically-declared types are checked — PB has no real type inference, so a lookup that can't be resolved is skipped rather than guessed.",
    "An unresolved or builtin call's arguments are never checked, since there's no declared parameter list to compare against.",
  ],
  example: () => (
    <table class="data-table" style={{ "font-size": "12px", margin: "10px 0" }}>
      <thead>
        <tr>
          <th>Target</th>
          <th>Expected</th>
          <th>Found</th>
          <th>Kind</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>ls_name</td>
          <td>string</td>
          <td>an integer literal</td>
          <td>Assignment</td>
        </tr>
      </tbody>
    </table>
  ),
};

export function TypeMismatches(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const [showHelp, setShowHelp] = createSignal(false);

  onMount(() => {
    store.dispatch({ tag: "analysis", action: { tag: "load-type-mismatches" } });
  });

  return (
    <div class="card">
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
        <h2 style={{ flex: 1 }}>Type Mismatches</h2>
        <Show when={snap().analysis.typeMismatchesLoaded}>
          <span style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            {snap().analysis.typeMismatches.length} finding{snap().analysis.typeMismatches.length === 1 ? "" : "s"}
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

      <AnalysisExplainer open={showHelp()} onClose={() => setShowHelp(false)} content={TYPE_MISMATCHES_EXPLAINER} />

      <Show when={!snap().analysis.typeMismatchesLoaded}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>Loading…</div>
      </Show>

      <Show when={snap().analysis.typeMismatchesLoaded}>
        <Show when={snap().analysis.typeMismatches.length === 0}>
          <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>
            No type-mismatch findings.
          </div>
        </Show>

        <Show when={snap().analysis.typeMismatches.length > 0}>
          <table class="data-table" style={{ "font-size": "13px" }}>
            <thead>
              <tr>
                <th>Object</th>
                <th>Procedure</th>
                <th>Line</th>
                <th>Target</th>
                <th>Expected</th>
                <th>Found</th>
                <th>Kind</th>
              </tr>
            </thead>
            <tbody>
              <For each={snap().analysis.typeMismatches}>
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
                    <td style={{ color: "var(--text-muted)" }}>{item.line}</td>
                    <td>{item.target}</td>
                    <td>{item.lhs_type}</td>
                    <td>{item.rhs_desc}</td>
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
