// ObjectDetail.tsx — Object detail view orchestrator.

import { Show, createSignal, createEffect } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import type { ObjectDetailResponse } from "../../types/api.js";
import type { ObjectsState } from "./types.js";
import { Loading } from "../../components/Loading.js";
import { DiagramCard } from "../../components/DiagramCard.js";
import { MetricsGrid } from "./detail/MetricsGrid.js";
import { InheritanceCard } from "./detail/InheritanceCard.js";
import { CallGraphCard } from "./detail/CallGraphCard.js";
import { ProceduresCard } from "./detail/ProceduresCard.js";
import { SourceCard } from "./detail/SourceCard.js";

function ObjectDetailContent(props: {
  o: ObjectDetailResponse;
  obj: () => ObjectsState["detail"];
  store: Store<AppState, AppAction>;
}) {
  const o = props.o;
  const store = props.store;
  const snap = useSnapshot(store.state);
  const src = () => snap().objects.sourceDetail;
  const [tab, setTab] = createSignal<"overview" | "diagram" | "source">("overview");
  createEffect(() => { props.obj(); setTab("overview"); });

  const hasCalls = (o.callers?.length ?? 0) + (o.callees?.length ?? 0) > 0;
  const hasAncestors = (o.ancestors?.length ?? 0) > 0;
  const bc = o.kind === "powerscript" ? "ps" : o.kind === "datawindow" ? "dw" : "proj";

  return (
    <>
      <h2 style={{ "margin-bottom": "16px", "font-size": "20px" }}>
        {o.name} <span class={`badge badge-${bc}`}>{o.kind}</span>
      </h2>

      <div class="tab-bar" style={{ "margin-bottom": "16px" }}>
        <button class={tab() === "overview" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("overview")}>Overview</button>
        <Show when={hasCalls || hasAncestors}>
          <button class={tab() === "diagram" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("diagram")}>Diagram</button>
        </Show>
        <Show when={o.file}>
          <button class={tab() === "source" ? "tab-btn active" : "tab-btn"} onClick={() => setTab("source")}>Source</button>
        </Show>
      </div>

      <Show when={tab() === "overview"}>
        <MetricsGrid metrics={o.metrics ?? {}} />
        {hasAncestors && <InheritanceCard store={store} name={o.name} ancestors={o.ancestors!} />}
        {(hasCalls) && <CallGraphCard store={store} callers={o.callers} callees={o.callees} />}
        {(o.procedures?.length ?? 0) > 0 && <ProceduresCard store={store} objectName={o.name} procedures={o.procedures!} />}
      </Show>

      <Show when={tab() === "diagram"}>
        {hasCalls && <DiagramCard title="Call Graph" kind="calls" params={{ focal: o.name, depth: 2 }} store={store} />}
        {hasAncestors && <DiagramCard title="Inheritance Tree" kind="inheritance" params={{ root: o.name }} store={store} />}
      </Show>

      <Show when={tab() === "source"}>
        {o.file && <SourceCard store={store} file={o.file} objectName={o.name} sourceDetail={src()} />}
      </Show>
    </>
  );
}

export function ObjectDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
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
