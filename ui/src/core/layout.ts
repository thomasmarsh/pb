// layout.ts — Extract window/control geometry from parsed typeBlocks AST.
// TD-2: ExStr contents include surrounding quotes; we strip them here.
// TD-3: Window block is found by checking known base ancestors, not by full chain resolution.

export interface LayoutControl {
  name: string;
  type: string;
  parent?: string;
  x: number;
  y: number;
  width: number;
  height: number;
  text?: string;
  properties: Record<string, string>;
}

export interface WindowLayout {
  name: string;
  type: string;
  width: number;
  height: number;
  title?: string;
  controls: LayoutControl[];
}

// Known window base ancestors. TD-3: extend when inheritance chain resolution is available.
const WINDOW_ANCESTORS = new Set(["window", "w_pbgrid"]);

export function extractLayout(typeBlocks: unknown[]): WindowLayout | null {
  const blocks = typeBlocks as { decl: { ancestor: string; name: string; within: string | null }; body: unknown[] }[];

  const windowBlock = blocks.find(
    (b) => b.decl?.within == null && WINDOW_ANCESTORS.has(b.decl?.ancestor?.split("`")[0] ?? ""),
  );
  if (!windowBlock) return null;

  const windowName = windowBlock.decl.name;
  const props = extractProperties(windowBlock.body);

  const controls = blocks
    .filter((b) => b.decl?.within === windowName)
    .map((b) => extractControl(b));

  return {
    name: windowName,
    type: windowBlock.decl.ancestor.split("`")[0] ?? windowBlock.decl.ancestor,
    width: parseInt(props["width"] ?? "0", 10),
    height: parseInt(props["height"] ?? "0", 10),
    title: props["title"],
    controls,
  };
}

function extractControl(block: {
  decl: { ancestor: string; name: string; within: string | null };
  body: unknown[];
}): LayoutControl {
  const props = extractProperties(block.body);
  return {
    name: block.decl.name,
    type: block.decl.ancestor.split("`")[0] ?? block.decl.ancestor,
    parent: block.decl.within ?? undefined,
    x: parseInt(props["x"] ?? "0", 10),
    y: parseInt(props["y"] ?? "0", 10),
    width: parseInt(props["width"] ?? "0", 10),
    height: parseInt(props["height"] ?? "0", 10),
    text: props["text"],
    properties: props,
  };
}

function extractProperties(body: unknown[]): Record<string, string> {
  const props: Record<string, string> = {};
  for (const entry of body as { node: { tag: string; name: string; init: { contents: string } | null } }[]) {
    const node = entry?.node;
    if (node?.tag !== "BsLocalVar" || !node.name || !node.init) continue;
    props[node.name] = stripQuotes(node.init.contents);
  }
  return props;
}

// TD-2: ExStr values include surrounding double-quotes in the AST; strip them.
function stripQuotes(value: string): string {
  if (value.startsWith('"') && value.endsWith('"')) return value.slice(1, -1);
  return value;
}
