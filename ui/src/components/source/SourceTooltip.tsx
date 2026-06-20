import { Show } from "solid-js";

interface SourceTooltipProps {
  tooltip: { html: string; x: number; y: number } | null;
}

export function SourceTooltip(props: SourceTooltipProps) {
  return (
    <Show when={props.tooltip}>
      <div
        class="source-proc-tooltip visible"
        style={{
          left: `${Math.min(props.tooltip!.x, window.innerWidth - 420)}px`,
          top: `${Math.min(props.tooltip!.y, window.innerHeight - 140)}px`,
        }}
        innerHTML={props.tooltip!.html}
      />
    </Show>
  );
}
