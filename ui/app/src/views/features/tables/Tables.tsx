// features/tables/Tables.tsx — Shell: routes between list and detail based on state.

import { Show } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { TableList } from "./TableList.js";
import { TableDetail } from "./TableDetail.js";
import { SchemaList } from "./SchemaList.js";

export function Tables(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  return (
    <Show when={snap().nav.route.view === "tableDetail"} fallback={
      <Show when={snap().nav.route.view === "schemas"} fallback={<TableList store={props.store} />}>
        <SchemaList store={props.store} />
      </Show>
    }>
      <TableDetail store={props.store} />
    </Show>
  );
}
