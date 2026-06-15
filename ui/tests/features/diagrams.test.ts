// tests/features/diagrams.test.ts — Tests for diagrams feature reducer.

import { describe, it } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { createTestStore } from "../test-store.js";
import { diagramsReducer, initialDiagramsState, type DiagramsEnv } from "../../src/features/diagrams/reducer.js";

const mockEnv: DiagramsEnv = {
  getDiagram: () => Effect.none(),
};

describe("diagrams reducer", () => {
  describe("diagrams/select", () => {
    it("updates active kind and clears svg", () => {
      const init = { ...{ ...initialDiagramsState }, svg: "<svg>old</svg>" };
      const ts = createTestStore(diagramsReducer, mockEnv, init);
      ts.send({ type: "select", kind: "calls" }, (s) => {
        s.active = "calls";
        s.svg = null;
      });
    });
  });

  describe("diagrams/params", () => {
    it("merges params into state", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ type: "params", params: { root: "foo" } }, (s) => {
        s.params = { root: "foo" };
      });
    });
  });

  describe("diagrams/generate", () => {
    it("sets loading", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ type: "generate" }, (s) => {
        s.loading = true;
      });
    });

    it("populates svg via effect", () => {
      const env: DiagramsEnv = { getDiagram: () => Effect.send("<svg>ok</svg>") };
      const ts = createTestStore(diagramsReducer, env, { ...initialDiagramsState });
      ts.send({ type: "generate" }, (s) => {
        s.loading = true;
      });
      ts.receive({ type: "loaded", svg: "<svg>ok</svg>" }, (s) => {
        s.svg = "<svg>ok</svg>";
        s.loading = false;
      });
    });
  });

  describe("diagrams/error", () => {
    it("clears loading and records error", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ type: "error", error: "timeout" }, (s) => {
        s.error = "timeout";
      });
    });
  });
});
