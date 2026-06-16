// tests/features/navigation.test.ts — Tests for navigation feature reducer.

import { describe, it, expect, vi } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { navReducer, type NavEnv } from "../../src/features/navigation/reducer.js";
import type { NavState, ViewName } from "../../src/features/navigation/types.js";
import { VIEW_PREFIX } from "../../src/features/navigation/routes.js";

function makeNavEnv(): NavEnv & { lastPush: string | null } {
  const env: NavEnv & { lastPush: string | null } = {
    lastPush: null,
    pushUrl: (path: string) => { env.lastPush = path; },
  };
  return env;
}

describe("navigation reducer", () => {
  describe("navigate", () => {
    it("sets view to the target view", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { view: "dashboard" as NavState["view"] });
      ts.send({ type: "navigate", view: "objects" }, (s) => {
        s.view = "objects";
      });
    });

    it("calls pushUrl with the correct prefix", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { view: "dashboard" as NavState["view"] });
      ts.send({ type: "navigate", view: "objects" });
      expect(env.lastPush).toBe("/objects");
    });

    it("dashboard maps to /", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { view: "objects" as NavState["view"] });
      ts.send({ type: "navigate", view: "dashboard" });
      expect(env.lastPush).toBe("/");
    });

    it("objectDetail maps to /objects", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { view: "dashboard" as NavState["view"] });
      ts.send({ type: "navigate", view: "objectDetail" });
      expect(env.lastPush).toBe("/objects");
    });

    it("dwDetail maps to /datawindows", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { view: "dashboard" as NavState["view"] });
      ts.send({ type: "navigate", view: "dwDetail" });
      expect(env.lastPush).toBe("/datawindows");
    });

    it("returns null (no effects)", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { view: "dashboard" as NavState["view"] });
      ts.send({ type: "navigate", view: "explore" });
    });

    it("all ViewName values map to correct prefixes", () => {
      const views: ViewName[] = [
        "dashboard", "objects", "objectDetail", "procedureDetail",
        "datawindows", "dwDetail", "diagrams", "queries", "search", "explore",
      ];
      for (const view of views) {
        const env = makeNavEnv();
        const ts = createTestStore(navReducer, env, { view: "dashboard" as NavState["view"] });
        ts.send({ type: "navigate", view });
        expect(env.lastPush).toBe(VIEW_PREFIX[view]);
      }
    });
  });
});
