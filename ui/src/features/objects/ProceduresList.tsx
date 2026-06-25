// ProceduresList.tsx — Browsable, sortable, filterable list of all procedures.

import { Show, For, onMount } from "solid-js";
import { ChevronUp, ChevronDown, ArrowUpDown, procBadge, type ProcedureListItem } from "@pb/platform";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { EntityCard } from "../../components/detail/EntityCard.js";
import { Loading } from "../../components/ui/Loading.js";
import { useListKeyboard } from "../../utils/hooks/useListKeyboard.js";

const KIND_LABELS: Record<string, string> = {
  function: "function", subroutine: "subroutine", event: "event", on: "on",
};

function sortItems(
  items: ProcedureListItem[],
  col: string,
  order: "asc" | "desc",
): ProcedureListItem[] {
  const cmp = (a: ProcedureListItem, b: ProcedureListItem): number => {
    let va: string | number, vb: string | number;
    switch (col) {
      case "object":       va = a.object;          vb = b.object;          break;
      case "cyclomatic":   va = a.cyclomatic ?? -1; vb = b.cyclomatic ?? -1; break;
      case "caller_count": va = a.caller_count;     vb = b.caller_count;    break;
      default:             va = a.name;             vb = b.name;
    }
    if (va < vb) return order === "asc" ? -1 : 1;
    if (va > vb) return order === "asc" ? 1 : -1;
    return 0;
  };
  return [...items].sort(cmp);
}

export function ProceduresList(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = store.getState();
  const ps = () => snap().objects;

  onMount(() => {
    store.dispatch({ tag: "objects", action: { tag: "procs-list-load" } });
  });

  useListKeyboard({
    items: () => filtered().map((item) => ({
      select: () => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: item.object, procName: item.name } }),
    })),
    tableSelector: ".procs-list-table",
  });

  const filtered = () => {
    const items = ps().proceduresList ?? [];
    const q = ps().proceduresListQ.toLowerCase();
    const kind = ps().proceduresListKind;
    const filtered = items.filter((p) => {
      if (kind && p.proc_type !== kind) return false;
      if (q && !p.name.toLowerCase().includes(q) && !p.object.toLowerCase().includes(q)) return false;
      return true;
    });
    return sortItems(filtered, ps().proceduresListSort, ps().proceduresListOrder);
  };

  const sortHeader = (col: "name" | "object" | "cyclomatic" | "caller_count", label: string) => {
    const active = () => ps().proceduresListSort === col;
    const sortIcon = () => {
      if (!active()) return <ArrowUpDown size={11} style={{ "vertical-align": "middle", opacity: "0.3" }} />;
      return ps().proceduresListOrder === "asc"
        ? <ChevronUp size={11} style={{ "vertical-align": "middle" }} />
        : <ChevronDown size={11} style={{ "vertical-align": "middle" }} />;
    };
    return (
      <th
        class={active() ? "sorted" : ""}
        style={{ cursor: "pointer" }}
        onClick={() => store.dispatch({ tag: "objects", action: { tag: "procs-list-sort", col } })}
      >
        {label}{" "}{sortIcon()}
      </th>
    );
  };

  const total = () => ps().proceduresList?.length ?? 0;
  const visibleCount = () => filtered().length;

  const headerLabel = () => {
    const hasFilter = ps().proceduresListQ || ps().proceduresListKind;
    if (hasFilter) return `Procedures — showing ${visibleCount()} of ${total()}`;
    return `Procedures (${total()})`;
  };

  return (
    <>
      <div style={{ display: "flex", gap: "8px", "align-items": "center", "margin-bottom": "12px" }}>
        <input
          class="search-input"
          style={{ flex: 1 }}
          type="text"
          placeholder="Search procedures or objects…"
          value={ps().proceduresListQ}
          onInput={(e) => {
            store.dispatch({ tag: "objects", action: { tag: "procs-list-filter", q: e.currentTarget.value } });
          }}
        />
      </div>

      <div class="filter-pills" style={{ "margin-bottom": "12px" }}>
        <For each={["", "function", "subroutine", "event", "on"]}>
          {(k) => (
            <button
              class={`filter-pill${ps().proceduresListKind === k ? " active" : ""}`}
              onClick={() => {
                store.dispatch({ tag: "objects", action: { tag: "procs-list-filter-kind", kind: k } });
              }}
            >
              {k ? KIND_LABELS[k] ?? k : "All"}
            </button>
          )}
        </For>
      </div>

      <Show when={!ps().proceduresListLoading} fallback={<Loading />}>
        <div class="card">
          <div class="card-header"><h2>{headerLabel()}</h2></div>
          <table class="data-table procs-list-table">
            <thead>
              <tr>
                {sortHeader("name", "Name")}
                {sortHeader("object", "Object")}
                <th>Type</th>
                {sortHeader("cyclomatic", "CC")}
                {sortHeader("caller_count", "Callers")}
              </tr>
            </thead>
            <tbody>
              <For each={filtered()} fallback={
                <tr><td colspan="5" style={{ color: "var(--text-muted)", padding: "16px" }}>No procedures found.</td></tr>
              }>
                {(p) => (
                  <tr>
                    <td class="name-cell" style={{ padding: "4px 8px" }}>
                      <EntityCard
                        type="procedure"
                        name={p.name}
                        tooltip={`${p.object}.${p.name}`}
                        onClick={() => store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: p.object, procName: p.name } })}
                      />
                    </td>
                    <td style={{ padding: "4px 8px" }}>
                      <EntityCard
                        type="object"
                        name={p.object}
                        onClick={() => store.dispatch({ tag: "objects", action: { tag: "select", name: p.object } })}
                      />
                    </td>
                    <td>
                      <span class={`badge badge-${procBadge(p.proc_type)}`}>{p.proc_type}</span>
                    </td>
                    <td>
                      {p.cyclomatic != null ? <span class="badge badge-cc">{String(p.cyclomatic)}</span> : "–"}
                    </td>
                    <td style={{ "font-size": "12px", color: "var(--text-muted)" }}>
                      {String(p.caller_count)}
                    </td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>
    </>
  );
}
