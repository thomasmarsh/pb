import { describe, it, expect } from "vitest";
import {
  buildObjectMap, buildCallSpanMap, buildVarRefSpanMap, buildProcCountMap, buildProcFirstLine, buildProcRangeMap,
} from "@pb/platform";
import type { ProcedureInfo, ResolvedCallInfo, ResolvedVarRefInfo } from "@pb/platform";

function makeProc(name: string, start = 1, end = 5): ProcedureInfo {
  return { name, proc_type: "function", modifiers: null, params: null, return_type: null, start_line: start, end_line: end, cyclomatic: null };
}

function makeCall(overrides: Partial<ResolvedCallInfo> = {}): ResolvedCallInfo {
  return {
    proc_name: "f_go", to_name: "f_validate", call_type: "ExCall", line: 10,
    target_object: "w_other", target_proc: "f_validate", kind: "virtual", confidence: "high",
    to_name_start_line: 10, to_name_start_col: 5, to_name_end_line: 10, to_name_end_col: 15,
    ...overrides,
  };
}

function makeVarRef(overrides: Partial<ResolvedVarRefInfo> = {}): ResolvedVarRefInfo {
  return {
    proc_name: "f_go", line: 10, name: "li_count", access: "read",
    target_object: null, kind: "local", confidence: "high",
    name_start_line: 10, name_start_col: 3, name_end_line: 10, name_end_col: 12,
    declared_type: null,
    ...overrides,
  };
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

describe("buildCallSpanMap", () => {
  it("returns empty map for empty input", () => {
    expect(buildCallSpanMap([])).toEqual(new Map());
  });

  it("keys by line:start_col, not by name", () => {
    const map = buildCallSpanMap([makeCall()]);
    expect(map.has("10:5")).toBe(true);
    expect(map.get("10:5")?.to_name).toBe("f_validate");
  });

  it("two calls with the same name on different lines resolve independently", () => {
    const a = makeCall({ to_name_start_line: 10, to_name_start_col: 5, target_object: "w_a" });
    const b = makeCall({ to_name_start_line: 20, to_name_start_col: 5, target_object: "w_b" });
    const map = buildCallSpanMap([a, b]);
    expect(map.get("10:5")?.target_object).toBe("w_a");
    expect(map.get("20:5")?.target_object).toBe("w_b");
  });

  it("skips rows with no span", () => {
    const map = buildCallSpanMap([makeCall({ to_name_start_line: null, to_name_start_col: null })]);
    expect(map.size).toBe(0);
  });
});

describe("buildVarRefSpanMap", () => {
  it("returns empty map for empty input", () => {
    expect(buildVarRefSpanMap([])).toEqual(new Map());
  });

  it("keys by line:start_col", () => {
    const map = buildVarRefSpanMap([makeVarRef()]);
    expect(map.has("10:3")).toBe(true);
    expect(map.get("10:3")?.name).toBe("li_count");
  });

  it("two refs with the same name in different procedures resolve independently", () => {
    const a = makeVarRef({ proc_name: "f_a", name_start_line: 10, name_start_col: 3, kind: "local" });
    const b = makeVarRef({ proc_name: "f_b", name_start_line: 30, name_start_col: 3, kind: "param" });
    const map = buildVarRefSpanMap([a, b]);
    expect(map.get("10:3")?.kind).toBe("local");
    expect(map.get("30:3")?.kind).toBe("param");
  });

  it("skips rows with no span", () => {
    const map = buildVarRefSpanMap([makeVarRef({ name_start_line: null, name_start_col: null })]);
    expect(map.size).toBe(0);
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
