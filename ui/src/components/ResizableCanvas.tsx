// ResizableCanvas.tsx — Shared resizable/scalable container used by DwPreview and RuntimeView.
//
// Renders children at their natural PB-unit dimensions then applies a CSS transform
// to fit the available container width. Exposes resize handles on right/bottom/corner edges.

import { createSignal, onMount, onCleanup } from "solid-js";
import type { JSX } from "solid-js";

const HANDLE_W = 6;

export function ResizableCanvas(props: {
  naturalWidth: number;
  naturalHeight: number;
  baseScale: number;
  children: JSX.Element;
}) {
  let wrapperRef: HTMLDivElement | undefined;
  // Initialise to natural pixel dimensions so content is visible before ResizeObserver fires.
  const [containerW, setContainerW] = createSignal(props.naturalWidth * props.baseScale);
  const [containerH, setContainerH] = createSignal(props.naturalHeight * props.baseScale);

  const naturalWidthPx = () => props.naturalWidth * props.baseScale;
  const naturalHeightPx = () => props.naturalHeight * props.baseScale;

  onMount(() => {
    if (!wrapperRef) return;
    const parent = wrapperRef.parentElement;

    function applyParentWidth(pw: number): void {
      const nh = naturalHeightPx();
      const nw = naturalWidthPx();
      setContainerW(Math.max(200, pw));
      setContainerH(Math.max(120, nw > 0 ? Math.round(nh * (pw / nw)) : 120));
    }

    if (parent) applyParentWidth(Math.max(200, parent.clientWidth - 2));

    const ro = new ResizeObserver(([entry]) => {
      if (!entry || dragging()) return;
      const pw = entry.contentRect.width - 2;
      if (pw > 0) applyParentWidth(pw);
    });
    if (parent) ro.observe(parent);
    onCleanup(() => ro.disconnect());
  });

  const scale = () => {
    const nw = naturalWidthPx();
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
    // --canvas-scale lets child controls counter-scale their font sizes to stay
    // visually constant regardless of how far the canvas is zoomed in or out.
    <div ref={wrapperRef} style={{ position: "relative", "--canvas-scale": `${scale()}` } as Record<string, string>}>
      <div style={{
        width: `${containerW()}px`,
        height: `${containerH()}px`,
        overflow: "hidden",
        position: "relative",
        border: "1px solid #ccc",
      }}>
        <div style={{
          width: `${naturalWidthPx()}px`,
          height: `${naturalHeightPx()}px`,
          transform: `scale(${scale()})`,
          "transform-origin": "top left",
          position: "relative",
        }}>
          {props.children}
        </div>

        {/* Resize handles */}
        <div
          style={{ position: "absolute", top: 0, right: 0, width: `${HANDLE_W}px`, height: "100%", cursor: "ew-resize", "z-index": "10" }}
          onMouseDown={(e) => startDrag("x", e)}
        />
        <div
          style={{ position: "absolute", bottom: 0, left: 0, width: "100%", height: `${HANDLE_W}px`, cursor: "ns-resize", "z-index": "10" }}
          onMouseDown={(e) => startDrag("y", e)}
        />
        <div
          style={{ position: "absolute", bottom: 0, right: 0, width: `${HANDLE_W * 2}px`, height: `${HANDLE_W * 2}px`, cursor: "nwse-resize", "z-index": "10" }}
          onMouseDown={(e) => startDrag("xy", e)}
        />
      </div>
    </div>
  );
}
