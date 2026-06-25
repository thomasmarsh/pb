// features/tables/Tables.tsx — Shell: routes between list and detail based on state.

import { Show } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../app/src/state.js";
import type { AppAction } from "../../../app/src/actions.js";
import { TableList } from "./TableList.js";
import { TableDetail } from "./TableDetail.js";

export function Tables(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  return (
    <Show when={snap().nav.route.view === "tableDetail"}
          fallback={<TableList store={props.store} />}>
      <TableDetail store={props.store} />
    </Show>
  );
}
