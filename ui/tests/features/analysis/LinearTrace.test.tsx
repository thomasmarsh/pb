// tests/features/analysis/LinearTrace.test.tsx — LinearTrace component tests.

import { describe, it, expect } from "vitest";
import { render, cleanup } from "@solidjs/testing-library";
import { afterEach } from "vitest";
import { LinearTrace } from "../../../src/features/analysis/LinearTrace.js";
import type { TaintStep } from "@pb/platform";

afterEach(cleanup);

function makeTaintSteps(n: number): TaintStep[] {
  const kinds = ["source", "def", "arg", "sink"];
  return Array.from({ length: n }, (_, i) => ({
    object: `w_obj${i}`,
    proc_name: `f_proc${i}`,
    line: i + 1,
    var_name: `ls_var${i}`,
    step_kind: kinds[i % kinds.length]!,
    description: `description ${i}`,
  }));
}

describe("LinearTrace — taint mode", () => {
  it("renders the correct number of visible steps for a short trace (≤20)", () => {
    const steps = makeTaintSteps(5);
    const { getAllByTestId } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getAllByTestId("trace-step").length).toBe(5);
  });

  it("renders SOURCE badge for step_kind=source", () => {
    const steps = makeTaintSteps(1);
    steps[0]!.step_kind = "source";
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText("SOURCE")).toBeTruthy();
  });

  it("renders TRANSFORM badge for step_kind=def", () => {
    const steps = makeTaintSteps(1);
    steps[0]!.step_kind = "def";
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText("TRANSFORM")).toBeTruthy();
  });

  it("renders TRANSFORM badge for step_kind=arg", () => {
    const steps = makeTaintSteps(1);
    steps[0]!.step_kind = "arg";
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText("TRANSFORM")).toBeTruthy();
  });

  it("renders SINK badge for step_kind=sink", () => {
    const steps = makeTaintSteps(1);
    steps[0]!.step_kind = "sink";
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText("SINK")).toBeTruthy();
  });

  it("renders step number label", () => {
    const steps = makeTaintSteps(3);
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText("1")).toBeTruthy();
    expect(getByText("2")).toBeTruthy();
    expect(getByText("3")).toBeTruthy();
  });

  it("renders statement text for each step", () => {
    const steps = makeTaintSteps(2);
    steps[0]!.description = "ls_amount = wf_amount.text";
    steps[1]!.description = "INSERT INTO accounts";
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText("ls_amount = wf_amount.text")).toBeTruthy();
    expect(getByText("INSERT INTO accounts")).toBeTruthy();
  });

  it("renders proc/line label for each step", () => {
    const steps = makeTaintSteps(1);
    steps[0]!.proc_name = "f_process";
    steps[0]!.line = 42;
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(getByText(/f_process/)).toBeTruthy();
    expect(getByText(/:42/)).toBeTruthy();
  });

  it("collapses middle steps when trace length > 20", () => {
    const steps = makeTaintSteps(25);
    const { getAllByTestId, getByTestId } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    // First 4 + last 4 always visible = 8 steps shown
    expect(getAllByTestId("trace-step").length).toBe(8);
    // Collapse button present
    expect(getByTestId("trace-collapse-toggle")).toBeTruthy();
  });

  it("collapse toggle shows correct intermediate count", () => {
    const steps = makeTaintSteps(25);
    const { getByTestId } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    const toggle = getByTestId("trace-collapse-toggle");
    // 25 - 4 - 4 = 17 intermediate steps
    expect(toggle.textContent).toContain("17");
  });

  it("expands all steps when collapse toggle is clicked", async () => {
    const steps = makeTaintSteps(25);
    const { getAllByTestId, getByTestId } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    const toggle = getByTestId("trace-collapse-toggle");
    toggle.click();
    expect(getAllByTestId("trace-step").length).toBe(25);
  });

  it("renders mini call graph when traversedProcs is non-empty", () => {
    const steps = makeTaintSteps(2);
    const { getByTestId } = render(() => (
      <LinearTrace
        steps={steps}
        traceType="taint"
        traversedProcs={["w_obj.f_a", "w_obj.f_b"]}
      />
    ));
    expect(getByTestId("trace-callgraph")).toBeTruthy();
  });

  it("hides mini call graph when traversedProcs is empty", () => {
    const steps = makeTaintSteps(2);
    const { queryByTestId } = render(() => (
      <LinearTrace steps={steps} traceType="taint" traversedProcs={[]} />
    ));
    expect(queryByTestId("trace-callgraph")).toBeNull();
  });
});

describe("LinearTrace — slice mode (backward)", () => {
  it("renders AFFECTED badge for slice steps (backward direction)", () => {
    const steps: TaintStep[] = [
      { object: "w_x", proc_name: "f_x", line: 1, var_name: "v", step_kind: "use", description: "use site" },
    ];
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="slice-backward" traversedProcs={[]} />
    ));
    expect(getByText("AFFECTED")).toBeTruthy();
  });

  it("renders AFFECTING badge for slice steps (forward direction)", () => {
    const steps: TaintStep[] = [
      { object: "w_x", proc_name: "f_x", line: 1, var_name: "v", step_kind: "definition", description: "def site" },
    ];
    const { getByText } = render(() => (
      <LinearTrace steps={steps} traceType="slice-forward" traversedProcs={[]} />
    ));
    expect(getByText("AFFECTING")).toBeTruthy();
  });
});
