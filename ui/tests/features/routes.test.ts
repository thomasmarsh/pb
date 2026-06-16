// tests/features/routes.test.ts — Tests for route resolution (pathToView, viewToPath).

import { describe, it, expect } from "vitest";
import { pathToView, viewToPath } from "../../src/features/navigation/routes.js";

describe("pathToView", () => {
  it('"/" resolves to dashboard', () => {
    expect(pathToView("/")).toEqual({ view: "dashboard", params: {} });
  });

  it('"/objects" resolves to objects', () => {
    expect(pathToView("/objects")).toEqual({ view: "objects", params: {} });
  });

  it('"/objects/MyWindow" resolves to objectDetail', () => {
    expect(pathToView("/objects/MyWindow")).toEqual({
      view: "objectDetail",
      params: { objectName: "MyWindow" },
    });
  });

  it('"/objects/MyWindow/MyProc" resolves to procedureDetail', () => {
    expect(pathToView("/objects/MyWindow/MyProc")).toEqual({
      view: "procedureDetail",
      params: { procObject: "MyWindow", procName: "MyProc" },
    });
  });

  it('"/datawindows" resolves to datawindows', () => {
    expect(pathToView("/datawindows")).toEqual({ view: "datawindows", params: {} });
  });

  it('"/datawindows/MyDW" resolves to dwDetail', () => {
    expect(pathToView("/datawindows/MyDW")).toEqual({
      view: "dwDetail",
      params: { dwName: "MyDW" },
    });
  });

  it('"/diagrams" resolves to diagrams', () => {
    expect(pathToView("/diagrams")).toEqual({ view: "diagrams", params: {} });
  });

  it('"/queries" resolves to queries', () => {
    expect(pathToView("/queries")).toEqual({ view: "queries", params: {} });
  });

  it('"/search" resolves to search', () => {
    expect(pathToView("/search")).toEqual({ view: "search", params: {} });
  });

  it('"/explore" resolves to explore', () => {
    expect(pathToView("/explore")).toEqual({ view: "explore", params: {} });
  });

  it('"/unknown" falls back to dashboard', () => {
    expect(pathToView("/unknown")).toEqual({ view: "dashboard", params: {} });
  });

  it('"/objects/My%20Window" decodes URL-encoded segments', () => {
    expect(pathToView("/objects/My%20Window")).toEqual({
      view: "objectDetail",
      params: { objectName: "My Window" },
    });
  });

  it('"" (empty path) resolves to dashboard', () => {
    expect(pathToView("")).toEqual({ view: "dashboard", params: {} });
  });
});

describe("viewToPath", () => {
  it('"dashboard" maps to "/"', () => {
    expect(viewToPath("dashboard", {})).toBe("/");
  });

  it('"objects" maps to "/objects"', () => {
    expect(viewToPath("objects", {})).toBe("/objects");
  });

  it('"objectDetail" with name maps to "/objects/{name}"', () => {
    expect(viewToPath("objectDetail", { objectDetail: { name: "MyWindow" } })).toBe("/objects/MyWindow");
  });

  it('"objectDetail" without name maps to "/objects"', () => {
    expect(viewToPath("objectDetail", {})).toBe("/objects");
  });

  it('"procedureDetail" with object and name maps to two-segment path', () => {
    const state = { procedureDetail: { object: "MyObj", name: "MyProc" } };
    expect(viewToPath("procedureDetail", state)).toBe("/objects/MyObj/MyProc");
  });

  it('"dwDetail" with name maps to "/datawindows/{name}"', () => {
    expect(viewToPath("dwDetail", { dwDetail: { name: "MyDW" } })).toBe("/datawindows/MyDW");
  });

  it('"datawindows" maps to "/datawindows"', () => {
    expect(viewToPath("datawindows", {})).toBe("/datawindows");
  });

  it('URL-encodes special characters in segments', () => {
    expect(viewToPath("objectDetail", { objectDetail: { name: "My Window" } })).toBe("/objects/My%20Window");
  });

  it('round-trips: pathToView(viewToPath(view, state)) re-encodes the view', () => {
    const state = { objectDetail: { name: "TestObj" } };
    const path = viewToPath("objectDetail", state);
    const resolved = pathToView(path);
    expect(resolved.view).toBe("objectDetail");
    expect(resolved.params.objectName).toBe("TestObj");
  });
});
