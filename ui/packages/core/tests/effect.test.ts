// effect.test.ts — Effect.delay: sends a value after a timer, for poll-loop backoff.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Effect } from "../src/effect.js";

describe("Effect.delay", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("sends the value after the given delay, not before", async () => {
    const received: string[] = [];
    const exec = Effect.delay(300, "tick").execute((a) => received.push(a));

    await vi.advanceTimersByTimeAsync(299);
    expect(received).toEqual([]);

    await vi.advanceTimersByTimeAsync(1);
    expect(received).toEqual(["tick"]);

    await exec;
  });

  it("does not send anything if no time has advanced", async () => {
    const received: number[] = [];
    void Effect.delay(500, 42).execute((a) => received.push(a));
    expect(received).toEqual([]);
  });
});
