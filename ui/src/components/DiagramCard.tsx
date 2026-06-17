// components/DiagramCard.tsx — Card wrapper for InlineDiagram with title header.

import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";
import type { DiagramKind } from "../utils/diagram.js";
import { InlineDiagram } from "./InlineDiagram.js";

export function DiagramCard(props: {
  title: string;
  kind: DiagramKind;
  params: Record<string, string | number>;
  store: Store<AppState, AppAction>;
  compact?: boolean;
}) {
  return (
    <div class="card">
      <div class="card-header"><h3>{props.title}</h3></div>
      <InlineDiagram kind={props.kind} params={props.params} store={props.store} compact={props.compact} />
    </div>
  );
}
