// tests/features/routes.pbt.test.ts — Property-based tests for route codec.

import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { parse, print } from "@pb/platform";
import type { Route, ViewName } from "@pb/platform";

const viewNames: ViewName[] = [
  "dashboard", "objectDetail", "procedureDetail",
  "dwDetail", "tableDetail", "browser",
  "diagrams", "queries", "explore", "diagnostics",
];

describe("routes — property-based", () => {
  it("parse always returns a known ViewName", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 80 }),
        (path) => {
          const result = parse(path);
          expect(viewNames).toContain(result.view);
        },
      ),
      { numRuns: 500 },
    );
  });

  it("round-trip: print then parse preserves simple routes", () => {
    const simpleRoutes: Route[] = [
      { view: "dashboard" },
      { view: "browser" },
      { view: "diagrams" },
      { view: "queries" },
      { view: "explore" },
      { view: "diagnostics" },
    ];
    for (const route of simpleRoutes) {
      expect(parse(print(route))).toEqual(route);
    }
  });

  it("round-trip: objectDetail preserves name", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 40 }).filter((s) => s.length > 0),
        (name) => {
          const route: Route = { view: "objectDetail", name };
          expect(parse(print(route))).toEqual(route);
        },
      ),
    );
  });

  it("round-trip: dwDetail preserves name", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 40 }).filter((s) => s.length > 0),
        (name) => {
          const route: Route = { view: "dwDetail", name };
          expect(parse(print(route))).toEqual(route);
        },
      ),
    );
  });

  it("round-trip: procedureDetail preserves name and proc", () => {
    fc.assert(
      fc.property(
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 20 }),
        fc.string({ unit: "grapheme", minLength: 1, maxLength: 20 }),
        (name, proc) => {
          const route: Route = { view: "procedureDetail", name, proc };
          expect(parse(print(route))).toEqual(route);
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
          const route: Route = { view: "objectDetail", name };
          expect(parse(print(route))).toEqual(route);
        },
      ),
    );
  });

  it("parse falls back to dashboard for unknown path prefixes", () => {
    fc.assert(
      fc.property(
        fc.oneof(
          fc.constant("/nope"),
          fc.constant("/random/abc/def"),
          fc.string({ unit: "grapheme", minLength: 1 }).map((s) => "/prefix/" + s),
        ),
        (path) => {
          const result = parse(path);
          expect(result.view).toBe("dashboard");
        },
      ),
    );
  });
});
