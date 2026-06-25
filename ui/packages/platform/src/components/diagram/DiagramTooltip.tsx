import { Show } from "solid-js";
import type { JSX } from "solid-js";

interface DiagramTooltipProps {
  x: number;
  y: number;
  name: string;
  kind?: string;
  meta: Record<string, string>;
  actions?: { label: string; onClick: () => void }[];
  onMouseOver?: (e: MouseEvent) => void;
  onMouseOut?: (e: MouseEvent) => void;
}

export function DiagramTooltip(props: DiagramTooltipProps): JSX.Element {
  return (
    <div
      class="diagram-tooltip"
      style={{ left: `${props.x}px`, top: `${props.y}px` }}
      onMouseOver={props.onMouseOver}
      onMouseOut={props.onMouseOut}
    >
      <div class="diagram-tooltip-header">
        <span class="diagram-tooltip-name">{props.name}</span>
        {props.kind && <span class="diagram-tooltip-badge">{props.kind}</span>}
      </div>
      <Show when={Object.keys(props.meta).length > 0 && !props.kind}>
        <div class="diagram-tooltip-meta">
          {Object.entries(props.meta).map(([k, v]) => `${k}=${v}`).join(" · ")}
        </div>
      </Show>
      {props.actions && props.actions.length > 0 && (
        <div class="diagram-tooltip-actions">
          {props.actions.map((a, i) => (
            <>
              {i > 0 && <span class="diagram-tooltip-sep">&middot;</span>}
              <a class="diagram-tooltip-link" onClick={a.onClick}>{a.label}</a>
            </>
          ))}
        </div>
      )}
    </div>
  );
}
