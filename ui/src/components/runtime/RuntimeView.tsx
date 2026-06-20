// RuntimeView.tsx — Wireframe layout renderer driven by the runtime reducer.

import { createEffect, createSignal, Show, For } from "solid-js";
import { extractLayout } from "../../core/layout.js";
import type { AstData, DWRow } from "../../core/interpreter.js";
import type { WindowLayout, LayoutControl } from "../../core/layout.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { StaticText } from "../controls/StaticText.js";
import { CommandButton } from "../controls/CommandButton.js";
import { GroupBox } from "../controls/GroupBox.js";
import { LineEdit } from "../controls/LineEdit.js";
import { DataWindowGrid } from "../DataWindowGrid.js";

// PB units to CSS pixels.
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

function ControlBox(props: { ctrl: LayoutControl; onClick: () => void }) {
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

function StateInspector(props: { variables: Record<string, unknown> }) {
  const vars = () => Object.entries(props.variables);
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

export function RuntimeView(props: {
  objectName: string;
  store: Store<AppState, AppAction>;
}) {
  const snap = props.store.getState();

  // Fire set-ast + run-event once when AST becomes available for this object.
  const [initialized, setInitialized] = createSignal<string | null>(null);
  createEffect(() => {
    if (initialized() === props.objectName) return;
    const ad = snap().objects.astData;
    if (!ad || "error" in ad) return;
    setInitialized(props.objectName);
    props.store.dispatch({ tag: "runtime", action: { tag: "set-ast", ast: ad as AstData } });
    props.store.dispatch({ tag: "runtime", action: { tag: "run-event", owner: props.objectName, event: "open" } });
  });

  const layout = (): WindowLayout | null => {
    const ad = snap().objects.astData;
    if (!ad || "error" in ad) return null;
    return extractLayout((ad as AstData).typeBlocks as unknown[]);
  };

  const controlValues = (): Record<string, DWRow[]> =>
    snap().runtime.controlValues as Record<string, DWRow[]>;

  const variables = (): Record<string, unknown> =>
    snap().runtime.variables;

  const handleControlClick = (ctrl: LayoutControl): void => {
    props.store.dispatch({ tag: "runtime", action: { tag: "control-click", controlName: ctrl.name } });
  };

  return (
    <div class="runtime-view">
      <Show when={!snap().objects.astData}>
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
                {(ctrl) => {
                  const isDw = ctrl.type.toLowerCase().includes("datawindow") || ctrl.name.startsWith("dw_");
                  if (isDw) {
                    return (
                      <div class="runtime-ctrl" style={controlStyle(ctrl)}>
                        <Show
                          when={controlValues()[ctrl.name]}
                          fallback={<ControlBox ctrl={ctrl} onClick={() => handleControlClick(ctrl)} />}
                        >
                          {(rows) => <DataWindowGrid data={rows() as DWRow[]} />}
                        </Show>
                      </div>
                    );
                  }
                  return renderControl(ctrl, () => handleControlClick(ctrl));
                }}
              </For>
            </div>
            <StateInspector variables={variables()} />
          </>
        )}
      </Show>
    </div>
  );
}
