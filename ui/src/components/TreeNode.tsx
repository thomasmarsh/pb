// TreeNode.tsx — Generic expandable tree node.

import { Show, children, type ParentProps, type JSX } from "solid-js";
import { useStore } from "../context.js";

function chevron(expanded: boolean): string { return expanded ? "\u25BE" : "\u25B8"; }

export interface TreeNodeProps {
  nodeId: string;
  depth: number;
  badge?: { text: string; cls: string };
  icon?: string;
  name: string;
  summary?: string;
  selected?: boolean;
  class?: string;
  onClick?: () => void;
}

export function TreeNode(props: ParentProps<TreeNodeProps>): JSX.Element {
  const store = useStore();
  const isExpanded = () => store.state.explore.expandedNodes.has(props.nodeId);
  const resolved = children(() => props.children);
  const hasChildren = () => !!resolved();

  function toggle() {
    console.log("[TreeNode] toggle", props.nodeId, "hasChildren:", hasChildren(), "onClick:", !!props.onClick);
    props.onClick?.();
    if (hasChildren()) {
      console.log("[TreeNode] dispatching EXPLORE_TOGGLE for", props.nodeId);
      store.dispatch({ type: "EXPLORE_TOGGLE", nodeId: props.nodeId });
    } else {
      console.log("[TreeNode] no children, skipping toggle dispatch");
    }
  }

  return (
    <div class={`tree-node ${props.class ?? ""}`}
         style={{ "padding-left": `${props.depth * 14}px` }}>
      <div class={`tree-node-row clickable${props.selected ? " selected" : ""}`}
           onClick={toggle}>
        {hasChildren() && <span class="tree-chevron">{chevron(isExpanded())}</span>}
        {props.icon && <span class="tree-icon">{props.icon}</span>}
        {props.badge && <span class={`badge ${props.badge.cls}`}>{props.badge.text}</span>}
        <span class="tree-name">{props.name}</span>
        {props.summary && <span class="tree-summary">{props.summary}</span>}
      </div>
      <Show when={isExpanded() && hasChildren()}>
        <div class="tree-children">{resolved()}</div>
      </Show>
    </div>
  );
}
