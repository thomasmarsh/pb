// components/windows/WindowRuntimeView.tsx — Lightweight runtime renderer for launched windows.
//
// Unlike RuntimeView (which initializes from objects.astData and dispatches set-ast/run-event),
// this component renders from the already-initialized runtime state. Used by Desktop to show
// content inside managed windows opened via the launch flow.

import { Show, For, type JSX } from "solid-js";
import { extractLayout } from "../../core/layout.js";
import type { DWRow } from "../../core/interpreter.js";
import { flattenVarEnv } from "../../core/cps/var-env.js";
import { initialRuntimeState } from "../../features/runtime/reducer.js";
import type { WindowLayout, LayoutControl } from "../../core/layout.js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { StaticText } from "../controls/StaticText.js";
import { CommandButton } from "../controls/CommandButton.js";
import { GroupBox } from "../controls/GroupBox.js";
import { LineEdit } from "../controls/LineEdit.js";
import { DataWindowGrid } from "../DataWindowGrid.js";
import { ResizableCanvas } from "../ResizableCanvas.js";

const BASE_SCALE = 0.08;

function controlStyle(ctrl: LayoutControl): Record<string, string> {
  return {
    position: "absolute",
    left: `${ctrl.x * BASE_SCALE}px`,
    top: `${ctrl.y * BASE_SCALE}px`,
    width: `${ctrl.width * BASE_SCALE}px`,
    height: `${ctrl.height * BASE_SCALE}px`,
    overflow: "hidden",
  };
}

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
          [{props.ctrl.dataobject ?? props.ctrl.properties?.["dataobject"] ?? "DataWindow"}]
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

export function WindowRuntimeView(props: {
  windowId: string;
  store: Store<AppState, AppAction>;
}): JSX.Element {
  const snap = props.store.getState();

  const runtime = () => snap().runtimes[props.windowId] ?? initialRuntimeState;

  const layout = (): WindowLayout | null => {
    const ast = runtime().ast;
    if (!ast) return null;
    return extractLayout(ast.typeBlocks as unknown[]);
  };

  const controlValues = (): Record<string, DWRow[]> =>
    runtime().controlValues as Record<string, DWRow[]>;

  const variables = (): Record<string, unknown> =>
    flattenVarEnv(runtime().varEnv);

  const handleControlClick = (ctrl: LayoutControl): void => {
    props.store.dispatch({ tag: "runtime", windowId: props.windowId, action: { tag: "control-click", controlName: ctrl.name } });
  };

  return (
    <div class="runtime-view">
      <Show when={!runtime().ast}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px" }}>Loading window…</div>
      </Show>
      <Show when={runtime().error}>
        <div style={{ color: "var(--error)", "font-size": "13px" }}>
          Error: {runtime().error}
        </div>
      </Show>
      <Show when={layout()}>
        {(wl: () => WindowLayout) => (
          <>
            <ResizableCanvas
              naturalWidth={wl().width}
              naturalHeight={wl().height}
              baseScale={BASE_SCALE}
            >
              <For each={wl().controls}>
                {(ctrl) => {
                  const isDw = ctrl.type.toLowerCase().includes("datawindow") || ctrl.name === "dw" || ctrl.name.startsWith("dw_");
                  if (isDw) {
                    const effectiveH = ctrl.height > 0 ? ctrl.height : wl().height - ctrl.y;
                    const dwStyle = { ...controlStyle(ctrl), height: `${effectiveH * BASE_SCALE}px` };
                    return (
                      <div class="runtime-ctrl" style={dwStyle}>
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
            </ResizableCanvas>
            <StateInspector variables={variables()} />
          </>
        )}
      </Show>
    </div>
  );
}
