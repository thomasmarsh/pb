// tests/components/TreeNode.test.tsx — Tests for TreeNode component.

import { describe, it, expect } from "vitest";
import { screen, fireEvent, render } from "@solidjs/testing-library";
import { ExploreStoreContext } from "../../src/features/explore/ExploreContext.js";
import { createTestStore } from "../helpers.js";
import { TreeNode } from "../../src/features/explore/TreeNode.js";
import type { JSX } from "solid-js";

function renderTreeNode(
  props: { nodeId: string; name: string; depth?: number; badge?: { text: string; cls: string }; selected?: boolean; summary?: string; onClick?: () => void },
  children?: () => JSX.Element,
) {
  const { store, captured } = createTestStore({
    explore: {
      libraries: [],
      expandedNodes: new Set<string>(),
      selectedProc: null,
      selectedDw: null,
      procCache: {},
      dwCache: {},
      loading: false,
      activeTab: "source",
      treeFilter: "",
      highlightedLine: null,
      sidebarGroups: { sourceTree: true, entityNav: false, analysisNav: false },
      sidebarCollapsed: false,
      tables: { items: [], filter: "", selected: null, detail: null, loading: false, detailLoading: false },
    },
  });
  const result = render(() => (
    <ExploreStoreContext.Provider value={store}>
      <TreeNode {...props} depth={props.depth ?? 0}>{children?.()}</TreeNode>
    </ExploreStoreContext.Provider>
  ));
  return { ...result, captured, store };
}

describe("TreeNode", () => {
  it("renders node name", () => {
    renderTreeNode({ nodeId: "lib:test", name: "test.pbl" });
    expect(screen.getByText("test.pbl")).toBeDefined();
  });

  it("renders badge when provided", () => {
    renderTreeNode({ nodeId: "obj:lib:o1", name: "w_main", badge: { text: "powerscript", cls: "badge-ps" } });
    expect(screen.getByText("powerscript")).toBeDefined();
  });

  it("shows chevron when has children", () => {
    renderTreeNode(
      { nodeId: "lib:test", name: "test.pbl" },
      () => <div>child content</div>,
    );
    expect(screen.getByText("▸")).toBeDefined();
  });

  it("no chevron for leaf nodes", () => {
    renderTreeNode({ nodeId: "obj:lib:o1", name: "w_main" });
    expect(screen.queryByText("▸")).toBeNull();
  });

  it("clicking node with children toggles expand", () => {
    const { captured } = renderTreeNode(
      { nodeId: "lib:test", name: "test.pbl" },
      () => <div>child content</div>,
    );
    fireEvent.click(screen.getByText("test.pbl"));
    const toggleActions = captured.filter(
      (a) => a.tag === "explore" && a.action.type === "toggle",
    );
    expect(toggleActions.length).toBe(1);
  });

  it("clicking leaf node calls onClick", () => {
    let clicked = false;
    render(() => (
      <ExploreStoreContext.Provider value={createTestStore().store}>
        <TreeNode nodeId="proc:o:p" name="of_click" depth={0} onClick={() => { clicked = true; }}>
        </TreeNode>
      </ExploreStoreContext.Provider>
    ));
    fireEvent.click(screen.getByText("of_click"));
    expect(clicked).toBe(true);
  });

  it("selected state adds selected class", () => {
    const { container } = renderTreeNode({
      nodeId: "proc:o:p",
      name: "of_active",
      depth: 0,
      selected: true,
    });
    const row = container.querySelector(".tree-node-row");
    expect(row!.classList.contains("selected")).toBe(true);
  });

  it("summary text renders when provided", () => {
    renderTreeNode({ nodeId: "proc:o:p", name: "of_calc", depth: 0, summary: "(n) : integer" });
    expect(screen.getByText("(n) : integer")).toBeDefined();
  });
});
