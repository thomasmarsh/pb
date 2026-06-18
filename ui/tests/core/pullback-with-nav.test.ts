// tests/core/pullback-with-nav.test.ts — Tests for pullbackWithNav composition.

import { describe, it, expect } from "vitest";
import { Effect } from "../../src/core/effect.js";
import { pullback, pullbackWithNav, combine } from "../../src/core/reducer.js";
import type { Reducer } from "../../src/core/reducer.js";
import { createTestStore } from "../test-store.js";

// ── Test types ────────────────────────────────────────────────────────────────

interface ChildState { value: number }
type ChildAction =
  | { tag: "increment" }
  | { tag: "navigate-away" }
  | { tag: "no-op" };

interface ParentState { child: ChildState; side: string }
type ParentAction =
  | { tag: "child"; action: ChildAction }
  | { tag: "nav"; nav: string };

interface ChildEnv {
  doWork(): Effect<ChildAction>;
  navigate(nav: string): Effect<never>;
}

const childLens = {
  get: (s: ParentState) => s.child,
  match: (a: ParentAction) => a.tag === "child" ? a.action : null,
  widen: (a: ChildAction): ParentAction => ({ tag: "child", action: a }),
  widenNav: (nav: string): ParentAction => ({ tag: "nav", nav }),
  getEnv: (env: ChildEnv): ChildEnv => ({ doWork: env.doWork, navigate: env.navigate }),
};

// A child reducer that tracks whether navigate was called
function makeChildReducer(opts: {
  onIncrement?: (draft: ChildState) => void;
  navigateView?: string;
  effect?: Effect<ChildAction>;
}): Reducer<ChildState, ChildAction, ChildEnv> {
  return (draft, action, env) => {
    switch (action.tag) {
    case "increment":
      opts.onIncrement?.(draft);
      return opts.effect ?? null;
    case "navigate-away":
      env.navigate(opts.navigateView ?? "objects");
      return null;
    case "no-op":
      return null;
    }
  };
}

function initialParent(): ParentState {
  return { child: { value: 0 }, side: "" };
}

// ── pullbackWithNav tests ─────────────────────────────────────────────────────

describe("pullbackWithNav", () => {
  it("captures env.navigate call into parent effect", () => {
    const child = makeChildReducer({ navigateView: "objects" });
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "navigate-away" } });
    // The nav action should be pending as a parent effect
    ts.receive({ tag: "nav", nav: "objects" });
  });

  it("returns null when child does not navigate and returns no effect", () => {
    const child = makeChildReducer({});
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "no-op" } });
    // No effects pending
  });

  it("merges child effect with nav effect", () => {
    let navCaptured = false;
    const child: Reducer<ChildState, ChildAction, ChildEnv> = (draft, action, env) => {
      if (action.tag === "increment") {
        draft.value = 1;
        env.navigate("dashboard");
        navCaptured = true;
        return Effect.send<ChildAction>({ tag: "no-op" });
      }
      return null;
    };
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } }, (s) => {
      s.child.value = 1;
    });
    expect(navCaptured).toBe(true);
    // Both effects should be pending
    ts.receive({ tag: "child", action: { tag: "no-op" } });
    ts.receive({ tag: "nav", nav: "dashboard" });
  });

  it("captures multiple nav calls", () => {
    const child: Reducer<ChildState, ChildAction, ChildEnv> = (_draft, action, env) => {
      if (action.tag === "increment") {
        env.navigate("objects");
        env.navigate("dashboard");
        return null;
      }
      return null;
    };
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } });
    ts.receive({ tag: "nav", nav: "objects" });
    ts.receive({ tag: "nav", nav: "dashboard" });
  });

  it("returns null for non-matching parent action", () => {
    const child = makeChildReducer({});
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "nav", nav: "something" });
    // No state change, no effects
  });

  it("mutates child state through the lens", () => {
    const child = makeChildReducer({ onIncrement: (s) => { s.value = 42; } });
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } }, (s) => {
      s.child.value = 42;
    });
  });

  it("maps child effect to parent via widen", () => {
    const child = makeChildReducer({
      effect: Effect.send<ChildAction>({ tag: "no-op" }),
    });
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } });
    ts.receive({ tag: "child", action: { tag: "no-op" } });
  });

  it("navigate returns Effect.none — not propagated as child effect", () => {
    const child = makeChildReducer({ navigateView: "search" });
    const reduced = pullbackWithNav(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv, childLens.widenNav,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "navigate-away" } });
    // Only the widenNav effect should be pending
    ts.receive({ tag: "nav", nav: "search" });
  });
});

// ── pullback tests (comparison) ───────────────────────────────────────────────

describe("pullback", () => {
  it("dispatches matching action and mutates state", () => {
    const child = makeChildReducer({ onIncrement: (s) => { s.value = 10; } });
    const reduced = pullback(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } }, (s) => {
      s.child.value = 10;
    });
  });

  it("returns null for non-matching action", () => {
    const child = makeChildReducer({});
    const reduced = pullback(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "nav", nav: "foo" });
  });

  it("maps child effect to parent", () => {
    const child = makeChildReducer({
      effect: Effect.send<ChildAction>({ tag: "no-op" }),
    });
    const reduced = pullback(
      child, childLens.get, childLens.match, childLens.widen,
      childLens.getEnv,
    );
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(reduced, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } });
    ts.receive({ tag: "child", action: { tag: "no-op" } });
  });
});

// ── combine tests ─────────────────────────────────────────────────────────────

describe("combine", () => {
  it("merges effects from multiple reducers", () => {
    const r1: Reducer<ParentState, ParentAction, ChildEnv> = (draft, action) => {
      if (action.tag === "child" && action.action.tag === "increment") {
        draft.child.value = 1;
        return Effect.send<ParentAction>({ tag: "nav", nav: "from-r1" });
      }
      return null;
    };
    const r2: Reducer<ParentState, ParentAction, ChildEnv> = (draft, action) => {
      if (action.tag === "child" && action.action.tag === "increment") {
        draft.child.value = 2;
        return Effect.send<ParentAction>({ tag: "nav", nav: "from-r2" });
      }
      return null;
    };
    const combined = combine(r1, r2);
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(combined, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } }, (s) => {
      // Both reducers ran: r2 ran last, so value = 2
      s.child.value = 2;
    });
    // Both effects should be pending
    ts.receive({ tag: "nav", nav: "from-r1" });
    ts.receive({ tag: "nav", nav: "from-r2" });
  });

  it("returns null when no reducers produce effects", () => {
    const r1: Reducer<ParentState, ParentAction, ChildEnv> = (draft, action) => {
      if (action.tag === "child" && action.action.tag === "increment") {
        draft.child.value = 1;
      }
      return null;
    };
    const r2: Reducer<ParentState, ParentAction, ChildEnv> = () => null;
    const combined = combine(r1, r2);
    const env: ChildEnv = { doWork: () => Effect.none(), navigate: () => Effect.none() };
    const ts = createTestStore(combined, env, initialParent());
    ts.send({ tag: "child", action: { tag: "increment" } }, (s) => {
      s.child.value = 1;
    });
  });
});
