// StaticText.tsx — PB statictext control renderer.

import type { LayoutControl } from "../../core/layout.js";

export function StaticText(props: { ctrl: LayoutControl }) {
  return (
    <div
      class="control-statictext"
      style={{
        "font-size": "11px",
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
