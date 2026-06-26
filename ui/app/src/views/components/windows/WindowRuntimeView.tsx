// components/windows/WindowRuntimeView.tsx — Lightweight runtime renderer for launched windows.
//
// Unlike RuntimeView (which initializes from objects.astData and dispatches set-ast/run-event),
// this component renders from the already-initialized runtime state. Used by Desktop to show
// content inside managed windows opened via the launch flow.

import { Show, For, type JSX } from "solid-js";
import { flattenVarEnv, type DWRow, type WindowLayout, type LayoutControl } from "@pb/interpreter";
import { initialRuntimeState } from "@pb/windowing";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import { StaticText, CommandButton, GroupBox, LineEdit, DataWindowGrid, ResizableCanvas } from "@pb/platform";

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

function resolveControlText(ctrl: LayoutControl, vars: Record<string, unknown>): string | undefined {
  const val = vars[ctrl.name];
  return typeof val === "string" ? val : ctrl.text;
}

function renderControl(ctrl: LayoutControl, onClick: () => void, vars: Record<string, unknown>): import("solid-js").JSX.Element {
  const resolved = { ...ctrl, text: resolveControlText(ctrl, vars) };
  const t = ctrl.type.toLowerCase();
  if (t === "statictext") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><StaticText ctrl={resolved} /></div>;
  }
  if (t === "commandbutton") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><CommandButton ctrl={resolved} onClick={onClick} /></div>;
  }
  if (t === "groupbox") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><GroupBox ctrl={resolved} /></div>;
  }
  if (t === "singlelineedit" || t === "multilineedit") {
    return <div class="runtime-ctrl" style={controlStyle(ctrl)}><LineEdit ctrl={resolved} /></div>;
  }
  return (
    <div class="runtime-ctrl" style={controlStyle(ctrl)}>
      <ControlBox ctrl={resolved} onClick={onClick} />
    </div>
  );
}

function ControlBox(props: { ctrl: LayoutControl; onClick: () => void }) {
  const isDw = () => props.ctrl.type.toLowerCase().includes("dw") || props.ctrl.name.startsWith("dw_");
  return (
    <div
      class="runtime-control"
      style={{
        position: "absolute",
        left: "0",
        top: "0",
        width: "100%",
        height: "100%",
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

  const layout = (): WindowLayout | null => runtime().layout;

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
                  const resolved = { ...ctrl, text: resolveControlText(ctrl, variables()) };
                  if (isDw) {
                    const effectiveH = ctrl.height > 0 ? ctrl.height : wl().height - ctrl.y;
                    const dwStyle = { ...controlStyle(ctrl), height: `${effectiveH * BASE_SCALE}px` };
                    return (
                      <div class="runtime-ctrl" style={dwStyle}>
                        <Show
                          when={controlValues()[ctrl.name]}
                          fallback={<ControlBox ctrl={resolved} onClick={() => handleControlClick(ctrl)} />}
                        >
                          {(rows) => <DataWindowGrid data={rows() as DWRow[]} />}
                        </Show>
                      </div>
                    );
                  }
                  return renderControl(resolved, () => handleControlClick(ctrl), variables());
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
