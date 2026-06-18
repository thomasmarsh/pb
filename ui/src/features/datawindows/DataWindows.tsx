// DataWindows.tsx — DataWindows list and detail views.

import { Show, For, onMount, onCleanup, createEffect } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { DwDetailResponse, DwControlRow } from "../../types/api.js";
import { CodeBlock } from "../../components/CodeBlock.js";
import { FaceToggle } from "../../components/FaceToggle.js";
import { PhaseGateInline } from "../../components/PhaseGate.js";
import { EntityCard } from "../../components/EntityCard.js";
import { shortFile } from "../../utils/format.js";
import { Loading } from "../../components/Loading.js";

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

  const hasUsedByObjects = () => (d.used_by_objects?.length ?? 0) > 0;
  const hasUsedByProcs   = () => (d.used_by_procs?.length ?? 0) > 0;
  const hasWhere         = d.retrieve_where.length > 0;
  const hasArgs          = d.arguments.length > 0;

  return (
    <>
      <div class="detail-header">
        <h2 style={{ "margin": "0", "font-size": "20px" }}>
          {d.name} <span class="badge badge-dw">datawindow</span>
        </h2>
        <FaceToggle
          face={face()}
          phaseLabel="P1"
          onToggle={(newFace, scrollTop) => {
            store.dispatch({ tag: "datawindows", action: { type: "set-dw-face", name: d.name, face: newFace, scrollTop } });
          }}
          scrollAreaRef={() => scrollEl}
        />
      </div>

      <div class="detail-body" ref={scrollEl}>
        {/* ── Source face ───────────────────────────────────────────────── */}
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

        {/* ── Analysis face ─────────────────────────────────────────────── */}
        <Show when={face() === "analysis"}>
          {/* Tables Accessed */}
          <Show when={d.retrieve_tables.length > 0}>
            <div class="card">
              <div class="card-header"><h3>Tables Accessed ({d.retrieve_tables.length})</h3></div>
              <div class="entity-card-list">
                <For each={d.retrieve_tables}>
                  {(t) => (
                    <EntityCard
                      type="table"
                      name={t}
                      onClick={() => store.dispatch({ tag: "tables", action: { type: "select", name: t } })}
                    />
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Used By — Objects */}
          <Show when={hasUsedByObjects()}>
            <div class="card">
              <div class="card-header"><h3>Used By — Objects ({d.used_by_objects!.length})</h3></div>
              <div class="entity-card-list">
                <For each={d.used_by_objects!}>
                  {(obj) => (
                    <EntityCard
                      type="object"
                      name={obj}
                      onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: obj } })}
                    />
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Used By — Procedures */}
          <Show when={hasUsedByProcs()}>
            <div class="card">
              <div class="card-header"><h3>Used By — Procedures ({d.used_by_procs!.length})</h3></div>
              <div class="entity-card-list">
                <For each={d.used_by_procs!}>
                  {(ref) => (
                    <EntityCard
                      type="procedure"
                      name={ref.proc}
                      context={ref.object}
                      tooltip={`${ref.object}.${ref.proc}`}
                      onClick={() => store.dispatch({ tag: "objects", action: { type: "proc-select", objectName: ref.object, procName: ref.proc } })}
                    />
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Retrieve Definition */}
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

          <PhaseGateInline
            phase={3}
            section="Taint on SQL Parameters"
            label="requires taint analysis"
            description="Taint flow through this DataWindow's SQL parameters is available after a P3 taint analysis run."
          />
        </Show>
      </div>
    </>
  );
}

export function DataWindows(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const dw = () => snap().datawindows;
  let cursorIdx = -1;

  // Preserve state: only load if the list is empty.
  onMount(() => {
    if (dw().items.length === 0) {
      store.dispatch({ tag: "datawindows", action: { type: "search", q: dw().q } });
    }
  });

  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      const items = dw().items;
      if (e.key === "j") {
        e.preventDefault();
        cursorIdx = Math.min(cursorIdx + 1, items.length - 1);
        highlightRow(cursorIdx, "dw-list-table");
      } else if (e.key === "k") {
        e.preventDefault();
        cursorIdx = Math.max(cursorIdx - 1, 0);
        highlightRow(cursorIdx, "dw-list-table");
      } else if (e.key === "Enter" && cursorIdx >= 0) {
        e.preventDefault();
        const item = items[cursorIdx];
        if (item) store.dispatch({ tag: "datawindows", action: { type: "select", name: item.name } });
      }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  return (
    <>
      <div class="search-bar">
        <input
          class="search-input"
          type="text"
          placeholder="Search DataWindows…"
          value={dw().q}
          onInput={(e) => {
            cursorIdx = -1;
            store.dispatch({ tag: "datawindows", action: { type: "search", q: e.currentTarget.value } });
          }}
        />
      </div>

      <Show when={!dw().loading || dw().items.length > 0} fallback={<Loading />}>
        <div class="card">
          <div class="card-header">
            <h2>{dw().q ? `DataWindows — ${dw().total} results` : `DataWindows (${dw().total})`}</h2>
          </div>
          <table class="data-table dw-list-table">
            <thead><tr><th>Name</th><th>File</th></tr></thead>
            <tbody>
              <For each={dw().items}>
                {(d) => (
                  <tr>
                    <td class="name-cell" style={{ padding: "4px 8px" }}>
                      <EntityCard
                        type="datawindow"
                        name={d.name}
                        onClick={() => store.dispatch({ tag: "datawindows", action: { type: "select", name: d.name } })}
                      />
                    </td>
                    <td style={{ "font-size": "11px", color: "var(--text-muted)" }}>{shortFile(d.file)}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>
    </>
  );
}

export function DWDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const dw = () => snap().datawindows.dwDetail;

  return (
    <>
      <button class="back-btn" onClick={() => store.dispatch({ tag: "datawindows", action: { type: "back-to-datawindows" } })}>
        {"←"} Back to DataWindows
      </button>
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

function highlightRow(idx: number, tableClass: string): void {
  const table = document.querySelector(`.${tableClass}`);
  if (!table) return;
  table.querySelectorAll("tr.list-cursor").forEach((r) => r.classList.remove("list-cursor"));
  const rows = table.querySelectorAll("tbody tr");
  rows[idx]?.classList.add("list-cursor");
  (rows[idx] as HTMLElement)?.scrollIntoView?.({ block: "nearest" });
}
