// UsesCard.tsx — Statically-resolvable outbound "uses" edges for this object
// (Plan 210 Phase 4b): window opens, object creates, menu/DW bindings, and
// global function calls, each navigable to its target.

import type { Store } from "@pb/core";
import type { AppState } from "../../../../state.js";
import type { AppAction } from "../../../../actions.js";
import { EntityListCard, type UseInfo, type UseKind } from "@pb/platform";

const KIND_LABELS: Record<UseKind, string> = {
  window_open: "opens",
  object_create: "creates",
  menu_binding: "menu",
  dw_binding: "DataWindow binding",
  function_call: "calls",
};

function useContext(u: UseInfo): string {
  const label = KIND_LABELS[u.kind];
  if (u.kind === "dw_binding") return `${label} (${u.control_name})`;
  if (u.proc_name != null && u.line != null) return `${label} · ${u.proc_name}:${u.line}`;
  return label;
}

export function UsesCard(props: { store: Store<AppState, AppAction>; uses: UseInfo[] }) {
  return (
    <EntityListCard
      title=""
      items={props.uses.map((u) => ({
        type: u.target_category === "datawindow" ? "datawindow" as const : "object" as const,
        name: u.target,
        context: useContext(u),
        onClick: () => {
          if (u.target_category === "datawindow") {
            props.store.dispatch({ tag: "datawindows", action: { tag: "select", name: u.target } });
          } else {
            props.store.dispatch({ tag: "objects", action: { tag: "select", name: u.target } });
          }
        },
      }))}
      emptyText="No statically-resolvable uses found."
    />
  );
}
