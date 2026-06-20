import { Show, For } from "solid-js";
import type { JSX } from "solid-js";
import { EntityCard } from "./EntityCard.js";
import type { EntityType } from "./EntityCard.js";

interface EntityItem {
  type: EntityType;
  name: string;
  context?: string;
  tooltip?: string;
  onClick: () => void;
}

interface EntityListCardProps {
  title: string;
  count?: number;
  items: EntityItem[];
  emptyText?: string;
  meta?: string;
}

export function EntityListCard(props: EntityListCardProps): JSX.Element {
  const title = () => props.count != null ? `${props.title} (${props.count})` : props.title;
  return (
    <div class="card">
      <div class="card-header">
        {props.title && <h3>{title()}</h3>}
        {props.meta && <span class="card-meta">{props.meta}</span>}
      </div>
      <Show
        when={props.items.length > 0}
        fallback={<p class="muted-note">{props.emptyText ?? "None found."}</p>}
      >
        <div class="entity-card-list">
          <For each={props.items}>
            {(item) => (
              <EntityCard
                type={item.type}
                name={item.name}
                context={item.context}
                tooltip={item.tooltip}
                onClick={item.onClick}
              />
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}
