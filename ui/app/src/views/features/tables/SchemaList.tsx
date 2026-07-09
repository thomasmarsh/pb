// features/tables/SchemaList.tsx — Landing page for SCHEMAS > TABLES > [table] nav.
//
// Only navigable schemas are those the DDL catalog actually tagged with a
// namespace (see PB.Pipeline.Runner's --ddl schema-tag form). A single-
// schema/no-DDL corpus has none — this page then just says so; the plain
// "Tables" link (unscoped) keeps working exactly as before either way.

import { For, Show, onMount } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { Loading } from "@pb/platform";

export function SchemaList(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const ts = () => snap().tables;

  onMount(() => {
    if (ts().schemas.length === 0 && !ts().schemasLoading) {
      props.store.dispatch({ tag: "tables", action: { tag: "schemas-load" } });
    }
  });

  return (
    <div class="card">
      <div class="card-header"><h2>Schemas ({ts().schemas.length})</h2></div>

      <Show when={ts().schemasLoading}><Loading /></Show>

      <Show when={!ts().schemasLoading && ts().schemas.length === 0}>
        <p style={{ color: "var(--text-muted)", padding: "16px" }}>
          No schema-tagged tables in this corpus — the DDL catalog was loaded without
          per-schema tags, so there's only one implicit schema. Use Tables directly.
        </p>
      </Show>

      <Show when={ts().schemas.length > 0}>
        <table class="data-table">
          <thead><tr><th>Schema</th><th>Tables</th></tr></thead>
          <tbody>
            <For each={ts().schemas}>
              {(s) => (
                <tr>
                  <td class="name-cell" style={{ padding: "4px 8px" }}>
                    <a
                      href="#"
                      onClick={(e) => {
                        e.preventDefault();
                        props.store.dispatch({ tag: "tables", action: { tag: "select-schema", namespace: s.namespace } });
                      }}
                    >
                      {s.namespace}
                    </a>
                  </td>
                  <td>{String(s.table_count)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </Show>
    </div>
  );
}
