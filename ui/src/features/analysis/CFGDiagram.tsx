// features/analysis/CFGDiagram.tsx — Full-page CFG view wrapping CFGCore in AnalysisView.

import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";
import { CFGCore } from "./CFGCore.js";
import { AnalysisView } from "./AnalysisView.js";

export function CFGDiagram(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();

  const object = (): string => {
    const r = snap().nav.route;
    return r.view === "cfgDiagram" ? r.object : "";
  };
  const proc = (): string => {
    const r = snap().nav.route;
    return r.view === "cfgDiagram" ? r.proc : "";
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
      contextLabel="Control Flow Graph"
      assumptions="CFG is constructed from the parsed AST body. Loop back-edges and exception paths are approximated. Dynamic dispatch is not resolved."
    >
      <CFGCore
        object={object()}
        proc={proc()}
        store={props.store}
        onGoto={gotoProc}
      />
    </AnalysisView>
  );
}
