// LiveProcedures.tsx — Live Procedures report (Plan 161 Phase 4): procedures
// the Souffle live_proc IDB confirms reachable and not dead.

import { Show, For, onMount, createSignal } from "solid-js";
import { Code2, AnalysisExplainer, type AnalysisExplainerContent } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

const LIVE_PROCEDURES_EXPLAINER: AnalysisExplainerContent = {
  title: "Live Procedures",
  whatItIs:
    "A cross-check, not a discovery tool: every procedure listed here both " +
    "touches tracked SQL or schema (it owns a SQL statement or DataWindow " +
    "retrieve) and is confirmed reachable by a second, independent engine " +
    "— Souffle, a Datalog fixpoint solver — rather than the hand-written " +
    "Haskell call-graph walk that produces the Dead Code report. The rule " +
    "is two lines: a procedure is live if it owns a tracked SQL statement " +
    "and does NOT appear in Dead Code's own reachability result " +
    "(live_proc(Object,Proc) :- stmt(_,Object,Proc,_), !dead(Object,Proc)).",
  howItsUsed:
    "Use this to sanity-check Dead Code and any schema-footprint analysis " +
    "that depends on reachability (blast radius, decomposition " +
    "candidates, taint paths) — a finding anchored to a procedure listed " +
    "here carries more weight than one anchored to dead or SQL-free code, " +
    "because its DB-touching code is both real (has SQL) and exercised " +
    "(has callers). Click a row to open that procedure's detail page.",
  tips: [
    "This list is deliberately narrow — most procedures in a typical app touch no SQL or schema object at all, and none of those ever appear here, live or dead.",
    "An empty list doesn't mean nothing is alive — it means no SQL-touching procedure passed the reachability check, which can also point at an embedded-SQL or DDL-catalog extraction gap worth checking first.",
    "This table is computed by a separate engine (Souffle) from Dead Code's own Haskell BFS — a procedure Dead Code calls reachable that never shows up here is worth investigating as a real discrepancy, not noise.",
  ],
  example: () => (
    <>
      <p style={{ margin: "0 0 8px", "font-size": "12px", color: "var(--text-muted)" }}>
        Three procedures in the same object, only one of which shows up here:
      </p>
      <table class="data-table" style={{ "font-size": "12px", margin: "10px 0" }}>
        <thead>
          <tr>
            <th>Procedure</th>
            <th>Touches SQL?</th>
            <th>Reachable?</th>
            <th>Shows up in</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>of_format_label</td>
            <td>No</td>
            <td>Yes</td>
            <td>Neither report</td>
          </tr>
          <tr>
            <td>of_legacy_migration</td>
            <td>Yes</td>
            <td>No (0 callers)</td>
            <td>Dead Code only</td>
          </tr>
          <tr>
            <td>of_save_order</td>
            <td>Yes</td>
            <td>Yes</td>
            <td><strong>Live Procedures</strong></td>
          </tr>
        </tbody>
      </table>
    </>
  ),
};

export function LiveProcedures(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const [showHelp, setShowHelp] = createSignal(false);

  onMount(() => {
    store.dispatch({ tag: "analysis", action: { tag: "load-live-procedures" } });
  });

  return (
    <div class="card">
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
        <h2 style={{ flex: 1 }}>Live Procedures</h2>
        <Show when={snap().analysis.liveProceduresLoaded}>
          <span style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            {snap().analysis.liveProcedures.length} procedure{snap().analysis.liveProcedures.length === 1 ? "" : "s"}
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

      <AnalysisExplainer open={showHelp()} onClose={() => setShowHelp(false)} content={LIVE_PROCEDURES_EXPLAINER} />

      <Show when={!snap().analysis.liveProceduresLoaded}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>Loading…</div>
      </Show>

      <Show when={snap().analysis.liveProceduresLoaded}>
        <Show when={snap().analysis.liveProcedures.length === 0}>
          <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>
            No SQL-touching procedures confirmed live.
          </div>
        </Show>

        <Show when={snap().analysis.liveProcedures.length > 0}>
          <table class="data-table" style={{ "font-size": "13px" }}>
            <thead>
              <tr>
                <th>Object</th>
                <th>Procedure</th>
              </tr>
            </thead>
            <tbody>
              <For each={snap().analysis.liveProcedures}>
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
