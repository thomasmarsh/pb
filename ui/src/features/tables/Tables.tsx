// features/tables/Tables.tsx — Shell: routes between list and detail based on state.

import { Show } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { TableList } from "./TableList.js";
import { TableDetail } from "./TableDetail.js";

export function Tables(props: { store: Store<AppState, AppAction> }) {
  const snap = useSnapshot(props.store.state);
  return (
    <Show when={snap().nav.route.view === "tableDetail"}
          fallback={<TableList store={props.store} />}>
      <TableDetail store={props.store} />
    </Show>
  );
}
