// StaticText.tsx — PB statictext control renderer.

import type { LayoutControl } from "@pb/interpreter";

export function StaticText(props: { ctrl: LayoutControl }) {
  return (
    <div
      class="control-statictext"
      style={{
        "font-size": "calc(11px / var(--canvas-scale, 1))",
        color: "var(--text)",
        padding: "2px 4px",
        "white-space": "nowrap",
        overflow: "hidden",
      }}
    >
      {props.ctrl.text ?? ""}
    </div>
  );
}
