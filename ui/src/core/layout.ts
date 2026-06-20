// layout.ts — Extract window/control geometry from parsed typeBlocks AST.

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

const WINDOW_BASES = new Set(["window", "w_pbgrid"]);

function stripQualifier(ancestor: string): string {
  return ancestor.split("`")[0] ?? ancestor;
}

function isWindowAncestor(
  ancestor: string,
  ancestorMap: Map<string, string>,
  visited: Set<string>,
): boolean {
  const base = stripQualifier(ancestor);
  if (WINDOW_BASES.has(base)) return true;
  if (visited.has(base)) return false;
  visited.add(base);
  const parent = ancestorMap.get(base);
  return parent != null && isWindowAncestor(parent, ancestorMap, visited);
}

export function extractLayout(typeBlocks: unknown[]): WindowLayout | null {
  const blocks = typeBlocks as { decl: { ancestor: string; name: string; within: string | null }; body: unknown[] }[];

  const ancestorMap = new Map<string, string>();
  for (const b of blocks) {
    if (b.decl?.name && b.decl?.ancestor) {
      ancestorMap.set(b.decl.name, b.decl.ancestor);
    }
  }

  const windowBlock = blocks.find(
    (b) => b.decl?.within == null && isWindowAncestor(b.decl?.ancestor ?? "", ancestorMap, new Set()),
  );
  if (!windowBlock) return null;

  const windowName = windowBlock.decl.name;
  const props = extractProperties(windowBlock.body);

  const controls = blocks
    .filter((b) => b.decl?.within === windowName)
    .map((b) => extractControl(b));

  return {
    name: windowName,
    type: stripQualifier(windowBlock.decl.ancestor),
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
    type: stripQualifier(block.decl.ancestor),
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
    props[node.name] = node.init.contents;
  }
  return props;
}

