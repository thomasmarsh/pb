import { Show, For, createSignal, onMount, onCleanup } from "solid-js";
import type { DataWindowFile } from "../types/ast.generated.js";
import { extractDwLayout, type DwBandLayout, type DwControlLayout } from "../core/dwLayout.js";

const BASE_SCALE = 0.2;

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
      top: `${props.band.yOffset * BASE_SCALE}px`,
      left: 0,
      width: `${props.totalWidth * BASE_SCALE}px`,
      height: `${props.band.height * BASE_SCALE}px`,
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
      left: `${props.ctrl.x * BASE_SCALE}px`,
      top: `${(yBase + props.ctrl.y) * BASE_SCALE}px`,
      width: `${props.ctrl.width * BASE_SCALE}px`,
      height: `${props.ctrl.height * BASE_SCALE}px`,
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

const HANDLE_W = 6;

export function DwPreview(props: { layout: DataWindowFile | null }) {
  const lay = () => props.layout ? extractDwLayout(props.layout) : null;

  const naturalWidth = () => (lay()?.totalWidth ?? 0) * BASE_SCALE;
  const naturalHeight = () => (lay()?.totalHeight ?? 0) * BASE_SCALE;

  let wrapperRef: HTMLDivElement | undefined;
  const [containerW, setContainerW] = createSignal(0);
  const [containerH, setContainerH] = createSignal(0);

  onMount(() => {
    if (!wrapperRef) return;
    const parent = wrapperRef.parentElement;
    if (parent) {
      const w = parent.clientWidth - 2;
      setContainerW(Math.max(200, w));
      setContainerH(Math.max(120, Math.round(naturalHeight() * (w / Math.max(1, naturalWidth())))));
    }
    const ro = new ResizeObserver(([entry]) => {
      if (!entry || dragging()) return;
      const pw = entry.contentRect.width - 2;
      if (pw > 0) {
        setContainerW(pw);
        const nw = naturalWidth();
        if (nw > 0) setContainerH(Math.max(120, Math.round(naturalHeight() * (pw / nw))));
      }
    });
    if (parent) ro.observe(parent);
    onCleanup(() => ro.disconnect());
  });

  const scale = () => {
    const nw = naturalWidth();
    if (nw === 0 || containerW() === 0) return 1;
    return containerW() / nw;
  };

  const [dragging, setDragging] = createSignal(false);

  function startDrag(axis: "x" | "y" | "xy", e: MouseEvent): void {
    e.preventDefault();
    const startX = e.clientX;
    const startY = e.clientY;
    const startW = containerW();
    const startH = containerH();
    setDragging(true);
    document.body.style.userSelect = "none";

    function onMove(ev: MouseEvent): void {
      const dx = ev.clientX - startX;
      const dy = ev.clientY - startY;
      if (axis === "x" || axis === "xy") setContainerW(Math.max(200, startW + dx));
      if (axis === "y" || axis === "xy") setContainerH(Math.max(120, startH + dy));
    }
    function onUp(): void {
      setDragging(false);
      document.body.style.userSelect = "";
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    }
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  }

  return (
    <div class="dw-preview">
      <div ref={wrapperRef} style={{ position: "relative" }}>
        <Show when={lay()}>
          {(l) => (
            <div style={{
              width: `${containerW()}px`,
              height: `${containerH()}px`,
              overflow: "hidden",
              position: "relative",
              border: "1px solid #ccc",
            }}>
              <div style={{
                width: `${naturalWidth()}px`,
                height: `${naturalHeight()}px`,
                transform: `scale(${scale()})`,
                "transform-origin": "top left",
                position: "relative",
              }}>
                <For each={l().bands}>
                  {(band) => <BandStripe band={band} totalWidth={l().totalWidth} />}
                </For>
                <For each={l().controls}>
                  {(ctrl) => <ControlBox ctrl={ctrl} bands={l().bands} />}
                </For>
              </div>
              <div
                style={{
                  position: "absolute",
                  top: 0,
                  right: 0,
                  width: `${HANDLE_W}px`,
                  height: "100%",
                  cursor: "ew-resize",
                  "z-index": "10",
                }}
                onMouseDown={(e) => startDrag("x", e)}
              />
              <div
                style={{
                  position: "absolute",
                  bottom: 0,
                  left: 0,
                  width: "100%",
                  height: `${HANDLE_W}px`,
                  cursor: "ns-resize",
                  "z-index": "10",
                }}
                onMouseDown={(e) => startDrag("y", e)}
              />
              <div
                style={{
                  position: "absolute",
                  bottom: 0,
                  right: 0,
                  width: `${HANDLE_W * 2}px`,
                  height: `${HANDLE_W * 2}px`,
                  cursor: "nwse-resize",
                  "z-index": "10",
                }}
                onMouseDown={(e) => startDrag("xy", e)}
              />
            </div>
          )}
        </Show>
      </div>
    </div>
  );
}
