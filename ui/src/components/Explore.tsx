// Explore.tsx — Interactive AST tree explorer.

import { Show, For, onMount, createMemo, type JSX } from "solid-js";
import { useStore } from "../context.js";
import { highlightPowerScript } from "../highlight.js";
import type { ExploreLibrary, ExploreObject, ExploreProcedure, DwExploreDetail } from "../types/api.js";

// ── Node IDs ──────────────────────────────────────────────────────────────────

function libId(name: string): string { return `lib:${name}`; }
function objId(lib: string, name: string): string { return `obj:${lib}:${name}`; }
function procId(obj: string, name: string): string { return `proc:${obj}:${name}`; }

// ── Helpers ───────────────────────────────────────────────────────────────────

const KIND_BADGES: Record<string, string> = {
  powerscript: "badge-ps", datawindow: "badge-dw", project: "badge-proj",
};
const PROC_BADGES: Record<string, string> = {
  function: "badge-func", subroutine: "badge-sub", event: "badge-event", on: "badge-on",
};

function kindBadge(kind: string): string { return KIND_BADGES[kind] ?? "badge-proj"; }
function procBadge(t: string): string { return PROC_BADGES[t] ?? "badge-func"; }
function chevron(expanded: boolean): string { return expanded ? "\u25BE" : "\u25B8"; }

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "\u2026" : s;
}

function isNode(n: unknown): n is Record<string, unknown> {
  return n !== null && typeof n === "object" && !Array.isArray(n);
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

// Expression summary — used by both expression renderers and as fallback
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
  BsAssign: compound(
    (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 2) {
        return getLvalue(c[0]) + " = " + exprSum(c[1]);
      }
      return "assign";
    },
    (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 2) {
        return [
          { key: "lhs", label: "lhs", value: c[0] },
          { key: "rhs", label: "rhs", value: c[1] },
        ];
      }
      return [];
    },
  ),
  BsAssignExpr: compound(
    (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 2) return exprSum(c[0]) + " = " + exprSum(c[1]);
      return "assign";
    },
    (n) => {
      const c = n.contents;
      if (Array.isArray(c) && c.length === 2) {
        return [
          { key: "lhs", label: "lhs", value: c[0] },
          { key: "rhs", label: "rhs", value: c[1] },
        ];
      }
      return [];
    },
  ),
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
    (n) => "choose case " + exprSum(n.contents),
    (n) => {
      const clauses = n.contents;
      if (!Array.isArray(clauses)) return [];
      return clauses.map((clause, i) => {
        const c = clause as Record<string, unknown>;
        const label = c.expr != null ? `case ${exprSum(c.expr)}` : "case else";
        return { key: `clause_${i}`, label, value: c.body ?? [] };
      });
    },
  ),
};

// Fallback renderer for unknown tags
const FALLBACK: NodeRenderer = {
  summary: (_n, tag) => tag ?? "{...}",
  children: () => [],
};

function resolveRenderer(_node: Record<string, unknown>, tag: string): NodeRenderer {
  return RENDERERS[tag] ?? FALLBACK;
}

// ── AST Node Renderer ─────────────────────────────────────────────────────────

function AstNode(props: {
  node: unknown;
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

  // Top-level array: render children directly
  if (Array.isArray(props.node)) {
    return (
      <div class="ast-body">
        <For each={props.node}>
          {(item, i) => (
            <AstNode node={item} nodeId={`${props.nodeId}.${i()}`} depth={props.depth} />
          )}
        </For>
      </div>
    );
  }

  // Leaf node: no chevron, syntax-highlighted source
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

  // Compound node: chevron + header, expandable children
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
  const isExpanded = () => store.state.explore.expandedNodes.has(nodeId());
  const astData = () => store.state.explore.astCache[nodeId()];

  function toggle() {
    store.dispatch({
      type: "EXPLORE_PROC_EXPAND",
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
      <div class="tree-node-row clickable" onClick={toggle}>
        <span class="tree-chevron">{chevron(isExpanded())}</span>
        <span class={`badge ${procBadge(props.proc.proc_type)}`}>{props.proc.proc_type}</span>
        <span class="tree-name">{props.proc.name}</span>
        <span class="tree-summary">{summary()}</span>
      </div>
      <Show when={isExpanded()}>
        <div class="tree-children">
          <Show
            when={astData() !== undefined}
            fallback={<div class="tree-loading">Loading AST...</div>}
          >
            <Show
              when={astData() !== null && !(astData() as Record<string, unknown>)?.error}
              fallback={<div class="tree-empty">No AST body</div>}
            >
              <AstNode node={astData()} nodeId={`${nodeId()}.root`} depth={0} />
            </Show>
          </Show>
        </div>
      </Show>
    </div>
  );
}

// ── DataWindow Tree Node ──────────────────────────────────────────────────────

function DwNode(props: { name: string; depth: number }): JSX.Element {
  const store = useStore();
  const nodeId = () => `dw:${props.name}`;
  const isExpanded = () => store.state.explore.expandedNodes.has(nodeId());
  const dwData = () => store.state.explore.dwCache[nodeId()];

  function toggle() {
    store.dispatch({
      type: "EXPLORE_DW_EXPAND",
      dwName: props.name,
      nodeId: nodeId(),
    });
  }

  const summary = createMemo(() => {
    const d = dwData();
    if (!d || !d.controls) return "";
    const parts: string[] = [];
    if (d.controls.length > 0) parts.push(`${d.controls.length} controls`);
    if (d.retrieve_tables.length > 0) parts.push(`${d.retrieve_tables.length} tables`);
    if (d.arguments.length > 0) parts.push(`${d.arguments.length} args`);
    return parts.join(" ");
  });

  return (
    <div class="tree-node dw-node" style={{ "padding-left": `${props.depth * 14}px` }}>
      <div class="tree-node-row clickable" onClick={toggle}>
        <span class="tree-chevron">{chevron(isExpanded())}</span>
        <span class="tree-name">{props.name}</span>
        <Show when={summary()}>
          <span class="tree-summary">{summary()}</span>
        </Show>
      </div>
      <Show when={isExpanded()}>
        <div class="tree-children">
          <Show
            when={dwData() !== undefined}
            fallback={<div class="tree-loading">Loading DataWindow...</div>}
          >
            <Show
              when={dwData() && dwData()!.controls}
              fallback={<div class="tree-empty">No data</div>}
            >
              <DwDetailTree data={dwData()!} />
            </Show>
          </Show>
        </div>
      </Show>
    </div>
  );
}

// ── DataWindow Detail Tree ────────────────────────────────────────────────────

function DwDetailTree(props: { data: DwExploreDetail }): JSX.Element {
  const store = useStore();

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
      {/* Controls by band */}
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
                <div class="dw-band-controls">
                  <For each={controlBands().get(band)!}>
                    {(ctrl) => (
                      <div class="dw-control">
                        <span class="dw-ctrl-type">{ctrl.control_type}</span>
                        <span class="dw-ctrl-name">{ctrl.control_name}</span>
                        <Show when={ctrl.expression}>
                          <span class="dw-ctrl-expr">{ctrl.expression}</span>
                        </Show>
                      </div>
                    )}
                  </For>
                </div>
              </Show>
            </div>
          )}
        </For>
      </Show>

      {/* Retrieve tables */}
      <Show when={props.data.retrieve_tables.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Retrieve Tables</span>
        </div>
        <For each={props.data.retrieve_tables}>
          {(table) => <div class="dw-table-name">{table}</div>}
        </For>
      </Show>

      {/* Retrieve columns */}
      <Show when={props.data.retrieve_columns.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Columns</span>
          <span class="dw-section-count">{props.data.retrieve_columns.length}</span>
        </div>
        <For each={props.data.retrieve_columns}>
          {(col) => (
            <div class="dw-column">
              <span class="dw-col-table">{col.table_name}</span>
              <span class="dw-col-dot">.</span>
              <span class="dw-col-name">{col.column_name}</span>
            </div>
          )}
        </For>
      </Show>

      {/* Retrieve where */}
      <Show when={props.data.retrieve_where.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Where Clauses</span>
        </div>
        <For each={props.data.retrieve_where}>
          {(w) => (
            <div class="dw-where">
              <span class="dw-where-exp">{w.exp1}</span>
              <span class="dw-where-op">{w.op}</span>
              <span class="dw-where-exp">{w.exp2}</span>
              <Show when={w.logic}><span class="dw-where-logic">{w.logic}</span></Show>
            </div>
          )}
        </For>
      </Show>

      {/* Arguments */}
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
  const isExpanded = () => store.state.explore.expandedNodes.has(nodeId());
  const isDw = () => props.obj.kind === "datawindow";

  const summary = createMemo(() => {
    if (isDw()) return ""; // DW summary comes from DwNode after load
    const count = props.obj.procedures.length;
    return `${count} procedure${count !== 1 ? "s" : ""}`;
  });

  return (
    <div class="tree-node obj-node" style={{ "padding-left": `${props.depth * 14}px` }}>
      <div
        class="tree-node-row clickable"
        onClick={() => store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: nodeId() })}
      >
        <span class="tree-chevron">{chevron(isExpanded())}</span>
        <span class={`badge ${kindBadge(props.obj.kind)}`}>{props.obj.kind}</span>
        <span class="tree-name">{props.obj.name}</span>
        <span class="tree-summary">{summary()}</span>
      </div>
      <Show when={isExpanded()}>
        <div class="tree-children">
          <Show when={isDw()} fallback={
            <Show when={props.obj.procedures.length > 0} fallback={<div class="tree-empty">No procedures</div>}>
              <For each={props.obj.procedures}>
                {(proc) => <ProcNode objName={props.obj.name} proc={proc} depth={props.depth + 1} />}
              </For>
            </Show>
          }>
            <DwNode name={props.obj.name} depth={props.depth + 1} />
          </Show>
        </div>
      </Show>
    </div>
  );
}

// ── Library Tree Node ─────────────────────────────────────────────────────────

function LibraryNode(props: { lib: ExploreLibrary; depth: number }): JSX.Element {
  const store = useStore();
  const nodeId = () => libId(props.lib.name);
  const isExpanded = () => store.state.explore.expandedNodes.has(nodeId());

  return (
    <div class="tree-node lib-node" style={{ "padding-left": `${props.depth * 14}px` }}>
      <div
        class="tree-node-row clickable"
        onClick={() => store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: nodeId() })}
      >
        <span class="tree-chevron">{chevron(isExpanded())}</span>
        <span class="tree-icon">{"\u25A3"}</span>
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
    <div class="explore-container">
      <div class="explore-header">
        <h2>AST Explorer</h2>
        <div class="explore-meta">
          <span>{store.state.explore.libraries.length} libraries</span>
          <span>{totalObjects()} objects</span>
          <span>{totalProcs()} procedures</span>
        </div>
        <div class="explore-actions">
          <button class="filter-pill" onClick={() => store.dispatch({ type: "EXPLORE_EXPAND_ALL" })}>
            Expand All
          </button>
          <button class="filter-pill" onClick={() => store.dispatch({ type: "EXPLORE_COLLAPSE_ALL" })}>
            Collapse All
          </button>
        </div>
      </div>
      <Show
        when={!store.state.explore.loading}
        fallback={<div class="loading-overlay"><div class="spinner" /> Loading AST tree...</div>}
      >
        <Show
          when={store.state.explore.libraries.length > 0}
          fallback={<div class="tree-empty">No data available. Run <code>pb ingest</code> first.</div>}
        >
          <div class="explore-tree">
            <For each={store.state.explore.libraries}>
              {(lib) => <LibraryNode lib={lib} depth={0} />}
            </For>
          </div>
        </Show>
      </Show>
    </div>
  );
}
