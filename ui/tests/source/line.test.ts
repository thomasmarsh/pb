import { describe, it, expect } from "vitest";
import { procSelectedRange, procedureAtLine } from "@pb/platform";
import type { ProcedureInfo } from "@pb/platform";

function makeProc(name: string, start: number | null, end: number | null): ProcedureInfo {
  return { name, proc_type: "function", modifiers: null, params: null, return_type: null, start_line: start, end_line: end, cyclomatic: null };
}

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

describe("procedureAtLine", () => {
  const procs = [makeProc("f_a", 5, 10), makeProc("f_b", 15, 20), makeProc("f_c", 25, null)];

  it("returns the procedure whose range contains the line", () => {
    expect(procedureAtLine(procs, 7)).toBe(procs[0]);
  });

  it("matches inclusive of the start and end boundary lines", () => {
    expect(procedureAtLine(procs, 15)).toBe(procs[1]);
    expect(procedureAtLine(procs, 20)).toBe(procs[1]);
  });

  it("returns undefined for a line outside every procedure's range", () => {
    expect(procedureAtLine(procs, 12)).toBeUndefined();
  });

  it("returns undefined for a procedure with a null end_line", () => {
    expect(procedureAtLine(procs, 25)).toBeUndefined();
  });

  it("returns undefined for an empty procedure list", () => {
    expect(procedureAtLine([], 1)).toBeUndefined();
  });
});
