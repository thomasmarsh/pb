// tests/features/diagrams.test.ts — Tests for diagrams feature reducer.

import { describe, it } from "vitest";
import { Effect, initialJobPollState } from "@pb/core";
import { createTestStore } from "../test-store.js";
import { diagramsReducer, initialDiagramsState, type DiagramsEnv } from "@pb/platform";
import type { DiagramsState } from "@pb/platform";

const mockEnv: DiagramsEnv = {
  submitDiagramJob: () => Effect.none(),
  pollDiagramJob: () => Effect.none(),
  getTables: () => Effect.none(),
  getAllObjects: () => Effect.none(),
  navigate: () => Effect.none(),
};

describe("diagrams reducer", () => {
  describe("diagrams/select", () => {
    it("updates active kind and resets the job to idle", () => {
      const init: DiagramsState = { ...initialDiagramsState, job: { ...initialJobPollState<string>(), status: "done", result: "<svg>old</svg>" } };
      const ts = createTestStore(diagramsReducer, mockEnv, init);
      ts.send({ tag: "select", kind: "calls" }, (s) => {
        s.active = "calls";
        s.job = initialJobPollState<string>();
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
    it("sets the job to pending", () => {
      const ts = createTestStore(diagramsReducer, mockEnv, { ...initialDiagramsState });
      ts.send({ tag: "generate" }, (s) => {
        s.job = { ...initialJobPollState<string>(), status: "pending" };
      });
    });

    it("populates svg via the job-poll cache-hit ('done') path", () => {
      const env: DiagramsEnv = { ...mockEnv, submitDiagramJob: () => Effect.send({ status: "done", result: "<svg>ok</svg>" }) };
      const ts = createTestStore(diagramsReducer, env, { ...initialDiagramsState });
      ts.send({ tag: "generate" }, (s) => {
        s.job = { ...initialJobPollState<string>(), status: "pending" };
      });
      ts.receive({ tag: "job", action: { tag: "submitted", result: { status: "done", result: "<svg>ok</svg>" } } }, (s) => {
        s.job.status = "done";
        s.job.result = "<svg>ok</svg>";
      });
    });

    it("polls to completion when the job is pending", () => {
      const env: DiagramsEnv = {
        ...mockEnv,
        submitDiagramJob: () => Effect.send({ status: "pending", jobId: "job-1" }),
        pollDiagramJob: () => Effect.send({ status: "done", result: "<svg>polled</svg>" }),
      };
      const ts = createTestStore(diagramsReducer, env, { ...initialDiagramsState });
      ts.send({ tag: "generate" }, (s) => {
        s.job = { ...initialJobPollState<string>(), status: "pending" };
      });
      ts.receive({ tag: "job", action: { tag: "submitted", result: { status: "pending", jobId: "job-1" } } }, (s) => {
        s.job.jobId = "job-1";
      });
      ts.receive({ tag: "job", action: { tag: "tick", jobId: "job-1" } });
      ts.receive({ tag: "job", action: { tag: "polled", jobId: "job-1", result: { status: "done", result: "<svg>polled</svg>" } } }, (s) => {
        s.job.status = "done";
        s.job.result = "<svg>polled</svg>";
      });
    });
  });
});
