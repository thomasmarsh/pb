// TableChip.tsx — Clickable pill that navigates to a table detail view.

import type { JSX } from "solid-js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";

interface TableChipProps {
  name:  string;
  store: Store<AppState, AppAction>;
  size?: "sm" | "md";
}

export function TableChip(props: TableChipProps): JSX.Element {
  function navigate() {
    props.store.dispatch({
      tag: "nav",
      action: { tag: "navigate", route: { view: "tableDetail", name: props.name } },
    });
  }
  return (
    <span
      class={`table-chip table-chip-${props.size ?? "md"}`}
      role="button"
      tabIndex={0}
      onClick={navigate}
      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); navigate(); } }}
    >
      ⊡ {props.name}
    </span>
  );
}
