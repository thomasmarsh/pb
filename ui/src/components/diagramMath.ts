// components/diagramMath.ts — Pure functions for diagram zoom/pan/momentum.
// No framework imports — fully testable.

export const ZOOM_MIN = 0.15;
export const ZOOM_MAX = 8;
const ZOOM_STEP = 1.15;
const MS_PER_FRAME = 1000 / 60;
const MAX_SPEED = 40;
const FRICTION = 0.955;
const MIN_VELOCITY = 0.05;

/** Compute new scale and offset for a wheel-zoom at (mouseX, mouseY). */
export function computeZoom(
  deltaY: number,
  scale: number,
  offsetX: number,
  offsetY: number,
  mouseX: number,
  mouseY: number,
): { scale: number; offsetX: number; offsetY: number } {
  const factor = deltaY < 0 ? ZOOM_STEP : 1 / ZOOM_STEP;
  const newScale = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, scale * factor));
  const ratio = newScale / scale;
  return {
    scale: newScale,
    offsetX: mouseX - ratio * (mouseX - offsetX),
    offsetY: mouseY - ratio * (mouseY - offsetY),
  };
}

/** Exponential moving average for velocity smoothing. */
export function smoothVelocity(prev: number, next: number, factor: number): number {
  return prev * (1 - factor) + next * factor;
}

/** Strip Graphviz <title> elements to prevent native browser tooltips. */
export function stripSvgTitles(html: string): string {
  return html.replace(/<title[^>]*>[\s\S]*?<\/title>/gi, "");
}

/** Compute tooltip position relative to the diagram container. */
export function computeTooltipPosition(
  anchorRect: { left: number; width: number; top: number },
  containerRect: { left: number; top: number },
): { x: number; y: number } {
  return {
    x: anchorRect.left + anchorRect.width / 2 - containerRect.left,
    y: anchorRect.top - containerRect.top - 8,
  };
}

/** Convert smoothed EMA velocity (px/ms) to per-frame velocity, capped. Returns null if below threshold. */
export function releaseVelocity(vx: number, vy: number): { fx: number; fy: number } | null {
  if (Math.abs(vx) < MIN_VELOCITY && Math.abs(vy) < MIN_VELOCITY) return null;
  let fx = vx * MS_PER_FRAME;
  let fy = vy * MS_PER_FRAME;
  const speed = Math.sqrt(fx * fx + fy * fy);
  if (speed > MAX_SPEED) { fx *= MAX_SPEED / speed; fy *= MAX_SPEED / speed; }
  return { fx, fy };
}

/** Animate momentum decay. Calls onFrame(x, y) each frame until velocity is negligible. Calls onEnd when done. Returns rAF id. */
export function runMomentum(
  fx: number, fy: number,
  startX: number, startY: number,
  onFrame: (x: number, y: number) => void,
  onEnd?: () => void,
): number {
  let x = startX;
  let y = startY;
  function tick() {
    fx *= FRICTION;
    fy *= FRICTION;
    if (Math.abs(fx) < MIN_VELOCITY && Math.abs(fy) < MIN_VELOCITY) {
      onEnd?.();
      return;
    }
    x += fx;
    y += fy;
    onFrame(x, y);
    requestAnimationFrame(tick);
  }
  return requestAnimationFrame(tick);
}
