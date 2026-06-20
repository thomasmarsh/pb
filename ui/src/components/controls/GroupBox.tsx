// GroupBox.tsx — PB groupbox control renderer.

import type { LayoutControl } from "../../core/layout.js";

export function GroupBox(props: { ctrl: LayoutControl }) {
  return (
    <fieldset
      class="control-groupbox"
      style={{
        width: "100%",
        height: "100%",
        "font-size": "11px",
        border: "1px solid var(--border)",
        padding: "4px",
        "box-sizing": "border-box",
      }}
    >
      <legend style={{ "font-size": "11px", color: "var(--text-muted)", padding: "0 4px" }}>
        {props.ctrl.text ?? ""}
      </legend>
    </fieldset>
  );
}
