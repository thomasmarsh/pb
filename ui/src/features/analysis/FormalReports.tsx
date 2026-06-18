// features/analysis/FormalReports.tsx — Formal Reports (P4-gated).

import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { PhaseGate } from "../../components/PhaseGate.js";

export function FormalReports(props: { store: Store<AppState, AppAction> }): JSX.Element {
  return (
    <PhaseGate
      phase={4}
      feature="Formal Reports"
      description="When P4 is built, this view will present Z3-backed formal verification results — proved
        invariants, counterexamples, and proof certificates — filterable by claim type and verdict."
      store={props.store}
    />
  );
}
