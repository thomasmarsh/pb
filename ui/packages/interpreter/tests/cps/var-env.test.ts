// tests/core/cps/var-env.test.ts — Unit tests for the three-tier variable environment.

import { describe, it, expect } from "vitest";
import {
  makeVarEnv,
  readVar,
  writeVar,
  declareLocal,
  pushFrame,
  popFrame,
  flattenVarEnv,
} from "../../src/cps/var-env.js";

describe("VarEnv", () => {
  it("readVar resolves local before instance before global for same name", () => {
    const env = makeVarEnv();
    env.globals["x"] = "global";
    env.instance["x"] = "instance";
    env.locals[0]!["x"] = "local";
    expect(readVar(env, "x")).toBe("local");

    delete env.locals[0]!["x"];
    expect(readVar(env, "x")).toBe("instance");

    delete env.instance["x"];
    expect(readVar(env, "x")).toBe("global");
  });

  it("readVar returns undefined for unknown name", () => {
    const env = makeVarEnv();
    expect(readVar(env, "nonexistent")).toBeUndefined();
  });

  it("declareLocal writes to top frame only; outer frames and instance are unchanged", () => {
    const env = makeVarEnv();
    env.locals[0]!["x"] = "outer";
    pushFrame(env);
    declareLocal(env, "x", "inner");
    expect(env.locals[1]!["x"]).toBe("inner");
    expect(env.locals[0]!["x"]).toBe("outer");
    expect(env.instance["x"]).toBeUndefined();
  });

  it("writeVar updates existing local in-place (does not promote to outer frame)", () => {
    const env = makeVarEnv();
    env.locals[0]!["x"] = 1;
    pushFrame(env);
    writeVar(env, "x", 99);
    expect(env.locals[0]!["x"]).toBe(99);
    expect(env.locals[1]!["x"]).toBeUndefined();
  });

  it("writeVar updates instance when name not found in any local frame", () => {
    const env = makeVarEnv();
    env.instance["flag"] = false;
    writeVar(env, "flag", true);
    expect(env.instance["flag"]).toBe(true);
    expect(env.locals[0]!["flag"]).toBeUndefined();
  });

  it("writeVar updates globals when name not found in locals or instance", () => {
    const env = makeVarEnv();
    env.globals["gs_code"] = "0001";
    writeVar(env, "gs_code", "0002");
    expect(env.globals["gs_code"]).toBe("0002");
    expect(env.instance["gs_code"]).toBeUndefined();
    expect(env.locals[0]!["gs_code"]).toBeUndefined();
  });

  it("writeVar writes to locals[top] for a name not found anywhere", () => {
    const env = makeVarEnv();
    writeVar(env, "newVar", 42);
    expect(env.locals[0]!["newVar"]).toBe(42);
    expect(env.instance["newVar"]).toBeUndefined();
    expect(env.globals["newVar"]).toBeUndefined();
  });

  it("pushFrame + declareLocal + popFrame: outer frame is unchanged", () => {
    const env = makeVarEnv();
    declareLocal(env, "i", 10);
    pushFrame(env);
    declareLocal(env, "i", 99);
    expect(readVar(env, "i")).toBe(99);
    popFrame(env);
    expect(readVar(env, "i")).toBe(10);
    expect(env.locals).toHaveLength(1);
  });

  it("flattenVarEnv: innermost local wins; instance wins over global; all keys present", () => {
    const env = makeVarEnv();
    env.globals["a"] = "g_a";
    env.globals["b"] = "g_b";
    env.instance["b"] = "i_b";
    env.instance["c"] = "i_c";
    env.locals[0]!["c"] = "l_c";
    env.locals[0]!["d"] = "l_d";
    pushFrame(env);
    env.locals[1]!["d"] = "l2_d";
    const flat = flattenVarEnv(env);
    expect(flat["a"]).toBe("g_a");
    expect(flat["b"]).toBe("i_b");
    expect(flat["c"]).toBe("l_c");
    expect(flat["d"]).toBe("l2_d");
  });
});
