// tests/features/routes.test.ts — Tests for route codec (parse, print).

import { describe, it, expect } from "vitest";
import { parse, print } from "../../src/features/navigation/routes.js";

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

  it('"/queries" resolves to queries', () => {
    expect(parse("/queries")).toEqual({ view: "queries" });
  });

  it('"/search" resolves to search', () => {
    expect(parse("/search")).toEqual({ view: "search" });
  });

  it('"/explore" resolves to explore', () => {
    expect(parse("/explore")).toEqual({ view: "explore" });
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

  it('URL-encodes special characters in segments', () => {
    expect(print({ view: "objectDetail", name: "My Window" })).toBe("/objects/My%20Window");
  });

  it('round-trip: parse(print(route)) preserves the route', () => {
    const route = { view: "objectDetail" as const, name: "TestObj" };
    expect(parse(print(route))).toEqual(route);
  });
});
