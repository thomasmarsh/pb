// InheritanceCard.tsx — Inheritance chain display.

import { For } from "solid-js";
import type { Store } from "../../../core/store.js";
import type { AppState } from "../../../app/state.js";
import type { AppAction } from "../../../app/actions.js";

export function InheritanceCard(props: { store: Store<AppState, AppAction>; name: string; ancestors: string[] }) {
  return (
    <div class="card">
      <div class="card-header"><h3>Inheritance</h3></div>
      <div style={{ display: "flex", "flex-wrap": "wrap", gap: "6px" }}>
        <span class="badge badge-ps" style={{ cursor: "pointer" }}
              onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: props.name } })}>
          {props.name}
        </span>
        <For each={props.ancestors}>
          {(a) => (
            <>
              <span style={{ color: "var(--text-muted)" }}>{"→"}</span>
              <span class="badge badge-ps" style={{ cursor: "pointer" }}
                    onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: a } })}>
                {a}
              </span>
            </>
          )}
        </For>
      </div>
    </div>
  );
}
