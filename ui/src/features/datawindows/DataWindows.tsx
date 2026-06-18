// DataWindows.tsx — Shell: routes between list and detail based on state.

import { Show } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { DWList } from "./DWList.js";
import { DWDetail } from "./DWDetail.js";

export function DataWindows(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  return (
    <Show when={snap().datawindows.dwDetail} fallback={<DWList store={props.store} />}>
      <DWDetail store={props.store} />
    </Show>
  );
}

export { DWDetail } from "./DWDetail.js";
