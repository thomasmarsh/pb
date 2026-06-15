// ProcedureDetail.tsx — Procedure detail view with tabs.

import { Show, createSignal } from "solid-js";
import { Tabs } from "@kobalte/core/tabs";
import { useSnapshot } from "../core/store.js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";
import { CodeBlock } from "./CodeBlock.js";

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

function Loading() {
  return <div class="loading-overlay"><div class="spinner" /> Loading...</div>;
}

export function ProcedureDetail(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const proc = () => snap().nav.procedureDetail;
  const [activeTab, setActiveTab] = createSignal("original");

  return (
    <Show when={proc()} fallback={<Loading />}>
      <Show when={!("error" in proc()!)} fallback={<div class="card"><p style={{ color: "var(--red)" }}>Error: {(proc() as { error: string }).error}</p></div>}>
        {(() => {
          const p = proc()!;
          if ("error" in p) return null;
          const bc = procBadge(p.proc_type);

          return (
            <>
              <button class="back-btn" onClick={() => store.dispatch({ tag: "nav", action: { type: "object-selected", name: p.object } })}>
                {"\u2190"} Back to {p.object}
              </button>

              <h2 style={{ "margin-bottom": "4px", "font-size": "18px" }}>
                {p.object}.<span style={{ color: "var(--accent)" }}>{p.name}</span>{" "}
                <span class={`badge badge-${bc}`}>{p.proc_type}</span>
              </h2>

              <div style={{ "font-size": "12px", color: "var(--text-muted)", "margin-bottom": "16px" }}>
                {p.modifiers && <span>{p.modifiers} </span>}
                {p.params && <span>({p.params}) </span>}
                {p.return_type && <span>returns {p.return_type} </span>}
                {p.cyclomatic != null && <span class="badge badge-cc" style={{ "margin-left": "8px" }}>CC: {p.cyclomatic}</span>}
              </div>

              <Show when={p.source_original || p.source_rendered}>
                <Tabs value={activeTab()} onChange={setActiveTab}>
                  <Tabs.List class="tab-bar">
                    <Show when={p.source_original}>
                      <Tabs.Trigger value="original" class="tab-btn">Original Source</Tabs.Trigger>
                    </Show>
                    <Show when={p.source_rendered}>
                      <Tabs.Trigger value="rendered" class="tab-btn">Rendered</Tabs.Trigger>
                    </Show>
                  </Tabs.List>

                  <Tabs.Content value="original">
                    <Show when={p.source_original}>
                      <CodeBlock code={p.source_original!} baseLine={p.start_line ?? 1} />
                      <Show when={p.file}>
                        <div style={{ "font-size": "11px", color: "var(--text-muted)", "margin-top": "8px" }}>
                          {p.file}:{p.start_line ?? ""}-{p.end_line ?? ""}
                        </div>
                      </Show>
                    </Show>
                  </Tabs.Content>

                  <Tabs.Content value="rendered">
                    <Show when={p.source_rendered}>
                      <CodeBlock code={p.source_rendered!} baseLine={p.start_line ?? 1} />
                    </Show>
                  </Tabs.Content>
                </Tabs>
              </Show>
            </>
          );
        })()}
      </Show>
    </Show>
  );
}
