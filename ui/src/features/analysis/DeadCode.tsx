// features/analysis/DeadCode.tsx — Dead Code report stub (P1).

import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";

export function DeadCode(_props: { store: Store<AppState, AppAction> }): JSX.Element {
  return (
    <div class="phase-gate">
      <div class="phase-gate-icon" style={{ color: "var(--text-muted)" }}>◎</div>
      <h2 class="phase-gate-heading">Dead Code Report</h2>
      <p class="phase-gate-desc">
        Lists procedures with a caller count of zero — potential dead code. This screen is a
        work-in-progress stub. Full implementation arrives in T3.
      </p>
    </div>
  );
}
