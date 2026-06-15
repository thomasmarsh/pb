// Explore.tsx — Interactive AST tree explorer.

import { Show, For, onMount, createMemo, createEffect, createSignal, type JSX } from "solid-js";
import { useStore } from "../context.js";
import { highlightPowerScript } from "../highlight.js";
import type { ExploreLibrary, ExploreObject, ExploreProcedure, DwExploreDetail, ExploreProcDetail } from "../types/api.js";
import type { BodyStmt, ChooseStmt } from "../types/ast.generated.js";

// ── Node IDs ──────────────────────────────────────────────────────────────────

function libId(name: string): string { return `lib:${name}`; }
function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }
function dwId(name: string): string { return `dw:${name}`; }

// ── Helpers ───────────────────────────────────────────────────────────────────

const KIND_BADGES: Record<string, string> = {
  powerscript: "badge-ps", datawindow: "badge-dw", project: "badge-proj",
};
const PROC_BADGES: Record<string, string> = {
  function: "badge-func", subroutine: "badge-sub", event: "badge-event", on: "badge-on",
};

function kindBadge(kind: string): string { return KIND_BADGES[kind] ?? "badge-proj"; }
function procBadge(t: string): string { return PROC_BADGES[t] ?? "badge-func"; }
function chevron(expanded: boolean): string { return expanded ? "▾" : "▸"; }

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "…" : s;
}

function isNode(n: unknown): n is Record<string, unknown> {
  return n !== null && typeof n === "object" && !Array.isArray(n);
}

function isLocated(v: unknown): v is { line: number; node: unknown } {
  return isNode(v) && typeof v.line === "number" && "node" in v;
}

function nodeTag(n: unknown): string | null {
  if (!isNode(n)) return null;
  if ("tag" in n) return String(n.tag);
  if ("segments" in n) return "Lvalue";
  return null;
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

function unwrapContent(node: Record<string, unknown>): unknown {
  return node.contents;
}

// ── Node Renderer registry ────────────────────────────────────────────────────

interface AstChild {
  key: string;
  label: string;
  value: unknown;
}

interface NodeRenderer {
  summary(node: Record<string, unknown>, tag: string): string;
  source?(node: Record<string, unknown>, tag: string): string | null;
  children(node: Record<string, unknown>, tag: string): AstChild[];
}

function exprSum(node: unknown): string {
  if (node === null || node === undefined) return "null";
  if (typeof node === "string") return truncate(node, 60);
  if (typeof node === "number" || typeof node === "boolean") return String(node);
  if (Array.isArray(node)) return `[${node.length}]`;
  if (!isNode(node)) return "{...}";
  const t = nodeTag(node);
  const r = RENDERERS[t ?? ""];
  return r ? r.summary(node, t!) : t ?? "{...}";
}

const BINOP_SYM: Record<string, string> = {
  BopAdd: "+", BopSub: "-", BopMul: "*", BopDiv: "/", BopPow: "^",
  BopEq: "=", BopNe: "<>", BopLt: "<", BopGt: ">", BopLe: "<=", BopGe: ">=",
  BopAnd: "and", BopOr: "or", BopXor: "xor",
};
const AUGOP_SYM: Record<string, string> = {
  AugAdd: "+=", AugSub: "-=", AugMul: "*=", AugDiv: "/=",
};

function leaf(summary: string, source?: string | null): NodeRenderer {
  return {
    summary: () => summary,
    source: source !== undefined ? () => source : undefined,
    children: () => [],
  };
}

function leafFromTag(summaryFn: (n: Record<string, unknown>, tag: string) => string): NodeRenderer {
  return { summary: summaryFn, children: () => [] };
}

function leafFromContent(summaryFn: (c: unknown) => string): NodeRenderer {
  return {
    summary: (n) => summaryFn(unwrapContent(n)),
    children: () => [],
  };
}

function compound(
  summaryFn: (n: Record<string, unknown>) => string,
  childrenFn: (n: Record<string, unknown>) => AstChild[],
  sourceFn?: (n: Record<string, unknown>) => string | null,
): NodeRenderer {
  return {
    summary: summaryFn,
    source: sourceFn,
    children: childrenFn,
  };
}

const RENDERERS: Record<string, NodeRenderer> = {
  // ── Expressions (leaf) ──
  Lvalue: leafFromTag((_n, _t) => renderLvalue(_n)),
  ExLvalue: leafFromTag((n) => {
    const c = n.contents;
    return c && isNode(c) ? renderLvalue(c) : "ExLvalue";
  }),
  ExCall: leafFromTag((n) => {
    const name = getLvalue(n.callee);
    const args = n.args as unknown[] | undefined;
    return `${name}(${args ? args.length : 0})`;
  }),
  ExMethodCall: leafFromTag((n) => {
    const r = exprSum(n.receiver);
    return `${r}.${n.method}(${Array.isArray(n.args) ? n.args.length : 0})`;
  }),
  ExBinOp: leafFromTag((n) => {
    return exprSum(n.lhs) + " " + (BINOP_SYM[n.op as string] ?? n.op as string) + " " + exprSum(n.rhs);
  }),
  ExInt: leafFromTag((n) => n.contents != null ? String(n.contents) : "ExInt"),
  ExReal: leafFromTag((n) => n.contents != null ? String(n.contents) : "ExReal"),
  ExStr: leafFromTag((n) => n.contents != null ? String(n.contents) : "ExStr"),
  ExBool: leafFromTag((n) => n.contents != null ? String(n.contents) : "ExBool"),
  ExNull: leaf("null"),
  ExEnum: leafFromTag((n) => n.contents ? String(n.contents) + "!" : "enum"),
  ExNot: leafFromTag((n) => "not " + exprSum(n.contents)),
  ExNeg: leafFromTag((n) => "-" + exprSum(n.contents)),
  ExRaw: leafFromTag((n) => {
    const c = n.contents;
    if (Array.isArray(c)) return truncate(c.join(" "), 50);
    return typeof c === "string" ? truncate(c, 50) : "raw";
  }),
  ExCreate: leafFromTag((n) => "create " + (n.contents ?? "")),
  ExArray: leafFromTag((n) => {
    const items = n.contents;
    return Array.isArray(items) ? `{${items.length}}` : "{...}";
  }),
  ExHostVar: leafFromTag((n) => ":" + getLvalue(n.contents)),
  ExDispatch: leafFromTag((n) => {
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
  }),

  // ── DoWhile / DoUntil (leaf, shown inside BsDo) ──
  DoWhile: leafFromContent((c) => "while " + exprSum(c)),
  DoUntil: leafFromContent((c) => "until " + exprSum(c)),

  // ── Statements (leaf) ──
  BsLocalVar: {
    summary: (n) => {
      const toks = n.contents;
      return Array.isArray(toks) ? toks.join(" ") : "var";
    },
    source: (n) => {
      const toks = n.contents;
      return Array.isArray(toks) ? toks.join(" ") : null;
    },
    children: () => [],
  },
  BsRaw: {
    summary: (n) => {
      const c = n.contents;
      if (typeof c === "string") return truncate(c, 60);
      return "raw";
    },
    source: (n) => {
      const c = n.contents;
      return typeof c === "string" ? c : null;
    },
    children: () => [],
  },
  BsInc: {
    summary: (n) => {
      const toks = n.contents;
      return (Array.isArray(toks) ? toks.join(" ") : "?") + "++";
    },
    source: (n) => {
      const toks = n.contents;
      return Array.isArray(toks) ? toks.join(" ") + "++" : null;
    },
    children: () => [],
  },
  BsDec: {
    summary: (n) => {
      const toks = n.contents;
      return (Array.isArray(toks) ? toks.join(" ") : "?") + "--";
    },
    source: (n) => {
      const toks = n.contents;
      return Array.isArray(toks) ? toks.join(" ") + "--" : null;
    },
    children: () => [],
  },
  BsExit: leaf("exit", "exit"),
  BsContinue: leaf("continue", "continue"),
  BsDestroy: leafFromTag((n) => "destroy " + exprSum(n.contents)),
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
    children: () => [],
  },
  BsCall: leafFromTag((n) => n.contents ? exprSum(n.contents) : "call"),
  BsReturn: leafFromTag((n) => "return" + (n.contents ? " " + exprSum(n.contents) : "")),

  // ── Statements (compound) ──
  BsAssign: leafFromTag((n) => {
    const c = n.contents;
    if (Array.isArray(c) && c.length === 2) return getLvalue(c[0]) + " = " + exprSum(c[1]);
    return "assign";
  }),
  BsAssignExpr: leafFromTag((n) => {
    const c = n.contents;
    if (Array.isArray(c) && c.length === 2) return exprSum(c[0]) + " = " + exprSum(c[1]);
    return "assign";
  }),
  BsAugAssign: leafFromTag((n) => {
    const c = n.contents;
    if (Array.isArray(c) && c.length === 3) {
      const lhs = Array.isArray(c[0]) ? c[0].join(" ") : "?";
      return lhs + " " + (AUGOP_SYM[c[1] as string] ?? c[1] as string) + " ...";
    }
    return "augassign";
  }),
  BsIf: compound(
    (n) => {
      const c = n.contents;
      if (c && isNode(c)) return "if " + exprSum(c.cond) + " then";
      return "if ...";
    },
    (n) => {
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
  ),
  BsFor: compound(
    (n) => {
      const c = n.contents;
      if (c && isNode(c)) {
        return "for " + getLvalue(c.var) + " = " + exprSum(c.from) + " to " + exprSum(c.to) +
          (c.step ? " step " + exprSum(c.step) : "");
      }
      return "for ...";
    },
    (n) => {
      const c = n.contents;
      if (!c || !isNode(c)) return [];
      const kids: AstChild[] = [];
      if (Array.isArray(c.body) && c.body.length > 0) kids.push({ key: "body", label: "body", value: c.body });
      return kids;
    },
  ),
  BsDo: compound(
    (n) => {
      const c = n.contents;
      if (c && isNode(c) && c.cond) {
        const cond = c.cond as Record<string, unknown>;
        const kind = cond.tag === "DoWhile" ? "while" : "until";
        return "do " + kind + " " + exprSum(cond.contents);
      }
      return "do ... loop";
    },
    (n) => {
      const c = n.contents;
      if (!c || !isNode(c)) return [];
      const kids: AstChild[] = [];
      if (Array.isArray(c.body) && c.body.length > 0) kids.push({ key: "body", label: "body", value: c.body });
      return kids;
    },
  ),
  BsChoose: compound(
    (n) => {
      const c = n.contents as ChooseStmt | undefined;
      return "choose case " + (c ? exprSum(c.expr) : "...");
    },
    (n) => {
      const c = n.contents as ChooseStmt | undefined;
      if (!c || !Array.isArray(c.clauses)) return [];
      return c.clauses.map((clause: { expr?: unknown; body?: unknown }, i: number) => {
        const label = clause.expr != null ? `case ${exprSum(clause.expr)}` : "case else";
        return { key: `clause_${i}`, label, value: clause.body ?? [] };
      });
    },
  ),
};

const FALLBACK: NodeRenderer = {
  summary: (_n, tag) => tag ?? "{...}",
  children: () => [],
};

function resolveRenderer(_node: Record<string, unknown>, tag: string): NodeRenderer {
  return RENDERERS[tag] ?? FALLBACK;
}

// ── AST Node Renderer ─────────────────────────────────────────────────────────
// Exported so it can be used by EX-2's AST tab without triggering noUnusedLocals.

export function AstNode(props: {
  node: BodyStmt | BodyStmt[] | unknown;
  nodeId: string;
  depth: number;
}): JSX.Element {
  const store = useStore();
  const isExpanded = () => store.state.explore.expandedNodes.has(props.nodeId);

  const tag = createMemo(() => nodeTag(props.node));

  const renderer = createMemo(() => {
    if (Array.isArray(props.node) || !isNode(props.node)) return null;
    return resolveRenderer(props.node, tag()!);
  });

  const summaryText = createMemo(() => {
    if (Array.isArray(props.node)) return "";
    if (!isNode(props.node)) return exprSum(props.node);
    return renderer()!.summary(props.node, tag()!);
  });

  const children = createMemo(() => {
    if (Array.isArray(props.node)) return [];
    if (!isNode(props.node)) return [];
    return renderer()!.children(props.node, tag()!);
  });
  const hasChildren = () => children().length > 0;

  const highlightedHtml = createMemo(() => {
    if (Array.isArray(props.node) || !isNode(props.node)) return null;
    const r = renderer();
    if (r?.source) {
      const src = r.source(props.node, tag()!);
      if (src) return highlightPowerScript(src);
    }
    return null;
  });

  function toggle() {
    if (hasChildren()) {
      store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: props.nodeId });
    }
  }

  if (Array.isArray(props.node)) {
    return (
      <div class="ast-body">
        <For each={props.node as unknown[]}>
          {(item, i) => {
            if (isLocated(item)) {
              const lineNum = item.line;
              return (
                <div class="ast-located-row" onClick={() => {
                  store.dispatch({ type: "EXPLORE_HIGHLIGHT_LINE", line: lineNum });
                  store.dispatch({ type: "EXPLORE_TAB", tab: "source" });
                }}>
                  <AstNode node={item.node} nodeId={`${props.nodeId}.${i()}`} depth={props.depth} />
                </div>
              );
            }
            return <AstNode node={item} nodeId={`${props.nodeId}.${i()}`} depth={props.depth} />;
          }}
        </For>
      </div>
    );
  }

  if (!hasChildren()) {
    return (
      <div class="ast-leaf" style={{ "margin-left": `${props.depth * 18}px` }}>
        <Show
          when={highlightedHtml()}
          fallback={<span class="ast-leaf-text">{summaryText()}</span>}
        >
          <span class="ast-leaf-text ast-highlighted" innerHTML={highlightedHtml()!} />
        </Show>
      </div>
    );
  }

  return (
    <div class="ast-branch" style={{ "margin-left": `${props.depth * 18}px` }}>
      <div class="ast-branch-header clickable" onClick={toggle}>
        <span class="ast-chevron">{chevron(isExpanded())}</span>
        <Show
          when={highlightedHtml()}
          fallback={<span class="ast-branch-text">{summaryText()}</span>}
        >
          <span class="ast-branch-text ast-highlighted" innerHTML={highlightedHtml()!} />
        </Show>
      </div>
      <Show when={isExpanded()}>
        <div class="ast-branch-children">
          <For each={children()}>
            {(child) => (
              <AstNode node={child.value} nodeId={`${props.nodeId}.${child.key}`} depth={props.depth + 1} />
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}

// ── Procedure Tree Node ───────────────────────────────────────────────────────

function ProcNode(props: { objName: string; proc: ExploreProcedure; depth: number }): JSX.Element {
  const store = useStore();
  const nodeId = () => procId(props.objName, props.proc.name);
  const isSelected = () => store.state.explore.selectedProc === nodeId();

  function select() {
    store.dispatch({
      type: "EXPLORE_PROC_SELECT",
      objectName: props.objName,
      procName: props.proc.name,
      nodeId: nodeId(),
    });
  }

  const summary = createMemo(() => {
    const p = props.proc;
    const parts: string[] = [];
    if (p.params) parts.push(truncate(p.params, 50));
    if (p.return_type) parts.push(`: ${p.return_type}`);
    if (p.cyclomatic != null) parts.push(`cc=${p.cyclomatic}`);
    return parts.join(" ");
  });

  return (
    <div class="tree-node proc-node" style={{ "padding-left": `${props.depth * 14}px` }}>
      <div class={`tree-node-row clickable${isSelected() ? " selected" : ""}`} onClick={select}>
        <span class={`badge ${procBadge(props.proc.proc_type)}`}>{props.proc.proc_type}</span>
        <span class="tree-name">{props.proc.name}</span>
        <span class="tree-summary">{summary()}</span>
      </div>
    </div>
  );
}

// ── DataWindow Tree Node ──────────────────────────────────────────────────────

function DwNode(props: { name: string; depth: number }): JSX.Element {
  const store = useStore();
  const nodeId = () => dwId(props.name);
  const isSelected = () => store.state.explore.selectedDw === nodeId();

  function select() {
    store.dispatch({ type: "EXPLORE_DW_SELECT", dwName: props.name, nodeId: nodeId() });
  }

  return (
    <div class="tree-node dw-node" style={{ "padding-left": `${props.depth * 14}px` }}>
      <div class={`tree-node-row clickable${isSelected() ? " selected" : ""}`} onClick={select}>
        <span class="badge badge-dw">datawindow</span>
        <span class="tree-name">{props.name}</span>
      </div>
    </div>
  );
}

// ── DataWindow Detail Tree ────────────────────────────────────────────────────

function DwDetailTree(props: { data: DwExploreDetail }): JSX.Element {
  const store = useStore();

  const retrieveSql = createMemo(() => {
    const cols = props.data.retrieve_columns
      .map(c => `${c.table_name}.${c.column_name}`)
      .join(", ");
    const tables = props.data.retrieve_tables.join(", ");
    const where = props.data.retrieve_where
      .map((w, i) => (i === 0 ? "" : `${w.logic ?? "AND"} `) + `${w.exp1} ${w.op} ${w.exp2}`)
      .join("\n        ");
    const lines = [
      cols   ? `SELECT  ${cols}`   : null,
      tables ? `FROM    ${tables}` : null,
      where  ? `WHERE   ${where}`  : null,
    ].filter(Boolean);
    return lines.length > 0 ? lines.join("\n") : null;
  });

  const controlBands = createMemo(() => {
    const bands = new Map<string, typeof props.data.controls>();
    for (const c of props.data.controls) {
      const b = c.band ?? "(none)";
      if (!bands.has(b)) bands.set(b, []);
      bands.get(b)!.push(c);
    }
    return bands;
  });

  function toggleBand(band: string) {
    store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: `dwband:${props.data.name}:${band}` });
  }

  const isBandExpanded = (band: string) => store.state.explore.expandedNodes.has(`dwband:${props.data.name}:${band}`);

  return (
    <div class="dw-detail">
      <Show when={props.data.controls.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Controls</span>
          <span class="dw-section-count">{props.data.controls.length}</span>
        </div>
        <For each={Array.from(controlBands().keys())}>
          {(band) => (
            <div class="dw-band">
              <div class="dw-band-header clickable" onClick={() => toggleBand(band)}>
                <span class="ast-chevron">{chevron(isBandExpanded(band))}</span>
                <span class="dw-band-name">{band}</span>
                <span class="dw-section-count">{controlBands().get(band)!.length}</span>
              </div>
              <Show when={isBandExpanded(band)}>
                <table class="dw-ctrl-table">
                  <thead>
                    <tr>
                      <th>type</th>
                      <th>name</th>
                      <th>expression</th>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={controlBands().get(band)!}>
                      {(ctrl) => (
                        <tr>
                          <td class="ct-type">{ctrl.control_type}</td>
                          <td class="ct-name">{ctrl.control_name}</td>
                          <td class="ct-expr">{ctrl.expression ?? ""}</td>
                        </tr>
                      )}
                    </For>
                  </tbody>
                </table>
              </Show>
            </div>
          )}
        </For>
      </Show>

      <Show when={retrieveSql()}>
        <div class="dw-section-header">
          <span class="dw-section-title">SQL</span>
        </div>
        <pre class="code-viewer" style={{ margin: "0 8px 4px", padding: "10px 14px", "font-size": "12px", "max-height": "200px" }}>{retrieveSql()}</pre>
      </Show>

      <Show when={props.data.arguments.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Arguments</span>
        </div>
        <For each={props.data.arguments}>
          {(arg) => (
            <div class="dw-arg">
              <span class="dw-arg-name">{arg.arg_name}</span>
              <span class="dw-arg-type">{arg.arg_type}</span>
            </div>
          )}
        </For>
      </Show>
    </div>
  );
}

// ── Object Tree Node ──────────────────────────────────────────────────────────

function ObjectNode(props: { lib: string; obj: ExploreObject; depth: number }): JSX.Element {
  const store = useStore();
  const nodeId = () => objId(props.lib, props.obj.name);
  const isDw = () => props.obj.kind === "datawindow";

  const treeFilter = () => store.state.explore.treeFilter.toLowerCase();

  const visibleProcs = createMemo(() => {
    const q = treeFilter();
    if (!q) return props.obj.procedures;
    return props.obj.procedures.filter(p => p.name.toLowerCase().includes(q));
  });

  const isVisible = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    if (props.obj.name.toLowerCase().includes(q)) return true;
    if (isDw()) return false;
    return visibleProcs().length > 0;
  });

  const isExpanded = () =>
    store.state.explore.expandedNodes.has(nodeId()) || (treeFilter() !== "" && isVisible());

  const procCount = createMemo(() => {
    if (isDw()) return "";
    const count = props.obj.procedures.length;
    return `${count} procedure${count !== 1 ? "s" : ""}`;
  });

  return (
    <Show when={isVisible()}>
      <div class="tree-node obj-node" style={{ "padding-left": `${props.depth * 14}px` }}>
        <div
          class="tree-node-row clickable"
          onClick={() => store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: nodeId() })}
        >
          <span class="tree-chevron">{chevron(isExpanded())}</span>
          <span class={`badge ${kindBadge(props.obj.kind)}`}>{props.obj.kind}</span>
          <span class="tree-name">{props.obj.name}</span>
          <Show when={!isDw()}>
            <span class="tree-summary">{procCount()}</span>
          </Show>
        </div>
        <Show when={isExpanded()}>
          <div class="tree-children">
            <Show when={isDw()} fallback={
              <Show when={visibleProcs().length > 0} fallback={<div class="tree-empty">No procedures</div>}>
                <For each={visibleProcs()}>
                  {(proc) => <ProcNode objName={props.obj.name} proc={proc} depth={props.depth + 1} />}
                </For>
              </Show>
            }>
              <DwNode name={props.obj.name} depth={props.depth + 1} />
            </Show>
          </div>
        </Show>
      </div>
    </Show>
  );
}

// ── Library Tree Node ─────────────────────────────────────────────────────────

function LibraryNode(props: { lib: ExploreLibrary; depth: number }): JSX.Element {
  const store = useStore();
  const nodeId = () => libId(props.lib.name);

  const treeFilter = () => store.state.explore.treeFilter.toLowerCase();

  const hasVisibleObjects = createMemo(() => {
    const q = treeFilter();
    if (!q) return true;
    return props.lib.objects.some(obj => {
      if (obj.name.toLowerCase().includes(q)) return true;
      if (obj.kind === "datawindow") return false;
      return obj.procedures.some(p => p.name.toLowerCase().includes(q));
    });
  });

  const isExpanded = () =>
    store.state.explore.expandedNodes.has(nodeId()) || (treeFilter() !== "" && hasVisibleObjects());

  return (
    <Show when={hasVisibleObjects()}>
      <div class="tree-node lib-node" style={{ "padding-left": `${props.depth * 14}px` }}>
        <div
          class="tree-node-row clickable"
          onClick={() => store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: nodeId() })}
        >
          <span class="tree-chevron">{chevron(isExpanded())}</span>
          <span class="tree-icon">{"▣"}</span>
          <span class="tree-name">{props.lib.name}</span>
          <span class="tree-summary">{props.lib.objects.length} objects</span>
        </div>
        <Show when={isExpanded()}>
          <div class="tree-children">
            <For each={props.lib.objects}>
              {(obj) => <ObjectNode lib={props.lib.name} obj={obj} depth={props.depth + 1} />}
            </For>
          </div>
        </Show>
      </div>
    </Show>
  );
}

// ── Proc Detail Panel ─────────────────────────────────────────────────────────

function ProcDetailPanel(props: { nodeId: string }): JSX.Element {
  const store = useStore();
  const entry = () => store.state.explore.procCache[props.nodeId];
  const procName = () => props.nodeId.split(":")[2] ?? "";

  const data = (): ExploreProcDetail | null => {
    const e = entry();
    if (!e || "error" in e) return null;
    return e as ExploreProcDetail;
  };

  const errorMsg = (): string | null => {
    const e = entry();
    if (e && "error" in e) return (e as { error: string }).error;
    return null;
  };

  const lines = createMemo(() => {
    const d = data();
    return d?.source_rendered ? d.source_rendered.split("\n") : [];
  });

  const highlighted = createMemo(() => {
    const d = data();
    return d?.source_rendered ? highlightPowerScript(d.source_rendered) : "";
  });

  const activeTab = () => store.state.explore.activeTab;

  const highlightIdx = createMemo(() => {
    const hl = store.state.explore.highlightedLine;
    const d = data();
    if (hl == null || !d) return null;
    const idx = hl - (d.start_line ?? 1);
    if (idx < 0 || idx >= lines().length) return null;
    return idx;
  });

  const [sourceViewerEl, setSourceViewerEl] = createSignal<HTMLDivElement | null>(null);
  createEffect(() => {
    const idx = highlightIdx();
    const el = sourceViewerEl();
    if (idx == null || !el) return;
    el.scrollTop = Math.max(0, idx * 20.8 - 80);
  });

  return (
    <Show when={entry() !== undefined} fallback={
      <div class="explore-right-body">
        <div class="loading-overlay"><div class="spinner" /> Loading...</div>
      </div>
    }>
      <Show when={data()} fallback={
        <div class="explore-right-body">
          <div class="tree-error">{errorMsg()}</div>
        </div>
      }>
        {(d) => (
          <>
            <div class="explore-right-header">
              <span class={`badge ${procBadge(d().proc_type)}`}>{d().proc_type}</span>
              <span class="proc-name">{procName()}</span>
              <Show when={d().params}>
                <span class="proc-params">({d().params})</span>
              </Show>
              <Show when={d().return_type}>
                <span class="proc-params">{"→"} {d().return_type}</span>
              </Show>
              <Show when={d().cyclomatic != null}>
                <span class="badge badge-cc">CC: {d().cyclomatic}</span>
              </Show>
              <div class="explore-tabs" style={{ "margin-left": "auto" }}>
                <button
                  class={`explore-tab-btn${activeTab() === "source" ? " active" : ""}`}
                  onClick={() => store.dispatch({ type: "EXPLORE_TAB", tab: "source" })}
                >Source</button>
                <button
                  class={`explore-tab-btn${activeTab() === "ast" ? " active" : ""}`}
                  onClick={() => store.dispatch({ type: "EXPLORE_TAB", tab: "ast" })}
                >AST</button>
              </div>
            </div>
            <div class="explore-right-body">
              <Show when={activeTab() === "source"}>
                <div class="source-viewer" ref={setSourceViewerEl}>
                  <div class="source-gutter">
                    <For each={lines()}>
                      {(_, i) => (
                        <div
                          class="source-gutter-line"
                          style={i() === highlightIdx() ? {
                            color: "#fb923c", "font-weight": "600",
                            background: "rgba(251, 146, 60, 0.12)",
                          } : undefined}
                        >
                          {(d().start_line ?? 1) + i()}
                        </div>
                      )}
                    </For>
                  </div>
                  <div class="source-code-area">
                    <Show when={highlightIdx() != null}>
                      <div class="ast-line-highlight" style={{
                        top: `${highlightIdx()! * 20.8}px`,
                        height: "20.8px",
                      }} />
                    </Show>
                    <pre innerHTML={highlighted()} />
                  </div>
                </div>
              </Show>
              <Show when={activeTab() === "ast"}>
                <AstNode node={d().ast} nodeId={props.nodeId + ".ast"} depth={0} />
              </Show>
            </div>
          </>
        )}
      </Show>
    </Show>
  );
}

// ── DW Detail Panel ───────────────────────────────────────────────────────────

function DwDetailPanel(props: { nodeId: string }): JSX.Element {
  const store = useStore();
  const entry = () => store.state.explore.dwCache[props.nodeId];
  const dwName = () => props.nodeId.replace(/^dw:/, "");

  const data = (): DwExploreDetail | null => {
    const e = entry();
    if (!e || "error" in e) return null;
    return e as DwExploreDetail;
  };

  const errorMsg = (): string | null => {
    const e = entry();
    if (e && "error" in e) return (e as { error: string }).error;
    return null;
  };

  return (
    <Show when={entry() !== undefined} fallback={
      <div class="explore-right-body">
        <div class="loading-overlay"><div class="spinner" /> Loading DataWindow...</div>
      </div>
    }>
      <Show when={data()} fallback={
        <div class="explore-right-body">
          <div class="tree-error">{errorMsg()}</div>
        </div>
      }>
        {(d) => (
          <>
            <div class="explore-right-header">
              <span class="badge badge-dw">datawindow</span>
              <span class="proc-name">{dwName()}</span>
              <span class="proc-params">{d().controls.length} controls</span>
            </div>
            <div class="explore-right-body">
              <DwDetailTree data={d()} />
            </div>
          </>
        )}
      </Show>
    </Show>
  );
}

// ── Detail Panel ──────────────────────────────────────────────────────────────

function DetailPanel(): JSX.Element {
  const store = useStore();
  const selectedProc = () => store.state.explore.selectedProc;
  const selectedDw = () => store.state.explore.selectedDw;

  return (
    <Show when={selectedProc()} fallback={
      <Show when={selectedDw()} fallback={
        <div class="explore-empty">Select a procedure or DataWindow</div>
      }>
        {(nodeId) => <DwDetailPanel nodeId={nodeId()} />}
      </Show>
    }>
      {(nodeId) => <ProcDetailPanel nodeId={nodeId()} />}
    </Show>
  );
}

// ── Main Explore Component ────────────────────────────────────────────────────

export function Explore() {
  const store = useStore();

  onMount(() => {
    store.dispatch({ type: "NAVIGATE", view: "explore" });
    if (store.state.explore.libraries.length === 0 && !store.state.explore.loading) {
      store.dispatch({ type: "EXPLORE_LOAD" });
    }
  });

  const totalObjects = createMemo(() =>
    store.state.explore.libraries.reduce((sum, lib) => sum + lib.objects.length, 0)
  );

  const totalProcs = createMemo(() =>
    store.state.explore.libraries.reduce(
      (sum, lib) => sum + lib.objects.reduce((s, obj) => s + obj.procedures.length, 0),
      0
    )
  );

  return (
    <div class="explore-split">
      <div class="explore-left">
        <div class="explore-left-header">
          <h2>AST Explorer</h2>
          <div class="explore-meta">
            <span>{store.state.explore.libraries.length} libraries</span>
            <span>{totalObjects()} objects</span>
            <span>{totalProcs()} procedures</span>
          </div>
          <div class="explore-left-actions">
            <button class="filter-pill" onClick={() => store.dispatch({ type: "EXPLORE_EXPAND_ALL" })}>
              Expand All
            </button>
            <button class="filter-pill" onClick={() => store.dispatch({ type: "EXPLORE_COLLAPSE_ALL" })}>
              Collapse All
            </button>
          </div>
          <input
            class="explore-filter-input"
            placeholder="Filter…"
            value={store.state.explore.treeFilter}
            onInput={(e) => store.dispatch({ type: "EXPLORE_FILTER", q: e.currentTarget.value })}
          />
        </div>
        <div class="explore-left-tree">
          <Show
            when={!store.state.explore.loading}
            fallback={<div class="loading-overlay"><div class="spinner" /> Loading AST tree...</div>}
          >
            <Show
              when={store.state.explore.libraries.length > 0}
              fallback={<div class="tree-empty">No data. Run <code>pb ingest</code> first.</div>}
            >
              <For each={store.state.explore.libraries}>
                {(lib) => <LibraryNode lib={lib} depth={0} />}
              </For>
            </Show>
          </Show>
        </div>
      </div>
      <div class="explore-right">
        <DetailPanel />
      </div>
    </div>
  );
}
