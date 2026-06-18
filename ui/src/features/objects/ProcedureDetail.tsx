// ProcedureDetail.tsx — Unified procedure detail: Source/Analysis faces.

import { Show, For, createEffect } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { ProcedureDetailResponse } from "../../types/api.js";
import { CodeBlock } from "../../components/detail/CodeBlock.js";
import { Loading } from "../../components/ui/Loading.js";
import { PhaseGateInline } from "../../components/ui/PhaseGate.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import { SqlStatementCard } from "../../components/detail/SqlStatementCard.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";
import { procBadge } from "../../utils/format.js";

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
        phaseLabel="P1"
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
          <div style={{ "margin-bottom": "12px" }}>
            <EntityCard
              type="object"
              name={props.objectName}
              context="containing object"
              tooltip={`Navigate to ${props.objectName}`}
              onClick={() => store.dispatch({ tag: "objects", action: { tag: "select", name: props.objectName } })}
            />
          </div>
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
                  <CodeBlock code={p.source_original!} baseLine={p.start_line ?? 1} />
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
              type: "object" as const,
              name: caller.object,
              context: caller.proc,
              tooltip: `${caller.object}.${caller.proc}`,
              onClick: () => store.dispatch({ tag: "objects", action: { tag: "select", name: caller.object } }),
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

          <PhaseGateInline phase={2} section="Control Flow Graph" label="requires typing pass"
            description="The CFG diagram for this procedure is available after a P2 typing pass." />
          <PhaseGateInline phase={3} section="Taint Paths" label="requires taint analysis"
            description="Taint flow through this procedure's parameters is available after a P3 taint analysis run." />
          <PhaseGateInline phase={4} section="Formal Properties" label="requires formal verification"
            description="Pre/post-condition proofs and invariant certificates require P4 formal verification infrastructure." />
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
