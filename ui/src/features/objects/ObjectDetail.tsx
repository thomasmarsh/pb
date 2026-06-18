// ObjectDetail.tsx — Object detail view with FaceToggle Source/Analysis pattern.

import { Show, For, createEffect, createSignal } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ObjectDetailResponse } from "../../types/api.js";
import type { ObjectsState } from "./types.js";
import { Loading } from "../../components/Loading.js";
import { FaceToggle } from "../../components/FaceToggle.js";
import { PhaseGateInline } from "../../components/PhaseGate.js";
import { EntityCard } from "../../components/EntityCard.js";
import { MetricsGrid } from "./detail/MetricsGrid.js";
import { InheritanceCard } from "./detail/InheritanceCard.js";
import { ProceduresCard } from "./detail/ProceduresCard.js";
import { SourceCard } from "./detail/SourceCard.js";

function ObjectDetailContent(props: {
  o: ObjectDetailResponse;
  obj: () => ObjectsState["detail"];
  store: Store<AppState, AppAction>;
}) {
  const o = props.o;
  const store = props.store;
  const snap = store.getState();
  const src = () => snap().objects.sourceDetail;
  const face = () => snap().objects.objectFace;

  let scrollEl: HTMLDivElement | undefined;

  createEffect(() => {
    const pos = snap().objects.objectScrollPos[o.name];
    if (!pos || !scrollEl) return;
    scrollEl.scrollTop = face() === "source" ? pos.source : pos.analysis;
  });

  const [bc] = createSignal(
    o.kind === "powerscript" ? "ps" : o.kind === "datawindow" ? "dw" : "proj",
  );

  const hasAncestors = (o.ancestors?.length ?? 0) > 0;
  const hasCallers = (o.callers?.length ?? 0) > 0;
  const hasDws = (o.dws_used?.length ?? 0) > 0;
  const hasTables = (o.tables_accessed?.length ?? 0) > 0;

  return (
    <>
      <div class="detail-header">
        <h2 style={{ "margin": "0", "font-size": "20px" }}>
          {o.name} <span class={`badge badge-${bc()}`}>{o.kind}</span>
        </h2>
        <FaceToggle
          face={face()}
          phaseLabel="P1"
          onToggle={(newFace, scrollTop) => {
            store.dispatch({ tag: "objects", action: { type: "set-object-face", name: o.name, face: newFace, scrollTop } });
          }}
          scrollAreaRef={() => scrollEl}
        />
      </div>

      <div class="detail-body" ref={scrollEl}>
        <Show when={face() === "source"}>
          <Show when={o.file} fallback={<p class="muted-note">No source file available.</p>}>
            <SourceCard store={store} file={o.file} objectName={o.name} sourceDetail={src()} />
          </Show>
          <Show when={(o.procedures?.length ?? 0) > 0}>
            <ProceduresCard store={store} objectName={o.name} procedures={o.procedures!} />
          </Show>
        </Show>

        <Show when={face() === "analysis"}>
          <Show when={o.metrics}>
            <MetricsGrid metrics={o.metrics!} />
          </Show>

          <Show when={hasAncestors}>
            <InheritanceCard store={store} name={o.name} ancestors={o.ancestors!} />
          </Show>

          {/* Callers */}
          <div class="card">
            <div class="card-header"><h3>Callers</h3></div>
            <Show
              when={hasCallers}
              fallback={<p class="muted-note">No callers found.</p>}
            >
              <div class="entity-card-list">
                <For each={o.callers}>
                  {(caller) => (
                    <EntityCard
                      type="object"
                      name={caller}
                      onClick={() => store.dispatch({ tag: "objects", action: { type: "select", name: caller } })}
                    />
                  )}
                </For>
              </div>
            </Show>
          </div>

          {/* DWs Used */}
          <Show when={hasDws}>
            <div class="card">
              <div class="card-header"><h3>DataWindows Used ({o.dws_used!.length})</h3></div>
              <div class="entity-card-list">
                <For each={o.dws_used!}>
                  {(dw) => (
                    <EntityCard
                      type="datawindow"
                      name={dw}
                      onClick={() => store.dispatch({ tag: "datawindows", action: { type: "select", name: dw } })}
                    />
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Tables Accessed */}
          <Show when={hasTables}>
            <div class="card">
              <div class="card-header">
                <h3>Tables Accessed ({o.tables_accessed!.length})</h3>
                <span class="card-meta">based on all DataWindows and direct SQL</span>
              </div>
              <div class="entity-card-list">
                <For each={o.tables_accessed!}>
                  {(tbl) => (
                    <EntityCard
                      type="table"
                      name={tbl}
                      onClick={() => store.dispatch({ tag: "tables", action: { type: "select", name: tbl } })}
                    />
                  )}
                </For>
              </div>
            </div>
          </Show>

          {/* Phase gates */}
          <PhaseGateInline
            phase={2}
            section="Type Analysis"
            label="requires typing pass"
            description="Type-level call graph and interface conformance checks require a P2 typing pass over the corpus."
          />
          <PhaseGateInline
            phase={3}
            section="Taint Paths"
            label="requires taint analysis"
            description="Taint flow from user inputs through this object's procedures is available after a P3 taint analysis run."
          />
          <PhaseGateInline
            phase={4}
            section="Formal Properties"
            label="requires formal verification"
            description="Invariant proofs and safety certificates for this object require P4 formal verification infrastructure."
          />
        </Show>
      </div>
    </>
  );
}

export function ObjectDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const obj = () => snap().objects.detail;

  return (
    <>
      <button class="back-btn" onClick={() => store.dispatch({ tag: "objects", action: { type: "back-to-objects" } })}>{"←"} Back to Objects</button>
      <Show when={obj()} fallback={<Loading />}>
        {(entry) => {
          if ("error" in entry()) {
            return <div class="card"><p style={{ color: "var(--red)" }}>Error: {(entry() as { error: string }).error}</p></div>;
          }
          return <ObjectDetailContent o={entry() as ObjectDetailResponse} obj={obj} store={store} />;
        }}
      </Show>
    </>
  );
}
