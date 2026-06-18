// ast-renderers.ts — Data-driven registry for AST node rendering.
// No JSX — pure functions. AstNode component consumes this.

import type { ChooseStmt } from "../../types/ast.generated.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function isNode(n: unknown): n is Record<string, unknown> {
  return n !== null && typeof n === "object" && !Array.isArray(n);
}

function nodeTag(n: unknown): string | null {
  if (!isNode(n)) return null;
  if ("tag" in n) return String(n.tag);
  if ("segments" in n) return "Lvalue";
  return null;
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "\u2026" : s;
}

function arrJoin(v: unknown): string {
  return Array.isArray(v) ? v.join(" ") : "?";
}

function strOrNull(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

function truncStr(v: unknown, max: number): string {
  if (typeof v === "string") return v.length > max ? v.slice(0, max) + "\u2026" : v;
  return "raw";
}

function renderPbType(t: unknown): string {
  if (!isNode(t)) return "?";
  const tag = t.tag;
  if (tag === "PtAny") return "any";
  if (tag === "PtPrimitive" || tag === "PtUserDefined") {
    return typeof t.contents === "string" ? t.contents : "?";
  }
  if (tag === "PtDecimalPrec") {
    return "decimal{" + String(t.contents) + "}";
  }
  return "?";
}

// ── Lvalue rendering ──────────────────────────────────────────────────────────

function renderLvalue(node: Record<string, unknown>): string {
  const segs = node.segments as { name: string; subscript: unknown }[] | undefined;
  if (!segs || !Array.isArray(segs) || segs.length === 0) return "{...}";
  return segs.map(s => {
    const sub = s.subscript;
    if (sub && Array.isArray(sub) && sub.length > 0) {
      return `${s.name}[${sub.map(String).join(", ")}]`;
    }
    return s.name;
  }).join(".");
}

function getLvalue(n: unknown): string {
  if (!isNode(n)) return "?";
  if ("segments" in n) return renderLvalue(n);
  if (n.tag === "ExLvalue" && isNode(n.contents)) return renderLvalue(n.contents);
  return "?";
}

// ── Expression summary ────────────────────────────────────────────────────────

export function exprSum(node: unknown): string {
  if (node === null || node === undefined) return "null";
  if (typeof node === "string") return truncate(node, 60);
  if (typeof node === "number" || typeof node === "boolean") return String(node);
  if (Array.isArray(node)) return `[${node.length}]`;
  if (!isNode(node)) return "{...}";
  const t = nodeTag(node);
  const r = RENDERERS[t ?? ""];
  return r ? r.summary(node) : t ?? "{...}";
}

// ── Operator maps ─────────────────────────────────────────────────────────────

const BINOP_SYM: Record<string, string> = {
  BopAdd: "+", BopSub: "-", BopMul: "*", BopDiv: "/", BopPow: "^",
  BopEq: "=", BopNe: "<>", BopLt: "<", BopGt: ">", BopLe: "<=", BopGe: ">=",
  BopAnd: "and", BopOr: "or", BopXor: "xor",
};

const AUGOP_SYM: Record<string, string> = {
  AugAdd: "+=", AugSub: "-=", AugMul: "*=", AugDiv: "/=",
};

// ── Renderer types ────────────────────────────────────────────────────────────

export interface AstChild {
  key: string;
  label: string;
  value: unknown;
}

export interface RendererEntry {
  summary: (n: Record<string, unknown>) => string;
  source?: (n: Record<string, unknown>) => string | null;
  children?: (n: Record<string, unknown>) => AstChild[];
  badge?: (n: Record<string, unknown>) => string | null;
}

const SQL_LEADING_RE = /^\s*(SELECT|INSERT|UPDATE|DELETE|DECLARE|OPEN|FETCH|CLOSE|COMMIT|ROLLBACK|EXECUTE|CONNECT|DISCONNECT)\b/i;

// ── Renderer registry ─────────────────────────────────────────────────────────

export const RENDERERS: Record<string, RendererEntry> = {
  // ── Literals ──
  ExInt:    { summary: (n) => String(n.contents ?? "") },
  ExReal:   { summary: (n) => String(n.contents ?? "") },
  ExStr:    { summary: (n) => String(n.contents ?? "") },
  ExBool:   { summary: (n) => String(n.contents ?? "") },
  ExNull:   { summary: () => "null" },
  ExEnum:   { summary: (n) => (n.contents ? String(n.contents) + "!" : "enum") },

  // ── Lvalue ──
  Lvalue:   { summary: (n) => renderLvalue(n) },
  ExLvalue: { summary: (n) => isNode(n.contents) ? renderLvalue(n.contents) : "?" },

  // ── Calls ──
  ExCall: {
    summary: (n) => {
      const name = getLvalue(n.callee);
      const args = n.args as unknown[] | undefined;
      return `${name}(${args ? args.length : 0})`;
    },
  },
  ExMethodCall: {
    summary: (n) => {
      const r = exprSum(n.receiver);
      return `${r}.${n.method}(${Array.isArray(n.args) ? n.args.length : 0})`;
    },
  },
  BsCall: {
    summary: (n) => n.contents ? exprSum(n.contents) : "call",
  },
  BsPbCall: {
    summary: (n) => {
      const c = n.contents;
      if (c && isNode(c)) {
        const ctrl = c.ctrl ? `\`${c.ctrl}` : "";
        return `call ${c.ancestor}${ctrl} :: ${c.event}`;
      }
      return "call ...";
    },
    source: (n) => {
      const c = n.contents;
      if (c && isNode(c)) {
        const ctrl = c.ctrl ? `\`${c.ctrl}` : "";
        return `call ${c.ancestor}${ctrl} :: ${c.event}`;
      }
      return null;
    },
  },

  // ── Binary / unary ops ──
  ExBinOp: {
    summary: (n) => exprSum(n.lhs) + " " + (BINOP_SYM[n.op as string] ?? n.op as string) + " " + exprSum(n.rhs),
  },
  ExNot: { summary: (n) => "not " + exprSum(n.contents) },
  ExNeg: { summary: (n) => "-" + exprSum(n.contents) },

  // ── Other expressions ──
  ExRaw: {
    summary: (n) => truncStr(n.contents, 50),
  },
  ExCreate: { summary: (n) => "create " + (n.contents ?? "") },
  ExArray: {
    summary: (n) => {
      const items = n.contents;
      return Array.isArray(items) ? `{${items.length}}` : "{...}";
    },
  },
  ExHostVar: { summary: (n) => ":" + getLvalue(n.contents) },
  ExDispatch: {
    summary: (n) => {
      const c = n.contents;
      if (c && isNode(c)) {
        const parts: string[] = [];
        if (c.dynamic) parts.push("DYNAMIC");
        if (c.mode === "DmPost") parts.push("POST");
        else if (c.mode === "DmTrigger") parts.push("TRIGGER");
        if (c.event) parts.push("EVENT");
        const obj = c.object && isNode(c.object) ? getLvalue(c.object) + "::" : "";
        return (parts.join(" ") + " " + obj + String(c.name ?? "")).trim();
      }
      return "dispatch";
    },
  },

  // ── DoWhile / DoUntil (inside BsDo) ──
  DoWhile: { summary: (n) => "while " + exprSum(n.contents) },
  DoUntil: { summary: (n) => "until " + exprSum(n.contents) },

  // ── Statements: leaf ──
  BsReturn: { summary: (n) => "return" + (n.contents ? " " + exprSum(n.contents) : "") },
  BsExit: { summary: () => "exit" },
  BsContinue: { summary: () => "continue" },
  BsDestroy: { summary: (n) => "destroy " + exprSum(n.contents) },
  BsLocalVar: {
    summary: (n) => {
      const mods = (n.mods as string[] | undefined) ?? [];
      const prefix = mods.length > 0 ? mods.join(" ") + " " : "";
      const init = n.init ? " = " + exprSum(n.init) : "";
      return prefix + renderPbType(n.type) + " " + String(n.name ?? "") + init;
    },
    source: (n) => {
      const mods = (n.mods as string[] | undefined) ?? [];
      const prefix = mods.length > 0 ? mods.join(" ") + " " : "";
      const init = n.init ? " = " + exprSum(n.init) : "";
      return prefix + renderPbType(n.type) + " " + String(n.name ?? "") + init;
    },
  },
  BsRaw: {
    summary: (n) => truncStr(n.contents, 60),
    source: (n) => strOrNull(n.contents),
    badge: (n) => {
      const text = typeof n.contents === "string" ? n.contents : null;
      return text && SQL_LEADING_RE.test(text) ? "SQL" : null;
    },
  },
  BsInc: {
    summary: (n) => arrJoin(n.contents) + "++",
    source: (n) => arrJoin(n.contents) + "++",
  },
  BsDec: {
    summary: (n) => arrJoin(n.contents) + "--",
    source: (n) => arrJoin(n.contents) + "--",
  },

  // ── Statements: compound (expandable) ──
  BsAssign: {
    summary: (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 2) return getLvalue(c[0]) + " = " + exprSum(c[1]);
      return "assign";
    },
  },
  BsAssignExpr: {
    summary: (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 2) return exprSum(c[0]) + " = " + exprSum(c[1]);
      return "assign";
    },
  },
  BsAugAssign: {
    summary: (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 3) {
        const lhs = Array.isArray(c[0]) ? c[0].join(" ") : "?";
        return lhs + " " + (AUGOP_SYM[c[1] as string] ?? c[1] as string) + " ...";
      }
      return "augassign";
    },
  },
  BsIf: {
    summary: (n) => {
      const c = n.contents;
      if (c && isNode(c)) return "if " + exprSum(c.cond) + " then";
      return "if ...";
    },
    children: (n) => {
      const c = n.contents;
      if (!c || !isNode(c)) return [];
      const kids: AstChild[] = [];
      if (Array.isArray(c.then) && c.then.length > 0) kids.push({ key: "then", label: "then", value: c.then });
      if (Array.isArray(c.elseIfs)) {
        for (let i = 0; i < c.elseIfs.length; i++) {
          const eif = c.elseIfs[i] as Record<string, unknown>;
          if (eif && isNode(eif)) {
            kids.push({ key: `elseif_${i}`, label: "elseif", value: eif });
          }
        }
      }
      if (Array.isArray(c.else) && c.else.length > 0) kids.push({ key: "else", label: "else", value: c.else });
      return kids;
    },
  },
  BsFor: {
    summary: (n) => {
      const c = n.contents;
      if (c && isNode(c)) {
        return "for " + getLvalue(c.var) + " = " + exprSum(c.from) + " to " + exprSum(c.to) +
          (c.step ? " step " + exprSum(c.step) : "");
      }
      return "for ...";
    },
    children: (n) => {
      const c = n.contents;
      if (!c || !isNode(c)) return [];
      const kids: AstChild[] = [];
      if (Array.isArray(c.body) && c.body.length > 0) kids.push({ key: "body", label: "body", value: c.body });
      return kids;
    },
  },
  BsDo: {
    summary: (n) => {
      const c = n.contents;
      if (c && isNode(c) && c.cond) {
        const cond = c.cond as Record<string, unknown>;
        const kind = cond.tag === "DoWhile" ? "while" : "until";
        return "do " + kind + " " + exprSum(cond.contents);
      }
      return "do ... loop";
    },
    children: (n) => {
      const c = n.contents;
      if (!c || !isNode(c)) return [];
      const kids: AstChild[] = [];
      if (Array.isArray(c.body) && c.body.length > 0) kids.push({ key: "body", label: "body", value: c.body });
      return kids;
    },
  },
  BsChoose: {
    summary: (n) => {
      const c = n.contents as ChooseStmt | undefined;
      return "choose case " + (c ? exprSum(c.expr) : "...");
    },
    children: (n) => {
      const c = n.contents as ChooseStmt | undefined;
      if (!c || !Array.isArray(c.clauses)) return [];
      return c.clauses.map((clause: { expr?: unknown; body?: unknown }, i: number) => {
        const label = clause.expr != null ? `case ${exprSum(clause.expr)}` : "case else";
        return { key: `clause_${i}`, label, value: clause.body ?? [] };
      });
    },
  },
};

// ── Resolver ──────────────────────────────────────────────────────────────────

const FALLBACK: RendererEntry = {
  summary: (_n) => "{...}",
};

export function resolveRenderer(_node: Record<string, unknown>, tag: string): RendererEntry {
  return RENDERERS[tag] ?? FALLBACK;
}
