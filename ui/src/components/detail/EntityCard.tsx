// components/EntityCard.tsx — Unified entity card: icon + name + context.

import type { JSX } from "solid-js";
import { Show } from "solid-js";
import { Dynamic } from "solid-js/web";
import type { IconComp } from "../../utils/icons.js";
import { LayoutDashboard, Box, Code2, Grid3X3, Database } from "../../utils/icons.js";

export type EntityType = "library" | "object" | "procedure" | "datawindow" | "table";

const ENTITY_ICONS: Record<EntityType, IconComp> = {
  library:    LayoutDashboard,
  object:     Box,
  procedure:  Code2,
  datawindow: Grid3X3,
  table:      Database,
};

interface EntityCardProps {
  type: EntityType;
  name: string;
  context?: string;
  tooltip?: string;
  onClick: () => void;
}

export function EntityCard(props: EntityCardProps): JSX.Element {
  return (
    <button
      class="entity-card"
      onClick={props.onClick}
      onKeyDown={(e) => { if (e.key === "Enter") props.onClick(); }}
      title={props.tooltip}
      aria-label={`${props.type}: ${props.name}${props.context ? ` (${props.context})` : ""}`}
    >
      <span class="entity-card-icon" aria-hidden="true">
        <Dynamic component={ENTITY_ICONS[props.type]} size={14} />
      </span>
      <span class="entity-card-body">
        <span class="entity-card-name">{props.name}</span>
        <Show when={props.context}>
          <span class="entity-card-context">{props.context}</span>
        </Show>
      </span>
    </button>
  );
}
