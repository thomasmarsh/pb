import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";

export function FormalReports(_props: { store: Store<AppState, AppAction> }): JSX.Element {
  return (
    <div class="card">
      <div class="card-header"><h2>Formal Verification</h2></div>
      <div style={{ padding: "16px", color: "var(--text-muted)", "font-size": "13px" }}>
        Z3-backed formal verification is not yet available. When built, this view will present
        proved invariants, counterexamples, and proof certificates filterable by claim type and verdict.
      </div>
    </div>
  );
}
