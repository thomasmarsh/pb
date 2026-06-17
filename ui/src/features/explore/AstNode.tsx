// ast-node.tsx — Recursive AST tree renderer.

import { Show, For, createMemo, type JSX } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { highlightPowerScript } from "../../lib/highlight.js";
import { resolveRenderer, type AstChild } from "./ast-renderers.js";

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

import { chevron } from "../../utils/format.js";

function isLocated(v: unknown): v is { line: number; node: unknown } {
  return isNode(v) && typeof v.line === "number" && "node" in v;
}

// ── Component ─────────────────────────────────────────────────────────────────

export function AstNode(props: {
  node: unknown;
  nodeId: string;
  depth: number;
}): JSX.Element {
  const store = useExploreStore();
  const snap = store.getState();
  const isExpanded = () => snap().explore.expandedNodes.has(props.nodeId);

  const tag = createMemo(() => nodeTag(props.node));

  const renderer = createMemo(() => {
    if (Array.isArray(props.node) || !isNode(props.node)) return null;
    return resolveRenderer(props.node, tag()!);
  });

  const summaryText = createMemo(() => {
    if (Array.isArray(props.node)) return "";
    if (!isNode(props.node)) return String(props.node);
    return renderer()!.summary(props.node);
  });

  const children = createMemo((): AstChild[] => {
    if (Array.isArray(props.node)) return [];
    if (!isNode(props.node)) return [];
    return renderer()!.children?.(props.node) ?? [];
  });
  const hasChildren = () => children().length > 0;

  const highlightedHtml = createMemo(() => {
    if (Array.isArray(props.node) || !isNode(props.node)) return null;
    const r = renderer();
    if (r?.source) {
      const src = r.source(props.node);
      if (src) return highlightPowerScript(src);
    }
    return null;
  });

  const badgeText = createMemo(() => {
    if (Array.isArray(props.node) || !isNode(props.node)) return null;
    return renderer()?.badge?.(props.node) ?? null;
  });

  function toggle() {
    if (hasChildren()) {
      store.dispatch({ tag: "explore", action: { type: "toggle", nodeId: props.nodeId } });
    }
  }

  // Array: render children directly
  if (Array.isArray(props.node)) {
    return (
      <div class="ast-body">
        <For each={props.node as unknown[]}>
          {(item, i) => {
            if (isLocated(item)) {
              const lineNum = item.line;
              return (
                <div class="ast-located-row" onClick={() => {
                  store.dispatch({ tag: "explore", action: { type: "highlight-line", line: lineNum } });
                  store.dispatch({ tag: "explore", action: { type: "tab", tab: "source" } });
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

  // Leaf: no chevron, syntax-highlighted source
  if (!hasChildren()) {
    return (
      <div class="ast-leaf" style={{ "margin-left": `${props.depth * 18}px` }}>
        <Show
          when={highlightedHtml()}
          fallback={<span class="ast-leaf-text">{summaryText()}</span>}
        >
          <span class="ast-leaf-text ast-highlighted" innerHTML={highlightedHtml()!} />
        </Show>
        <Show when={badgeText()}>
          <span class="badge-sql ast-badge">{badgeText()}</span>
        </Show>
      </div>
    );
  }

  // Branch: chevron + header, expandable children
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
        <Show when={badgeText()}>
          <span class="badge-sql ast-badge">{badgeText()}</span>
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
