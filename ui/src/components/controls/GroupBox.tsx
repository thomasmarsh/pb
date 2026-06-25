// GroupBox.tsx — PB groupbox control renderer.

import type { LayoutControl } from "@pb/interpreter";

export function GroupBox(props: { ctrl: LayoutControl }) {
  return (
    <fieldset
      class="control-groupbox"
      style={{
        width: "100%",
        height: "100%",
        "font-size": "calc(11px / var(--canvas-scale, 1))",
        border: "1px solid var(--border)",
        padding: "4px",
        "box-sizing": "border-box",
      }}
    >
      <legend style={{ "font-size": "calc(11px / var(--canvas-scale, 1))", color: "var(--text-muted)", padding: "0 4px" }}>
        {props.ctrl.text ?? ""}
      </legend>
    </fieldset>
  );
}
