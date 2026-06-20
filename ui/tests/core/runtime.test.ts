// tests/core/runtime.test.ts — Unit tests for PB_BUILTINS.

import { describe, it, expect } from "vitest";
import { PB_BUILTINS } from "../../src/core/runtime.js";

// Helper: call a builtin and assert it exists first
function callBuiltin(name: string, ...args: unknown[]): unknown {
  const fn = PB_BUILTINS[name];
  expect(fn).toBeDefined();
  return fn!(...args);
}

describe("PB_BUILTINS", () => {
  describe("string functions", () => {
    it("mid(str, start, len) extracts substring with 1-based indexing", () => {
      expect(callBuiltin("mid", "hello", 2, 3)).toBe("ell");
    });

    it("mid(str, start) extracts from start to end", () => {
      expect(callBuiltin("mid", "hello", 3)).toBe("llo");
    });

    it("left(str, n) returns first n characters", () => {
      expect(callBuiltin("left", "hello", 3)).toBe("hel");
    });

    it("right(str, n) returns last n characters", () => {
      expect(callBuiltin("right", "hello", 3)).toBe("llo");
    });

    it("len(str) returns character count", () => {
      expect(callBuiltin("len", "hello")).toBe(5);
      expect(callBuiltin("len", "")).toBe(0);
    });

    it("pos(str, search) returns 1-based index (0 if not found)", () => {
      expect(callBuiltin("pos", "hello", "ell")).toBe(2);
      expect(callBuiltin("pos", "hello", "xyz")).toBe(0);
    });

    it("trim(str) strips whitespace", () => {
      expect(callBuiltin("trim", "  hello  ")).toBe("hello");
    });

    it("upper(str) converts to uppercase", () => {
      expect(callBuiltin("upper", "hello")).toBe("HELLO");
    });

    it("lower(str) converts to lowercase", () => {
      expect(callBuiltin("lower", "HELLO")).toBe("hello");
    });

    it("reverse(str) reverses string", () => {
      expect(callBuiltin("reverse", "abc")).toBe("cba");
    });

    it("replace(str, from, to) replaces all occurrences", () => {
      expect(callBuiltin("replace", "a-b-c", "-", "+")).toBe("a+b+c");
    });

    it("space(n) returns n spaces", () => {
      expect(callBuiltin("space", 3)).toBe("   ");
    });

    it("fill(n, ch) repeats character n times", () => {
      expect(callBuiltin("fill", 4, "*")).toBe("****");
    });
  });

  describe("type conversions", () => {
    it("string(val) converts to string", () => {
      expect(callBuiltin("string", 42)).toBe("42");
      expect(callBuiltin("string", true)).toBe("true");
    });

    it("integer(val) truncates to int", () => {
      expect(callBuiltin("integer", "3.9")).toBe(3);
      expect(callBuiltin("integer", "abc")).toBe(0);
    });

    it("long(val) truncates to int", () => {
      expect(callBuiltin("long", "42.7")).toBe(42);
    });

    it("real(val) parses float", () => {
      expect(callBuiltin("real", "3.14")).toBe(3.14);
      expect(callBuiltin("real", "abc")).toBe(0);
    });

    it("char(code) returns character from code point", () => {
      expect(callBuiltin("char", 65)).toBe("A");
    });
  });

  describe("null / type checks", () => {
    it("isnull(val) returns true for null/undefined", () => {
      expect(callBuiltin("isnull", null)).toBe(true);
      expect(callBuiltin("isnull", undefined)).toBe(true);
      expect(callBuiltin("isnull", 0)).toBe(false);
      expect(callBuiltin("isnull", "")).toBe(false);
    });

    it("isnumber(val) returns true for numeric strings", () => {
      expect(callBuiltin("isnumber", "42")).toBe(true);
      expect(callBuiltin("isnumber", "3.14")).toBe(true);
      expect(callBuiltin("isnumber", "abc")).toBe(false);
      expect(callBuiltin("isnumber", null)).toBe(false);
    });
  });

  describe("numeric", () => {
    it("abs(val) returns absolute value", () => {
      expect(callBuiltin("abs", -5)).toBe(5);
      expect(callBuiltin("abs", 5)).toBe(5);
    });

    it("mod(a, b) returns remainder", () => {
      expect(callBuiltin("mod", 7, 3)).toBe(1);
    });

    it("max(a, b) returns maximum", () => {
      expect(callBuiltin("max", 3, 7)).toBe(7);
    });

    it("min(a, b) returns minimum", () => {
      expect(callBuiltin("min", 3, 7)).toBe(3);
    });

    it("round(val, dec) rounds to decimal places", () => {
      expect(callBuiltin("round", 3.14159, 2)).toBe(3.14);
    });

    it("ceiling(val) rounds up", () => {
      expect(callBuiltin("ceiling", 3.1)).toBe(4);
    });

    it("floor(val) rounds down", () => {
      expect(callBuiltin("floor", 3.9)).toBe(3);
    });

    it("sign(val) returns -1, 0, or 1", () => {
      expect(callBuiltin("sign", -5)).toBe(-1);
      expect(callBuiltin("sign", 0)).toBe(0);
      expect(callBuiltin("sign", 5)).toBe(1);
    });
  });

  describe("color", () => {
    it("rgb(r, g, b) returns 24-bit color number", () => {
      expect(callBuiltin("rgb", 255, 0, 0)).toBe(0xFF0000);
      expect(callBuiltin("rgb", 0, 255, 0)).toBe(0x00FF00);
      expect(callBuiltin("rgb", 0, 0, 255)).toBe(0x0000FF);
    });
  });

  describe("translation stubs", () => {
    it("trn(id) returns bracketed ID", () => {
      expect(callBuiltin("trn", 42)).toBe("[42]");
    });

    it("tr(id) returns bracketed ID", () => {
      expect(callBuiltin("tr", 42)).toBe("[42]");
    });
  });
});
