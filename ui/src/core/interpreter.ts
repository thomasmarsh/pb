// interpreter.ts — Minimal PB AST interpreter (spike).
// TD-4: walkNode uses untyped AST nodes; typed coverage expanded in 101b.
// TD-5: trn()/tr() return ID string; real impl needs translation table lookup.
// TD-7: executeEvent does O(n) scan over events; index in 101b.

export interface AstData {
  typeBlocks: unknown[];
  events: { name: string; owner: string; body: unknown[] }[];
}

export interface InterpreterState {
  variables: Record<string, unknown>;
  controlValues: Record<string, unknown>;
}

export class PBInterpreter {
  private _variables = new Map<string, unknown>();
  private _controlValues = new Map<string, unknown>();
  ast: AstData | null = null;

  setAst(ast: AstData): void {
    this.ast = ast;
  }

  async loadAst(objectName: string): Promise<void> {
    const r = await fetch(`/api/objects/${encodeURIComponent(objectName)}/ast`);
    if (!r.ok) throw new Error(`AST fetch failed: ${r.status}`);
    this.ast = (await r.json()) as AstData;
  }

  async executeEvent(owner: string, event: string): Promise<void> {
    const handler = this.ast?.events.find(
      (e) => e.name === event && e.owner === owner,
    );
    if (handler) await this._walkStatements(handler.body);
  }

  getState(): InterpreterState {
    return {
      variables: Object.fromEntries(this._variables),
      controlValues: Object.fromEntries(this._controlValues),
    };
  }

  private async _walkStatements(stmts: unknown[]): Promise<void> {
    for (const stmt of stmts as { node: unknown }[]) {
      await this._walkNode(stmt?.node);
    }
  }

  private async _walkNode(node: unknown): Promise<unknown> {
    if (!node || typeof node !== "object") return undefined;
    const n = node as Record<string, unknown>;

    switch (n["tag"]) {
      case "BsAssign":  return this._execAssign(n);
      case "BsIf":      return this._execIf(n);
      case "BsCall":    return this._execCall(n);
      case "BsReturn":  return this._evalExpr(n["expr"]);
      case "BsRaw":     return undefined; // SQL / unclassified — skip
      default:          return undefined;
    }
  }

  private _execAssign(n: Record<string, unknown>): void {
    const lhs = n["lhs"] as Record<string, unknown> | undefined;
    const segments = lhs?.["segments"] as { name: string }[] | undefined;
    const varName = segments?.[0]?.name;
    if (varName) this._variables.set(varName, this._evalExpr(n["rhs"]));
  }

  private async _execIf(n: Record<string, unknown>): Promise<void> {
    const cond = this._evalExpr(n["cond"]);
    if (cond) {
      await this._walkStatements((n["then"] as unknown[]) ?? []);
      return;
    }
    const elseIfs = (n["elseIfs"] as [unknown, unknown[]][]) ?? [];
    for (const [expr, body] of elseIfs) {
      if (this._evalExpr(expr)) {
        await this._walkStatements(body ?? []);
        return;
      }
    }
    if (n["else"]) await this._walkStatements(n["else"] as unknown[]);
  }

  private async _execCall(n: Record<string, unknown>): Promise<unknown> {
    const callee = n["callee"] as Record<string, unknown> | undefined;
    const segments = callee?.["segments"] as { name: string }[] | undefined;
    const name = segments?.map((s) => s.name).join(".") ?? "";

    // TD-5: translation stub — returns ID string
    if (name === "trn" || name === "tr") {
      const args = n["args"] as unknown[][] | undefined;
      return String(args?.[0]?.[0] ?? "");
    }
    if (name === "MessageBox") return undefined; // no-op in interpreter
    return undefined;
  }

  private _evalExpr(expr: unknown): unknown {
    if (!expr || typeof expr !== "object") return undefined;
    const e = expr as Record<string, unknown>;

    switch (e["tag"]) {
      case "ExLit": {
        const lit = e["contents"] as Record<string, unknown> | undefined;
        if (!lit) return undefined;
        switch (lit["tag"]) {
          case "LitBool": return lit["contents"] === true || lit["contents"] === "true";
          case "LitInt":  return parseInt(lit["contents"] as string, 10);
          case "LitReal": return parseFloat(lit["contents"] as string);
          case "LitStr":  return String(lit["contents"]).replace(/^"|"$/g, "");
          case "LitNull": return null;
          default:        return lit["contents"];
        }
      }
      case "ExStr":   return String(e["contents"]).replace(/^"|"$/g, "");
      case "ExInt":   return parseInt(e["contents"] as string, 10);
      case "ExLvalue": {
        const segs = e["segments"] as { name: string }[] | undefined;
        const name = segs?.[0]?.name;
        return name ? this._variables.get(name) : undefined;
      }
      default: return undefined;
    }
  }
}
