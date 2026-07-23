// features/analysis/DecompositionCandidatesCore.tsx — Embeddable decomposition-
// candidates panel (Plan 153 D5): ranks candidate column-block splits for a
// table by co-update/FK/blast-radius evidence.
//
// Data flows through the tables feature's env/reducer (CLAUDE.md Rule 1/2),
// mirroring FootprintPanel.tsx — not a self-fetching component.
//
// EvidencePathsCell (below) is exported for reuse by FootprintPanel.tsx's
// blast-radius section (Plan 163 Phase 6) — same DecompositionEvidencePath
// shape, no need for a second tree renderer.
//
// Consolidation (2026-07-09): this is now the sole entry point for schema-
// normalization analysis on a table — the table-wide Column Affinity heat
// matrix + dendrogram render once here as an overview (previously their own
// standalone panel), and each candidate's own co-update ritual evidence
// renders inside its expandable row, scoped to just that candidate's 2-4
// columns rather than a whole-table cross join of every column pair (see
// RitualViolationsList below for why only violations are shown).

import { Show, Switch, Match, For, createMemo, createSignal, onMount } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type {
  DecompositionCandidate,
  DecompositionEvidencePath,
  SchemaObjectRef,
  AnalysisExplainerContent,
  CoUpdateRitual,
  FkColumnRef,
} from "@pb/platform";
import { EntityCard } from "@pb/platform";
import { TableChip } from "../../components/detail/TableChip.js";
import { HeatMatrix, DendrogramList, AFFINITY_EXAMPLE_COLUMNS, AFFINITY_EXAMPLE_MATRIX, AFFINITY_EXAMPLE_MERGES } from "./ColumnAffinityCore.js";

export interface DecompositionCandidatesCoreProps {
  store: Store<AppState, AppAction>;
  table: string;
  namespace?: string;
}

// Coslice sizes routinely reach 100+ statements (e.g. misth_final_ypal's
// {kodfinal,kodxrisi,kodypal} = 120) — the API intentionally returns every
// path (pinned by test_get_decomposition_candidates_zero_evidence_still_
// reports_real_coslice), so truncation belongs here, in the UI, not the
// response shape. The detail pane (below) has its own dedicated space, so
// it can afford a larger preview count than a table cell could.
const PATH_PREVIEW_COUNT = 15;

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
      <Match when={props.obj.kind === "dw_retrieve" && props.obj.object}>
        <EntityCard
          type="datawindow"
          name={props.obj.object!}
          onClick={() => props.store.dispatch({ tag: "datawindows", action: { tag: "select", name: props.obj.object! } })}
        />
      </Match>
    </Switch>
  );
}

// A path's legs chain from node to node (leg[i].to_object === leg[i+1].from_object),
// so the naive rendering — "from --kind--> to" per leg — repeats every shared
// midpoint twice. Flatten to the deduplicated node sequence instead: the
// target itself falls out naturally as one end of the chain (whichever end
// depends on direction), so it doesn't need to be shown separately either.
function pathChainNodes(p: DecompositionEvidencePath): SchemaObjectRef[] {
  if (p.legs.length === 0) return [p.target];
  return [p.legs[0]!.from_object, ...p.legs.map((leg) => leg.to_object)];
}

const LEG_KIND_TITLE: Record<string, string> = {
  reads: "read in this statement",
  writes: "written in this statement",
  retrieve: "retrieved via this DataWindow",
  fk: "linked by a foreign key",
};

function directionClass(direction: string): string {
  return direction === "forward" || direction === "backward" ? direction : "other";
}

// Stable identity string for a schema object, used to group/sort/compare
// nodes across paths — two SchemaObjectRef values describing the same
// column/statement/retrieve must hash to the same key regardless of which
// path produced them.
export function schemaObjectKey(obj: SchemaObjectRef): string {
  switch (obj.kind) {
    case "column":
      return `column:${obj.namespace ?? ""}.${obj.table ?? ""}.${obj.column ?? ""}`;
    case "sql":
      return `sql:${obj.object ?? ""}.${obj.proc_name ?? ""}:${obj.line ?? ""}`;
    case "dw_retrieve":
      return `dw_retrieve:${obj.object ?? ""}`;
    default:
      return `unknown:${obj.file ?? ""}`;
  }
}

// columnCoslice's "backward" paths (PB.Analysis.SchemaCategory.
// validationWalkBack) store legs walking from the target end toward the
// seed — the opposite orientation from "forward" paths, which walk seed ->
// target (see DuckDb.hs's appendDecompositionCoslice, which writes spLegs
// verbatim with no reordering). Rather than hard-code that direction
// convention here, use the path's own `target` field (always the non-seed
// endpoint) to detect which end of the raw chain needs flipping — a forest
// should always branch outward from the seed, regardless of direction.
function seedRootedChain(p: DecompositionEvidencePath): { nodes: SchemaObjectRef[]; legKinds: string[] } {
  const nodes = pathChainNodes(p);
  const legKinds = p.legs.map((leg) => leg.leg_kind);
  const targetKey = schemaObjectKey(p.target);
  const endsAtTarget = nodes.length > 0 && schemaObjectKey(nodes[nodes.length - 1]!) === targetKey;
  if (endsAtTarget) return { nodes, legKinds };
  return { nodes: [...nodes].reverse(), legKinds: [...legKinds].reverse() };
}

function commonPrefixLen(a: string[], b: string[]): number {
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  return i;
}

export interface TreeRow {
  depth: number;
  node: SchemaObjectRef;
  legKind: string | null;
  isTarget: boolean;
}

export interface PathTree {
  direction: string;
  rootNode: SchemaObjectRef;
  pathCount: number;
  rows: TreeRow[];
}

// Evidence paths from columnCoslice are a union of shortest paths radiating
// outward from each candidate column, so dozens of them routinely share a
// long common prefix (same seed -> same intermediate statement, diverging
// only near the target). Group into a forest — one tree per (direction,
// seed) pair — and compress each tree's paths like `tree`/sorted-directory
// output: sort by node-key chain so shared prefixes sit adjacent, then walk
// the sorted list rendering only each path's suffix past the longest common
// prefix with the previous path.
export function buildPathForest(paths: DecompositionEvidencePath[]): PathTree[] {
  const groupOrder: string[] = [];
  const groups = new Map<string, DecompositionEvidencePath[]>();
  for (const p of paths) {
    const { nodes } = seedRootedChain(p);
    const groupKey = `${p.direction} ${schemaObjectKey(nodes[0]!)}`;
    if (!groups.has(groupKey)) {
      groups.set(groupKey, []);
      groupOrder.push(groupKey);
    }
    groups.get(groupKey)!.push(p);
  }

  return groupOrder.map((groupKey) => {
    const groupPaths = groups.get(groupKey)!;
    const chains = groupPaths.map((p) => {
      const { nodes, legKinds } = seedRootedChain(p);
      return { nodes, legKinds, keys: nodes.map(schemaObjectKey) };
    });
    const sorted = [...chains].sort((a, b) => {
      const ak = a.keys.join("");
      const bk = b.keys.join("");
      return ak < bk ? -1 : ak > bk ? 1 : 0;
    });

    const rows: TreeRow[] = [];
    let prevKeys: string[] = [];
    for (const c of sorted) {
      const start = commonPrefixLen(prevKeys, c.keys);
      for (let i = start; i < c.nodes.length; i++) {
        rows.push({
          depth: i,
          node: c.nodes[i]!,
          legKind: i > 0 ? c.legKinds[i - 1]! : null,
          isTarget: i === c.nodes.length - 1,
        });
      }
      prevKeys = c.keys;
    }

    return {
      direction: groupPaths[0]!.direction,
      rootNode: sorted[0]!.nodes[0]!,
      pathCount: groupPaths.length,
      rows,
    };
  });
}

export function EvidencePathsCell(props: { paths: DecompositionEvidencePath[]; store: Store<AppState, AppAction> }): JSX.Element {
  const [expanded, setExpanded] = createSignal(false);
  const visible = createMemo(() => (expanded() ? props.paths : props.paths.slice(0, PATH_PREVIEW_COUNT)));
  const forest = createMemo(() => buildPathForest(visible()));

  return (
    <Show when={props.paths.length > 0} fallback={<span style={{ color: "var(--text-muted)" }}>None</span>}>
      <div class="decomp-forest">
        <For each={forest()}>
          {(tree) => (
            <div class="decomp-tree">
              <div class="decomp-tree-header">
                <span class={`decomp-dir-badge decomp-dir-${directionClass(tree.direction)}`}>{tree.direction}</span>
                <span class="decomp-tree-count">
                  {tree.pathCount} path{tree.pathCount === 1 ? "" : "s"} from
                </span>
                <SchemaObjectRefLink obj={tree.rootNode} store={props.store} />
              </div>
              <div class="decomp-tree-rows">
                <For each={tree.rows.filter((r) => r.depth > 0 || r.isTarget)}>
                  {(row) => (
                    <div
                      class="decomp-tree-row"
                      classList={{ "decomp-tree-row-target": row.isTarget }}
                      style={{ "padding-left": `${row.depth * 14}px` }}
                    >
                      <Show when={row.legKind}>
                        <span
                          class={`decomp-leg-badge decomp-leg-${row.legKind}`}
                          title={LEG_KIND_TITLE[row.legKind!] ?? row.legKind!}
                        >
                          {row.legKind}
                        </span>
                      </Show>
                      <SchemaObjectRefLink obj={row.node} store={props.store} />
                    </div>
                  )}
                </For>
              </div>
            </div>
          )}
        </For>
      </div>
      <Show when={props.paths.length > PATH_PREVIEW_COUNT}>
        <button type="button" class="link-btn" style={{ "font-size": "11px", "margin-top": "6px" }} onClick={() => setExpanded((v) => !v)}>
          {expanded() ? "Show less" : `Show ${props.paths.length - PATH_PREVIEW_COUNT} more`}
        </button>
      </Show>
    </Show>
  );
}

function refLabel(col: FkColumnRef): string {
  return `${col.namespace ? `${col.namespace}.` : ""}${col.table}.${col.column}`;
}

// Every ritual pair reaching this component already has at least one
// violation — get_decomposition_candidates (schema.py) filters the routine
// "always written together, no exceptions" pairs out before returning
// ritual_pairs, since those just restate what the affinity heatmap above
// already shows visually. What's left is the actionable case: a statement
// that broke an established co-write convention by writing one column of
// the pair but not the other.
function RitualViolationsList(props: { pairs: CoUpdateRitual[] }): JSX.Element {
  return (
    <div style={{ "margin-top": "12px" }}>
      <div style={{ "font-weight": 600, "font-size": "12px", "margin-bottom": "6px" }}>
        Co-update rule violations
      </div>
      <table class="data-table" style={{ "font-size": "12px" }}>
        <thead><tr><th>Column A</th><th>Column B</th><th>Co-write support</th><th>Violations</th></tr></thead>
        <tbody>
          <For each={props.pairs}>
            {(ritual) => (
              <tr>
                <td style={{ padding: "4px 8px" }}>{refLabel(ritual.column_a)}</td>
                <td style={{ padding: "4px 8px" }}>{refLabel(ritual.column_b)}</td>
                <td>{ritual.co_write_support}</td>
                <td>
                  <ul style={{ margin: "0", "padding-left": "16px" }}>
                    <For each={ritual.violations}>
                      {(v) => (
                        <li>
                          {v.object}.{v.proc_name} (line {v.line}) wrote only {refLabel(v.written_column)}
                        </li>
                      )}
                    </For>
                  </ul>
                </td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
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

// Synthetic violation example (no store, no API) — teaches the one concept
// this panel's own ritual evidence otherwise never demonstrates in real
// data: this corpus (see doc/plan/153's D1 retrospective) has never found a
// single co-update violation, so a real screenshot could only ever show an
// empty list. of_save_name_only writes `name` without its usual partner
// `email` — that's what breaks an established co-write convention.
const RITUAL_VIOLATION_EXAMPLE: CoUpdateRitual = {
  column_a: { namespace: null, table: "employee", column: "name" },
  column_b: { namespace: null, table: "employee", column: "email" },
  co_write_support: 4,
  violations: [
    {
      file: "u_profile.srw",
      object: "w_profile_edit",
      proc_name: "of_save_name_only",
      line: 88,
      written_column: { namespace: null, table: "employee", column: "name" },
    },
  ],
};

// Consolidates what used to be two separate explainers (Column Affinity's
// own, and this one) into a single walkthrough — Column Affinity is no
// longer a standalone panel, it's the overview at the top of this one, and
// co-update rituals are evidence nested inside each candidate row, not a
// panel of their own. Continues the employee(name, email, salary,
// hire_date, dept_id) example throughout (Plan 156 rollout, merged further
// 2026-07-09) rather than inventing a new one per section.
export const DECOMPOSITION_EXPLAINER: AnalysisExplainerContent = {
  title: "Decomposition Candidates",
  whatItIs:
    "A ranked, multi-signal verdict for whether a table should be split in " +
    "two. The overview at the top is a heat matrix of how often each pair " +
    "of columns is touched together by the same SQL statement or " +
    "DataWindow retrieve, plus a dendrogram clustering columns that " +
    "co-occur — columns merging together at high similarity are almost " +
    "always read or written in the same breath. Each ranked candidate " +
    "below is one of those clusters, scored by combining that similarity " +
    "with co-update rituals (do the columns change together row by row, " +
    "not just in the same statement type?), unenforced foreign-key " +
    "evidence, and the coslice size (a math term for 'blast radius' — " +
    "every SQL statement or DataWindow retrieve you'd have to touch, found " +
    "by following column reads/writes and FK edges outward from these " +
    "columns) that would need to change if the split actually happened.",
  howItsUsed:
    "Each row is one candidate split. Columns is the block that clusters " +
    "together in the heat matrix above; Similarity mirrors that " +
    "dendrogram's merge height; Ritual support and Unenforced FKs are " +
    "independent evidence the two halves are really separate entities " +
    "today, not just habitually queried together; Coslice size (the blast " +
    "radius above) is the cost of acting on the recommendation; Score " +
    "folds all of it into one ranking. Click a row to expand its evidence " +
    "— the blast-radius paths, and, only when one exists, a co-update rule " +
    "violation: a statement that wrote one column of an established pair " +
    "without its usual partner (see the example below). A pair with no " +
    "violations means its columns are, without exception, always written " +
    "together — which the heat matrix above already shows, so nothing " +
    "further is listed for it.",
  tips: [
    "The number in each heat-matrix cell is a statement count, not a row count — a high count means many statements touch both columns, not that many rows share a value.",
    "A cluster that merges early (high similarity) and stays separate from the rest of the table in the dendrogram is the strongest split signal.",
    "High similarity with zero ritual support and zero unenforced FKs is weaker evidence than the same similarity backed by both — the extra signals rule out 'just happens to be queried together'.",
    "Score is null, not zero, when there isn't enough evidence to combine the signals confidently — read it as 'unscored', not 'bad'.",
    "Coslice size (the blast radius — see 'What it is' above) routinely reaches 100+ for tables with many downstream FK dependents — a bigger number means a bigger migration, not necessarily a bad split.",
    "Unenforced FK evidence needs a loaded DDL catalog (--ddl) to mean anything; with none loaded every candidate reports 0 unenforced FKs, which reads as 'no evidence' rather than 'nothing found'.",
    "A ritual violation is a real anomaly, not routine output — most tables will never show one, and that's the expected, healthy case, not a sign the feature found nothing.",
  ],
  example: () => (
    <>
      <p style={{ margin: "0 0 8px", "font-size": "12px", color: "var(--text-muted)" }}>
        Sample <code>employee(name, email, salary, hire_date, dept_id)</code> — a profile-edit form always reads/writes {"{name, email}"} together, payroll always touches {"{salary, hire_date}"} together, and dept_id is touched independently of both:
      </p>
      <HeatMatrix columns={AFFINITY_EXAMPLE_COLUMNS} matrix={AFFINITY_EXAMPLE_MATRIX} />
      <DendrogramList merges={AFFINITY_EXAMPLE_MERGES.slice(0, 1)} />
      <p style={{ margin: "10px 0 0", "font-size": "12px", color: "var(--text-muted)" }}>
        The {"{name, email}"} cluster that merged early above also has corroborating ritual and FK evidence, so it ranks as a candidate:
      </p>
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
      <p style={{ margin: "10px 0 0", "font-size": "12px", color: "var(--text-muted)" }}>
        Ritual support of 4 means 4 statements write both columns together. One of those statements broke that pattern — expanding the row's evidence would show:
      </p>
      <RitualViolationsList pairs={[RITUAL_VIOLATION_EXAMPLE]} />
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

// Finder-style expandable rows: each candidate is a normal scoring row in a
// single table; clicking it toggles a full-width evidence row directly
// beneath it (colspan across every column). Replaces an earlier side-by-side
// master/detail split (Plan 158) that had three usability problems in real
// use: the detail pane fell out of view once you'd scrolled deep into a long
// candidate list, its hover-preview meant the mouse path from a master row
// to the detail pane could clip other rows and flicker the preview
// mid-transit, and its fixed 360px height was often too small for the
// largest coslices (285+ legs in the real corpus). Rows expand
// independently (not accordion-exclusive) so two candidates' evidence can be
// compared without losing either. Defaults to the top-ranked candidate
// expanded so evidence is never empty on load.
export function DecompositionCandidatesTable(props: {
  candidates: DecompositionCandidate[];
  store: Store<AppState, AppAction>;
}): JSX.Element {
  const [expanded, setExpanded] = createSignal<ReadonlySet<number>>(
    new Set(props.candidates.length > 0 ? [0] : []),
  );

  function toggleRow(i: number): void {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(i)) next.delete(i);
      else next.add(i);
      return next;
    });
  }

  return (
    <div class="decomp-table-wrap" style={{ "overflow-x": "auto" }}>
      <table class="data-table" style={{ "font-size": "12px", "table-layout": "fixed", width: "100%" }}>
        <colgroup>
          <col style={{ width: "34%" }} />
          <col style={{ width: "14%" }} />
          <col style={{ width: "16%" }} />
          <col style={{ width: "14%" }} />
          <col style={{ width: "12%" }} />
          <col style={{ width: "10%" }} />
        </colgroup>
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
          <For each={props.candidates}>
            {(c, i) => (
              <>
                <tr
                  class="decomp-row"
                  classList={{ "decomp-row-active": expanded().has(i()) }}
                  style={{ cursor: "pointer", background: expanded().has(i()) ? "var(--bg-hover)" : undefined }}
                  onClick={() => toggleRow(i())}
                >
                  <td
                    style={{ overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap" }}
                    title={c.columns.join(", ")}
                  >
                    {c.columns.join(", ")}
                  </td>
                  <td>{c.similarity.toFixed(3)}</td>
                  <td>{c.ritual_support}</td>
                  <td>{c.unenforced_fk_count}</td>
                  <td>{c.coslice_size}</td>
                  <td>{c.score !== null ? c.score.toFixed(3) : "–"}</td>
                </tr>
                <Show when={expanded().has(i())}>
                  <tr class="decomp-evidence-row">
                    <td colspan="6" style={{ padding: "10px 12px", "border-top": "1px solid var(--border)" }}>
                      <div style={{ "font-weight": 600, "font-size": "12px", "margin-bottom": "6px" }}>
                        Evidence for {c.columns.join(", ")}
                      </div>
                      <div style={{ "max-height": "min(60vh, 520px)", "overflow-y": "auto" }}>
                        <EvidencePathsCell paths={c.paths} store={props.store} />
                        <Show when={c.ritual_pairs.length > 0}>
                          <RitualViolationsList pairs={c.ritual_pairs} />
                        </Show>
                      </div>
                    </td>
                  </tr>
                </Show>
              </>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

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
          <>
            <Show when={data().affinity.columns.length > 0}>
              <div style={{ "margin-bottom": "16px" }}>
                <div style={{ "font-weight": 600, "font-size": "12px", "margin-bottom": "6px" }}>
                  Column Affinity (overview)
                </div>
                <HeatMatrix columns={data().affinity.columns} matrix={data().affinity.co_access_matrix} />
                <DendrogramList merges={data().affinity.dendrogram} />
              </div>
            </Show>
            <Show
              when={data().candidates.length > 0}
              fallback={
                <div style={{ padding: "8px 0", color: "var(--text-muted)", "font-size": "13px" }}>
                  No decomposition candidates found for this table.
                </div>
              }
            >
              <DecompositionCandidatesTable candidates={data().candidates} store={props.store} />
            </Show>
          </>
        )}
      </Show>
    </>
  );
}
