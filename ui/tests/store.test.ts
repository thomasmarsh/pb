// store.test.ts — Confirm valtio+SolidJS reactivity via the useSnapshot bridge.
//
// These tests document the exact timing of the valtio→SolidJS update cycle so
// that the bridge implementation can be reasoned about confidently.

import { describe, it, expect } from "vitest";
import { createRoot } from "solid-js";
import { proxy } from "valtio/vanilla";
import { useSnapshot } from "../src/core/store.js";

describe("useSnapshot — valtio+SolidJS bridge", () => {
  it("snap() returns initial proxy state", () => {
    createRoot(dispose => {
      const p = proxy({ count: 0, name: "hello" });
      const snap = useSnapshot(p);
      expect(snap().count).toBe(0);
      expect(snap().name).toBe("hello");
      dispose();
    });
  });

  // valtio subscribe callbacks fire asynchronously (microtask after mutation).
  // Reading snap() synchronously after mutation returns the stale snapshot.
  it("snap() is stale immediately after proxy mutation — update is async", () => {
    const p = proxy({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = useSnapshot(p); return d; });

    p.count = 42;
    expect(snap().count).toBe(0); // stale — subscribe hasn't fired yet

    dispose();
  });

  it("snap() reflects proxy mutation after subscribe microtask", async () => {
    const p = proxy({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = useSnapshot(p); return d; });

    p.count = 42;
    await Promise.resolve(); // let valtio subscribe callback fire → setSnap called
    expect(snap().count).toBe(42);

    dispose();
  });

  it("snap() reflects nested object mutation after microtask", async () => {
    const p = proxy({ nested: { value: 0 } });
    let snap!: () => { nested: { value: number } };
    const dispose = createRoot(d => { snap = useSnapshot(p); return d; });

    p.nested.value = 7;
    await Promise.resolve();
    expect(snap().nested.value).toBe(7);

    dispose();
  });

  it("multiple rapid mutations — only latest value visible after microtask", async () => {
    const p = proxy({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = useSnapshot(p); return d; });

    p.count = 1;
    p.count = 2;
    p.count = 3;
    await Promise.resolve();
    expect(snap().count).toBe(3);

    dispose();
  });

  it("owner dispose unsubscribes — no further updates", async () => {
    const p = proxy({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = useSnapshot(p); return d; });

    dispose(); // runs onCleanup → unsub()

    p.count = 99;
    await Promise.resolve();
    expect(snap().count).toBe(0); // still the initial snapshot — no update after unsub
  });
});
