// ProcedureDetail.tsx — Unified procedure detail: Source/Analysis faces.

import { Show, For, createEffect } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ProcedureDetailResponse } from "../../types/api.js";
import { CodeBlock } from "../../components/CodeBlock.js";
import { Loading } from "../../components/Loading.js";
import { FaceToggle } from "../../components/FaceToggle.js";
import { PhaseGateInline } from "../../components/PhaseGate.js";
import { EntityCard } from "../../components/EntityCard.js";
import { SqlStatementCard } from "../../components/SqlStatementCard.js";
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

  const hasCallers = (p.callers?.length ?? 0) > 0;
  const hasCallees = (p.callees?.length ?? 0) > 0;
  const hasSql = (p.sql_statements?.length ?? 0) > 0;

  return (
    <>
      <div class="detail-header">
        <div>
          <h2 style={{ "margin": "0 0 4px 0", "font-size": "18px" }}>
            {p.object}.<span style={{ color: "var(--accent)" }}>{p.name}</span>{" "}
            <span class={`badge badge-${bc}`}>{p.proc_type}</span>
          </h2>
          <div style={{ "font-size": "12px", color: "var(--text-muted)" }}>
            {p.modifiers && <span>{p.modifiers} </span>}
            {p.params && <span>({p.params}) </span>}
            {p.return_type && <span>returns {p.return_type} </span>}
            {p.cyclomatic != null && (
              <span class="badge badge-cc" style={{ "margin-left": "8px" }}>CC: {p.cyclomatic}</span>
            )}
          </div>
        </div>
        <FaceToggle
          face={face()}
          phaseLabel="P1"
          onToggle={(newFace, scrollTop) => {
            store.dispatch({ tag: "objects", action: { type: "set-proc-face", key: procKey, face: newFace, scrollTop } });
          }}
          scrollAreaRef={() => scrollEl}
        />
      </div>

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
          {/* Callers */}
          <div class="card">
            <div class="card-header"><h3>Callers</h3></div>
            <Show
              when={hasCallers}
              fallback={<p class="muted-note">No callers found.</p>}
            >
              <div class="entity-card-list">
                <For each={p.callers!}>
                  {(caller) => (
                    <EntityCard
                      type="object"
                      name={caller.object}
                      context={caller.proc}
                      tooltip={`${caller.object}.${caller.proc}`}
                      onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: caller.object } })}
                    />
                  )}
                </For>
              </div>
            </Show>
          </div>

          {/* Callees */}
          <Show when={hasCallees}>
            <div class="card">
              <div class="card-header"><h3>Callees ({p.callees!.length})</h3></div>
              <div class="entity-card-list">
                <For each={p.callees!}>
                  {(callee) => (
                    <EntityCard
                      type="procedure"
                      name={callee}
                      onClick={() => {
                        const dotIdx = callee.indexOf(".");
                        if (dotIdx > 0) {
                          store.dispatch({ tag: "objects", action: { type: "proc-select", objectName: callee.slice(0, dotIdx), procName: callee.slice(dotIdx + 1) } });
                        } else {
                          store.dispatch({ tag: "objects", action: { type: "proc-select", objectName: p.object, procName: callee } });
                        }
                      }}
                    />
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* SQL Statements */}
          <Show when={hasSql}>
            <div class="card">
              <div class="card-header"><h3>SQL Statements ({p.sql_statements!.length})</h3></div>
              <div class="sql-tab-body">
                <For each={p.sql_statements!}>
                  {(stmt) => <SqlStatementCard stmt={stmt} store={store} />}
                </For>
              </div>
            </div>
          </Show>

          {/* Phase gates */}
          <PhaseGateInline
            phase={2}
            section="Control Flow Graph"
            label="requires typing pass"
            description="The CFG diagram for this procedure is available after a P2 typing pass."
          />
          <PhaseGateInline
            phase={3}
            section="Taint Paths"
            label="requires taint analysis"
            description="Taint flow through this procedure's parameters is available after a P3 taint analysis run."
          />
          <PhaseGateInline
            phase={4}
            section="Formal Properties"
            label="requires formal verification"
            description="Pre/post-condition proofs and invariant certificates require P4 formal verification infrastructure."
          />
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
      <button
        class="back-btn"
        onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: objectName() } })}
      >
        {"←"} Back to {objectName()}
      </button>
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
