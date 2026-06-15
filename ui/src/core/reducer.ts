// core/reducer.ts — TCA-style reducer composition with valtio drafts.
//
// pullback() scopes a child Reducer to a parent state via lens mutation.
// combine() runs all reducers in sequence over the same proxy.

import { Effect } from "./effect.js";

export type Reducer<S, A, Env> = (
  draft: S,
  action: A,
  env: Env,
) => Effect<A> | null;

export function pullback<S, A, PS, PA, FEnv, PEnv>(
  child: Reducer<S, A, FEnv>,
  get: (parent: PS) => S,
  match: (action: PA) => A | null,
  widen: (a: A) => PA,
  getEnv: (env: PEnv) => FEnv,
): Reducer<PS, PA, PEnv> {
  return (draft, action, env) => {
    const local = match(action);
    if (!local) return null;
    const eff = child(get(draft), local, getEnv(env));
    return eff ? eff.map(widen) : null;
  };
}

export function combine<S, A, Env>(
  ...reducers: Reducer<S, A, Env>[]
): Reducer<S, A, Env> {
  return (draft, action, env) => {
    const effs: Effect<A>[] = [];
    for (const r of reducers) {
      const eff = r(draft, action, env);
      if (eff) effs.push(eff);
    }
    return effs.length > 0 ? Effect.merge(...effs) : null;
  };
}
