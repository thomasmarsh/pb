// components/EntityCard.tsx — Unified entity card: icon + name + context.

import type { JSX } from "solid-js";
import { Show } from "solid-js";

export type EntityType = "library" | "object" | "procedure" | "datawindow" | "table";

const ENTITY_ICONS: Record<EntityType, string> = {
  library:    "◆",
  object:     "⬜",
  procedure:  "ƒ",
  datawindow: "▦",
  table:      "⊟",
};

interface EntityCardProps {
  type: EntityType;
  name: string;
  context?: string;
  tooltip?: string;
  onClick: () => void;
}

export function EntityCard(props: EntityCardProps): JSX.Element {
  const icon = () => ENTITY_ICONS[props.type];

  return (
    <button
      class="entity-card"
      onClick={props.onClick}
      onKeyDown={(e) => { if (e.key === "Enter") props.onClick(); }}
      title={props.tooltip}
      aria-label={`${props.type}: ${props.name}${props.context ? ` (${props.context})` : ""}`}
    >
      <span class="entity-card-icon" aria-hidden="true">{icon()}</span>
      <span class="entity-card-body">
        <span class="entity-card-name">{props.name}</span>
        <Show when={props.context}>
          <span class="entity-card-context">{props.context}</span>
        </Show>
      </span>
    </button>
  );
}
