// features/analysis/DecompositionCandidatesCore.tsx — Embeddable decomposition-
// candidates panel (Plan 153 D5): ranks candidate column-block splits for a
// table by co-update/FK/blast-radius evidence.
//
// Data flows through the tables feature's env/reducer (CLAUDE.md Rule 1/2),
// mirroring ProcedureFootprintCore.tsx — not a self-fetching component.

import { Show, For, createMemo, createSignal, onMount } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { DecompositionEvidencePath } from "@pb/platform";

export interface DecompositionCandidatesCoreProps {
  store: Store<AppState, AppAction>;
  table: string;
}

// Coslice sizes routinely reach 100+ statements (e.g. misth_final_ypal's
// {kodfinal,kodxrisi,kodypal} = 120) — the API intentionally returns every
// path (pinned by test_get_decomposition_candidates_zero_evidence_still_
// reports_real_coslice), so truncation belongs here, in the UI, not the
// response shape.
const PATH_PREVIEW_COUNT = 5;

function EvidencePathsCell(props: { paths: DecompositionEvidencePath[] }): JSX.Element {
  const [expanded, setExpanded] = createSignal(false);
  const visible = createMemo(() => (expanded() ? props.paths : props.paths.slice(0, PATH_PREVIEW_COUNT)));

  return (
    <Show when={props.paths.length > 0} fallback={<span style={{ color: "var(--text-muted)" }}>None</span>}>
      <ul style={{ margin: "0", "padding-left": "16px" }}>
        <For each={visible()}>
          {(p) => <li>{p.target} ({p.direction}): {p.legs.join(" ")}</li>}
        </For>
      </ul>
      <Show when={props.paths.length > PATH_PREVIEW_COUNT}>
        <button type="button" class="link-btn" style={{ "font-size": "11px" }} onClick={() => setExpanded((v) => !v)}>
          {expanded() ? "Show less" : `Show ${props.paths.length - PATH_PREVIEW_COUNT} more`}
        </button>
      </Show>
    </Show>
  );
}

export function DecompositionCandidatesCore(props: DecompositionCandidatesCoreProps): JSX.Element {
  const snap = props.store.getState();

  onMount(() => {
    props.store.dispatch({
      tag: "tables",
      action: { tag: "decomposition-candidates-load", tableName: props.table },
    });
  });

  const entry = createMemo(() => snap().tables.decompositionCandidates);
  const loading = createMemo(() => snap().tables.decompositionCandidatesLoading);

  const current = createMemo(() => {
    const e = entry();
    if (!e || "error" in e) return null;
    if (e.table !== props.table) return null;
    return e;
  });

  return (
    <>
      <Show when={loading() && !current()}>
        <div style={{ padding: "8px 0" }}>
          <div class="loading-overlay"><div class="spinner" /> Loading decomposition candidates…</div>
        </div>
      </Show>
      <Show when={!loading() && entry() && "error" in entry()!}>
        <div class="error-banner">
          Failed to load decomposition candidates: {(entry() as { error: string }).error}
        </div>
      </Show>
      <Show when={current()}>
        {(data) => (
          <Show
            when={data().candidates.length > 0}
            fallback={
              <div style={{ padding: "8px 0", color: "var(--text-muted)", "font-size": "13px" }}>
                No decomposition candidates found for this table.
              </div>
            }
          >
            <table class="data-table" style={{ "font-size": "12px" }}>
              <thead>
                <tr>
                  <th>Columns</th>
                  <th>Similarity</th>
                  <th>Ritual support</th>
                  <th>Unenforced FKs</th>
                  <th>Coslice size</th>
                  <th>Score</th>
                  <th>Evidence paths</th>
                </tr>
              </thead>
              <tbody>
                <For each={data().candidates}>
                  {(c) => (
                    <tr>
                      <td>{c.columns.join(", ")}</td>
                      <td>{c.similarity.toFixed(3)}</td>
                      <td>{c.ritual_support}</td>
                      <td>{c.unenforced_fk_count}</td>
                      <td>{c.coslice_size}</td>
                      <td>{c.score !== null ? c.score.toFixed(3) : "–"}</td>
                      <td><EvidencePathsCell paths={c.paths} /></td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </Show>
        )}
      </Show>
    </>
  );
}
