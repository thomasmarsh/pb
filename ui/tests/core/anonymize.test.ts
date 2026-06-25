// tests/core/anonymize.test.ts — Tests for the source-text anonymization utility.

import { describe, it, expect } from "vitest";
import { anonymizeText } from "@pb/platform";

describe("anonymizeText", () => {
  it("preserves identifier length and underscore position", () => {
    const out = anonymizeText("my_table");
    expect(out.length).toBe("my_table".length);
    expect(out[2]).toBe("_");
  });

  it("changes the identifier's letters", () => {
    const out = anonymizeText("customer_balance");
    expect(out).not.toBe("customer_balance");
    expect(out.length).toBe("customer_balance".length);
  });

  it("leaves keywords untouched (case-insensitive)", () => {
    const src = "SELECT cust_name FROM customer WHERE cust_id = 1";
    const out = anonymizeText(src);
    expect(out.startsWith("SELECT ")).toBe(true);
    expect(out).toContain(" FROM ");
    expect(out).toContain(" WHERE ");
  });

  it("leaves punctuation, whitespace, and newlines untouched", () => {
    const src = "if (my_var > 0) then\n\tcall foo()\nend if";
    const out = anonymizeText(src);
    const stripAlnum = (s: string) => s.replace(/[A-Za-z0-9]/g, "#");
    expect(stripAlnum(out)).toBe(stripAlnum(src));
  });

  it("leaves numeric literals untouched", () => {
    const out = anonymizeText("li_count = 12345");
    expect(out).toContain("12345");
  });

  it("maps the same identifier to the same replacement within one call", () => {
    const out = anonymizeText("ls_name + ls_name + ls_name");
    const parts = out.split(" + ");
    expect(parts[0]).toBe(parts[1]);
    expect(parts[1]).toBe(parts[2]);
  });

  it("maps two different identifiers to different replacements", () => {
    const out = anonymizeText("ls_alpha ls_beta");
    const [a, b] = out.split(" ");
    expect(a).not.toBe(b);
  });

  it("does not crash on lex-broken / non-tokenizable fragments", () => {
    const src = "foo()bar() & // @#$% garble \"unterminated";
    expect(() => anonymizeText(src)).not.toThrow();
    const out = anonymizeText(src);
    const stripAlnum = (s: string) => s.replace(/[A-Za-z0-9]/g, "#");
    expect(stripAlnum(out)).toBe(stripAlnum(src));
  });
});
