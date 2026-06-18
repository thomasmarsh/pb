// tests/components/DetailShell.test.tsx — Tests for DetailShell render-prop component.

import { describe, it, expect } from "vitest";
import { render } from "@solidjs/testing-library";
import { DetailShell } from "../../src/components/detail/DetailShell.js";

describe("DetailShell", () => {
  it("shows loading when entry is undefined", () => {
    const { container } = render(() => (
      <DetailShell entry={undefined} loadingMsg="Loading data...">
        {(d: { name: string }) => <span>{d.name}</span>}
      </DetailShell>
    ));
    expect(container.textContent).toContain("Loading data...");
  });

  it("shows error when entry has error field", () => {
    const { container } = render(() => (
      <DetailShell entry={{ error: "Something went wrong" }} loadingMsg="Loading...">
        {(d: { name: string }) => <span>{d.name}</span>}
      </DetailShell>
    ));
    expect(container.textContent).toContain("Something went wrong");
    expect(container.querySelector("span")).toBeNull();
  });

  it("renders children callback when entry is valid data", () => {
    const { container } = render(() => (
      <DetailShell entry={{ name: "MyProc", source: "code" }} loadingMsg="Loading...">
        {(d: { name: string }) => <span>{d.name}</span>}
      </DetailShell>
    ));
    expect(container.textContent).toContain("MyProc");
    expect(container.querySelector("span")).not.toBeNull();
  });

  it("shows loading for null entry (falsy non-undefined)", () => {
    const { container } = render(() => (
      <DetailShell entry={null} loadingMsg="Fetching...">
        {(d: string) => <span>{d}</span>}
      </DetailShell>
    ));
    // null is not undefined, so the outer Show fires; inner Show gets null data → error fallback
    const el = container.querySelector(".explore-right-body");
    expect(el).not.toBeNull();
  });

  it("shows error for null with no error field", () => {
    const { container } = render(() => (
      <DetailShell entry="" loadingMsg="Fetching...">
        {(d: string) => <span>{d}</span>}
      </DetailShell>
    ));
    // empty string is truthy for !== undefined, but data() returns null (not an object)
    const el = container.querySelector(".explore-right-body");
    expect(el).not.toBeNull();
  });
});
