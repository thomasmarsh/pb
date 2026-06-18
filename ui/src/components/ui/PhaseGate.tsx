// components/PhaseGate.tsx — Full-page and inline phase gate components.

import { createSignal } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";

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
          onClick={() => props.store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "dashboard" } } })}
        >
          Dashboard
        </button>
      </div>
    </div>
  );
}

// ── PhaseGateInline ───────────────────────────────────────────────────────────

interface PhaseGateInlineProps {
  phase: 2 | 3 | 4;
  section: string;
  label: string;
  description?: string;
}

export function PhaseGateInline(props: PhaseGateInlineProps): JSX.Element {
  const [open, setOpen] = createSignal(false);

  return (
    <div class="phase-gate-inline">
      <button
        class="phase-gate-inline-row"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open()}
        aria-label={`${props.section} — ${props.label}`}
      >
        <span class={`phase-gate-inline-triangle${open() ? " open" : ""}`} aria-hidden="true">▸</span>
        <span class="phase-gate-inline-section">{props.section}</span>
        <span class="phase-gate-inline-label">P{props.phase} — {props.label}</span>
      </button>
      {open() && props.description && (
        <div class="phase-gate-inline-body">{props.description}</div>
      )}
    </div>
  );
}
