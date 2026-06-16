// tests/components/HealthCheck.test.tsx — Tests for HealthCheck polling component.

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@solidjs/testing-library";
import { HealthCheck } from "../../src/components/HealthCheck.js";

describe("HealthCheck", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("renders nothing when connected (initial state)", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true }));
    const { container } = render(() => <HealthCheck />);
    await vi.advanceTimersByTimeAsync(0);
    expect(container.querySelector(".health-overlay")).toBeNull();
  });

  it("shows overlay when fetch fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network")));
    const { container } = render(() => <HealthCheck />);
    await vi.advanceTimersByTimeAsync(0);
    expect(screen.getByText("Connection lost")).toBeDefined();
    expect(screen.getByText("Unable to reach the backend server.")).toBeDefined();
    expect(container.querySelector(".health-overlay")).not.toBeNull();
  });

  it("shows Reconnect button when disconnected", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network")));
    render(() => <HealthCheck />);
    await vi.advanceTimersByTimeAsync(0);
    const btns = screen.getAllByText("Reconnect");
    expect(btns.length).toBeGreaterThanOrEqual(1);
  });

  it("Reconnect button shows Retrying... during retry", async () => {
    let resolveRetry!: () => void;
    const retryPromise = new Promise<void>((r) => { resolveRetry = r; });
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new Error("fail"))
      .mockReturnValueOnce(retryPromise.then(() => ({ ok: true })));
    vi.stubGlobal("fetch", fetchMock);

    render(() => <HealthCheck />);
    await vi.advanceTimersByTimeAsync(0);

    fireEvent.click(screen.getAllByText("Reconnect")[0]!);
    await vi.advanceTimersByTimeAsync(0);
    expect(screen.getAllByText("Retrying...").length).toBeGreaterThanOrEqual(1);

    resolveRetry();
    await vi.advanceTimersByTimeAsync(0);
  });

  it("hides overlay when reconnect succeeds", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValueOnce(new Error("fail")));
    const { container } = render(() => <HealthCheck />);
    await vi.advanceTimersByTimeAsync(0);
    expect(screen.getByText("Connection lost")).toBeDefined();

    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true }));
    fireEvent.click(screen.getAllByText("Reconnect")[0]!);
    await vi.advanceTimersByTimeAsync(0);
    expect(container.querySelector(".health-overlay")).toBeNull();
  });
});
