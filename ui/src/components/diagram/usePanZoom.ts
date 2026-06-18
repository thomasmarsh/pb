// components/usePanZoom.ts — Pan/zoom/momentum hook for diagram viewports.

import { createSignal } from "solid-js";
import { computeZoom, smoothVelocity, releaseVelocity, runMomentum } from "./diagramMath.js";

const SMOOTHING = 0.4;
const ZOOM_BUTTON_STEP = 1.3;

export interface PanZoomState {
  scale: () => number;
  offset: () => { x: number; y: number };
  dragging: () => boolean;
  momentum: () => boolean;
}

export interface PanZoomActions {
  zoomIn: () => void;
  zoomOut: () => void;
  resetView: () => void;
  setView: (scale: number, offX: number, offY: number) => void;
}

export interface PanZoomHandlers {
  onWheel: (e: WheelEvent) => void;
  onMouseDown: (e: MouseEvent) => void;
  onMouseMove: (e: MouseEvent) => void;
  onMouseUp: () => void;
  onMouseLeave: () => void;
}

export interface PanZoom {
  state: PanZoomState;
  actions: PanZoomActions & { dismissTooltip: () => void };
  handlers: PanZoomHandlers;
  cleanup: () => void;
  setViewportRef: (el: HTMLDivElement) => void;
  removeViewportRef: () => void;
}

export function createPanZoom(opts: {
  dismissTooltip: () => void;
}): PanZoom {
  const [scale, setScale] = createSignal(1);
  const [offset, setOffset] = createSignal({ x: 0, y: 0 });
  const [dragging, setDragging] = createSignal(false);
  const [momentum, setMomentum] = createSignal(false);

  let momentumRaf = 0;
  let dragStart = { x: 0, y: 0 };
  let offsetStart = { x: 0, y: 0 };
  let lastMoveTime = 0;
  let lastMovePos = { x: 0, y: 0 };
  let smoothVx = 0;
  let smoothVy = 0;
  let viewportRef: HTMLDivElement | null = null;

  function cleanup() {
    cancelAnimationFrame(momentumRaf);
    setMomentum(false);
  }

  function setViewportRef(el: HTMLDivElement) {
    viewportRef = el;
    el.addEventListener("wheel", handlers.onWheel, { passive: false });
  }

  function removeViewportRef() {
    viewportRef?.removeEventListener("wheel", handlers.onWheel);
    viewportRef = null;
  }

  function handleWheel(e: WheelEvent) {
    if (e.ctrlKey) e.preventDefault();
    e.preventDefault();
    opts.dismissTooltip();
    if (!viewportRef) return;
    const rect = viewportRef.getBoundingClientRect();
    const mx = e.clientX - rect.left;
    const my = e.clientY - rect.top;
    const { scale: s, offsetX: ox, offsetY: oy } = computeZoom(e.deltaY, scale(), offset().x, offset().y, mx, my);
    setOffset({ x: ox, y: oy });
    setScale(s);
  }

  function handleMouseDown(e: MouseEvent) {
    if (e.button !== 0) return;
    if ((e.target as HTMLElement).closest("a, button")) return;
    cancelAnimationFrame(momentumRaf);
    setMomentum(false);
    setDragging(true);
    opts.dismissTooltip();
    dragStart = { x: e.clientX, y: e.clientY };
    offsetStart = { ...offset() };
    lastMoveTime = performance.now();
    lastMovePos = { x: e.clientX, y: e.clientY };
    smoothVx = 0;
    smoothVy = 0;
  }

  function handleMouseMove(e: MouseEvent) {
    if (!dragging()) return;
    const now = performance.now();
    const dt = now - lastMoveTime;
    if (dt > 0) {
      const vx = (e.clientX - lastMovePos.x) / dt;
      const vy = (e.clientY - lastMovePos.y) / dt;
      smoothVx = smoothVelocity(smoothVx, vx, SMOOTHING);
      smoothVy = smoothVelocity(smoothVy, vy, SMOOTHING);
    }
    lastMoveTime = now;
    lastMovePos = { x: e.clientX, y: e.clientY };
    setOffset({
      x: offsetStart.x + (e.clientX - dragStart.x),
      y: offsetStart.y + (e.clientY - dragStart.y),
    });
  }

  function handleMouseUp() {
    if (!dragging()) return;
    setDragging(false);
    cancelAnimationFrame(momentumRaf);
    const v = releaseVelocity(smoothVx, smoothVy);
    if (!v) return;
    setMomentum(true);
    const cur = offset();
    momentumRaf = runMomentum(v.fx, v.fy, cur.x, cur.y, (x, y) => setOffset({ x, y }), () => setMomentum(false));
  }

  function handleMouseLeave() {
    if (!dragging()) return;
    setDragging(false);
    cancelAnimationFrame(momentumRaf);
  }

  function zoomIn() {
    opts.dismissTooltip();
    setScale(s => Math.min(8, s * ZOOM_BUTTON_STEP));
  }

  function zoomOut() {
    opts.dismissTooltip();
    setScale(s => Math.max(0.15, s / ZOOM_BUTTON_STEP));
  }

  function resetView() {
    opts.dismissTooltip();
    setScale(1);
    setOffset({ x: 0, y: 0 });
  }

  function setView(scale: number, offX: number, offY: number) {
    opts.dismissTooltip();
    setScale(scale);
    setOffset({ x: offX, y: offY });
  }

  const handlers: PanZoomHandlers = {
    onWheel: handleWheel,
    onMouseDown: handleMouseDown,
    onMouseMove: handleMouseMove,
    onMouseUp: handleMouseUp,
    onMouseLeave: handleMouseLeave,
  };

  return {
    state: { scale, offset, dragging, momentum },
    actions: { zoomIn, zoomOut, resetView, setView, dismissTooltip: opts.dismissTooltip },
    handlers,
    cleanup,
    setViewportRef,
    removeViewportRef,
  };
}
