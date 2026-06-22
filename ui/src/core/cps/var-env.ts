// core/cps/var-env.ts — Three-tier variable environment for the PB runtime.

export interface VarEnv {
  globals:  Record<string, unknown>;
  instance: Record<string, unknown>;
  locals:   Record<string, unknown>[];  // always non-empty; index [length-1] is top
}

export function makeVarEnv(): VarEnv {
  return { globals: {}, instance: {}, locals: [{}] };
}

export function readVar(env: VarEnv, name: string): unknown {
  for (let i = env.locals.length - 1; i >= 0; i--) {
    if (Object.prototype.hasOwnProperty.call(env.locals[i], name)) {
      return env.locals[i]![name];
    }
  }
  if (Object.prototype.hasOwnProperty.call(env.instance, name)) return env.instance[name];
  return env.globals[name];
}

export function writeVar(env: VarEnv, name: string, value: unknown): void {
  for (let i = env.locals.length - 1; i >= 0; i--) {
    if (Object.prototype.hasOwnProperty.call(env.locals[i], name)) {
      env.locals[i]![name] = value;
      return;
    }
  }
  if (Object.prototype.hasOwnProperty.call(env.instance, name)) {
    env.instance[name] = value;
    return;
  }
  if (Object.prototype.hasOwnProperty.call(env.globals, name)) {
    env.globals[name] = value;
    return;
  }
  env.locals[env.locals.length - 1]![name] = value;
}

export function declareLocal(env: VarEnv, name: string, value: unknown): void {
  env.locals[env.locals.length - 1]![name] = value;
}

export function pushFrame(env: VarEnv): void {
  env.locals.push({});
}

export function popFrame(env: VarEnv): void {
  if (env.locals.length > 1) env.locals.pop();
}

export function flattenVarEnv(env: VarEnv): Record<string, unknown> {
  let result: Record<string, unknown> = { ...env.globals, ...env.instance };
  for (const frame of env.locals) {
    result = { ...result, ...frame };
  }
  return result;
}
