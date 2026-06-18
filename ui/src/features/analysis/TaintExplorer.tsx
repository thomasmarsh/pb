// features/analysis/TaintExplorer.tsx — Taint Explorer (P3-gated).

import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { PhaseGate } from "../../components/PhaseGate.js";

export function TaintExplorer(props: { store: Store<AppState, AppAction> }): JSX.Element {
  return (
    <PhaseGate
      phase={3}
      feature="Taint Explorer"
      description="When P3 is built, this view will show all taint paths across the corpus, filterable by
        source type, sink type, and severity. Each path is navigable step-by-step into source."
      store={props.store}
    />
  );
}
