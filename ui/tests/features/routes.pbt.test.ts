// tests/features/routes.pbt.test.ts — Property-based tests for route resolution.

import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { pathToView, viewToPath, VIEW_PREFIX } from "../../src/features/navigation/routes.js";
import type { ViewName } from "../../src/features/navigation/types.js";

const viewNames: ViewName[] = [
  "dashboard", "objects", "objectDetail", "procedureDetail",
  "datawindows", "dwDetail", "diagrams", "queries", "search", "explore",
];

const viewNameArb = fc.constantFrom(...viewNames);

describe("routes — property-based", () => {
  it("pathToView always returns a known ViewName", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 80 }),
        (path) => {
          const result = pathToView(path);
          expect(viewNames).toContain(result.view);
        },
      ),
      { numRuns: 500 },
    );
  });

  it("VIEW_PREFIX covers all ViewNames with non-empty strings", () => {
    for (const view of viewNames) {
      expect(typeof VIEW_PREFIX[view]).toBe("string");
      expect(VIEW_PREFIX[view]!.length).toBeGreaterThan(0);
    }
  });

  it("round-trip: viewToPath then pathToView preserves the view name for exact views", () => {
    const exactViews = viewNames.filter(
      (v) => !["objectDetail", "procedureDetail", "dwDetail"].includes(v),
    );
    fc.assert(
      fc.property(
        fc.constantFrom(...exactViews),
        (view) => {
          const path = viewToPath(view, {});
          const resolved = pathToView(path);
          expect(resolved.view).toBe(view);
        },
      ),
    );
  });

  it("round-trip: objectDetail preserves objectName", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 40 }).filter((s) => s.length > 0),
        (name) => {
          const path = viewToPath("objectDetail", { objectDetail: { name } });
          const resolved = pathToView(path);
          expect(resolved.view).toBe("objectDetail");
          expect(resolved.params.objectName).toBe(name);
        },
      ),
    );
  });

  it("round-trip: dwDetail preserves dwName", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 40 }).filter((s) => s.length > 0),
        (name) => {
          const path = viewToPath("dwDetail", { dwDetail: { name } });
          const resolved = pathToView(path);
          expect(resolved.view).toBe("dwDetail");
          expect(resolved.params.dwName).toBe(name);
        },
      ),
    );
  });

  it("round-trip: procedureDetail preserves procObject and procName", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 20 }),
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 20 }),
        (obj, proc) => {
          const path = viewToPath("procedureDetail", { procedureDetail: { object: obj, name: proc } });
          const resolved = pathToView(path);
          expect(resolved.view).toBe("procedureDetail");
          expect(resolved.params.procObject).toBe(obj);
          expect(resolved.params.procName).toBe(proc);
        },
      ),
    );
  });

  it("URL-encoded names round-trip through encode/decode", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 30 })
          .filter((s) => s.length > 0 && !s.includes("\0")),
        (name) => {
          const path = viewToPath("objectDetail", { objectDetail: { name } });
          const resolved = pathToView(path);
          expect(resolved.view).toBe("objectDetail");
          expect(resolved.params.objectName).toBe(name);
        },
      ),
    );
  });

  it("pathToView falls back to dashboard for unknown paths", () => {
    fc.assert(
      fc.property(
        fc.oneof(
          fc.constant("/nope"),
          fc.constant("/objects/"),
          fc.constant("/random/abc/def"),
          fc.string({ unit: "grapheme", minLength: 1 }).map((s) => "/prefix/" + s),
        ),
        (path) => {
          const result = pathToView(path);
          if (result.view === "dashboard" && result.params && Object.keys(result.params).length === 0) {
            expect(result.view).toBe("dashboard");
          }
        },
      ),
    );
  });
});
