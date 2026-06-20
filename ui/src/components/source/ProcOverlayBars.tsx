import { For } from "solid-js";
import type { ProcedureInfo } from "../../types/api.js";
import { PROC_COLORS } from "./pure/tooltip.js";
import { overlayTop, overlayHeight } from "./pure/line.js";

interface ProcOverlayBarsProps {
  procedures: ProcedureInfo[];
  selectedProcName?: string;
  procCountMap: Map<string, { caller_count: number; callee_count: number }>;
  onBarEnter: (p: ProcedureInfo, e: MouseEvent) => void;
  onBarLeave: () => void;
  onClick: (p: ProcedureInfo) => void;
}

export function ProcOverlayBars(props: ProcOverlayBarsProps) {
  return (
    <For each={props.procedures}>
      {(p) => {
        if (p.start_line == null || p.end_line == null) return null;
        const color = PROC_COLORS[p.proc_type ?? ""] ?? "";
        const isSelected = () => p.name === props.selectedProcName;

        return (
          <div
            class={`source-proc-bar ${color}${isSelected() ? " selected" : ""}`}
            style={{
              top: `${overlayTop(p.start_line!)}px`,
              height: `${overlayHeight(p.start_line!, p.end_line!)}px`,
            }}
            onMouseEnter={(e) => props.onBarEnter(p, e)}
            onMouseLeave={() => props.onBarLeave()}
            onClick={() => props.onClick(p)}
          />
        );
      }}
    </For>
  );
}
