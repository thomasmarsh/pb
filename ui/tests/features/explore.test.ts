// tests/features/explore.test.ts — Tests for explore feature reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { exploreReducer, makeInitialExploreState, type ExploreEnv } from "../../src/features/explore/reducer.js";
import type { ExploreTreeResponse } from "../../src/types/api.js";

const mockEnv: ExploreEnv = {
  getExploreTree: () => Effect.none(),
  getExploreProcedure: () => Effect.none(),
  getExploreDatawindow: () => Effect.none(),
  getDwLayout: () => Effect.none(),
  getObjectSource: () => Effect.none(),
  getTables: () => Effect.none(),
  getTableDetail: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("explore reducer", () => {
  describe("explore/toggle", () => {
    it("adds node to expanded set", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "toggle", nodeId: "lib:foo" }, (s) => {
        s.expandedNodes = new Set(["lib:foo"]);
      });
    });

    it("removes node if already expanded", () => {
      const init = makeInitialExploreState();
      init.expandedNodes.add("lib:foo");
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "toggle", nodeId: "lib:foo" }, (s) => {
        s.expandedNodes = new Set();
      });
    });
  });

  describe("explore/expand-all", () => {
    it("expands all libraries and objects", () => {
      const init = makeInitialExploreState();
      init.libraries = [
        { name: "a.pbl", objects: [{ name: "o1", kind: "powerscript", file: "f", procedures: [] }] },
      ];
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "expand-all" }, (s) => {
        s.expandedNodes = new Set(["lib:a.pbl", "obj:a.pbl:o1"]);
      });
    });
  });

  describe("explore/collapse-all", () => {
    it("clears all expanded nodes", () => {
      const init = makeInitialExploreState();
      init.expandedNodes.add("lib:x");
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "collapse-all" }, (s) => {
        s.expandedNodes = new Set();
      });
    });
  });

  describe("explore/load", () => {
    it("sets loading", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "load" }, (s) => {
        s.loading = true;
      });
    });

    it("populates libraries via effect", () => {
      const data: ExploreTreeResponse = { libraries: [{ name: "lib1", objects: [] }] };
      const env: ExploreEnv = { ...mockEnv, getExploreTree: () => Effect.send(data) };
      const ts = createTestStore(exploreReducer, env, makeInitialExploreState());
      ts.send({ tag: "load" }, (s) => {
        s.loading = true;
      });
      ts.receive({ tag: "loaded", data }, (s) => {
        s.libraries = data.libraries;
        s.loading = false;
      });
    });
  });

  describe("explore/proc-select", () => {
    it("sets selectedProc, selectedObject, highlightedProcName and clears selectedDw", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "proc-select", objectName: "o", procName: "p", nodeId: "proc:o:p" }, (s) => {
        s.selectedProc = "proc:o:p";
        s.selectedObject = "o";
        s.highlightedProcName = "p";
      });
    });

    it("auto-reveals library and object (no kind groups)", () => {
      const init = makeInitialExploreState();
      init.libraries = [
        { name: "app.pbl", objects: [
          { name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
            { name: "of_init", proc_type: "function", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null },
          ] },
        ] },
      ];
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "proc-select", objectName: "w_main", procName: "of_init", nodeId: "proc:w_main:of_init" }, (s) => {
        s.selectedProc = "proc:w_main:of_init";
        s.selectedObject = "w_main";
        s.highlightedProcName = "of_init";
        s.expandedNodes = new Set(["lib:app.pbl", "obj:app.pbl:w_main"]);
        s.sidebarGroups = { sourceTree: true, entityNav: false, analysisNav: false };
      });
    });
  });

  describe("explore/filter", () => {
    it("sets treeFilter", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "filter", q: "foo" }, (s) => {
        s.treeFilter = "foo";
      });
    });
  });

  describe("explore/tab", () => {
    it("sets activeTab", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "tab", tab: "ast" }, (s) => {
        s.activeTab = "ast";
      });
    });
  });

  describe("sidebar accordion", () => {
    it("sidebar-toggle-group flips sourceTree from true to false", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "sidebar-toggle-group", group: "sourceTree" }, (s) => {
        s.sidebarGroups = { sourceTree: false, entityNav: false, analysisNav: false };
      });
    });

    it("sidebar-toggle-group flips entityNav from false to true", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "sidebar-toggle-group", group: "entityNav" }, (s) => {
        s.sidebarGroups = { sourceTree: true, entityNav: true, analysisNav: false };
      });
    });

    it("sidebar-set-collapsed sets sidebarCollapsed true", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "sidebar-set-collapsed", collapsed: true }, (s) => {
        s.sidebarCollapsed = true;
      });
    });

    it("sidebar-set-collapsed sets sidebarCollapsed false", () => {
      const init = makeInitialExploreState();
      init.sidebarCollapsed = true;
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "sidebar-set-collapsed", collapsed: false }, (s) => {
        s.sidebarCollapsed = false;
      });
    });
  });

  describe("sidebar-reveal", () => {
    it("adds library and object to expandedNodes when object found", () => {
      const init = makeInitialExploreState();
      init.libraries = [
        { name: "app.pbl", objects: [
          { name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [] },
        ] },
      ];
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "sidebar-reveal", objectName: "w_main" }, (s) => {
        s.expandedNodes = new Set(["lib:app.pbl", "obj:app.pbl:w_main"]);
        s.sidebarGroups = { sourceTree: true, entityNav: false, analysisNav: false };
      });
    });

    it("reveals library and object when procName given (no group nodes)", () => {
      const init = makeInitialExploreState();
      init.libraries = [
        { name: "app.pbl", objects: [
          { name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [
            { name: "ue_open", proc_type: "event", params: "", return_type: "", cyclomatic: null, start_line: null, end_line: null, object: "w_main", modifiers: null },
          ] },
        ] },
      ];
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "sidebar-reveal", objectName: "w_main", procName: "ue_open" }, (s) => {
        s.expandedNodes = new Set(["lib:app.pbl", "obj:app.pbl:w_main"]);
        s.sidebarGroups = { sourceTree: true, entityNav: false, analysisNav: false };
      });
    });

    it("does not collapse previously expanded nodes", () => {
      const init = makeInitialExploreState();
      init.expandedNodes = new Set(["lib:other.pbl"]);
      init.libraries = [
        { name: "app.pbl", objects: [
          { name: "w_main", kind: "powerscript", file: "app.pbl", procedures: [] },
        ] },
        { name: "other.pbl", objects: [] },
      ];
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ tag: "sidebar-reveal", objectName: "w_main" }, (s) => {
        s.expandedNodes = new Set(["lib:other.pbl", "lib:app.pbl", "obj:app.pbl:w_main"]);
      });
    });

    it("no-op when objectName not found in libraries", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ tag: "sidebar-reveal", objectName: "nonexistent" }, (s) => {
        s.expandedNodes = new Set();
      });
    });
  });
});
