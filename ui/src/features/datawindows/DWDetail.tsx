// DWDetail.tsx — DataWindow detail view with FaceToggle Source/Analysis faces.

import { Show, For, createEffect } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { DwDetailResponse, DwControlRow } from "../../types/api.js";
import { CodeBlock } from "../../components/detail/CodeBlock.js";
import { Loading } from "../../components/ui/Loading.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";

function DWControlsTable(props: { controls: DwControlRow[] }) {
  return (
    <div class="card">
      <div class="card-header"><h3>Controls ({props.controls.length})</h3></div>
      <table class="data-table">
        <thead>
          <tr><th>Name</th><th>Type</th><th>Band</th><th>X</th><th>Y</th><th>W</th><th>H</th><th>Expr</th></tr>
        </thead>
        <tbody>
          <For each={props.controls}>
            {(c) => (
              <tr>
                <td class="name-cell">{c.control_name ?? "–"}</td>
                <td>{c.control_type ?? ""}</td>
                <td><span class="badge badge-on">{c.band ?? ""}</span></td>
                <td>{c.x != null ? String(c.x) : ""}</td>
                <td>{c.y != null ? String(c.y) : ""}</td>
                <td>{c.width != null ? String(c.width) : ""}</td>
                <td>{c.height != null ? String(c.height) : ""}</td>
                <td style={{ "max-width": "200px", overflow: "hidden", "text-overflow": "ellipsis", "white-space": "nowrap", "font-size": "11px" }}>
                  {c.expression ?? ""}
                </td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  );
}

function DWDetailContent(props: { d: DwDetailResponse; store: Store<AppState, AppAction> }) {
  const d = props.d;
  const store = props.store;
  const snap = store.getState();
  const face = () => snap().datawindows.dwFace;

  let scrollEl: HTMLDivElement | undefined;

  createEffect(() => {
    const pos = snap().datawindows.dwScrollPos[d.name];
    if (!pos || !scrollEl) return;
    scrollEl.scrollTop = face() === "source" ? pos.source : pos.analysis;
  });

  const hasWhere = d.retrieve_where.length > 0;
  const hasArgs = d.arguments.length > 0;

  return (
    <>
      <DetailHeader
        name={d.name}
        badgeClass="badge-dw"
        badgeLabel="datawindow"
        face={face()}
        store={store}
        onToggle={(newFace, scrollTop) => {
          store.dispatch({ tag: "datawindows", action: { tag: "set-dw-face", name: d.name, face: newFace, scrollTop } });
        }}
        scrollAreaRef={() => scrollEl}
      />

      <div class="detail-body" ref={scrollEl}>
        <Show when={face() === "source"}>
          <Show when={d.controls.length > 0}>
            <DWControlsTable controls={d.controls} />
          </Show>
          <Show when={d.source}>
            <div class="card">
              <div class="card-header"><h3>Source</h3></div>
              <CodeBlock code={d.source!} />
            </div>
          </Show>
        </Show>

        <Show when={face() === "analysis"}>
          <Show when={d.retrieve_tables.length > 0}>
            <EntityListCard
              title="Tables Accessed"
              count={d.retrieve_tables.length}
              items={d.retrieve_tables.map((t) => ({
                type: "table" as const,
                name: t,
                onClick: () => store.dispatch({ tag: "tables", action: { tag: "select", name: t } }),
              }))}
            />
          </Show>

          <Show when={(d.used_by_objects?.length ?? 0) > 0}>
            <EntityListCard
              title="Used By — Objects"
              count={d.used_by_objects!.length}
              items={d.used_by_objects!.map((obj) => ({
                type: "object" as const,
                name: obj,
                onClick: () => store.dispatch({ tag: "objects", action: { tag: "select", name: obj } }),
              }))}
            />
          </Show>

          <Show when={(d.used_by_procs?.length ?? 0) > 0}>
            <EntityListCard
              title="Used By — Procedures"
              count={d.used_by_procs!.length}
              items={d.used_by_procs!.map((ref) => ({
                type: "procedure" as const,
                name: ref.proc,
                context: ref.object,
                tooltip: `${ref.object}.${ref.proc}`,
                onClick: () => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: ref.object, procName: ref.proc } }),
              }))}
            />
          </Show>

          <Show when={hasWhere || hasArgs}>
            <div class="card">
              <div class="card-header"><h3>Retrieve Definition</h3></div>
              <Show when={hasArgs}>
                <div style={{ "padding": "8px 16px" }}>
                  <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "4px" }}>Arguments</div>
                  <table class="data-table">
                    <thead><tr><th>Name</th><th>Type</th></tr></thead>
                    <tbody>
                      <For each={d.arguments}>
                        {(a) => <tr><td class="name-cell">{a.arg_name}</td><td>{a.arg_type ?? ""}</td></tr>}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>
              <Show when={hasWhere}>
                <div style={{ "padding": "8px 16px" }}>
                  <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "4px" }}>WHERE Clauses</div>
                  <table class="data-table">
                    <thead><tr><th>#</th><th>Exp1</th><th>Op</th><th>Exp2</th><th>Logic</th></tr></thead>
                    <tbody>
                      <For each={d.retrieve_where}>
                        {(w) => (
                          <tr>
                            <td>{String(w.idx)}</td>
                            <td>{w.exp1 ?? ""}</td>
                            <td><span class="badge badge-event">{w.op ?? ""}</span></td>
                            <td>{w.exp2 ?? ""}</td>
                            <td><span class="badge badge-func">{w.logic ?? ""}</span></td>
                          </tr>
                        )}
                      </For>
                    </tbody>
                  </table>
                </div>
              </Show>
            </div>
          </Show>

        </Show>
      </div>
    </>
  );
}

export function DWDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const dw = () => snap().datawindows.dwDetail;

  return (
    <>
      <BackButton label="DataWindows" onClick={() => store.dispatch({ tag: "datawindows", action: { tag: "back-to-datawindows" } })} />
      <Show when={dw()} fallback={<Loading />}>
        {(entry) => {
          if ("error" in entry()) {
            return <div class="card"><p style={{ color: "var(--red)" }}>Error: {(entry() as { error: string }).error}</p></div>;
          }
          return <DWDetailContent d={entry() as DwDetailResponse} store={store} />;
        }}
      </Show>
    </>
  );
}
