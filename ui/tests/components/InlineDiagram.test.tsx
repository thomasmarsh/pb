// tests/components/InlineDiagram.test.tsx — Tests for InlineDiagram.

import { describe, it, expect, vi, afterEach } from "vitest";
import { render, fireEvent, cleanup } from "@solidjs/testing-library";
import * as fc from "fast-check";
import {
  InlineDiagram,
  computeZoom,
  smoothVelocity,
  stripSvgTitles,
  computeTooltipPosition,
  releaseVelocity,
  ZOOM_MIN,
  ZOOM_MAX,
} from "../../src/components/diagram/InlineDiagram.js";
import { createStore, Effect } from "@pb/core";
import { reducer, initialState } from "../../app/src/reducer.js";
import type { AppEnv } from "../../app/src/reducer.js";
import type { AppAction } from "../../app/src/actions.js";
import { mockEnv } from "../helpers.js";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

// ── Component rendering ────────────────────────────────────────────────

describe("InlineDiagram", () => {
  it("shows loading overlay before effect resolves", async () => {
    const env = { ...mockEnv, getDiagram: () => Effect.none() } as AppEnv;
    const store = createStore(initialState(), reducer, env);
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} />,
    );
    await vi.waitFor(() => {
      expect(container.querySelector(".loading-overlay")).not.toBeNull();
    });
  });

  it("renders SVG from getDiagram response", async () => {
    const env = { ...mockEnv, getDiagram: () => Effect.send('<svg id="test"></svg>') } as AppEnv;
    const store = createStore(initialState(), reducer, env);
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("#test") != null);
    expect(container.querySelector("#test")).not.toBeNull();
  });

  it("strips <title> elements from SVG", async () => {
    const svg = '<svg><a href="pb://object/x"><title>tooltip</title><rect/></a></svg>';
    const env = { ...mockEnv, getDiagram: () => Effect.send(svg) } as AppEnv;
    const store = createStore(initialState(), reducer, env);
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("a") != null);
    expect(container.querySelector("title")).toBeNull();
  });

  it("shows error message on getDiagram failure", async () => {
    const env = { ...mockEnv, getDiagram: () => Effect.fromPromise(() => Promise.reject(new Error("HTTP 503"))) } as AppEnv;
    const store = createStore(initialState(), reducer, env);
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} />,
    );
    await vi.waitUntil(
      () =>
        container.querySelector(".loading-overlay") != null &&
        !container.querySelector(".spinner"),
    );
    expect(container.querySelector(".loading-overlay")!.textContent).toContain(
      "unavailable",
    );
  });

  it("applies compact class when compact prop set", () => {
    const env = { ...mockEnv, getDiagram: () => Effect.send("<svg></svg>") } as AppEnv;
    const store = createStore(initialState(), reducer, env);
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} compact />,
    );
    expect(container.querySelector(".diagram-container.compact")).not.toBeNull();
  });

  it("navigates to objectDetail on pb://object click", async () => {
    const svgWithLink = `<svg><a href="pb://object/w_main"><rect/></a></svg>`;
    const env = { ...mockEnv, getDiagram: () => Effect.send(svgWithLink) } as AppEnv;
    const captured: AppAction[] = [];
    const store = createStore(initialState(), reducer, env, (a) => { captured.push(a); });
    const { container } = render(() =>
      <InlineDiagram kind="calls" params={{ focal: "w_main" }} store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("a") != null);
    fireEvent.click(container.querySelector("a")!);
    expect(captured).toContainEqual({
      tag: "objects",
      action: { tag: "select", name: "w_main" },
    });
  });

  it("navigates to tableDetail on pb://table click", async () => {
    const svgWithLink = `<svg><a href="pb://table/customer"><rect/></a></svg>`;
    const env = { ...mockEnv, getDiagram: () => Effect.send(svgWithLink) } as AppEnv;
    const captured: AppAction[] = [];
    const store = createStore(initialState(), reducer, env, (a) => { captured.push(a); });
    const { container } = render(() =>
      <InlineDiagram kind="dw-tables" store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("a") != null);
    fireEvent.click(container.querySelector("a")!);
    expect(captured).toContainEqual({
      tag: "datawindows",
      action: { tag: "select", name: "customer" },
    });
  });
});

// ── computeZoom ────────────────────────────────────────────────────────

describe("computeZoom", () => {
  it("zooms in on negative deltaY", () => {
    const r = computeZoom(-100, 1, 0, 0, 500, 300);
    expect(r.scale).toBeGreaterThan(1);
  });

  it("zooms out on positive deltaY", () => {
    const r = computeZoom(100, 1, 0, 0, 500, 300);
    expect(r.scale).toBeLessThan(1);
  });

  it("clamps scale to ZOOM_MIN", () => {
    const r = computeZoom(100, ZOOM_MIN, 0, 0, 500, 300);
    expect(r.scale).toBeGreaterThanOrEqual(ZOOM_MIN);
  });

  it("clamps scale to ZOOM_MAX", () => {
    const r = computeZoom(-100, ZOOM_MAX, 0, 0, 500, 300);
    expect(r.scale).toBeLessThanOrEqual(ZOOM_MAX);
  });

  it("keeps the point under the cursor fixed", () => {
    const mouseX = 200, mouseY = 150;
    const offsetX = 50, offsetY = 30;
    const oldScale = 2;
    const r = computeZoom(-100, oldScale, offsetX, offsetY, mouseX, mouseY);
    const contentX = (mouseX - offsetX) / oldScale;
    const contentY = (mouseY - offsetY) / oldScale;
    expect(r.offsetX + contentX * r.scale).toBeCloseTo(mouseX, 6);
    expect(r.offsetY + contentY * r.scale).toBeCloseTo(mouseY, 6);
  });

  it("symmetric: zoom in then out returns to original scale", () => {
    const r1 = computeZoom(-100, 1, 0, 0, 400, 300);
    const r2 = computeZoom(100, r1.scale, r1.offsetX, r1.offsetY, 400, 300);
    expect(r2.scale).toBeCloseTo(1, 6);
  });
});

// ── smoothVelocity ─────────────────────────────────────────────────────

describe("smoothVelocity", () => {
  it("returns next when factor is 1", () => {
    expect(smoothVelocity(10, 20, 1)).toBe(20);
  });

  it("returns prev when factor is 0", () => {
    expect(smoothVelocity(10, 20, 0)).toBe(10);
  });

  it("blends at factor 0.5", () => {
    expect(smoothVelocity(10, 20, 0.5)).toBe(15);
  });

  it("converges toward constant input", () => {
    let v = 0;
    for (let i = 0; i < 100; i++) v = smoothVelocity(v, 10, 0.4);
    expect(v).toBeCloseTo(10, 2);
  });
});

// ── stripSvgTitles ─────────────────────────────────────────────────────

describe("stripSvgTitles", () => {
  it("removes simple <title> elements", () => {
    expect(stripSvgTitles("<svg><title>hello</title></svg>")).toBe("<svg></svg>");
  });

  it("removes <title> with attributes", () => {
    expect(stripSvgTitles('<svg><title id="x" class="y">hi</title></svg>')).toBe("<svg></svg>");
  });

  it("removes multiple <title> elements", () => {
    const input = "<svg><title>a</title><rect/><title>b</title></svg>";
    expect(stripSvgTitles(input)).toBe("<svg><rect/></svg>");
  });

  it("removes multiline <title> elements", () => {
    const input = "<svg><title>\nmulti\nline\n</title></svg>";
    expect(stripSvgTitles(input)).toBe("<svg></svg>");
  });

  it("preserves non-title content", () => {
    const input = '<svg><a href="x"><title>t</title><rect/></a></svg>';
    expect(stripSvgTitles(input)).toBe('<svg><a href="x"><rect/></a></svg>');
  });

  it("is case-insensitive", () => {
    expect(stripSvgTitles("<svg><TITLE>hi</TITLE></svg>")).toBe("<svg></svg>");
  });
});

// ── computeTooltipPosition ─────────────────────────────────────────────

describe("computeTooltipPosition", () => {
  it("centers horizontally on the anchor", () => {
    const pos = computeTooltipPosition(
      { left: 100, width: 20, top: 200 },
      { left: 0, top: 0 },
    );
    expect(pos.x).toBe(110);
  });

  it("places above the anchor with 8px gap", () => {
    const pos = computeTooltipPosition(
      { left: 100, width: 20, top: 200 },
      { left: 0, top: 0 },
    );
    expect(pos.y).toBe(192);
  });

  it("adjusts for container offset", () => {
    const pos = computeTooltipPosition(
      { left: 150, width: 20, top: 250 },
      { left: 50, top: 100 },
    );
    expect(pos.x).toBe(110);
    expect(pos.y).toBe(142);
  });
});

// ── releaseVelocity ────────────────────────────────────────────────────

describe("releaseVelocity", () => {
  const MS_PER_FRAME = 1000 / 60;

  it("returns null for sub-threshold velocity", () => {
    expect(releaseVelocity(0, 0)).toBeNull();
    expect(releaseVelocity(0.01, 0.01)).toBeNull();
    expect(releaseVelocity(0.04, 0)).toBeNull();
  });

  it("converts px/ms to px/frame", () => {
    const result = releaseVelocity(1, 0);
    expect(result).not.toBeNull();
    expect(result!.fx).toBeCloseTo(1 * MS_PER_FRAME, 6);
    expect(result!.fy).toBe(0);
  });

  it("caps velocity at MAX_SPEED", () => {
    const result = releaseVelocity(5, 0);
    expect(result).not.toBeNull();
    const speed = Math.sqrt(result!.fx ** 2 + result!.fy ** 2);
    expect(speed).toBeLessThanOrEqual(40 + 0.001);
  });

  it("preserves direction when capping", () => {
    const result = releaseVelocity(3, 4);
    expect(result).not.toBeNull();
    const angle = Math.atan2(result!.fy, result!.fx);
    const expectedAngle = Math.atan2(4 * MS_PER_FRAME, 3 * MS_PER_FRAME);
    expect(angle).toBeCloseTo(expectedAngle, 6);
  });

  it("returns null when both components are below threshold", () => {
    expect(releaseVelocity(0.03, 0.03)).toBeNull();
  });

  it("returns non-null when one component exceeds threshold", () => {
    expect(releaseVelocity(0.1, 0)).not.toBeNull();
    expect(releaseVelocity(0, 0.1)).not.toBeNull();
  });
});

// ── PBT: releaseVelocity ──────────────────────────────────────────────

describe("releaseVelocity (PBT)", () => {
  const MAX_SPEED = 40;
  const MAX_INPUT = Math.fround(100);

  it("output speed never exceeds MAX_SPEED", () => {
    fc.assert(
      fc.property(
        fc.float({ min: -MAX_INPUT, max: MAX_INPUT, noNaN: true }),
        fc.float({ min: -MAX_INPUT, max: MAX_INPUT, noNaN: true }),
        (vx, vy) => {
          const r = releaseVelocity(vx, vy);
          if (!r) return true;
          const speed = Math.sqrt(r.fx * r.fx + r.fy * r.fy);
          return speed <= MAX_SPEED + 0.001;
        },
      ),
    );
  });

  it("non-null result implies non-zero speed", () => {
    fc.assert(
      fc.property(
        fc.float({ min: -MAX_INPUT, max: MAX_INPUT, noNaN: true }),
        fc.float({ min: -MAX_INPUT, max: MAX_INPUT, noNaN: true }),
        (vx, vy) => {
          const r = releaseVelocity(vx, vy);
          if (!r) return true;
          const speed = Math.sqrt(r.fx * r.fx + r.fy * r.fy);
          return speed > 0;
        },
      ),
    );
  });

  it("direction is preserved when capping", () => {
    fc.assert(
      fc.property(
        fc.float({ min: Math.fround(0.1), max: MAX_INPUT, noNaN: true }),
        fc.float({ min: Math.fround(0.1), max: MAX_INPUT, noNaN: true }),
        (vx, vy) => {
          const r = releaseVelocity(vx, vy);
          if (!r) return true;
          const outputAngle = Math.atan2(r.fy, r.fx);
          const inputAngle = Math.atan2(vy, vx);
          return Math.abs(outputAngle - inputAngle) < 0.001;
        },
      ),
    );
  });

  it("non-null for any input where |v| exceeds threshold", () => {
    fc.assert(
      fc.property(
        fc.float({ min: -MAX_INPUT, max: MAX_INPUT, noNaN: true }),
        fc.float({ min: -MAX_INPUT, max: MAX_INPUT, noNaN: true }),
        (vx, vy) => {
          if (Math.abs(vx) >= 0.05 || Math.abs(vy) >= 0.05) {
            return releaseVelocity(vx, vy) !== null;
          }
          return true;
        },
      ),
    );
  });
});

// ── PBT: momentum simulation ──────────────────────────────────────────

describe("momentum simulation (PBT)", () => {
  const FRICTION = 0.955;
  const MIN_V = 0.05;

  function simulateSteps(fx: number, fy: number, maxSteps: number): { steps: number; x: number; y: number } {
    let x = 0, y = 0, steps = 0;
    let vx = fx, vy = fy;
    while (steps < maxSteps) {
      vx *= FRICTION;
      vy *= FRICTION;
      if (Math.abs(vx) < MIN_V && Math.abs(vy) < MIN_V) break;
      x += vx;
      y += vy;
      steps++;
    }
    return { steps, x, y };
  }

  const POSITIVE = fc.float({ min: Math.fround(0.1), max: Math.fround(50), noNaN: true });

  it("always terminates within 10k steps", () => {
    fc.assert(
      fc.property(POSITIVE, POSITIVE, (fx, fy) => {
        return simulateSteps(fx, fy, 10000).steps < 10000;
      }),
    );
  });

  it("position is monotonic for positive velocity", () => {
    fc.assert(
      fc.property(POSITIVE, (fy) => {
        const { y } = simulateSteps(0, fy, 1000);
        return y > 0;
      }),
    );
  });

  it("displacement is finite and bounded", () => {
    fc.assert(
      fc.property(POSITIVE, (f) => {
        const { x } = simulateSteps(f, 0, 10000);
        return Number.isFinite(x) && Math.abs(x) < 10000;
      }),
    );
  });

  it("longer initial velocity → more displacement", () => {
    fc.assert(
      fc.property(POSITIVE, POSITIVE, (a, b) => {
        if (a >= b) return true;
        const { x: dA } = simulateSteps(a, 0, 10000);
        const { x: dB } = simulateSteps(b, 0, 10000);
        return dA < dB;
      }),
    );
  });
});
