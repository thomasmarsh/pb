// AST types derived from Haskell JSON serialization (PB.Pipeline.Serialise).
// Uses "tag" as the discriminator, matching the Aeson encoding.

export type Token = string;

// ── Literal ─────────────────────────────────────────────────────────────────

export type Literal =
  | { tag: "bool"; value: boolean }
  | { tag: "int"; value: string }
  | { tag: "real"; value: string }
  | { tag: "string"; value: string }
  | { tag: "date"; value: string }
  | { tag: "time"; value: string }
  | { tag: "null" };

// ── Lvalue ──────────────────────────────────────────────────────────────────

export interface LvSegment {
  name: string;
  subscript: Token[][] | null;
}

export interface Lvalue {
  segments: LvSegment[];
}

// ── Expression ──────────────────────────────────────────────────────────────

export type Expr =
  | Literal
  | { tag: "enum"; name: string }
  | { tag: "lvalue"; segments: LvSegment[] }
  | { tag: "call_expr"; callee: Lvalue; args: Token[][] }
  | { tag: "method_call"; receiver: Expr; method: string; args: Token[][] }
  | {
      tag: "dispatch";
      object: Lvalue | null;
      mode: "post" | "trigger" | "sync";
      dynamic: boolean;
      event: boolean;
      name: string;
      args: Token[][];
    }
  | { tag: "create"; class: string }
  | { tag: "create_using"; expr: Expr }
  | { tag: "array"; items: Expr[] }
  | { tag: "not"; expr: Expr }
  | { tag: "host_var"; lvalue: Lvalue }
  | { tag: "binop"; op: string; lhs: Expr; rhs: Expr }
  | { tag: "neg"; expr: Expr }
  | { tag: "raw"; tokens: Token[] };

// ── Body statements ─────────────────────────────────────────────────────────

export interface ElseIfClause {
  cond: Expr;
  body: BodyStmt[];
}

export interface CaseClause {
  expr: Token[] | null;
  body: BodyStmt[];
}

export type DoCondition =
  | { tag: "while"; expr: Expr }
  | { tag: "until"; expr: Expr };

export type BodyStmt =
  | { tag: "local_var"; tokens: Token[] }
  | { tag: "assign"; lhs: Lvalue; rhs: Expr }
  | { tag: "assign_expr"; lhs: Expr; rhs: Expr }
  | { tag: "aug_assign"; lhs: Token[]; op: string; rhs: Token[] }
  | { tag: "inc"; lhs: Token[] }
  | { tag: "dec"; lhs: Token[] }
  | { tag: "call"; expr: Expr }
  | { tag: "pb_call"; ancestor: string; event: string }
  | { tag: "return"; value?: Expr }
  | {
      tag: "if";
      cond: Expr;
      then: BodyStmt[];
      elseIfs: ElseIfClause[];
      else: BodyStmt[] | null;
    }
  | {
      tag: "for";
      var: Lvalue;
      from: Expr;
      to: Expr;
      step: Expr | null;
      body: BodyStmt[];
    }
  | {
      tag: "do";
      cond: DoCondition | null;
      body: BodyStmt[];
      loop: DoCondition | null;
    }
  | {
      tag: "choose";
      expr: Expr;
      clauses: CaseClause[];
    }
  | { tag: "exit" }
  | { tag: "continue" }
  | { tag: "destroy"; lvalue: Lvalue }
  | { tag: "raw"; text: string };
