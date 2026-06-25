// tests/features/diagrams.test.ts — Tests for diagrams feature reducer.

import { describe, it } from "vitest";
import { Effect } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { diagramsReducer, initialDiagramsState, type DiagramsEnv } from "@pb/platform";
import type { DiagramsState } from "@pb/platform";

const mockEnv: DiagramsEnv = {
  getDiagram: () => Effect.none(),
  getTables: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("diagrams reducer", () => {
  describe("diagrams/select", () => {
    it("updates active kind and clears svg", () => {
      const init: DiagramsState = { ...initialDiagramsState, svg: "<svg>old</svg>" };
      const ts = createTestStore(diagramsReducer, mockEnv, init);
      ts.send({ tag: "select", kind: "calls" }, (s) => {
        s.active = "calls";
        s.svg = null;
      });
    });
  });

  describe("diagrams/params", () => {
    it("merges params into state", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ tag: "params", params: { root: "foo" } }, (s) => {
        s.params = { root: "foo" };
      });
    });
  });

  describe("diagrams/generate", () => {
    it("sets loading", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ tag: "generate" }, (s) => {
        s.loading = true;
      });
    });

    it("populates svg via effect", () => {
      const env: DiagramsEnv = { ...mockEnv, getDiagram: () => Effect.send("<svg>ok</svg>") };
      const ts = createTestStore(diagramsReducer, env, { ...initialDiagramsState });
      ts.send({ tag: "generate" }, (s) => {
        s.loading = true;
      });
      ts.receive({ tag: "loaded", svg: "<svg>ok</svg>" }, (s) => {
        s.svg = "<svg>ok</svg>";
        s.loading = false;
      });
    });
  });

  describe("diagrams/error", () => {
    it("clears loading and records error", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ tag: "error", error: "timeout" }, (s) => {
        s.error = "timeout";
      });
    });
  });
});
