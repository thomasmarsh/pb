// tests/components/InlineDiagram.test.tsx — Tests for InlineDiagram.

import { describe, it, expect, vi, afterEach } from "vitest";
import { render, fireEvent, cleanup } from "@solidjs/testing-library";
import { InlineDiagram } from "../../src/components/InlineDiagram.js";
import { createTestStore } from "../helpers.js";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("InlineDiagram", () => {
  it("shows loading spinner while fetching", () => {
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    const { store } = createTestStore();
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} />,
    );
    expect(container.querySelector(".spinner")).not.toBeNull();
  });

  it("renders SVG from fetch response", async () => {
    vi.stubGlobal("fetch", () =>
      Promise.resolve({ ok: true, text: () => Promise.resolve('<svg id="test"></svg>') }),
    );
    const { store } = createTestStore();
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("#test") != null);
    expect(container.querySelector("#test")).not.toBeNull();
  });

  it("shows error message on failed fetch", async () => {
    vi.stubGlobal("fetch", () =>
      Promise.resolve({ ok: false, status: 503, text: () => Promise.resolve("") }),
    );
    const { store } = createTestStore();
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
    vi.stubGlobal("fetch", () => new Promise(() => {}));
    const { store } = createTestStore();
    const { container } = render(() =>
      <InlineDiagram kind="heatmap" store={store} compact />,
    );
    expect(container.querySelector(".diagram-container.compact")).not.toBeNull();
  });

  it("navigates to objectDetail on pb://object click", async () => {
    const svgWithLink = `<svg><a href="pb://object/w_main"><rect/></a></svg>`;
    vi.stubGlobal("fetch", () =>
      Promise.resolve({ ok: true, text: () => Promise.resolve(svgWithLink) }),
    );
    const { store, captured } = createTestStore();
    const { container } = render(() =>
      <InlineDiagram kind="calls" params={{ focal: "w_main" }} store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("a") != null);
    fireEvent.click(container.querySelector("a")!);
    expect(captured).toContainEqual({
      tag: "nav",
      action: { type: "navigate", route: { view: "objectDetail", name: "w_main" } },
    });
  });

  it("navigates to tableDetail on pb://table click", async () => {
    const svgWithLink = `<svg><a href="pb://table/customer"><rect/></a></svg>`;
    vi.stubGlobal("fetch", () =>
      Promise.resolve({ ok: true, text: () => Promise.resolve(svgWithLink) }),
    );
    const { store, captured } = createTestStore();
    const { container } = render(() =>
      <InlineDiagram kind="dw-tables" store={store} />,
    );
    await vi.waitUntil(() => container.querySelector("a") != null);
    fireEvent.click(container.querySelector("a")!);
    expect(captured).toContainEqual({
      tag: "nav",
      action: { type: "navigate", route: { view: "tableDetail", name: "customer" } },
    });
  });
});
