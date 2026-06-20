import { Show, For } from "solid-js";
import type { DataWindowFile } from "../types/ast.generated.js";
import { extractDwLayout, type DwBandLayout, type DwControlLayout } from "../core/dwLayout.js";

const SCALE = 0.12; // PB units → px

const BAND_BG: Record<string, string> = {
  BkHeader: "#e8f0fe",
  BkDetail: "#ffffff",
  BkSummary: "#f0f0f0",
  BkFooter: "#f5f5f5",
};

function bandLabel(tag: string): string {
  return tag.replace("Bk", "").toLowerCase();
}

function BandStripe(props: { band: DwBandLayout; totalWidth: number }) {
  if (props.band.height === 0) return null;
  return (
    <div style={{
      position: "absolute",
      top: `${props.band.yOffset * SCALE}px`,
      left: 0,
      width: `${props.totalWidth * SCALE}px`,
      height: `${props.band.height * SCALE}px`,
      "border-bottom": "1px solid #ddd",
      background: BAND_BG[props.band.tag] ?? "#fff",
      "box-sizing": "border-box",
    }}>
      <span style={{ "font-size": "9px", color: "#888", padding: "1px 3px", "line-height": "1" }}>
        {bandLabel(props.band.tag)}
      </span>
    </div>
  );
}

function ControlBox(props: { ctrl: DwControlLayout; bands: DwBandLayout[] }) {
  const band = props.bands.find((b) => b.tag === props.ctrl.band);
  const yBase = band?.yOffset ?? 0;
  const label = props.ctrl.label ?? props.ctrl.colName ?? props.ctrl.type;
  const isText = props.ctrl.type === "text";

  return (
    <div style={{
      position: "absolute",
      left: `${props.ctrl.x * SCALE}px`,
      top: `${(yBase + props.ctrl.y) * SCALE}px`,
      width: `${props.ctrl.width * SCALE}px`,
      height: `${props.ctrl.height * SCALE}px`,
      border: isText ? "none" : "1px solid #bbb",
      background: isText ? "transparent" : "#fafafa",
      overflow: "hidden",
      "font-size": "9px",
      display: "flex",
      "align-items": "center",
      "padding-left": "2px",
      "box-sizing": "border-box",
      color: isText ? "#555" : "#222",
      "font-weight": isText ? "600" : "normal",
    }}>
      {label}
    </div>
  );
}

export function DwPreview(props: { layout: DataWindowFile | null }) {
  const lay = () => props.layout ? extractDwLayout(props.layout) : null;

  return (
    <div class="dw-preview" style={{ "overflow-x": "auto" }}>
      <Show when={lay()}>
        {(l) => (
          <div style={{
            position: "relative",
            width: `${l().totalWidth * SCALE}px`,
            height: `${l().totalHeight * SCALE}px`,
            border: "1px solid #ccc",
            "min-width": "100px",
            "min-height": "20px",
          }}>
            <For each={l().bands}>
              {(band) => <BandStripe band={band} totalWidth={l().totalWidth} />}
            </For>
            <For each={l().controls}>
              {(ctrl) => <ControlBox ctrl={ctrl} bands={l().bands} />}
            </For>
          </div>
        )}
      </Show>
    </div>
  );
}
