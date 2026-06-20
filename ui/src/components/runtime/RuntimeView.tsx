// RuntimeView.tsx — Wireframe layout renderer + minimal event interpreter (Plan 101a spike).

import { createSignal, createResource, Show, For } from "solid-js";
import { extractLayout } from "../../core/layout.js";
import { PBInterpreter } from "../../core/interpreter.js";
import type { WindowLayout, LayoutControl } from "../../core/layout.js";

// PB units to CSS pixels. ~0.08 gives a reasonable preview size.
const SCALE = 0.08;

async function fetchAst(objectName: string) {
  const r = await fetch(`/api/objects/${encodeURIComponent(objectName)}/ast`);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json() as Promise<{ typeBlocks: unknown[]; events: { name: string; owner: string; body: unknown[] }[] }>;
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
        position: "absolute",
        left: `${props.ctrl.x * SCALE}px`,
        top: `${props.ctrl.y * SCALE}px`,
        width: `${props.ctrl.width * SCALE}px`,
        height: `${props.ctrl.height * SCALE}px`,
        border: "1px solid var(--border)",
        background: isDw() ? "var(--surface)" : "var(--surface-raised)",
        padding: "2px 4px",
        "font-size": "10px",
        overflow: "hidden",
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

export function RuntimeView(props: { objectName: string }) {
  const [astData] = createResource(() => props.objectName, fetchAst);
  const [state, setState] = createSignal<{ variables: Record<string, unknown>; controlValues: Record<string, unknown> }>({ variables: {}, controlValues: {} });
  const [interp] = createSignal(new PBInterpreter());
  const [didOpen, setDidOpen] = createSignal(false);

  const layout = () => {
    const data = astData();
    if (!data) return null;
    const parsed = extractLayout(data.typeBlocks);

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
      const data = astData();
      if (data) i.setAst(data);
    }
    await i.executeEvent(ctrl.name, "clicked");
    setState(i.getState());
  };

  return (
    <div class="runtime-view">
      <Show when={astData.loading}>
        <div style={{ color: "var(--text-muted)", "font-size": "13px" }}>Loading layout…</div>
      </Show>
      <Show when={astData.error}>
        <div class="error-banner">Failed to load AST: {String(astData.error)}</div>
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
                {(ctrl) => (
                  <ControlBox ctrl={ctrl} onClick={() => void handleControlClick(ctrl)} />
                )}
              </For>
            </div>
            <StateInspector state={state()} />
          </>
        )}
      </Show>
    </div>
  );
}
