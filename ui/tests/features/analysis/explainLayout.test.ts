// tests/features/analysis/explainLayout.test.ts — Pure PStmt normalization
// and region-DAG-walk tests (Plan 222 Phase 4).

import { describe, it, expect } from "vitest";
import {
  normalizeStmt, sourceLinesForStmt, collectRegionCards,
  formatInferredSignature, formatDeclaredSig, regionDisplayLabel, formatRegionCallLabel,
} from "@pb/platform";
import type { PStmt, Pseudocode, InferredSignature, DeclaredSig } from "@pb/platform";

const SIG: InferredSignature = {
  inputs: [{ name: "li_width", type: { tag: "PtPrimitive", contents: "integer" } }],
  outputs: [],
  effects: [],
};

describe("normalizeStmt", () => {
  it("normalizes a PAssign to its named line/text fields", () => {
    const stmt: PStmt = { tag: "PAssign", contents: ["ls_x", null, null, 7], stmtText: "ls_x = 1" };
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

describe("formatInferredSignature", () => {
  it("matches Render/Text.hs's renderInferredSig shape: name(ins) -> (outs)  [effects]", () => {
    expect(formatInferredSignature("region_3", SIG)).toBe("region_3(li_width: integer) -> ()  [pure]");
  });

  it("sorts effect tags ascending, matching Set.toAscList", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: ["WritesUi", "ReadsDb"] };
    expect(formatInferredSignature("r", sig)).toBe("r() -> ()  [ReadsDb, WritesUi]");
  });
});

describe("regionDisplayLabel", () => {
  it("formats a cut-region label as an identifier, not region@line", () => {
    expect(regionDisplayLabel("region_3", [10, 14])).toBe("region_10");
  });

  it("falls back to the raw regionId when there's no line range (the root region)", () => {
    expect(regionDisplayLabel("region_0", null)).toBe("region_0");
  });
});

describe("formatRegionCallLabel", () => {
  it("renders a region-ref as a call: name(inputArgNames)", () => {
    expect(formatRegionCallLabel("region_3", [10, 14], SIG)).toBe("region_10(li_width)");
  });

  it("renders an empty arg list when the signature has no inputs", () => {
    const sig: InferredSignature = { inputs: [], outputs: [], effects: [] };
    expect(formatRegionCallLabel("region_3", [10, 14], sig)).toBe("region_10()");
  });

  it("renders an empty arg list when the signature is null", () => {
    expect(formatRegionCallLabel("region_3", [10, 14], null)).toBe("region_10()");
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
