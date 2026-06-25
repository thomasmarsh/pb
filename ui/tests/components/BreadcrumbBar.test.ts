// tests/components/BreadcrumbBar.test.ts — Tests for breadcrumb display logic.

import { describe, it, expect } from "vitest";
import { buildDisplay } from "../../app/src/layout/BreadcrumbBar.js";
import type { BreadcrumbSegment } from "@pb/platform";

function seg(label: string): BreadcrumbSegment {
  return { icon: "object", label, route: { view: "dashboard" } };
}

function segs(n: number): BreadcrumbSegment[] {
  return Array.from({ length: n }, (_, i) => seg(String(i + 1)));
}

describe("buildDisplay", () => {
  it("1 crumb → 1 crumb item, isLast = true", () => {
    const result = buildDisplay([seg("A")]);
    expect(result).toHaveLength(1);
    const item = result[0]!;
    expect(item.kind).toBe("crumb");
    if (item.kind === "crumb") expect(item.isLast).toBe(true);
  });

  it("3 crumbs → 3 crumb items, last item isLast = true", () => {
    const result = buildDisplay(segs(3));
    expect(result.every(i => i.kind === "crumb")).toBe(true);
    expect(result).toHaveLength(3);
    const last = result[2]!;
    if (last.kind === "crumb") expect(last.isLast).toBe(true);
    const first = result[0]!;
    if (first.kind === "crumb") expect(first.isLast).toBe(false);
  });

  it("5 crumbs → no truncation (5 crumb items)", () => {
    const result = buildDisplay(segs(5));
    expect(result).toHaveLength(5);
    expect(result.every(i => i.kind === "crumb")).toBe(true);
  });

  it("6 crumbs → first 2 + ellipsis (2 hidden) + last 2 = 5 items", () => {
    const result = buildDisplay(segs(6));
    expect(result).toHaveLength(5);
    expect(result[0]!.kind).toBe("crumb");
    expect(result[1]!.kind).toBe("crumb");
    expect(result[2]!.kind).toBe("ellipsis");
    expect(result[3]!.kind).toBe("crumb");
    expect(result[4]!.kind).toBe("crumb");

    const ellipsis = result[2]!;
    if (ellipsis.kind === "ellipsis") {
      expect(ellipsis.hidden).toHaveLength(2);
      expect(ellipsis.hidden[0]!.label).toBe("3");
      expect(ellipsis.hidden[1]!.label).toBe("4");
    }
  });

  it("8 crumbs → 4 hidden in ellipsis", () => {
    const result = buildDisplay(segs(8));
    expect(result).toHaveLength(5);
    const ellipsis = result[2]!;
    if (ellipsis.kind === "ellipsis") {
      expect(ellipsis.hidden).toHaveLength(4);
    }
  });

  it("6 crumbs: last item has isLast = true", () => {
    const result = buildDisplay(segs(6));
    const last = result[4]!;
    if (last.kind === "crumb") expect(last.isLast).toBe(true);
  });

  it("6 crumbs: first item has isLast = false", () => {
    const result = buildDisplay(segs(6));
    const first = result[0]!;
    if (first.kind === "crumb") expect(first.isLast).toBe(false);
  });
});
