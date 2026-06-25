// interpreter.ts — PB AST type exports shared across the runtime and UI.

import type { BodyStmt, Located } from "./types/ast.js";

export interface DWRow {
  [column: string]: unknown;
}

export type ProcEntry = { name: string; owner: string; cpsGraph?: unknown };

export interface GlobalVarDecl {
  name: string;
  type: string;
  modifiers?: string;
  scope: string;
}

export interface AstData {
  typeBlocks: { decl: { ancestor: string; name: string; within: string | null }; body: Located<BodyStmt>[] }[];
  events: ProcEntry[];
  functions?: ProcEntry[];
  variables?: GlobalVarDecl[];
  ancestorName?: string;
  ancestorEvents?: ProcEntry[];
  ancestorFunctions?: ProcEntry[];
}
