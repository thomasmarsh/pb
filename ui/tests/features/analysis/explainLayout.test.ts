// tests/features/analysis/explainLayout.test.ts — Pure PStmt normalization
// and region-DAG-walk tests (Plan 222 Phase 4, Plan 225 Phase 5).

import { describe, it, expect } from "vitest";
import {
  normalizeStmt, sourceLinesForStmt, collectRegionCards,
  formatInferredSignature, formatDeclaredSig, regionDisplayLabel, formatRegionCallLabel,
  capabilitiesOf, CAPABILITY_LABEL,
} from "@pb/platform";
import type {
  PStmt, Pseudocode, InferredSignature, DeclaredSig, EffectTagFull,
} from "@pb/platform";

const SIG: InferredSignature = {
  inputs: [{ name: "li_width", type: { tag: "PtPrimitive", contents: "integer" } }],
  outputs: [],
  effects: [],
};

describe("normalizeStmt", () => {
  it("normalizes a PAssign to its named line/text fields", () => {
    const stmt: PStmt = { tag: "PAssign", contents: ["ls_x", null, null, null, 7], stmtText: "ls_x = 1" };
    expect(normalizeStmt(stmt)).toEqual({ kind: "assign", line: 7, text: "ls_x = 1" });
  });

  it("normalizes a PBranch, recursing into then/else", () => {
    const thenStmt: PStmt = { tag: "PReturn", contents: [null, 3], stmtText: "return true" };
    const stmt: PStmt = { tag: "PBranch", contents: [null, [thenStmt], [], 2], stmtText: "if x then" };
    const normalized = normalizeStmt(stmt);
    expect(normalized).toEqual({
      kind: "branch",
      line: 2,
      text: "if x then",
      then: [{ kind: "return", line: 3, text: "return true" }],
      else: [],
    });
  });

  it("normalizes a PRegionRef to its regionId/lineRange/sig", () => {
    const stmt: PStmt = { tag: "PRegionRef", contents: ["region_3", [10, 14], SIG], stmtText: "-> region@10" };
    expect(normalizeStmt(stmt)).toEqual({
      kind: "regionRef", text: "-> region@10", regionId: "region_3", lineRange: [10, 14], sig: SIG,
    });
  });
});

describe("sourceLinesForStmt", () => {
  it("expands a PRegionRef's line range to every line in it", () => {
    const stmt = normalizeStmt({ tag: "PRegionRef", contents: ["r", [10, 12], null], stmtText: "-> r" });
    expect(sourceLinesForStmt(stmt)).toEqual(new Set([10, 11, 12]));
  });

  it("returns the single line for a non-regionRef statement", () => {
    const stmt = normalizeStmt({ tag: "PReturn", contents: [null, 5], stmtText: "return" });
    expect(sourceLinesForStmt(stmt)).toEqual(new Set([5]));
  });

  it("returns an empty set for a regionRef with no line range", () => {
    const stmt = normalizeStmt({ tag: "PRegionRef", contents: ["r", null, null], stmtText: "-> r" });
    expect(sourceLinesForStmt(stmt)).toEqual(new Set());
  });
});

describe("collectRegionCards", () => {
  function pc(overrides: Partial<Pseudocode> = {}): Pseudocode {
    return {
      declaredSig: null,
      rootRegion: "region_0",
      rootSig: null,
      regions: {},
      sourceOriginal: null,
      procStartLine: null,
      ...overrides,
    };
  }

  it("emits the root card first even when it's never referenced by a PRegionRef", () => {
    const cards = collectRegionCards(pc({
      regions: { region_0: [{ tag: "PReturn", contents: [null, 1], stmtText: "return true" }] },
    }));
    expect(cards).toHaveLength(1);
    expect(cards[0]).toMatchObject({ regionId: "region_0", isRoot: true });
  });

  it("dedups a region referenced from two call sites, emitting it once", () => {
    const ref: PStmt = { tag: "PRegionRef", contents: ["region_shared", [5, 6], null], stmtText: "-> region_shared" };
    const cards = collectRegionCards(pc({
      rootRegion: "region_0",
      regions: {
        region_0: [
          { tag: "PBranch", contents: [null, [ref], [ref], 1], stmtText: "if x then" },
        ],
        region_shared: [{ tag: "PReturn", contents: [null, 5], stmtText: "return true" }],
      },
    }));
    const sharedCards = cards.filter((c) => c.regionId === "region_shared");
    expect(sharedCards).toHaveLength(1);
    expect(cards.map((c) => c.regionId)).toEqual(["region_0", "region_shared"]);
  });

  it("does not recurse into a referenced region's own body a second time", () => {
    const cards = collectRegionCards(pc({
      rootRegion: "region_0",
      regions: {
        region_0: [{ tag: "PRegionRef", contents: ["region_1", [2, 2], null], stmtText: "-> region_1" }],
        region_1: [{ tag: "PRegionRef", contents: ["region_0", [1, 1], null], stmtText: "-> region_0" }],
      },
    }));
    expect(cards.map((c) => c.regionId)).toEqual(["region_0", "region_1"]);
  });
});

describe("capabilitiesOf", () => {
  // Hand-typed fixture list (Plan 225 Layer 3.6): the table's key set must
  // equal the 7 EffectTag values PB.Analysis.CallClassify enumerates. Not
  // derived from the wire EffectTag (a 4-tag subset) so a Haskell-side
  // vocabulary change is caught here rather than silently drifting.
  const ALL_EFFECT_TAGS: EffectTagFull[] = [
    "ReadsDb", "WritesDb", "WritesUi", "Suspends",
    "ReadsControlState", "WritesControlState", "WritesInstanceState",
  ];

  it("CAPABILITY_LABEL's key set matches the 7 EffectTag values PB.Analysis.CallClassify enumerates", () => {
    expect(Object.keys(CAPABILITY_LABEL).sort()).toEqual([...ALL_EFFECT_TAGS].sort());
  });

  it("yields an empty array for a pure effect list", () => {
    expect(capabilitiesOf([])).toEqual([]);
  });

  it("dedupes multiple effects of the same capability into a single label", () => {
    expect(capabilitiesOf(["ReadsDb", "WritesDb"])).toEqual(["DB"]);
  });

  it("returns capability labels sorted ascending, matching PB.Analysis.CallClassify's Set.toAscList", () => {
    expect(capabilitiesOf(["WritesUi", "ReadsDb", "Suspends"])).toEqual(["Async", "DB", "UI"]);
  });
});

describe("formatInferredSignature", () => {
  it("a pure region's signature has no ability prefix and a capitalized primitive input type", () => {
    expect(formatInferredSignature("region_3", SIG)).toBe("function region_3(li_width: Integer) -> () {");
  });

  it("an effectful region's signature shows a sorted, deduplicated capability prefix", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["WritesUi", "ReadsDb"] };
    expect(formatInferredSignature("r", sig)).toBe("function r() -> '{DB, UI} () {");
  });

  it("a single-output signature's return type is bare; a multi-output signature's return type is a tuple", () => {
    const single: InferredSignature = { inputs: [], outputs: [{ name: "x", type: null }], effects: [] };
    const multi: InferredSignature = { inputs: [], outputs: [{ name: "x", type: null }, { name: "y", type: null }], effects: [] };
    expect(formatInferredSignature("f", single)).toBe("function f() -> x {");
    expect(formatInferredSignature("f", multi)).toBe("function f() -> (x, y) {");
  });

  it("with declaredReturnType='string', emits '-> String' instead of the live-out tuple", () => {
    expect(formatInferredSignature("region_0", SIG, "string")).toBe("function region_0(li_width: Integer) -> String {");
  });

  it("with declaredReturnType='integer', emits '-> Integer'", () => {
    expect(formatInferredSignature("region_0", SIG, "integer")).toBe("function region_0(li_width: Integer) -> Integer {");
  });

  it("with no declaredReturnType, falls back to the inferred live-out tuple (existing behavior)", () => {
    const single: InferredSignature = { inputs: [], outputs: [{ name: "x", type: null }], effects: [] };
    expect(formatInferredSignature("f", single)).toBe("function f() -> x {");
  });

  it("with declaredReturnType and effects, ability prefix still applies: '-> '{DB} String'", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["ReadsDb"] };
    expect(formatInferredSignature("r", sig, "string")).toBe("function r() -> '{DB} String {");
  });

  it("with declaredReturnType='string' and no inferred sig.inputs, emits 'function f() -> String {'", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: [] };
    expect(formatInferredSignature("f", sig, "string")).toBe("function f() -> String {");
  });
});

// Plan 226 Layer 2 — the wire-side EffectTag is 7 tags (PB.Analysis.CallClassify's
// full vocabulary, already serialized by PB.Pipeline.Serialise's genericToJSON
// instance on the 7-constructor ADT). formatInferredSignature must render an
// ability prefix for every wire tag, not just the 4-tag subset api.ts:801 used
// to declare.
describe("formatInferredSignature with 7-tag effects (Plan 226 Layer 2)", () => {
  it("emits '{Control}' for ReadsControlState", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["ReadsControlState"] };
    expect(formatInferredSignature("r", sig)).toBe("function r() -> '{Control} () {");
  });

  it("emits '{Control}' for WritesControlState", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["WritesControlState"] };
    expect(formatInferredSignature("r", sig)).toBe("function r() -> '{Control} () {");
  });

  it("emits '{State}' for WritesInstanceState", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["WritesInstanceState"] };
    expect(formatInferredSignature("r", sig)).toBe("function r() -> '{State} () {");
  });

  it("dedupes ReadsControlState + WritesControlState to a single 'Control' label", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["ReadsControlState", "WritesControlState"] };
    expect(formatInferredSignature("r", sig)).toBe("function r() -> '{Control} () {");
  });

  it("sorts 7-tag effects mixed with 4-tag effects correctly", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["ReadsControlState", "WritesUi", "ReadsDb", "WritesInstanceState"] };
    expect(formatInferredSignature("r", sig)).toBe("function r() -> '{Control, DB, State, UI} () {");
  });
});

describe("regionDisplayLabel", () => {
  it("uses the region@N convention, matching the backend's Render/Text.hs regionLabel", () => {
    expect(regionDisplayLabel("region_3", [10, 14])).toBe("region@10");
  });

  it("falls back to the raw regionId when there's no line range (the root region)", () => {
    expect(regionDisplayLabel("region_0", null)).toBe("region_0");
  });
});

describe("formatRegionCallLabel", () => {
  it("renders a region-ref as a call: name(inputArgNames), using region@N", () => {
    expect(formatRegionCallLabel("region_3", [10, 14], SIG)).toBe("region@10(li_width)");
  });

  it("renders an empty arg list when the signature has no inputs", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: [] };
    expect(formatRegionCallLabel("region_3", [10, 14], sig)).toBe("region@10()");
  });

  it("renders an empty arg list when the signature is null", () => {
    expect(formatRegionCallLabel("region_3", [10, 14], null)).toBe("region@10()");
  });

  it("uses the raw regionId when there's no line range", () => {
    expect(formatRegionCallLabel("region_0", null, SIG)).toBe("region_0(li_width)");
  });
});

describe("formatDeclaredSig", () => {
  it("renders a Left/FnSig as name(params): returnType", () => {
    const d: DeclaredSig = {
      Left: {
        mods: [], returnType: "integer", returnTypeSpan: null, name: "uf_save",
        params: [{ mods: [], type: "string", typeSpan: null, name: "as_name" }],
        throws: null, library: null, aliasFor: null,
      },
    };
    expect(formatDeclaredSig(d)).toBe("uf_save(string as_name): integer");
  });

  it("renders a Right/SubSig as name(params), no return type", () => {
    const d: DeclaredSig = {
      Right: {
        mods: [], name: "uf_close", params: [], throws: null, library: null, aliasFor: null,
      },
    };
    expect(formatDeclaredSig(d)).toBe("uf_close()");
  });
});
