// features/analysis/ExplainView.tsx — Full-page Explain view wrapping
// ExplainCore in AnalysisView.

import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { ExplainCore } from "./ExplainCore.js";
import { AnalysisView } from "@pb/platform";

export function ExplainView(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();

  const object = (): string => {
    const r = snap().nav.route;
    return r.view === "explainView" ? r.object : "";
  };
  const proc = (): string => {
    const r = snap().nav.route;
    return r.view === "explainView" ? r.proc : "";
  };

  function gotoProc(): void {
    props.store.dispatch({
      tag: "nav",
      action: { tag: "navigate", route: { view: "procedureDetail", name: object(), proc: proc() } },
    });
  }

  return (
    <AnalysisView
      title={`${object()}.${proc()}`}
      contextLabel="Explain"
      assumptions="Pseudocode is reconstructed from the compiled control-flow shape, cut into regions at the same points a human reader would treat as a sub-step. Each region shows its inferred data-flow signature alongside the procedure's declared one; a region-ref chip jumps to that region's own card rather than inlining it."
    >
      <ExplainCore
        object={object()}
        proc={proc()}
        store={props.store}
        onGoto={gotoProc}
      />
    </AnalysisView>
  );
}
