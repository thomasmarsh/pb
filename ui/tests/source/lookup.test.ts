import { describe, it, expect } from "vitest";
import {
  buildObjectMap, buildProcMap, buildVarMap, buildProcCountMap, buildProcFirstLine, buildProcRangeMap,
} from "@pb/platform";
import type { KnownProcInfo, ProcedureInfo, LocalSymbolInfo } from "@pb/platform";

function makeProc(name: string, start = 1, end = 5): ProcedureInfo {
  return { name, proc_type: "function", modifiers: null, params: null, return_type: null, start_line: start, end_line: end, cyclomatic: null };
}

function makeKnownProc(name: string, object = "w_other"): KnownProcInfo {
  return { name, object, proc_type: "function", params: null, return_type: null, modifiers: null, start_line: null, end_line: null, cyclomatic: null };
}

function makeVar(name: string): LocalSymbolInfo {
  return { proc_name: "f_go", var_name: name, raw_type: "integer", resolved_kind: "primitive", resolved_target: null, scope: "local" };
}

describe("buildObjectMap", () => {
  it("returns empty map for empty input", () => {
    expect(buildObjectMap([])).toEqual(new Map());
  });

  it("keys are lowercased", () => {
    const map = buildObjectMap([{ name: "W_Main", kind: "window" }]);
    expect(map.has("w_main")).toBe(true);
    expect(map.get("w_main")?.name).toBe("W_Main");
  });

  it("preserves original name in value", () => {
    const map = buildObjectMap([{ name: "D_Orders", kind: "datawindow" }]);
    expect(map.get("d_orders")?.kind).toBe("datawindow");
  });
});

describe("buildProcMap", () => {
  it("returns empty map for empty inputs", () => {
    expect(buildProcMap([], [], "w_test")).toEqual(new Map());
  });

  it("includes known procs keyed by lowercase name", () => {
    const map = buildProcMap([makeKnownProc("F_Validate")], [], "w_test");
    expect(map.has("f_validate")).toBe(true);
    expect(map.get("f_validate")?.object).toBe("w_other");
  });

  it("local procedures override known procs and use objectName", () => {
    const map = buildProcMap([makeKnownProc("f_go", "w_other")], [makeProc("f_go")], "w_local");
    expect(map.get("f_go")?.object).toBe("w_local");
  });

  it("converts ProcedureInfo fields to KnownProcInfo shape", () => {
    const p = makeProc("f_run", 10, 20);
    const map = buildProcMap([], [p], "w_obj");
    const entry = map.get("f_run")!;
    expect(entry.start_line).toBe(10);
    expect(entry.end_line).toBe(20);
    expect(entry.object).toBe("w_obj");
  });
});

describe("buildVarMap", () => {
  it("returns empty map for empty input", () => {
    expect(buildVarMap([])).toEqual(new Map());
  });

  it("keys by lowercase var_name", () => {
    const map = buildVarMap([makeVar("LI_Count")]);
    expect(map.has("li_count")).toBe(true);
  });

  it("first occurrence wins on duplicate names", () => {
    const v1 = { ...makeVar("li_x"), raw_type: "integer" };
    const v2 = { ...makeVar("li_x"), raw_type: "string" };
    const map = buildVarMap([v1, v2]);
    expect(map.get("li_x")?.raw_type).toBe("integer");
  });
});

describe("buildProcCountMap", () => {
  it("defaults missing counts to 0", () => {
    const map = buildProcCountMap([makeProc("f_go")]);
    expect(map.get("f_go")?.caller_count).toBe(0);
    expect(map.get("f_go")?.callee_count).toBe(0);
  });

  it("uses provided caller/callee counts", () => {
    const p: ProcedureInfo = { ...makeProc("f_go"), caller_count: 3, callee_count: 7 };
    const map = buildProcCountMap([p]);
    expect(map.get("f_go")?.caller_count).toBe(3);
    expect(map.get("f_go")?.callee_count).toBe(7);
  });
});

describe("buildProcFirstLine", () => {
  it("maps start_line to procedure", () => {
    const map = buildProcFirstLine([makeProc("f_a", 5, 10), makeProc("f_b", 15, 20)]);
    expect(map.get(5)?.name).toBe("f_a");
    expect(map.get(15)?.name).toBe("f_b");
  });

  it("skips procedures with null start_line", () => {
    const p: ProcedureInfo = { ...makeProc("f_x"), start_line: null };
    const map = buildProcFirstLine([p]);
    expect(map.size).toBe(0);
  });
});

describe("buildProcRangeMap", () => {
  it("maps every line in [start_line, end_line] to the procedure", () => {
    const map = buildProcRangeMap([makeProc("f_a", 10, 15)]);
    expect(map.size).toBe(6);
    for (let line = 10; line <= 15; line++) expect(map.get(line)?.name).toBe("f_a");
  });

  it("does not map lines outside the range", () => {
    const map = buildProcRangeMap([makeProc("f_a", 10, 15)]);
    expect(map.has(9)).toBe(false);
    expect(map.has(16)).toBe(false);
  });

  it("skips procedures with a null start_line or end_line", () => {
    const p: ProcedureInfo = { ...makeProc("f_x"), start_line: null };
    expect(buildProcRangeMap([p]).size).toBe(0);
  });
});
