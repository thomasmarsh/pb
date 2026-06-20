// RuntimeView.tsx — Wireframe layout renderer + minimal event interpreter.

import { createSignal, Show, For } from "solid-js";
import { extractLayout } from "../../core/layout.js";
import { PBInterpreter, type AstData } from "../../core/interpreter.js";
import type { WindowLayout, LayoutControl } from "../../core/layout.js";
import { StaticText } from "../controls/StaticText.js";
import { CommandButton } from "../controls/CommandButton.js";
import { GroupBox } from "../controls/GroupBox.js";
import { LineEdit } from "../controls/LineEdit.js";

// PB units to CSS pixels. ~0.08 gives a reasonable preview size.
const SCALE = 0.08;

function renderControl(ctrl: LayoutControl, onClick: () => void): import("solid-js").JSX.Element {
  const t = ctrl.type.toLowerCase();
  if (t === "statictext") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><StaticText ctrl={ctrl} /></div>;
  }
  if (t === "commandbutton") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><CommandButton ctrl={ctrl} onClick={onClick} /></div>;
  }
  if (t === "groupbox") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><GroupBox ctrl={ctrl} /></div>;
  }
  if (t === "singlelineedit" || t === "multilineedit") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><LineEdit ctrl={ctrl} /></div>;
  }
  // Fallback: generic ControlBox
  return <ControlBox ctrl={ctrl} onClick={onClick} />;
}

function controlStyle(ctrl: LayoutControl): Record<string, string> {
  return {
    position: "absolute",
    left: `${ctrl.x * SCALE}px`,
    top: `${ctrl.y * SCALE}px`,
    width: `${ctrl.width * SCALE}px`,
    height: `${ctrl.height * SCALE}px`,
    overflow: "hidden",
  };
}

function ControlBox(props: {
  ctrl: LayoutControl;
  onClick: () => void;
}) {
  const isDw = () => props.ctrl.type.toLowerCase().includes("dw") || props.ctrl.name.startsWith("dw_");
  return (
    <div
      class="runtime-control"
      style={{
        ...controlStyle(props.ctrl),
        border: "1px solid var(--border)",
        background: isDw() ? "var(--surface)" : "var(--surface-raised)",
        padding: "2px 4px",
        "font-size": "10px",
        cursor: "pointer",
        "box-sizing": "border-box",
        color: "var(--text-muted)",
      }}
      onClick={props.onClick}
      title={`${props.ctrl.name} (${props.ctrl.type})`}
    >
      <span style={{ "font-weight": "600", color: "var(--text)" }}>{props.ctrl.name}</span>
      <Show when={isDw()}>
        <div style={{ "font-size": "9px", color: "var(--text-muted)", "margin-top": "2px" }}>
          [{props.ctrl.properties["dataobject"] ?? "DataWindow"}]
        </div>
      </Show>
      <Show when={props.ctrl.text && !isDw()}>
        <div style={{ "font-size": "9px" }}>{props.ctrl.text}</div>
      </Show>
    </div>
  );
}

function StateInspector(props: { state: { variables: Record<string, unknown>; controlValues: Record<string, unknown> } }) {
  const vars = () => Object.entries(props.state.variables);
  return (
    <Show when={vars().length > 0}>
      <div class="card" style={{ "margin-top": "8px", padding: "8px 12px" }}>
        <div style={{ "font-size": "11px", "font-weight": "600", "margin-bottom": "4px", color: "var(--text-muted)" }}>
          Runtime State
        </div>
        <table class="data-table" style={{ "font-size": "11px" }}>
          <tbody>
            <For each={vars()}>
              {([k, v]) => (
                <tr>
                  <td style={{ color: "var(--text-muted)", "padding-right": "12px" }}>{k}</td>
                  <td>{String(v)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </Show>
  );
}

export function RuntimeView(props: { objectName: string; astData: AstData | null }) {
  const [state, setState] = createSignal<{ variables: Record<string, unknown>; controlValues: Record<string, unknown> }>({ variables: {}, controlValues: {} });
  const [interp] = createSignal(new PBInterpreter());
  const [didOpen, setDidOpen] = createSignal(false);

  const layout = () => {
    const data = props.astData;
    if (!data) return null;
    const parsed = extractLayout(data.typeBlocks as unknown[]);

    // Fire open event once after first layout is available
    if (parsed && !didOpen()) {
      setDidOpen(true);
      const i = interp();
      i.setAst(data);
      i.executeEvent(props.objectName, "open").then(() => setState(i.getState()));
    }
    return parsed;
  };

  const handleControlClick = async (ctrl: LayoutControl) => {
    const i = interp();
    if (!i.ast) {
      const data = props.astData;
      if (data) i.setAst(data);
    }
    await i.executeEvent(ctrl.name, "clicked");
    setState(i.getState());
  };

  return (
    <div class="runtime-view">
      <Show when={!props.astData}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px" }}>No AST data available.</div>
      </Show>
      <Show when={layout()}>
        {(wl: () => WindowLayout) => (
          <>
            <div
              class="wireframe"
              style={{
                position: "relative",
                width: `${wl().width * SCALE}px`,
                height: `${wl().height * SCALE}px`,
                border: "1px solid var(--border)",
                background: "var(--bg)",
                overflow: "hidden",
              }}
            >
              <For each={wl().controls}>
                {(ctrl) => renderControl(ctrl, () => void handleControlClick(ctrl))}
              </For>
            </div>
            <StateInspector state={state()} />
          </>
        )}
      </Show>
    </div>
  );
}
