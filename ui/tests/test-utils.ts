// test-utils.ts — Shared test helpers for core tests.
//
// Usage:
//   const ts = createTestStore({ ...defaultMockEnv, getStats: () => Effect.send(mockStats) });
//   await ts.send({ type: "STATS_LOAD" });
//   ts.receive({ type: "STATS_LOADED", stats: mockStats }).assertDrained();

import { afterEach, expect } from "vitest";
import { Effect, initialState, reducer } from "../src/core.js";
import type { Env } from "../src/core.js";
import type { AppState } from "../src/types/state.js";
import type { AppAction } from "../src/types/actions.js";

export { Effect };

export const defaultMockEnv: Env = {
  getStats:             () => Effect.none(),
  getObjects:           () => Effect.none(),
  getObject:            () => Effect.none(),
  getObjectSource:      () => Effect.none(),
  getAllObjects:         () => Effect.none(),
  getProcedure:         () => Effect.none(),
  search:               () => Effect.none(),
  getDW:                () => Effect.none(),
  getDiagram:           () => Effect.none(),
  getQueries:           () => Effect.none(),
  runQuery:             () => Effect.none(),
  getExploreTree:       () => Effect.none(),
  getExploreProcedure:  () => Effect.none(),
  getExploreDatawindow: () => Effect.none(),
};

export class TestStore {
  private state: AppState;
  private pending: AppAction[] = [];

  constructor(private readonly env: Env, state = initialState()) {
    this.state = state;
  }

  async send(action: AppAction): Promise<this> {
    const [next, effect] = reducer(this.state, action, this.env);
    this.state = next;
    if (effect) await effect.execute(a => this.pending.push(a));
    return this;
  }

  receive(expected: AppAction): this {
    if (this.pending.length === 0) {
      throw new Error(`Expected to receive ${JSON.stringify(expected)}, but no effects were dispatched`);
    }
    const actual = this.pending.shift()!;
    expect(actual).toEqual(expected);
    return this;
  }

  getState(): AppState { return this.state; }

  assertDrained(): this {
    if (this.pending.length > 0) {
      throw new Error(`TestStore has ${this.pending.length} unhandled action(s): ${JSON.stringify(this.pending)}`);
    }
    return this;
  }
}

export function createTestStore(env: Partial<Env> = {}, state = initialState()): TestStore {
  const store = new TestStore({ ...defaultMockEnv, ...env }, state);
  afterEach(() => { store.assertDrained(); });
  return store;
}
