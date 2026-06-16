// Objects.tsx — Objects list and detail shell.

import { Show, onMount } from "solid-js";
import { useSnapshot } from "../../core/store.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../app/state.js";
import type { AppAction } from "../../app/actions.js";
import { ObjectList } from "./ObjectList.js";
import { ObjectDetail } from "./ObjectDetail.js";

export function Objects(props: { store: Store<AppState, AppAction> }) {
  const store = props.store;
  const snap = useSnapshot(store.state);
  const os = () => snap().objects;

  onMount(() => {
    store.dispatch({ tag: "nav", action: { type: "navigate", view: "objects" } });
    store.dispatch({ tag: "objects", action: { type: "search", q: os().q } });
  });

  return (
    <Show when={os().detail} fallback={<ObjectList store={store} />}>
      <ObjectDetail store={store} />
    </Show>
  );
}
