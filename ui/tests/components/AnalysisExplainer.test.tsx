// tests/components/AnalysisExplainer.test.tsx — Tests for the reusable
// analysis-panel explainer modal.

import { describe, it, expect } from "vitest";
import { fireEvent, render } from "@solidjs/testing-library";
import { AnalysisExplainer } from "@pb/platform";
import type { AnalysisExplainerContent } from "@pb/platform";

const CONTENT: AnalysisExplainerContent = {
  title: "Widget Frobnication",
  whatItIs: "A description of what it is.",
  howItsUsed: "A description of how it's used.",
  tips: ["First tip.", "Second tip."],
  example: () => <div class="fake-example">Example payload</div>,
};

describe("AnalysisExplainer", () => {
  it("renders nothing when closed", () => {
    const { container } = render(() => <AnalysisExplainer open={false} onClose={() => {}} content={CONTENT} />);
    expect(container.textContent).not.toContain("Widget Frobnication");
  });

  it("renders title, description sections, example, and tips when open", () => {
    const { container } = render(() => <AnalysisExplainer open={true} onClose={() => {}} content={CONTENT} />);
    expect(container.textContent).toContain("Widget Frobnication");
    expect(container.textContent).toContain("A description of what it is.");
    expect(container.textContent).toContain("A description of how it's used.");
    expect(container.textContent).toContain("Example payload");
    expect(container.textContent).toContain("First tip.");
    expect(container.textContent).toContain("Second tip.");
  });

  it("calls onClose when the close button is clicked", () => {
    let closed = false;
    const { container } = render(() => (
      <AnalysisExplainer open={true} onClose={() => { closed = true; }} content={CONTENT} />
    ));
    fireEvent.click(container.querySelector(".help-close-btn")!);
    expect(closed).toBe(true);
  });

  it("calls onClose when the backdrop is clicked", () => {
    let closed = false;
    const { container } = render(() => (
      <AnalysisExplainer open={true} onClose={() => { closed = true; }} content={CONTENT} />
    ));
    fireEvent.click(container.querySelector(".gs-backdrop")!);
    expect(closed).toBe(true);
  });
});
