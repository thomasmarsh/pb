import { describe, it, expect } from "vitest";
import { PIXELS_PER_LINE, lineFromY, overlayTop, overlayHeight, procSelectedRange } from "../../src/components/source/pure/line.js";
import type { ProcedureInfo } from "../../src/types/api.js";

function makeProc(name: string, start: number | null, end: number | null): ProcedureInfo {
  return { name, proc_type: "function", modifiers: null, params: null, return_type: null, start_line: start, end_line: end, cyclomatic: null };
}

describe("PIXELS_PER_LINE", () => {
  it("is 20.8", () => {
    expect(PIXELS_PER_LINE).toBe(20.8);
  });
});

describe("lineFromY", () => {
  it("returns 1 for the first pixel of the container", () => {
    expect(lineFromY(0, 0, 0)).toBe(1);
  });

  it("clamps to minimum line 1", () => {
    expect(lineFromY(0, 100, 0)).toBe(1);
  });

  it("accounts for scroll offset", () => {
    // clientY=0, containerTop=0, scrollTop=20.8 → pixel 20.8 → line 2
    expect(lineFromY(0, 0, 20.8)).toBe(2);
  });

  it("computes correct line from clientY", () => {
    // clientY=41.6, containerTop=0, scrollTop=0 → pixel 41.6 → floor(41.6/20.8)=2 → line 3
    expect(lineFromY(41.6, 0, 0)).toBe(3);
  });
});

describe("overlayTop", () => {
  it("line 1 starts at 0px", () => {
    expect(overlayTop(1)).toBe(0);
  });

  it("line 5 starts at 4 * PIXELS_PER_LINE", () => {
    expect(overlayTop(5)).toBeCloseTo(4 * PIXELS_PER_LINE);
  });
});

describe("overlayHeight", () => {
  it("single line has height PIXELS_PER_LINE", () => {
    expect(overlayHeight(3, 3)).toBeCloseTo(PIXELS_PER_LINE);
  });

  it("five-line range has height 5 * PIXELS_PER_LINE", () => {
    expect(overlayHeight(1, 5)).toBeCloseTo(5 * PIXELS_PER_LINE);
  });
});

describe("procSelectedRange", () => {
  const procs = [makeProc("f_a", 5, 10), makeProc("f_b", 15, null)];

  it("returns null when selectedProcName is undefined", () => {
    expect(procSelectedRange(procs, undefined)).toBeNull();
  });

  it("returns null when proc is not found", () => {
    expect(procSelectedRange(procs, "f_missing")).toBeNull();
  });

  it("returns null when proc has null start/end lines", () => {
    expect(procSelectedRange(procs, "f_b")).toBeNull();
  });

  it("returns start and end for a found proc", () => {
    expect(procSelectedRange(procs, "f_a")).toEqual({ start: 5, end: 10 });
  });
});
