// tests/features/navigation.test.ts — Tests for navigation feature reducer.

import { describe, it, expect } from "vitest";
import { createTestStore } from "../test-store.js";
import { navReducer, type NavEnv } from "../../src/features/navigation/reducer.js";
import type { NavState, Route } from "../../src/features/navigation/types.js";

function makeNavEnv(): NavEnv & { lastPush: string | null } {
  const env: NavEnv & { lastPush: string | null } = {
    lastPush: null,
    pushUrl: (path: string) => { env.lastPush = path; },
  };
  return env;
}

const initial: NavState = { route: { view: "dashboard" } };

describe("navigation reducer", () => {
  describe("navigate", () => {
    it("sets route to the target route", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, initial);
      ts.send({ type: "navigate", route: { view: "objects" } }, (s) => {
        s.route = { view: "objects" };
      });
    });

    it("calls pushUrl with the correct path", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, initial);
      ts.send({ type: "navigate", route: { view: "objects" } });
      expect(env.lastPush).toBe("/objects");
    });

    it("dashboard maps to /", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, { route: { view: "objects" } });
      ts.send({ type: "navigate", route: { view: "dashboard" } });
      expect(env.lastPush).toBe("/");
    });

    it("objectDetail with name maps to /objects/{name}", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, initial);
      ts.send({ type: "navigate", route: { view: "objectDetail", name: "MyWindow" } });
      expect(env.lastPush).toBe("/objects/MyWindow");
    });

    it("procedureDetail maps to /objects/{name}/{proc}", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, initial);
      ts.send({ type: "navigate", route: { view: "procedureDetail", name: "MyObj", proc: "MyProc" } });
      expect(env.lastPush).toBe("/objects/MyObj/MyProc");
    });

    it("dwDetail with name maps to /datawindows/{name}", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, initial);
      ts.send({ type: "navigate", route: { view: "dwDetail", name: "MyDW" } });
      expect(env.lastPush).toBe("/datawindows/MyDW");
    });

    it("returns null (no effects)", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, initial);
      ts.send({ type: "navigate", route: { view: "explore" } });
    });

    it("all routes map to correct paths", () => {
      const cases: [Route, string][] = [
        [{ view: "dashboard" },                                    "/"],
        [{ view: "objects" },                                      "/objects"],
        [{ view: "objectDetail",    name: "Foo" },                 "/objects/Foo"],
        [{ view: "procedureDetail", name: "Foo", proc: "Bar" },    "/objects/Foo/Bar"],
        [{ view: "datawindows" },                                  "/datawindows"],
        [{ view: "dwDetail",        name: "Baz" },                 "/datawindows/Baz"],
        [{ view: "diagrams" },                                     "/diagrams"],
        [{ view: "queries" },                                      "/queries"],
        [{ view: "search" },                                       "/search"],
        [{ view: "explore" },                                      "/explore"],
      ];
      for (const [route, expectedPath] of cases) {
        const env = makeNavEnv();
        const ts = createTestStore(navReducer, env, initial);
        ts.send({ type: "navigate", route });
        expect(env.lastPush).toBe(expectedPath);
      }
    });
  });
});
