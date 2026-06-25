// CommandButton.tsx — PB commandbutton control renderer.

import type { LayoutControl } from "../../core/layout.js";

export function CommandButton(props: { ctrl: LayoutControl; onClick: () => void }) {
  return (
    <button
      class="control-commandbutton"
      style={{
        width: "100%",
        height: "100%",
        "font-size": "calc(11px / var(--canvas-scale, 1))",
        cursor: "pointer",
        border: "1px solid var(--border)",
        background: "var(--surface-raised)",
        color: "var(--text)",
        padding: "2px 6px",
        "box-sizing": "border-box",
      }}
      onClick={props.onClick}
    >
      {props.ctrl.text ?? props.ctrl.name}
    </button>
  );
}
