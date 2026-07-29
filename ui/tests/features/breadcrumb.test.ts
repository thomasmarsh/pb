// tests/features/breadcrumb.test.ts — Tests for breadcrumb derivation.

import { describe, it, expect } from "vitest";
import { crumbsForRoute, ICONS } from "@pb/platform";

describe("crumbsForRoute", () => {
  it("dashboard → 1 crumb with library icon", () => {
    const crumbs = crumbsForRoute({ view: "dashboard" });
    expect(crumbs).toHaveLength(1);
    expect(crumbs[0]!.label).toBe("Dashboard");
    expect(crumbs[0]!.icon).toBe(ICONS.library);
  });

  it("browser → 1 crumb with list icon", () => {
    const crumbs = crumbsForRoute({ view: "browser" });
    expect(crumbs).toHaveLength(1);
    expect(crumbs[0]!.icon).toBe(ICONS.list);
    expect(crumbs[0]!.label).toBe("Browser");
  });

  it("browser with category → label from browserTabLabel", () => {
    const crumbs = crumbsForRoute({ view: "browser", category: "datawindow" });
    expect(crumbs[0]!.label).toBe("DataWindow");
  });

  it("objectDetail → 2 crumbs", () => {
    const crumbs = crumbsForRoute({ view: "objectDetail", name: "w_payment" });
    expect(crumbs).toHaveLength(2);
    expect(crumbs[0]!.label).toBe("Browser");
    expect(crumbs[1]!.label).toBe("w_payment");
    expect(crumbs[1]!.icon).toBe(ICONS.object);
    expect(crumbs[1]!.route).toEqual({ view: "objectDetail", name: "w_payment" });
  });

  it("procedureDetail → 3 crumbs with correct parent routes", () => {
    const crumbs = crumbsForRoute({ view: "procedureDetail", name: "w_pay", proc: "f_validate" });
    expect(crumbs).toHaveLength(3);
    expect(crumbs[0]!.route.view).toBe("browser");
    expect(crumbs[1]!.route).toEqual({ view: "objectDetail", name: "w_pay" });
    expect(crumbs[2]!.icon).toBe(ICONS.procedure);
    expect(crumbs[2]!.label).toBe("f_validate");
  });

  it("dwDetail → 2 crumbs", () => {
    const crumbs = crumbsForRoute({ view: "dwDetail", name: "d_grid" });
    expect(crumbs).toHaveLength(2);
    expect(crumbs[0]!.label).toBe("DataWindow");
    expect(crumbs[1]!.icon).toBe(ICONS.datawindow);
  });

  it("tableDetail → 2 crumbs", () => {
    const crumbs = crumbsForRoute({ view: "tableDetail", name: "accounts" });
    expect(crumbs).toHaveLength(2);
    expect(crumbs[1]!.icon).toBe(ICONS.table);
    expect(crumbs[1]!.label).toBe("accounts");
  });

  it("taintExplorer → analysis icon", () => {
    const crumbs = crumbsForRoute({ view: "taintExplorer" });
    expect(crumbs[0]!.icon).toBe(ICONS.analysis);
    expect(crumbs[0]!.label).toBe("Taint Explorer");
  });

  it("formalReports → analysis icon", () => {
    const crumbs = crumbsForRoute({ view: "formalReports" });
    expect(crumbs[0]!.label).toBe("Formal Reports");
  });

  it("deadCode → analysis icon", () => {
    const crumbs = crumbsForRoute({ view: "deadCode" });
    expect(crumbs[0]!.label).toBe("Dead Code");
  });

  it("queries → ask icon", () => {
    const crumbs = crumbsForRoute({ view: "queries" });
    expect(crumbs[0]!.icon).toBe(ICONS.ask);
    expect(crumbs[0]!.label).toBe("Ask");
  });

  it("queries with queryName still shows Ask label (query name lives in navigate-from-ask crumb)", () => {
    const crumbs = crumbsForRoute({ view: "queries", queryName: "top-complex" });
    expect(crumbs[0]!.icon).toBe(ICONS.ask);
    expect(crumbs[0]!.label).toBe("Ask");
  });

  it("last crumb route matches the input route exactly", () => {
    const route = { view: "objectDetail" as const, name: "w_admin" };
    const crumbs = crumbsForRoute(route);
    expect(crumbs[crumbs.length - 1]!.route).toEqual(route);
  });
});
