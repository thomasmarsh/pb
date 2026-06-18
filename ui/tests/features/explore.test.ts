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
  getTables: () => Effect.none(),
  getTableDetail: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("explore reducer", () => {
  describe("explore/toggle", () => {
    it("adds node to expanded set", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ type: "toggle", nodeId: "lib:foo" }, (s) => {
        s.expandedNodes = new Set(["lib:foo"]);
      });
    });

    it("removes node if already expanded", () => {
      const init = makeInitialExploreState();
      init.expandedNodes.add("lib:foo");
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ type: "toggle", nodeId: "lib:foo" }, (s) => {
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
      ts.send({ type: "expand-all" }, (s) => {
        s.expandedNodes = new Set(["lib:a.pbl", "obj:a.pbl:o1"]);
      });
    });
  });

  describe("explore/collapse-all", () => {
    it("clears all expanded nodes", () => {
      const init = makeInitialExploreState();
      init.expandedNodes.add("lib:x");
      const ts = createTestStore(exploreReducer, mockEnv, init);
      ts.send({ type: "collapse-all" }, (s) => {
        s.expandedNodes = new Set();
      });
    });
  });

  describe("explore/load", () => {
    it("sets loading", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ type: "load" }, (s) => {
        s.loading = true;
      });
    });

    it("populates libraries via effect", () => {
      const data: ExploreTreeResponse = { libraries: [{ name: "lib1", objects: [] }] };
      const env: ExploreEnv = { ...mockEnv, getExploreTree: () => Effect.send(data) };
      const ts = createTestStore(exploreReducer, env, makeInitialExploreState());
      ts.send({ type: "load" }, (s) => {
        s.loading = true;
      });
      ts.receive({ type: "loaded", data }, (s) => {
        s.libraries = data.libraries;
        s.loading = false;
      });
    });
  });

  describe("explore/proc-select", () => {
    it("sets selectedProc and clears selectedDw", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ type: "proc-select", objectName: "o", procName: "p", nodeId: "proc:o:p" }, (s) => {
        s.selectedProc = "proc:o:p";
      });
    });
  });

  describe("explore/filter", () => {
    it("sets treeFilter", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ type: "filter", q: "foo" }, (s) => {
        s.treeFilter = "foo";
      });
    });
  });

  describe("explore/tab", () => {
    it("sets activeTab", () => {
      const ts = createTestStore(exploreReducer, mockEnv, makeInitialExploreState());
      ts.send({ type: "tab", tab: "ast" }, (s) => {
        s.activeTab = "ast";
      });
    });
  });
});
