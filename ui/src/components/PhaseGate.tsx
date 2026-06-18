// components/PhaseGate.tsx — Full-page phase gate screen.

import type { JSX } from "solid-js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";

interface PhaseGateProps {
  phase: 2 | 3 | 4;
  feature: string;
  description: string;
  store: Store<AppState, AppAction>;
}

export function PhaseGate(props: PhaseGateProps): JSX.Element {
  return (
    <div class="phase-gate">
      <div class="phase-gate-icon">⚠</div>
      <h2 class="phase-gate-heading">Requires P{props.phase} analysis infrastructure</h2>
      <p class="phase-gate-desc">{props.description}</p>
      <div class="phase-gate-footer">
        Current analysis depth: P1 &mdash;{" "}
        <button
          class="link-btn"
          onClick={() => props.store.dispatch({ tag: "nav", action: { type: "navigate", route: { view: "dashboard" } } })}
        >
          Dashboard
        </button>
      </div>
    </div>
  );
}
