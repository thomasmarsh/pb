// DeadCode.tsx — Dead Code report: uncalled procedures (P1).

import { Show, For, createResource, createSignal } from "solid-js";
import { Code2, procBadge, type DeadCodeResponse } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { Loading } from "../../components/ui/Loading.js";

type SortKey = "confidence" | "cc" | "object" | "name" | "type";

function confidence(item: { caller_count_naive: number }): "high" | "medium" {
  return item.caller_count_naive === 0 ? "high" : "medium";
}

export function DeadCode(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const [sortBy, setSortBy] = createSignal<SortKey>("confidence");

  const [data] = createResource<DeadCodeResponse>(
    () =>
      fetch("/api/analysis/dead-code")
        .then((r) => {
          if (!r.ok) throw new Error(`${r.status}`);
          return r.json() as Promise<DeadCodeResponse>;
        }),
  );

  const sorted = () => {
    const items = data()?.items ?? [];
    const key = sortBy();
    return [...items].sort((a, b) => {
      if (key === "confidence") {
        const ca = confidence(a) === "high" ? 0 : 1;
        const cb = confidence(b) === "high" ? 0 : 1;
        return ca - cb || (b.cyclomatic ?? -1) - (a.cyclomatic ?? -1);
      }
      if (key === "cc") return (b.cyclomatic ?? -1) - (a.cyclomatic ?? -1);
      if (key === "object") return a.object.localeCompare(b.object) || a.name.localeCompare(b.name);
      if (key === "name") return a.name.localeCompare(b.name);
      if (key === "type") return a.proc_type.localeCompare(b.proc_type) || a.name.localeCompare(b.name);
      return 0;
    });
  };

  function SortBtn(p: { k: SortKey; label: string }) {
    return (
      <button
        class={`filter-pill${sortBy() === p.k ? " active" : ""}`}
        style={{ "font-size": "12px", padding: "2px 10px" }}
        onClick={() => setSortBy(p.k)}
      >
        {p.label}
      </button>
    );
  }

  return (
    <div class="card">
      <div class="card-header" style={{ display: "flex", "align-items": "center", gap: "8px", "flex-wrap": "wrap" }}>
        <h2 style={{ flex: 1 }}>Dead Code</h2>
        <Show when={data() && !data.loading}>
          <span style={{ color: "var(--text-muted)", "font-size": "13px" }}>
            {data()!.total} procedure{data()!.total === 1 ? "" : "s"}
          </span>
          <div style={{ display: "flex", gap: "4px" }}>
            <SortBtn k="confidence" label="Confidence" />
            <SortBtn k="cc" label="CC ↓" />
            <SortBtn k="object" label="Object" />
            <SortBtn k="name" label="Name" />
            <SortBtn k="type" label="Type" />
          </div>
        </Show>
      </div>

      <Show when={data.loading}><Loading /></Show>

      <Show when={data.error}>
        <div class="error-banner">Failed to load: {String(data.error)}</div>
      </Show>

      <Show when={data() && !data.loading}>
        <Show when={data()!.total === 0}>
          <div style={{ color: "var(--text-muted)", "font-size": "13px", padding: "8px 0" }}>
            No uncalled procedures found.
          </div>
        </Show>

        <Show when={data()!.total > 0}>
          <table class="data-table" style={{ "font-size": "13px" }}>
            <thead>
              <tr>
                <th>Object</th>
                <th>Procedure</th>
                <th>Type</th>
                <th>Confidence</th>
                <th style={{ "text-align": "right" }}>CC</th>
              </tr>
            </thead>
            <tbody>
              <For each={sorted()}>
                {(item) => (
                  <tr
                    class="clickable"
                    onClick={() => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: item.object, procName: item.name } })}
                  >
                    <td style={{ color: "var(--text-muted)", "font-size": "12px" }}>{item.object}</td>
                    <td>
                      <span class="entity-card-icon" style={{ "margin-right": "4px" }}><Code2 size={13} /></span>
                      {item.name}
                    </td>
                    <td>
                      <span class={`badge badge-${procBadge(item.proc_type)}`}>{item.proc_type}</span>
                    </td>
                    <td>
                      <span class={`badge badge-${confidence(item)}`}>{confidence(item)}</span>
                    </td>
                    <td style={{ "text-align": "right" }}>
                      {item.cyclomatic != null
                        ? <span class="badge badge-cc">{item.cyclomatic}</span>
                        : <span style={{ color: "var(--text-muted)" }}>–</span>}
                    </td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </Show>
      </Show>
    </div>
  );
}
