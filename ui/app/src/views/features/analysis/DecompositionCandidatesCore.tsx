// features/analysis/DecompositionCandidatesCore.tsx — Embeddable decomposition-
// candidates panel (Plan 153 D5): ranks candidate column-block splits for a
// table by co-update/FK/blast-radius evidence.
//
// Data flows through the tables feature's env/reducer (CLAUDE.md Rule 1/2),
// mirroring ProcedureFootprintCore.tsx — not a self-fetching component.

import { Show, Switch, Match, For, createMemo, createSignal, onMount } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { DecompositionEvidencePath, SchemaObjectRef, AnalysisExplainerContent } from "@pb/platform";
import { EntityCard } from "@pb/platform";
import { TableChip } from "../../components/detail/TableChip.js";
import { DendrogramList, AFFINITY_EXAMPLE_MERGES } from "./ColumnAffinityCore.js";

export interface DecompositionCandidatesCoreProps {
  store: Store<AppState, AppAction>;
  table: string;
  namespace?: string;
}

// Coslice sizes routinely reach 100+ statements (e.g. misth_final_ypal's
// {kodfinal,kodxrisi,kodypal} = 120) — the API intentionally returns every
// path (pinned by test_get_decomposition_candidates_zero_evidence_still_
// reports_real_coslice), so truncation belongs here, in the UI, not the
// response shape.
const PATH_PREVIEW_COUNT = 5;

// Renders a SchemaObjectRef as a real clickable entity rather than a
// formatted label: column -> TableChip + ".column", sql -> EntityCard
// navigating to that procedure, dw_retrieve -> EntityCard navigating to
// that DataWindow (Plan 153 D5 follow-up).
function SchemaObjectRefLink(props: { obj: SchemaObjectRef; store: Store<AppState, AppAction> }): JSX.Element {
  return (
    <Switch fallback={<span>{props.obj.kind}</span>}>
      <Match when={props.obj.kind === "column" && props.obj.table}>
        <TableChip name={props.obj.table!} store={props.store} size="sm" />
        <span>.{props.obj.column}</span>
      </Match>
      <Match when={props.obj.kind === "sql" && props.obj.object && props.obj.proc_name}>
        <EntityCard
          type="procedure"
          name={`${props.obj.object}.${props.obj.proc_name}`}
          context={props.obj.line != null ? `line ${props.obj.line}` : undefined}
          onClick={() => props.store.dispatch({
            tag: "objects",
            action: { tag: "proc-select", objectName: props.obj.object!, procName: props.obj.proc_name! },
          })}
        />
      </Match>
      <Match when={props.obj.kind === "dw_retrieve" && props.obj.dw_name}>
        <EntityCard
          type="datawindow"
          name={props.obj.dw_name!}
          onClick={() => props.store.dispatch({ tag: "datawindows", action: { tag: "select", name: props.obj.dw_name! } })}
        />
      </Match>
    </Switch>
  );
}

function EvidencePathsCell(props: { paths: DecompositionEvidencePath[]; store: Store<AppState, AppAction> }): JSX.Element {
  const [expanded, setExpanded] = createSignal(false);
  const visible = createMemo(() => (expanded() ? props.paths : props.paths.slice(0, PATH_PREVIEW_COUNT)));

  return (
    <Show when={props.paths.length > 0} fallback={<span style={{ color: "var(--text-muted)" }}>None</span>}>
      <ul style={{ margin: "0", "padding-left": "16px", "list-style": "none" }}>
        <For each={visible()}>
          {(p) => (
            <li style={{ display: "flex", "align-items": "center", gap: "4px", "flex-wrap": "wrap", "margin-bottom": "2px" }}>
              <SchemaObjectRefLink obj={p.target} store={props.store} /> <span style={{ color: "var(--text-muted)" }}>({p.direction})</span>
              <For each={p.legs}>
                {(leg) => (
                  <>
                    <span style={{ color: "var(--text-muted)" }}>·</span>
                    <SchemaObjectRefLink obj={leg.from_object} store={props.store} />
                    <span style={{ color: "var(--text-muted)" }}>--{leg.leg_kind}--&gt;</span>
                    <SchemaObjectRefLink obj={leg.to_object} store={props.store} />
                  </>
                )}
              </For>
            </li>
          )}
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

// A minimal "table shape" box for the before/after split payoff below — not
// the real TableChip (which navigates a live store), just enough visual
// structure to show what "split into two tables" means concretely.
function SchemaBox(props: { name: string; columns: string[] }): JSX.Element {
  return (
    <div style={{ border: "1px solid var(--border)", "border-radius": "6px", padding: "8px 10px", "min-width": "170px" }}>
      <div style={{ "font-weight": 600, "font-size": "12px" }}>{props.name}</div>
      <div style={{ color: "var(--text-muted)", "font-size": "11px" }}>{props.columns.join(", ")}</div>
    </div>
  );
}

// Continues Column Affinity's employee(name, email, salary, hire_date,
// dept_id) example (Plan 156 rollout) rather than inventing a second one —
// the {name, email} cluster that merges early there is the same candidate
// scored here, now with corroborating ritual/FK evidence and the concrete
// before/after split it implies.
export const DECOMPOSITION_EXPLAINER: AnalysisExplainerContent = {
  title: "Decomposition Candidates",
  whatItIs:
    "A ranked, multi-signal verdict for whether a table should be split in " +
    "two. It combines the same column co-access affinity behind Column " +
    "Affinity with co-update rituals (do the columns change together row " +
    "by row, not just in the same statement?), unenforced foreign-key " +
    "evidence, and the coslice size (a math term for 'blast radius' — " +
    "every SQL statement or DataWindow retrieve you'd have to touch, found " +
    "by following column reads/writes and FK edges outward from these " +
    "columns) that would need to change if the split actually happened.",
  howItsUsed:
    "Each row is one candidate split. Columns is the block that clusters " +
    "together; Similarity mirrors the Column Affinity dendrogram's merge " +
    "height; Ritual support and Unenforced FKs are independent evidence " +
    "the two halves are really separate entities today, not just " +
    "habitually queried together; Coslice size (the blast radius above) " +
    "is the cost of acting on the recommendation; Score folds all of it " +
    "into one ranking. This panel is downstream of Column Affinity — open " +
    "that panel's own explainer to see how the underlying matrix and " +
    "dendrogram are built.",
  tips: [
    "High similarity with zero ritual support and zero unenforced FKs is weaker evidence than the same similarity backed by both — the extra signals rule out 'just happens to be queried together'.",
    "Score is null, not zero, when there isn't enough evidence to combine the signals confidently — read it as 'unscored', not 'bad'.",
    "Coslice size (the blast radius — see 'What it is' above) routinely reaches 100+ for tables with many downstream FK dependents — a bigger number means a bigger migration, not necessarily a bad split.",
    "Unenforced FK evidence needs a loaded DDL catalog (--ddl) to mean anything; with none loaded every candidate reports 0 unenforced FKs, which reads as 'no evidence' rather than 'nothing found'.",
  ],
  example: () => (
    <>
      <p style={{ margin: "0 0 8px", "font-size": "12px", color: "var(--text-muted)" }}>
        Continuing the <code>employee(name, email, salary, hire_date, dept_id)</code> example from Column Affinity — the {"{name, email}"} cluster that merged early there also has corroborating ritual and FK evidence:
      </p>
      <DendrogramList merges={AFFINITY_EXAMPLE_MERGES.slice(0, 1)} />
      <table class="data-table" style={{ "font-size": "12px", margin: "10px 0" }}>
        <thead>
          <tr>
            <th>Columns</th>
            <th>Similarity</th>
            <th>Ritual support</th>
            <th>Unenforced FKs</th>
            <th>Coslice size</th>
            <th>Score</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>name, email</td>
            <td>0.930</td>
            <td>4</td>
            <td>1</td>
            <td>6</td>
            <td>0.810</td>
          </tr>
        </tbody>
      </table>
      <p style={{ margin: "8px 0", "font-size": "12px", color: "var(--text-muted)" }}>
        Score 0.81 says: split it. Here's what that split looks like —
      </p>
      <div style={{ display: "flex", "align-items": "center", gap: "12px", "flex-wrap": "wrap" }}>
        <SchemaBox name="employee" columns={["name", "email", "salary", "hire_date", "dept_id"]} />
        <span style={{ "font-size": "16px", color: "var(--text-muted)" }}>→</span>
        <div style={{ display: "flex", "flex-direction": "column", gap: "6px" }}>
          <SchemaBox name="employee" columns={["employee_id (PK)", "salary", "hire_date", "dept_id"]} />
          <SchemaBox name="employee_profile" columns={["employee_id (FK)", "name", "email"]} />
        </div>
      </div>
    </>
  ),
};

export function DecompositionCandidatesCore(props: DecompositionCandidatesCoreProps): JSX.Element {
  const snap = props.store.getState();

  onMount(() => {
    props.store.dispatch({
      tag: "tables",
      action: { tag: "decomposition-candidates-load", tableName: props.table, namespace: props.namespace },
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
                      <td><EvidencePathsCell paths={c.paths} store={props.store} /></td>
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
