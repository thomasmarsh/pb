// ObjectDetail.tsx — Object detail view orchestrator.

import { Show } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { Loading } from "../../components/Loading.js";
import { MetricsGrid } from "./detail/MetricsGrid.js";
import { InheritanceCard } from "./detail/InheritanceCard.js";
import { CallGraphCard } from "./detail/CallGraphCard.js";
import { ProceduresCard } from "./detail/ProceduresCard.js";
import { SourceCard } from "./detail/SourceCard.js";

export function ObjectDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const obj = () => snap().objects.detail;
  const src = () => snap().objects.sourceDetail;

  return (
    <>
      <button class="back-btn" onClick={() => store.dispatch({ tag: "objects", action: { type: "back-to-objects" } })}>{"←"} Back to Objects</button>
      <Show when={obj()} fallback={<Loading />}>
        <Show when={!("error" in obj()!)} fallback={<div class="card"><p style={{ color: "var(--red)" }}>Error: {"error" in obj()! ? (obj() as { error: string }).error : ""}</p></div>}>

        {(() => {
          const o = obj()!;
          if ("error" in o) return null;
          const bc = o.kind === "powerscript" ? "ps" : o.kind === "datawindow" ? "dw" : "proj";
          return (
            <>
              <h2 style={{ "margin-bottom": "16px", "font-size": "20px" }}>
                {o.name} <span class={`badge badge-${bc}`}>{o.kind}</span>
              </h2>

              <MetricsGrid metrics={o.metrics ?? {}} />
              {(o.ancestors?.length ?? 0) > 0 && <InheritanceCard store={store} name={o.name} ancestors={o.ancestors!} />}
              {((o.callers?.length ?? 0) > 0 || (o.callees?.length ?? 0) > 0) && <CallGraphCard store={store} callers={o.callers} callees={o.callees} />}
              {(o.procedures?.length ?? 0) > 0 && <ProceduresCard store={store} objectName={o.name} procedures={o.procedures!} />}
              {o.file && <SourceCard store={store} file={o.file} objectName={o.name} sourceDetail={src()} />}
            </>
          );
        })()}
        </Show>
      </Show>
    </>
  );
}
