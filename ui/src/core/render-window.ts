// render-window.ts — Pure function: AST + controlValues + variables → logical structure.
// No DOM mounting, no server, no browser. Tests can assert on the output directly.

import type { AstData, DWRow } from "./interpreter.js";
import type { WindowLayout } from "./layout.js";
import { extractLayout } from "./layout.js";

export interface RenderedWindow {
  layout: WindowLayout | null;
  controls: RenderedControl[];
  dataWindows: RenderedDW[];
  variables: Record<string, unknown>;
}

export interface RenderedControl {
  name: string;
  type: string;
  x: number;
  y: number;
  width: number;
  height: number;
  text: string | null;
  visible: boolean;
}

export interface RenderedDW {
  name: string;
  dataobject: string | null;
  rows: DWRow[];
  columns: string[];
}

/**
 * Render a window from AST + controlValues + variables.
 * Returns a logical structure that tests can assert on directly.
 * No DOM mounting required.
 */
export function renderWindow(
  ast: AstData,
  controlValues: Record<string, DWRow[]>,
  variables: Record<string, unknown>,
): RenderedWindow {
  const layout = extractLayout(ast.typeBlocks as unknown[]);

  const controls: RenderedControl[] = (layout?.controls ?? []).map((c) => ({
    name: c.name,
    type: c.type,
    x: c.x,
    y: c.y,
    width: c.width,
    height: c.height,
    text: c.text ?? null,
    visible: true,
  }));

  const dataWindows: RenderedDW[] = controls
    .filter((c) => c.type.toLowerCase().includes("datawindow") || c.name.startsWith("dw_"))
    .map((c) => ({
      name: c.name,
      dataobject: findDataobject(ast, c.name),
      rows: controlValues[c.name] ?? [],
      columns: controlValues[c.name]?.length
        ? Object.keys(controlValues[c.name]![0]!)
        : [],
    }));

  return { layout, controls, dataWindows, variables };
}

function findDataobject(ast: AstData, controlName: string): string | null {
  for (const tb of ast.typeBlocks) {
    if (tb.decl.within !== null && tb.decl.name === controlName) {
      for (const s of tb.body) {
        if (
          s.node.tag === "BsLocalVar" &&
          s.node.name === "dataobject" &&
          s.node.init?.tag === "ExStr"
        ) {
          return (s.node.init as { tag: "ExStr"; contents: string }).contents;
        }
      }
    }
  }
  return null;
}
