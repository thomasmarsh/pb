// utils/diagram.ts — Shared diagram utilities.

export type DiagramKind =
  | "inheritance"
  | "calls"
  | "dw-tables"
  | "heatmap"
  | "sql-lineage"
  | "table-lineage"
  | "proc-tables"
  | "fk-graph";

export const HAS_FOCUS: ReadonlySet<DiagramKind> = new Set([
  "calls",
  "dw-tables",
  "sql-lineage",
  "table-lineage",
  "proc-tables",
]);

export const AUTO_GENERATE: ReadonlySet<DiagramKind> = new Set([
  "heatmap",
  "inheritance",
  "dw-tables",
  "sql-lineage",
  "proc-tables",
  "fk-graph",
]);

export function parsePbUrl(href: string | null): { kind: "object" | "table"; name: string; meta: Record<string, string> } | null {
  if (!href || !href.startsWith("pb://")) return null;
  const rest = href.slice(5);
  const hashIdx = rest.indexOf("#");
  const path = hashIdx >= 0 ? rest.slice(0, hashIdx) : rest;
  const fragment = hashIdx >= 0 ? rest.slice(hashIdx + 1) : "";
  const slash = path.indexOf("/");
  if (slash < 0) return null;
  const kind = path.slice(0, slash);
  const name = path.slice(slash + 1);
  if ((kind === "object" || kind === "table") && name.length > 0) {
    const meta: Record<string, string> = {};
    if (fragment) {
      for (const pair of fragment.split(",")) {
        const eq = pair.indexOf("=");
        if (eq > 0) meta[pair.slice(0, eq)] = pair.slice(eq + 1);
      }
    }
    return { kind, name, meta };
  }
  return null;
}

export function getPbHref(el: Element): string | null {
  return el.getAttribute("href") || el.getAttributeNS("http://www.w3.org/1999/xlink", "href");
}

export function diagramUrl(
  kind: DiagramKind,
  params: Record<string, string | number> = {},
): string {
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== "" && v != null) qs.set(k, String(v));
  }
  const q = qs.toString();
  return `/api/diagram/${kind}${q ? `?${q}` : ""}`;
}
