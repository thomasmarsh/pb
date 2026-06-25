// store.test.ts — Confirm valtio+SolidJS reactivity via the getState() bridge.
//
// These tests document the exact timing of the valtio→SolidJS update cycle so
// that the bridge implementation can be reasoned about confidently.

import { describe, it, expect } from "vitest";
import { createRoot } from "solid-js";
import { createStore } from "../src/store.js";

function makeStore<T extends object>(init: T) {
  return createStore(init, () => null, undefined);
}

describe("getState — valtio+SolidJS bridge", () => {
  it("snap() returns initial state", () => {
    createRoot(dispose => {
      const store = makeStore({ count: 0, name: "hello" });
      const snap = store.getState();
      expect(snap().count).toBe(0);
      expect(snap().name).toBe("hello");
      dispose();
    });
  });

  // valtio subscribe callbacks fire asynchronously (microtask after mutation).
  // Reading snap() synchronously after mutation returns the stale snapshot.
  it("snap() is stale immediately after mutation — update is async", () => {
    const store = makeStore({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = store.getState(); return d; });

    store.state.count = 42;
    expect(snap().count).toBe(0); // stale — subscribe hasn't fired yet

    dispose();
  });

  it("snap() reflects mutation after subscribe microtask", async () => {
    const store = makeStore({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = store.getState(); return d; });

    store.state.count = 42;
    await Promise.resolve(); // let valtio subscribe callback fire → setSnap called
    expect(snap().count).toBe(42);

    dispose();
  });

  it("snap() reflects nested object mutation after microtask", async () => {
    const store = makeStore({ nested: { value: 0 } });
    let snap!: () => { nested: { value: number } };
    const dispose = createRoot(d => { snap = store.getState(); return d; });

    store.state.nested.value = 7;
    await Promise.resolve();
    expect(snap().nested.value).toBe(7);

    dispose();
  });

  it("multiple rapid mutations — only latest value visible after microtask", async () => {
    const store = makeStore({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = store.getState(); return d; });

    store.state.count = 1;
    store.state.count = 2;
    store.state.count = 3;
    await Promise.resolve();
    expect(snap().count).toBe(3);

    dispose();
  });

  it("owner dispose unsubscribes — no further updates", async () => {
    const store = makeStore({ count: 0 });
    let snap!: () => { count: number };
    const dispose = createRoot(d => { snap = store.getState(); return d; });

    dispose(); // runs onCleanup → unsub()

    store.state.count = 99;
    await Promise.resolve();
    expect(snap().count).toBe(0); // still the initial snapshot — no update after unsub
  });
});
