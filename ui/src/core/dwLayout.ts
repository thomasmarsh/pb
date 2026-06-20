import type { DataWindowFile, DwBandKind } from "../types/ast.generated.js";

export interface DwBandLayout {
  tag: string;
  height: number;
  yOffset: number;
}

export interface DwControlLayout {
  type: string;
  name: string | null;
  band: string;
  x: number;
  y: number;
  width: number;
  height: number;
  label: string | null;
  colName: string | null;
}

export interface DwLayout {
  totalWidth: number;
  totalHeight: number;
  bands: DwBandLayout[];
  controls: DwControlLayout[];
}

// Standard PB display order for bands.
const BAND_ORDER: Record<string, number> = {
  BkHeader: 0,
  BkDetail: 1,
  BkSummary: 2,
  BkFooter: 3,
  BkBackground: 4,
  BkForeground: 5,
};

function bandTag(kind: DwBandKind | null): string {
  if (!kind) return "BkDetail";
  return typeof kind === "object" && "tag" in kind ? (kind as { tag: string }).tag : String(kind);
}

// "Κωδ.~ttrn(418)" → "Κωδ."  (the suffix after ~t is a runtime expression)
function stripTildeT(text: string | null | undefined): string | null {
  if (!text) return null;
  const idx = text.indexOf("~t");
  const result = idx >= 0 ? text.slice(0, idx).trim() : text.trim();
  return result || null;
}

export function extractDwLayout(dw: DataWindowFile): DwLayout {
  const sorted = [...dw.bands].sort(
    (a, b) =>
      (BAND_ORDER[bandTag(a.kind)] ?? 99) - (BAND_ORDER[bandTag(b.kind)] ?? 99),
  );

  const bands: DwBandLayout[] = [];
  let yOff = 0;
  for (const b of sorted) {
    const h = b.height ?? 0;
    bands.push({ tag: bandTag(b.kind), height: h, yOffset: yOff });
    yOff += h;
  }

  const controls: DwControlLayout[] = dw.controls
    .filter((c) => c.x != null && c.y != null)
    .map((c) => ({
      type: c.type,
      name: c.name,
      band: bandTag(c.band),
      x: c.x ?? 0,
      y: c.y ?? 0,
      width: c.width ?? 0,
      height: c.height ?? 0,
      label: c.type === "text" ? stripTildeT(c.attrs["text"]) : null,
      colName: c.type === "column" ? c.name : null,
    }));

  const totalWidth =
    controls.length > 0
      ? Math.max(...controls.map((c) => c.x + c.width))
      : 0;

  return { totalWidth, totalHeight: yOff, bands, controls };
}
