// LineEdit.tsx — PB singlelineedit / multilineedit control renderer.

import type { LayoutControl } from "@pb/interpreter";

export function LineEdit(props: { ctrl: LayoutControl }) {
  const isMulti = props.ctrl.type.toLowerCase().includes("multi");
  return isMulti ? (
    <textarea
      class="control-multilineedit"
      style={{
        width: "100%",
        height: "100%",
        "font-size": "11px",
        border: "1px solid var(--border)",
        background: "var(--surface)",
        color: "var(--text)",
        padding: "2px 4px",
        resize: "none",
        "box-sizing": "border-box",
      }}
      value={props.ctrl.text ?? ""}
      readOnly
    />
  ) : (
    <input
      class="control-singlelineedit"
      type="text"
      style={{
        width: "100%",
        height: "100%",
        "font-size": "11px",
        border: "1px solid var(--border)",
        background: "var(--surface)",
        color: "var(--text)",
        padding: "2px 4px",
        "box-sizing": "border-box",
      }}
      value={props.ctrl.text ?? ""}
      readOnly
    />
  );
}
