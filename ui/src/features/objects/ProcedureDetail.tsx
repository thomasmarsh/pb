// ProcedureDetail.tsx — Unified procedure detail: Source/Analysis faces.

import { Show, For, createEffect, createResource } from "solid-js";
import { ArrowRight } from "../../utils/icons.js";
import { Tabs } from "@kobalte/core/tabs";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { ProcedureDetailResponse, TaintPathsResponse, TaintPathSummary } from "../../types/api.js";
import { CodeBlock } from "../../components/detail/CodeBlock.js";
import { Loading } from "../../components/ui/Loading.js";
import { SqlStatementCard } from "../../components/detail/SqlStatementCard.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";
import { procBadge } from "../../utils/format.js";

const SEVERITY_ORDER: Record<string, number> = { critical: 0, high: 1, medium: 2, low: 3 };

function ProcTaintCard(props: {
  objectName: string;
  procName: string;
  store: Store<AppState, AppAction>;
}): import("solid-js").JSX.Element {
  const key = () => `${props.objectName}::${props.procName}`;
  const [data] = createResource(key, async (): Promise<TaintPathsResponse> => {
    const params = new URLSearchParams({
      object_name: props.objectName,
      proc_name: props.procName,
      limit: "10",
    });
    const res = await fetch("/api/analysis/taint-paths?" + params.toString());
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<TaintPathsResponse>;
  });

  const sorted = (): TaintPathSummary[] =>
    [...(data()?.paths ?? [])].sort(
      (a, b) => (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9),
    );

  function openPath(id: number): void {
    props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintPathView", pathId: id } } });
  }

  return (
    <div class="card">
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px" }}>
        <h3 style={{ flex: 1 }}>Taint Paths</h3>
        <Show when={(data()?.total ?? 0) > 0}>
          <button
            class="filter-pill active"
            style={{ "font-size": "12px", padding: "3px 10px" }}
            onClick={() => props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "taintExplorer" } } })}
          >
            Taint Explorer ↗
          </button>
        </Show>
      </div>
      <Show when={data.loading}><Loading /></Show>
      <Show when={data.error}>
        <div class="error-banner">Failed to load taint paths: {String(data.error)}</div>
      </Show>
      <Show when={!data.loading && !data.error && data()}>
        <Show
          when={sorted().length > 0}
          fallback={
            <div style={{ padding: "8px 0", color: "var(--text-muted)", "font-size": "13px" }}>
              No taint paths found through this procedure.
            </div>
          }
        >
          <table class="data-table" style={{ "font-size": "12px" }}>
            <thead>
              <tr>
                <th>Severity</th>
                <th>Category</th>
                <th>Source</th>
                <th>Sink</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <For each={sorted()}>
                {(path) => (
                  <tr class="clickable" onClick={() => openPath(path.id)}>
                    <td><span class={`badge badge-severity-${path.severity}`}>{path.severity}</span></td>
                    <td>{path.category}</td>
                    <td style={{ "font-size": "11px" }}>{path.source.object}.{path.source.proc}</td>
                    <td style={{ "font-size": "11px" }}>{path.sink.object}.{path.sink.proc}</td>
                    <td><span class="trace-nav-link">View <ArrowRight size={12} style={{ "vertical-align": "middle" }} /></span></td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
          <Show when={(data()?.total ?? 0) > 10}>
            <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-top": "6px" }}>
              Showing 10 of {data()!.total} paths.
            </div>
          </Show>
        </Show>
      </Show>
    </div>
  );
}

function ProcedureDetailContent(props: {
  p: ProcedureDetailResponse;
  store: Store<AppState, AppAction>;
  objectName: string;
  procKey: string;
}) {
  const { p, store, procKey } = props;
  const snap = store.getState();
  const face = () => snap().objects.procFace;
  const bc = procBadge(p.proc_type);

  let scrollEl: HTMLDivElement | undefined;

  createEffect(() => {
    const pos = snap().objects.procScrollPos[procKey];
    if (!pos || !scrollEl) return;
    scrollEl.scrollTop = face() === "source" ? pos.source : pos.analysis;
  });

  const subtitle = (
    <div style={{ "font-size": "12px", color: "var(--text-muted)" }}>
      {p.modifiers && <span>{p.modifiers} </span>}
      {p.params && <span>({p.params}) </span>}
      {p.return_type && <span>returns {p.return_type} </span>}
      {p.cyclomatic != null && (
        <span class="badge badge-cc" style={{ "margin-left": "8px" }}>CC: {p.cyclomatic}</span>
      )}
    </div>
  );

  return (
    <>
      <DetailHeader
        name={`${p.object}.`}
        badgeClass={`badge-${bc}`}
        badgeLabel={p.proc_type}
        face={face()}
        store={store}
        onToggle={(newFace, scrollTop) => {
          store.dispatch({ tag: "objects", action: { tag: "set-proc-face", key: procKey, face: newFace, scrollTop } });
        }}
        scrollAreaRef={() => scrollEl}
        subtitle={
          <>
            <span style={{ color: "var(--accent)" }}>{p.name}</span>{" "}
            {subtitle}
          </>
        }
      />

      <div class="detail-body" ref={scrollEl}>
        <Show when={face() === "source"}>
          <Show when={p.source_original || p.source_rendered}>
            <Tabs defaultValue={p.source_original ? "original" : "rendered"}>
              <Tabs.List class="tab-bar">
                <Show when={p.source_original}>
                  <Tabs.Trigger value="original" class="tab-btn">Original Source</Tabs.Trigger>
                </Show>
                <Show when={p.source_rendered}>
                  <Tabs.Trigger value="rendered" class="tab-btn">Rendered</Tabs.Trigger>
                </Show>
              </Tabs.List>
              <Show when={p.source_original}>
                <Tabs.Content value="original">
                  <CodeBlock
                    code={p.source_original!}
                    baseLine={p.start_line ?? 1}
                    onLineClick={(line) =>
                      store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "sliceView", object: props.objectName, proc: p.name, line, direction: "backward" } } })
                    }
                  />
                  <Show when={p.file}>
                    <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-top": "8px" }}>
                      {p.file}:{p.start_line ?? ""}–{p.end_line ?? ""}
                    </div>
                  </Show>
                </Tabs.Content>
              </Show>
              <Show when={p.source_rendered}>
                <Tabs.Content value="rendered">
                  <CodeBlock code={p.source_rendered} baseLine={p.start_line ?? 1} />
                </Tabs.Content>
              </Show>
            </Tabs>
          </Show>
        </Show>

        <Show when={face() === "analysis"}>
          <EntityListCard
            title="Callers"
            items={(p.callers ?? []).map((caller) => ({
              type: "procedure" as const,
              name: caller.proc,
              context: caller.object,
              tooltip: `${caller.object}.${caller.proc}`,
              onClick: () => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: caller.object, procName: caller.proc } }),
            }))}
            emptyText="No callers found."
          />

          <Show when={(p.callees?.length ?? 0) > 0}>
            <EntityListCard
              title="Callees"
              count={p.callees!.length}
              items={p.callees!.map((callee) => ({
                type: "procedure" as const,
                name: callee,
                onClick: () => {
                  const dotIdx = callee.indexOf(".");
                  if (dotIdx > 0) {
                    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: callee.slice(0, dotIdx), procName: callee.slice(dotIdx + 1) } });
                  } else {
                    store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: p.object, procName: callee } });
                  }
                },
              }))}
            />
          </Show>

          <Show when={(p.sql_statements?.length ?? 0) > 0}>
            <div class="card">
              <div class="card-header"><h3>SQL Statements ({p.sql_statements!.length})</h3></div>
              <div class="sql-tab-body">
                <For each={p.sql_statements!}>
                  {(stmt) => <SqlStatementCard stmt={stmt} store={store} />}
                </For>
              </div>
            </div>
          </Show>

          <div class="card">
            <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "10px" }}>
              <h3 style={{ flex: 1 }}>Control Flow Graph</h3>
              <button
                class="filter-pill active"
                style={{ "font-size": "12px", padding: "3px 10px" }}
                onClick={() => store.dispatch({
                  tag: "nav",
                  action: { tag: "navigate", route: { view: "cfgDiagram", object: props.objectName, proc: p.name } },
                })}
              >
                View CFG ↗
              </button>
            </div>
          </div>
          <ProcTaintCard objectName={props.objectName} procName={p.name} store={store} />
        </Show>
      </div>
    </>
  );
}

export function ProcedureDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const proc = () => snap().objects.procedureDetail;
  const objectName = () => {
    const r = snap().nav.route;
    return r.view === "procedureDetail" ? r.name : "";
  };
  const procName = () => {
    const r = snap().nav.route;
    return r.view === "procedureDetail" ? r.proc : "";
  };
  const procKey = () => `${objectName()}:${procName()}`;

  return (
    <>
      <BackButton
        label={objectName()}
        onClick={() => store.dispatch({ tag: "objects", action: { tag: "select", name: objectName() } })}
      />
      <Show when={proc()} fallback={<Loading />}>
        {(entry) => {
          if ("error" in entry()) {
            return (
              <div class="card">
                <p style={{ color: "var(--red)" }}>Error: {(entry() as { error: string }).error}</p>
              </div>
            );
          }
          const p = entry() as ProcedureDetailResponse;
          return (
            <ProcedureDetailContent
              p={p}
              store={store}
              objectName={objectName()}
              procKey={procKey()}
            />
          );
        }}
      </Show>
    </>
  );
}
