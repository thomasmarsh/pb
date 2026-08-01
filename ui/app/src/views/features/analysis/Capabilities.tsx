// Capabilities.tsx — corpus-wide capability catalog (Plan 225 Layer 6): every
// procedure's EffectTag closure (proc_effects) grouped into the small display
// vocabulary PB.Analysis.CallClassify.capabilityLabel defines (DB/UI/Async/
// Control/State). Each row expands to its procedure list, lazily fetched via
// GET /api/analysis/capabilities/{capability} and cached in
// AnalysisState.capabilityProcedures — same expandable-row shape as
// DecompositionCandidatesTable, keyed by capability string instead of index.

import { Show, For, onMount, createSignal } from "solid-js";
import {
  Code2,
  AnalysisExplainer,
  type AnalysisExplainerContent,
} from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

const CAPABILITY_DESCRIPTIONS: Record<string, string> = {
  DB: "Reads or writes a database table.",
  UI: "Writes to a window or control's visible state.",
  Async: "Makes a suspending / round-trip call.",
  Control: "Synchronous read/write of a control's own live buffer state (DataWindow row cursor, etc.).",
  State: "Writes the enclosing object's own instance variable.",
};

const CAPABILITIES_EXPLAINER: AnalysisExplainerContent = {
  title: "Capabilities",
  whatItIs:
    "A corpus-wide index of what every procedure's effect closure touches, " +
    "grouped from the compiler's 7-tag EffectTag vocabulary into 5 readable " +
    "capabilities: DB (reads or writes a database table), UI (writes a " +
    "window/control's visible state), Async (a suspending/round-trip call), " +
    "Control (synchronous read/write of a control's own live buffer state, " +
    "e.g. a DataWindow row cursor), and State (writes the enclosing " +
    "object's own instance variable). Each row is one capability; expanding " +
    "it lists every procedure whose effect closure carries it.",
  howItsUsed:
    "Use this to answer 'what in this corpus touches the database' or " +
    "'what could possibly write instance state' without reading pseudocode " +
    "procedure by procedure. Click a capability to expand its procedure " +
    "list; click a procedure to jump to it.",
  tips: [
    "A procedure can carry more than one capability — it's counted once per capability it carries, not split across them.",
    "This catalog is descriptive, not enforced — there is no type-level check that a procedure claiming 'pure' never gains a capability later.",
  ],
  example: () => (
    <>
      <p
        style={{
          margin: "0 0 8px",
          "font-size": "12px",
          color: "var(--text-muted)",
        }}
      >
        A procedure that reads a table and writes an instance variable carries two capabilities:
      </p>
      <table
        class="data-table"
        style={{ "font-size": "12px", margin: "10px 0" }}
      >
        <thead>
          <tr>
            <th>Capability</th>
            <th>Procedures (excerpt)</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>DB</td>
            <td>of_load_order</td>
          </tr>
          <tr>
            <td>State</td>
            <td>of_load_order</td>
          </tr>
        </tbody>
      </table>
    </>
  ),
};

export function Capabilities(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const [showHelp, setShowHelp] = createSignal(false);
  const [expanded, setExpanded] = createSignal<ReadonlySet<string>>(new Set());

  onMount(() => {
    store.dispatch({ tag: "analysis", action: { tag: "load-capabilities" } });
  });

  function toggleRow(capability: string): void {
    const wasExpanded = expanded().has(capability);
    setExpanded((prev) => {
      const next = new Set(prev);
      if (wasExpanded) next.delete(capability);
      else next.add(capability);
      return next;
    });
    if (!wasExpanded && snap().analysis.capabilityProcedures[capability] === undefined) {
      store.dispatch({ tag: "analysis", action: { tag: "load-capability-procedures", capability } });
    }
  }

  return (
    <div class="card">
      <div
        class="card-header"
        style={{ display: "flex", "align-items": "center", gap: "8px" }}
      >
        <h2 style={{ flex: 1 }}>Capabilities</h2>
        <Show when={snap().analysis.capabilitiesLoaded}>
          <span style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            {snap().analysis.capabilities.length} capabilit
            {snap().analysis.capabilities.length === 1 ? "y" : "ies"}
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

      <AnalysisExplainer
        open={showHelp()}
        onClose={() => setShowHelp(false)}
        content={CAPABILITIES_EXPLAINER}
      />

      <Show when={!snap().analysis.capabilitiesLoaded}>
        <div
          style={{
            color: "var(--text-muted)",
            "font-size": "13px",
            padding: "8px 0",
          }}
        >
          Loading…
        </div>
      </Show>

      <Show when={snap().analysis.capabilitiesLoaded}>
        <Show when={snap().analysis.capabilities.length === 0}>
          <div
            style={{
              color: "var(--text-muted)",
              "font-size": "13px",
              padding: "8px 0",
            }}
          >
            No capabilities found.
          </div>
        </Show>

        <Show when={snap().analysis.capabilities.length > 0}>
          <table class="data-table" style={{ "font-size": "13px" }}>
            <thead>
              <tr>
                <th>Capability</th>
                <th>Procedures</th>
              </tr>
            </thead>
            <tbody>
              <For each={snap().analysis.capabilities}>
                {(item) => (
                  <>
                    <tr
                      class="capability-row"
                      classList={{ "capability-row-active": expanded().has(item.capability) }}
                      style={{ cursor: "pointer" }}
                      onClick={() => toggleRow(item.capability)}
                    >
                      <td>
                        {item.capability}
                        <div style={{ color: "var(--text-muted)", "font-size": "11px" }}>
                          {CAPABILITY_DESCRIPTIONS[item.capability] ?? ""}
                        </div>
                      </td>
                      <td>{item.proc_count}</td>
                    </tr>
                    <Show when={expanded().has(item.capability)}>
                      <tr class="capability-evidence-row">
                        <td colspan="2" style={{ padding: "8px 12px", "border-top": "1px solid var(--border)" }}>
                          <Show
                            when={snap().analysis.capabilityProcedures[item.capability]}
                            fallback={<span style={{ color: "var(--text-muted)" }}>Loading…</span>}
                          >
                            {(procs) => (
                              <ul class="capability-proc-list" style={{ margin: 0, padding: 0, "list-style": "none" }}>
                                <For each={procs()}>
                                  {(p) => (
                                    <li
                                      class="clickable"
                                      style={{ padding: "2px 0", cursor: "pointer" }}
                                      onClick={() =>
                                        store.dispatch({
                                          tag: "objects",
                                          action: { tag: "proc-select", objectName: p.object, procName: p.proc_name },
                                        })
                                      }
                                    >
                                      <span class="entity-card-icon" style={{ "margin-right": "4px" }}>
                                        <Code2 size={13} />
                                      </span>
                                      {p.object}.{p.proc_name}
                                    </li>
                                  )}
                                </For>
                              </ul>
                            )}
                          </Show>
                        </td>
                      </tr>
                    </Show>
                  </>
                )}
              </For>
            </tbody>
          </table>
        </Show>
      </Show>
    </div>
  );
}
