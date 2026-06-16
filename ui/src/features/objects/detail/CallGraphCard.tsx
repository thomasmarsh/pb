// CallGraphCard.tsx — Callers/callees grid display.

import { Show, For } from "solid-js";
import type { Store } from "../../../core/store.js";
import type { AppState } from "../../../app/state.js";
import type { AppAction } from "../../../app/actions.js";

export function CallGraphCard(props: {
  store: Store<AppState, AppAction>;
  callers?: string[];
  callees?: string[];
}) {
  return (
    <div class="card">
      <div class="card-header"><h3>Call Graph</h3></div>
      <div style={{ display: "grid", "grid-template-columns": "1fr 1fr", gap: "16px" }}>
        <For each={[["CALLERS", props.callers], ["CALLEES", props.callees]] as [string, string[] | undefined][]}>
          {([label, items]) => (
            <Show when={items && items.length > 0}>
              <div>
                <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-bottom": "4px" }}>
                  {label} ({items!.length})
                </div>
                <div style={{ display: "flex", "flex-wrap": "wrap", gap: "4px" }}>
                  <For each={items!}>
                    {(c) => (
                      <span class="badge badge-func" style={{ cursor: "pointer" }}
                            onClick={() => props.store.dispatch({ tag: "objects", action: { type: "select", name: c } })}>
                        {c}
                      </span>
                    )}
                  </For>
                </div>
              </div>
            </Show>
          )}
        </For>
      </div>
    </div>
  );
}
