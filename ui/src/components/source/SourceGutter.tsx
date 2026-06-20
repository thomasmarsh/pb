import { For } from "solid-js";
import type { ProcedureInfo } from "../../types/api.js";
import { PROC_BADGE_COLORS } from "./pure/tooltip.js";

interface SourceGutterProps {
  lines: string[];
  procFirstLine: Map<number, ProcedureInfo>;
}

export function SourceGutter(props: SourceGutterProps) {
  return (
    <div class="source-gutter">
      <For each={props.lines}>
        {(_line, i) => {
          const lineNum = i() + 1;
          const proc = props.procFirstLine.get(lineNum);
          return (
            <div
              class="source-gutter-line"
              style={proc ? {
                color: PROC_BADGE_COLORS[proc.proc_type ?? ""] ?? "var(--text-muted)",
                "font-weight": "600",
              } : undefined}
            >
              {String(lineNum)}
            </div>
          );
        }}
      </For>
    </div>
  );
}
