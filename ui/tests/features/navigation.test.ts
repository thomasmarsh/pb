// tests/features/navigation.test.ts — Tests for navigation feature reducer.

import { describe, it, expect } from "vitest";
import { createTestStore } from "../test-store.js";
import { navReducer, type NavEnv } from "@pb/platform";
import type { NavState, Route } from "@pb/platform";
import { crumbsForRoute, ICONS } from "@pb/platform";

function makeNavEnv(): NavEnv & { lastPush: string | null } {
  const env: NavEnv & { lastPush: string | null } = {
    lastPush: null,
    pushUrl: (path: string) => { env.lastPush = path; },
  };
  return env;
}

function makeInitial(route: Route = { view: "dashboard" }): NavState {
  return {
    route,
    crumbs: crumbsForRoute(route),
    history: [route],
    historyIdx: 0,
    askContext: null,
  };
}

describe("navigation reducer", () => {
  describe("navigate", () => {
    it("sets route to the target route", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } }, (s) => {
        s.route = { view: "objects" };
        s.crumbs = crumbsForRoute({ view: "objects" });
        s.history = [{ view: "dashboard" }, { view: "objects" }];
        s.historyIdx = 1;
      });
    });

    it("calls pushUrl with the correct path", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } });
      expect(env.lastPush).toBe("/objects");
    });

    it("dashboard maps to /", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial({ view: "objects" }));
      ts.send({ tag: "navigate", route: { view: "dashboard" } });
      expect(env.lastPush).toBe("/");
    });

    it("objectDetail with name maps to /objects/{name}", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objectDetail", name: "MyWindow" } });
      expect(env.lastPush).toBe("/objects/MyWindow");
    });

    it("procedureDetail maps to /objects/{name}/{proc}", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "procedureDetail", name: "MyObj", proc: "MyProc" } });
      expect(env.lastPush).toBe("/objects/MyObj/MyProc");
    });

    it("dwDetail with name maps to /datawindows/{name}", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "dwDetail", name: "MyDW" } });
      expect(env.lastPush).toBe("/datawindows/MyDW");
    });

    it("returns null (no effects)", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "explore" } });
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
        [{ view: "deadCode" },                                     "/dead-code"],
        [{ view: "taintExplorer" },                                "/taint"],
        [{ view: "formalReports" },                                "/reports"],
      ];
      for (const [route, expectedPath] of cases) {
        const env = makeNavEnv();
        const ts = createTestStore(navReducer, env, makeInitial());
        ts.send({ tag: "navigate", route });
        expect(env.lastPush).toBe(expectedPath);
      }
    });
  });

  describe("crumbs derived on navigate", () => {
    it("dashboard crumb has Dashboard label", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial({ view: "objects" }));
      ts.send({ tag: "navigate", route: { view: "dashboard" } }, (s) => {
        s.route = { view: "dashboard" };
        s.crumbs = crumbsForRoute({ view: "dashboard" });
        s.history = [{ view: "objects" }, { view: "dashboard" }];
        s.historyIdx = 1;
      });
    });

    it("procedureDetail builds 3-segment chain", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      const route = { view: "procedureDetail" as const, name: "w_pay", proc: "f_validate" };
      ts.send({ tag: "navigate", route }, (s) => {
        s.route = route;
        s.crumbs = crumbsForRoute(route);
        s.history = [{ view: "dashboard" }, route];
        s.historyIdx = 1;
      });
    });

    it("taintExplorer shows Taint Explorer label", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "taintExplorer" } }, (s) => {
        s.route = { view: "taintExplorer" };
        s.crumbs = crumbsForRoute({ view: "taintExplorer" });
        s.history = [{ view: "dashboard" }, { view: "taintExplorer" }];
        s.historyIdx = 1;
      });
    });
  });

  describe("history stack", () => {
    it("grows on each navigate", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } }, (s) => {
        s.route = { view: "objects" };
        s.crumbs = crumbsForRoute({ view: "objects" });
        s.history = [{ view: "dashboard" }, { view: "objects" }];
        s.historyIdx = 1;
      });
    });

    it("navigate from back position truncates forward history", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } });
      ts.send({ tag: "navigate", route: { view: "datawindows" } });
      ts.send({ tag: "back" });
      // Now navigate to a new destination — forward history (datawindows) is discarded
      ts.send({ tag: "navigate", route: { view: "tables" } }, (s) => {
        s.route = { view: "tables" };
        s.crumbs = crumbsForRoute({ view: "tables" });
        s.history = [{ view: "dashboard" }, { view: "objects" }, { view: "tables" }];
        s.historyIdx = 2;
      });
    });
  });

  describe("back action", () => {
    it("goes back one step in history", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } });
      ts.send({ tag: "back" }, (s) => {
        s.route = { view: "dashboard" };
        s.crumbs = crumbsForRoute({ view: "dashboard" });
        s.historyIdx = 0;
      });
      expect(env.lastPush).toBe("/");
    });

    it("does nothing at the start of history", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      const prevPush = env.lastPush;
      ts.send({ tag: "back" });
      // pushUrl should not have been called
      expect(env.lastPush).toBe(prevPush);
    });

    it("updates crumbs to match restored route", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objectDetail", name: "w_pay" } });
      ts.send({ tag: "back" }, (s) => {
        s.route = { view: "dashboard" };
        s.crumbs = crumbsForRoute({ view: "dashboard" });
        s.historyIdx = 0;
      });
    });
  });

  describe("navigate-from-ask", () => {
    it("sets askContext with queryName and queryRoute", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      const queryRoute: Route = { view: "queries", queryName: "top" };
      const entityRoute: Route = { view: "objectDetail", name: "w_payment" };
      ts.send(
        { tag: "navigate-from-ask", route: entityRoute, queryName: "top", queryRoute },
        (s) => {
          s.route = entityRoute;
          s.askContext = { queryName: "top", queryRoute };
          s.crumbs = [
            { icon: ICONS.ask, label: "top", route: queryRoute },
            { icon: ICONS.object, label: "w_payment", route: entityRoute },
          ];
          s.history = [{ view: "dashboard" }, entityRoute];
          s.historyIdx = 1;
        },
      );
    });

    it("drops the leading list crumb from the entity chain", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      const queryRoute: Route = { view: "queries", queryName: "top" };
      const entityRoute: Route = { view: "procedureDetail", name: "w_pay", proc: "f_validate" };
      ts.send({ tag: "navigate-from-ask", route: entityRoute, queryName: "top", queryRoute });
      const state = env.lastPush;
      // breadcrumb should NOT start with the list (Objects) segment
      expect(state).toBe("/objects/w_pay/f_validate");
    });

    it("navigate after navigate-from-ask clears askContext", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      const queryRoute: Route = { view: "queries", queryName: "top" };
      ts.send({ tag: "navigate-from-ask", route: { view: "objectDetail", name: "w_pay" }, queryName: "top", queryRoute });
      ts.send({ tag: "navigate", route: { view: "objects" } }, (s) => {
        s.route = { view: "objects" };
        s.crumbs = crumbsForRoute({ view: "objects" });
        s.askContext = null;
        s.history = [{ view: "dashboard" }, { view: "objectDetail", name: "w_pay" }, { view: "objects" }];
        s.historyIdx = 2;
      });
    });
  });

  describe("forward action", () => {
    it("goes forward after back", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } });
      ts.send({ tag: "back" });
      ts.send({ tag: "forward" }, (s) => {
        s.route = { view: "objects" };
        s.crumbs = crumbsForRoute({ view: "objects" });
        s.historyIdx = 1;
      });
    });

    it("does nothing at end of history", () => {
      const env = makeNavEnv();
      const ts = createTestStore(navReducer, env, makeInitial());
      ts.send({ tag: "navigate", route: { view: "objects" } });
      ts.send({ tag: "forward" });
    });
  });
});
