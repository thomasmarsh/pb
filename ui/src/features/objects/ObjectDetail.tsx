// ObjectDetail.tsx — Object detail view with FaceToggle Source/Analysis pattern.

import { Show, createEffect, createSignal } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { ObjectDetailResponse } from "../../types/api.js";
import type { ObjectsState } from "./types.js";
import { Loading } from "../../components/ui/Loading.js";
import { PhaseGateInline } from "../../components/ui/PhaseGate.js";
import { DetailHeader } from "../../components/detail/DetailHeader.js";
import { BackButton } from "../../components/ui/BackButton.js";
import { EntityListCard } from "../../components/detail/EntityListCard.js";
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

  return (
    <>
      <DetailHeader
        name={o.name}
        badgeClass={`badge-${bc()}`}
        badgeLabel={o.kind}
        face={face()}
        phaseLabel="P1"
        store={store}
        onToggle={(newFace, scrollTop) => {
          store.dispatch({ tag: "objects", action: { tag: "set-object-face", name: o.name, face: newFace, scrollTop } });
        }}
        scrollAreaRef={() => scrollEl}
      />

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

          <Show when={(o.ancestors?.length ?? 0) > 0}>
            <InheritanceCard store={store} name={o.name} ancestors={o.ancestors!} />
          </Show>

          <EntityListCard
            title="Callers"
            items={(o.callers ?? []).map((caller) => ({
              type: "object" as const,
              name: caller,
              onClick: () => store.dispatch({ tag: "objects", action: { tag: "select", name: caller } }),
            }))}
            emptyText="No callers found."
          />

          <Show when={(o.dws_used?.length ?? 0) > 0}>
            <EntityListCard
              title="DataWindows Used"
              count={o.dws_used!.length}
              items={o.dws_used!.map((dw) => ({
                type: "datawindow" as const,
                name: dw,
                onClick: () => store.dispatch({ tag: "datawindows", action: { tag: "select", name: dw } }),
              }))}
            />
          </Show>

          <Show when={(o.tables_accessed?.length ?? 0) > 0}>
            <EntityListCard
              title="Tables Accessed"
              count={o.tables_accessed!.length}
              meta="based on all DataWindows and direct SQL"
              items={o.tables_accessed!.map((tbl) => ({
                type: "table" as const,
                name: tbl,
                onClick: () => store.dispatch({ tag: "tables", action: { tag: "select", name: tbl } }),
              }))}
            />
          </Show>

          <PhaseGateInline phase={2} section="Type Analysis" label="requires typing pass"
            description="Type-level call graph and interface conformance checks require a P2 typing pass over the corpus." />
          <PhaseGateInline phase={3} section="Taint Paths" label="requires taint analysis"
            description="Taint flow from user inputs through this object's procedures is available after a P3 taint analysis run." />
          <PhaseGateInline phase={4} section="Formal Properties" label="requires formal verification"
            description="Invariant proofs and safety certificates for this object require P4 formal verification infrastructure." />
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
      <BackButton label="Objects" onClick={() => store.dispatch({ tag: "objects", action: { tag: "back-to-objects" } })} />
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
