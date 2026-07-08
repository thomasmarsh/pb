// tests/features/routes.test.ts — Tests for route codec (parse, print).

import { describe, it, expect } from "vitest";
import { parse, print } from "@pb/platform";

describe("parse", () => {
  it('"/" resolves to dashboard', () => {
    expect(parse("/")).toEqual({ view: "dashboard" });
  });

  it('"/objects" resolves to objects', () => {
    expect(parse("/objects")).toEqual({ view: "objects" });
  });

  it('"/objects/MyWindow" resolves to objectDetail', () => {
    expect(parse("/objects/MyWindow")).toEqual({ view: "objectDetail", name: "MyWindow" });
  });

  it('"/objects/MyWindow/MyProc" resolves to procedureDetail', () => {
    expect(parse("/objects/MyWindow/MyProc")).toEqual({
      view: "procedureDetail", name: "MyWindow", proc: "MyProc",
    });
  });

  it('"/datawindows" resolves to datawindows', () => {
    expect(parse("/datawindows")).toEqual({ view: "datawindows" });
  });

  it('"/datawindows/MyDW" resolves to dwDetail', () => {
    expect(parse("/datawindows/MyDW")).toEqual({ view: "dwDetail", name: "MyDW" });
  });

  it('"/tables" resolves to tables', () => {
    expect(parse("/tables")).toEqual({ view: "tables" });
  });

  it('"/tables/MY_TABLE" resolves to tableDetail', () => {
    expect(parse("/tables/MY_TABLE")).toEqual({ view: "tableDetail", name: "MY_TABLE" });
  });

  it('"/tables/schema.table%20name" decodes URL-encoded table names', () => {
    expect(parse("/tables/schema.table%20name")).toEqual({ view: "tableDetail", name: "schema.table name" });
  });

  it('"/diagrams" resolves to diagrams', () => {
    expect(parse("/diagrams")).toEqual({ view: "diagrams" });
  });

  it('"/diagrams" with ?kind=fk-graph resolves to diagrams with kind', () => {
    expect(parse("/diagrams", "?kind=fk-graph")).toEqual({ view: "diagrams", kind: "fk-graph" });
  });

  it('"/diagrams" with an unknown ?kind= falls back to no kind', () => {
    expect(parse("/diagrams", "?kind=not-a-real-kind")).toEqual({ view: "diagrams" });
  });

  it('"/queries" resolves to queries with no queryName', () => {
    expect(parse("/queries")).toEqual({ view: "queries" });
  });

  it('"/queries" with ?q=top resolves to queries with queryName', () => {
    expect(parse("/queries", "?q=top")).toEqual({ view: "queries", queryName: "top", queryParams: {} });
  });

  it('"/queries" with ?q=top&p_n=15 includes queryParams', () => {
    expect(parse("/queries", "?q=top&p_n=15")).toEqual({
      view: "queries", queryName: "top", queryParams: { n: "15" },
    });
  });

  it('"/queries" with search without leading ? still works', () => {
    expect(parse("/queries", "q=top&p_n=5")).toEqual({
      view: "queries", queryName: "top", queryParams: { n: "5" },
    });
  });

  it('"/search" resolves to search', () => {
    expect(parse("/search")).toEqual({ view: "search" });
  });

  it('"/explore" resolves to explore', () => {
    expect(parse("/explore")).toEqual({ view: "explore" });
  });

  it('"/errors" resolves to errors', () => {
    expect(parse("/errors")).toEqual({ view: "errors" });
  });

  it('"/unknown" falls back to dashboard', () => {
    expect(parse("/unknown")).toEqual({ view: "dashboard" });
  });

  it('"/objects/My%20Window" decodes URL-encoded segments', () => {
    expect(parse("/objects/My%20Window")).toEqual({ view: "objectDetail", name: "My Window" });
  });

  it('"" (empty path) resolves to dashboard', () => {
    expect(parse("")).toEqual({ view: "dashboard" });
  });
});

describe("print", () => {
  it('dashboard maps to "/"', () => {
    expect(print({ view: "dashboard" })).toBe("/");
  });

  it('objects maps to "/objects"', () => {
    expect(print({ view: "objects" })).toBe("/objects");
  });

  it('objectDetail maps to "/objects/{name}"', () => {
    expect(print({ view: "objectDetail", name: "MyWindow" })).toBe("/objects/MyWindow");
  });

  it('procedureDetail maps to "/objects/{name}/{proc}"', () => {
    expect(print({ view: "procedureDetail", name: "MyObj", proc: "MyProc" })).toBe("/objects/MyObj/MyProc");
  });

  it('dwDetail maps to "/datawindows/{name}"', () => {
    expect(print({ view: "dwDetail", name: "MyDW" })).toBe("/datawindows/MyDW");
  });

  it('tables maps to "/tables"', () => {
    expect(print({ view: "tables" })).toBe("/tables");
  });

  it('tableDetail maps to "/tables/{name}"', () => {
    expect(print({ view: "tableDetail", name: "MY_TABLE" })).toBe("/tables/MY_TABLE");
  });

  it('round-trip: tableDetail preserves name', () => {
    const route = { view: "tableDetail" as const, name: "schema.orders" };
    expect(parse(print(route))).toEqual(route);
  });

  it('datawindows maps to "/datawindows"', () => {
    expect(print({ view: "datawindows" })).toBe("/datawindows");
  });

  it('diagrams with kind maps to "/diagrams?kind={kind}"', () => {
    expect(print({ view: "diagrams", kind: "fk-graph" })).toBe("/diagrams?kind=fk-graph");
  });

  it('round-trip: diagrams with kind preserves kind', () => {
    const route = { view: "diagrams" as const, kind: "window-table-lattice" as const };
    const printed = print(route);
    const [pathname, search] = printed.split("?");
    expect(parse(pathname!, search ? `?${search}` : undefined)).toEqual(route);
  });

  it('URL-encodes special characters in segments', () => {
    expect(print({ view: "objectDetail", name: "My Window" })).toBe("/objects/My%20Window");
  });

  it('round-trip: parse(print(route)) preserves the route', () => {
    const route = { view: "objectDetail" as const, name: "TestObj" };
    expect(parse(print(route))).toEqual(route);
  });

  it('queries without queryName maps to "/queries"', () => {
    expect(print({ view: "queries" })).toBe("/queries");
  });

  it('queries with queryName maps to "/queries?q=name"', () => {
    expect(print({ view: "queries", queryName: "top" })).toBe("/queries?q=top");
  });

  it('queries with queryName and queryParams maps to "/queries?q=name&p_key=val"', () => {
    const result = print({ view: "queries", queryName: "top", queryParams: { n: "5" } });
    expect(result).toBe("/queries?q=top&p_n=5");
  });

  it('round-trip: queries with queryName and queryParams preserves route', () => {
    const route = { view: "queries" as const, queryName: "callers", queryParams: { name: "f_proc" } };
    const printed = print(route);
    const [pathname, search] = printed.split("?");
    expect(parse(pathname!, search ? `?${search}` : undefined)).toEqual(route);
  });

  it('queries with sqlText maps to "/queries?sql=..."', () => {
    const sql = "SELECT name FROM objects";
    const result = print({ view: "queries", sqlText: sql });
    expect(result).toBe("/queries?sql=SELECT+name+FROM+objects");
  });

  it('parse queries with ?sql=... returns sqlText route', () => {
    expect(parse("/queries", "?sql=SELECT+1")).toEqual({ view: "queries", sqlText: "SELECT 1" });
  });

  it('round-trip: queries with sqlText preserves route', () => {
    const route = { view: "queries" as const, sqlText: "SELECT name, object FROM procedures WHERE cyclomatic > 5" };
    const printed = print(route);
    const [pathname, search] = printed.split("?");
    expect(parse(pathname!, search ? `?${search}` : undefined)).toEqual(route);
  });

  it('taintPathView maps to "/taint/{id}"', () => {
    expect(print({ view: "taintPathView", pathId: 7 })).toBe("/taint/7");
  });

  it('round-trip: taintPathView preserves pathId', () => {
    const route = { view: "taintPathView" as const, pathId: 13 };
    expect(parse(print(route))).toEqual(route);
  });

  it('sliceView maps to "/slice/{object}/{proc}/{line}?dir=backward"', () => {
    const route = { view: "sliceView" as const, object: "w_pay", proc: "f_proc", line: 42, direction: "backward" as const };
    expect(print(route)).toBe("/slice/w_pay/f_proc/42?dir=backward");
  });

  it('round-trip: sliceView backward preserves all fields', () => {
    const route = { view: "sliceView" as const, object: "w_pay", proc: "f_proc", line: 42, direction: "backward" as const };
    const printed = print(route);
    const [pathname, search] = printed.split("?");
    expect(parse(pathname!, search ? `?${search}` : undefined)).toEqual(route);
  });

  it('round-trip: sliceView forward preserves direction', () => {
    const route = { view: "sliceView" as const, object: "w_x", proc: "f_y", line: 10, direction: "forward" as const };
    const printed = print(route);
    const [pathname, search] = printed.split("?");
    expect(parse(pathname!, search ? `?${search}` : undefined)).toEqual(route);
  });

  it('sliceView URL-encodes object and proc names', () => {
    const route = { view: "sliceView" as const, object: "w my obj", proc: "f my proc", line: 1, direction: "backward" as const };
    expect(print(route)).toContain("w%20my%20obj");
    expect(print(route)).toContain("f%20my%20proc");
  });
});
