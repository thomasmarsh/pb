// job-poll.test.ts — Generic background-job submit/poll state machine (Plan 159).

import { describe, it, vi } from "vitest";
import { Effect } from "../src/effect.js";
import {
  jobPollReduce,
  initialJobPollState,
  type JobPollState,
  type JobPollEnv,
} from "../src/job-poll.js";
import { createTestStore } from "../../../tests/test-store.js";

type Result = { svg: string };

const mockEnv: JobPollEnv<Result> = {
  submitJob: () => Effect.none(),
  pollJob: () => Effect.none(),
};

describe("job-poll: start", () => {
  it("submits and transitions to pending", () => {
    const env: JobPollEnv<Result> = {
      ...mockEnv,
      submitJob: () => Effect.send({ status: "pending", jobId: "job-1" }),
    };
    const ts = createTestStore(jobPollReduce<Result>, env, initialJobPollState<Result>());
    ts.send({ tag: "start" }, (s) => {
      s.status = "pending";
      s.jobId = null;
      s.result = null;
      s.error = null;
      s.attempt = 0;
    });
    ts.receive({ tag: "submitted", result: { status: "pending", jobId: "job-1" } }, (s) => {
      s.jobId = "job-1";
    });
  });

  it("is a no-op while already pending", () => {
    const init: JobPollState<Result> = { ...initialJobPollState<Result>(), status: "pending", jobId: "existing" };
    const ts = createTestStore(jobPollReduce<Result>, mockEnv, init);
    ts.send({ tag: "start" });
  });

  it("a rejected submitJob (transport failure) surfaces as a 'failed' action, not a silent drop", async () => {
    const env: JobPollEnv<Result> = {
      ...mockEnv,
      submitJob: () => Effect.fromPromise(() => Promise.reject(new Error("HTTP 503"))),
    };
    const ts = createTestStore(jobPollReduce<Result>, env, initialJobPollState<Result>());
    ts.send({ tag: "start" }, (s) => {
      s.status = "pending";
      s.jobId = null;
      s.result = null;
      s.error = null;
      s.attempt = 0;
    });
    await ts.drain();
    ts.receive({ tag: "failed", error: "Error: HTTP 503" }, (s) => {
      s.status = "error";
      s.error = "Error: HTTP 503";
    });
  });
});

describe("job-poll: submitted", () => {
  it("a done result sets status done and result, with no further effect", () => {
    const ts = createTestStore(jobPollReduce<Result>, mockEnv, { ...initialJobPollState<Result>(), status: "pending" });
    ts.send({ tag: "submitted", result: { status: "done", result: { svg: "<svg/>" } } }, (s) => {
      s.status = "done";
      s.result = { svg: "<svg/>" };
    });
  });

  it("a pending result stores jobId and dispatches tick", () => {
    const ts = createTestStore(jobPollReduce<Result>, mockEnv, { ...initialJobPollState<Result>(), status: "pending" });
    ts.send({ tag: "submitted", result: { status: "pending", jobId: "job-2" } }, (s) => {
      s.jobId = "job-2";
    });
    ts.receive({ tag: "tick", jobId: "job-2" });
  });
});

describe("job-poll: tick", () => {
  it("calls pollJob and dispatches polled", () => {
    const env: JobPollEnv<Result> = {
      ...mockEnv,
      pollJob: () => Effect.send({ status: "pending" }),
    };
    const ts = createTestStore(
      jobPollReduce<Result>,
      env,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "job-3" },
    );
    ts.send({ tag: "tick", jobId: "job-3" });
    ts.receive({ tag: "polled", jobId: "job-3", result: { status: "pending" } });
  });

  it("a rejected pollJob (transport failure) surfaces as a 'failed' action, not a silent drop", async () => {
    const env: JobPollEnv<Result> = {
      ...mockEnv,
      pollJob: () => Effect.fromPromise(() => Promise.reject(new Error("network error"))),
    };
    const ts = createTestStore(
      jobPollReduce<Result>,
      env,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "job-3b" },
    );
    ts.send({ tag: "tick", jobId: "job-3b" });
    await ts.drain();
    ts.receive({ tag: "failed", error: "Error: network error" }, (s) => {
      s.status = "error";
      s.error = "Error: network error";
    });
  });
});

describe("job-poll: polled", () => {
  it("a pending result increments attempt and schedules the next tick via Effect.delay", async () => {
    vi.useFakeTimers();
    const ts = createTestStore(
      jobPollReduce<Result>,
      mockEnv,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "job-4", attempt: 0 },
    );
    ts.send({ tag: "polled", jobId: "job-4", result: { status: "pending" } }, (s) => {
      s.attempt = 1;
    });
    // Effect.delay(300, ...) is now in flight — advance the fake clock so its
    // setTimeout fires and the dispatched "tick" can be drained by afterEach;
    // otherwise switching back to real timers below orphans that setTimeout
    // and the suite's afterEach(drain()) hangs forever awaiting it.
    await vi.advanceTimersByTimeAsync(300);
    ts.receive({ tag: "tick", jobId: "job-4" });
    vi.useRealTimers();
  });

  it("a done result sets status done and result", () => {
    const ts = createTestStore(
      jobPollReduce<Result>,
      mockEnv,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "job-5" },
    );
    ts.send({ tag: "polled", jobId: "job-5", result: { status: "done", result: { svg: "<svg/>" } } }, (s) => {
      s.status = "done";
      s.result = { svg: "<svg/>" };
    });
  });

  it("an error result sets status error and message", () => {
    const ts = createTestStore(
      jobPollReduce<Result>,
      mockEnv,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "job-6" },
    );
    ts.send({ tag: "polled", jobId: "job-6", result: { status: "error", error: "dot crashed" } }, (s) => {
      s.status = "error";
      s.error = "dot crashed";
    });
  });

  it("ignores a polled action for a superseded jobId (stale-poll guard)", () => {
    const ts = createTestStore(
      jobPollReduce<Result>,
      mockEnv,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "current-job" },
    );
    ts.send({ tag: "polled", jobId: "stale-job", result: { status: "done", result: { svg: "<svg/>" } } });
  });

  it("gives up and reports a timeout error after max attempts", () => {
    const ts = createTestStore(
      jobPollReduce<Result>,
      mockEnv,
      { ...initialJobPollState<Result>(), status: "pending", jobId: "job-7", attempt: 29 },
    );
    ts.send({ tag: "polled", jobId: "job-7", result: { status: "pending" } }, (s) => {
      s.status = "error";
      s.attempt = 30;
      s.error = "Timed out waiting for diagram render";
    });
  });
});
