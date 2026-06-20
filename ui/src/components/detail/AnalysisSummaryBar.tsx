import { For, Show } from "solid-js";
import type { JSX } from "solid-js";

export interface SummaryItem {
  label: string;
  count?: number;
  active?: boolean;
  onClick?: () => void;
}

interface AnalysisSummaryBarProps {
  items: SummaryItem[];
}

export function AnalysisSummaryBar(props: AnalysisSummaryBarProps): JSX.Element {
  return (
    <div class="analysis-summary-bar" style={{ display: "flex", "flex-wrap": "wrap", gap: "6px", padding: "8px 0" }}>
      <For each={props.items}>
        {(item) => (
          <Show
            when={item.onClick}
            fallback={
              <span class="filter-pill" style={{ cursor: "default" }}>
                {item.label}{item.count != null ? ` (${item.count})` : ""}
              </span>
            }
          >
            <button
              class={`filter-pill${item.active ? " active" : ""}`}
              onClick={item.onClick}
            >
              {item.label}{item.count != null ? ` (${item.count})` : ""}
            </button>
          </Show>
        )}
      </For>
    </div>
  );
}
