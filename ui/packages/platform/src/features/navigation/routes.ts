// features/navigation/routes.ts — Typed route codec.

import type { Route } from "./types.js";
import { DIAGRAM_KINDS, type DiagramKind } from "../../utils/diagram.js";

export type { Route };

export function print(route: Route): string {
  switch (route.view) {
    case "dashboard":        return "/";
    case "objects":          return "/objects";
    case "objectDetail":     return "/objects/"     + encodeURIComponent(route.name);
    case "procedureDetail":  return "/objects/"     + encodeURIComponent(route.name)
                                    + "/"           + encodeURIComponent(route.proc);
    case "proceduresList":   return "/procedures";
    case "datawindows":      return "/datawindows";
    case "dwDetail":         return "/datawindows/" + encodeURIComponent(route.name);
    case "tables":
      return route.namespace ? `/tables?ns=${encodeURIComponent(route.namespace)}` : "/tables";
    case "tableDetail":
      // Namespace is a path segment, not a query param: a table's identity
      // is (namespace, name), not name-filtered-by-namespace. `/tables/foo`
      // (no namespace) is only ever a provisional/unresolved URL — the app
      // corrects it to the canonical `/tables/{namespace}/foo` once the
      // detail response reports the table's real namespace.
      return route.namespace
        ? "/tables/" + encodeURIComponent(route.namespace) + "/" + encodeURIComponent(route.name)
        : "/tables/" + encodeURIComponent(route.name);
    case "libraryDetail":    return "/library/"     + encodeURIComponent(route.name);
    case "diagrams":
      return route.kind ? `/diagrams?kind=${encodeURIComponent(route.kind)}` : "/diagrams";
    case "queries": {
      if (route.sqlText) {
        return "/queries?" + new URLSearchParams({ sql: route.sqlText }).toString();
      }
      if (!route.queryName) return "/queries";
      const p = new URLSearchParams({ q: route.queryName });
      if (route.queryParams) {
        for (const [k, v] of Object.entries(route.queryParams)) p.set(`p_${k}`, v);
      }
      return "/queries?" + p.toString();
    }
    case "search":           return "/search";
    case "explore":          return "/explore";
    case "errors":           return "/errors";
    case "deadCode":         return "/dead-code";
    case "taintExplorer":    return "/taint";
    case "taintPathView":    return "/taint/" + route.pathId;
    case "sliceView":
      return "/slice/" + encodeURIComponent(route.object)
             + "/" + encodeURIComponent(route.proc)
             + "/" + route.line
             + "?dir=" + route.direction;
    case "formalReports":    return "/reports";
    case "cfgDiagram":
      return "/analysis/cfg/" + encodeURIComponent(route.object)
             + "/"            + encodeURIComponent(route.proc);
    case "launch":           return "/launch";
  }
}

export function parse(path: string, search?: string): Route {
  const segs = path.split("/").filter(Boolean);
  switch (segs[0]) {
    case "objects":
      if (segs[2]) return { view: "procedureDetail",
                             name: decodeURIComponent(segs[1]!),
                             proc: decodeURIComponent(segs[2]) };
      if (segs[1]) return { view: "objectDetail", name: decodeURIComponent(segs[1]) };
      return { view: "objects" };
    case "datawindows":
      if (segs[1]) return { view: "dwDetail", name: decodeURIComponent(segs[1]) };
      return { view: "datawindows" };
    case "tables": {
      // /tables/{namespace}/{table} (canonical) vs /tables/{table} (provisional,
      // unresolved) — disambiguated by segment count, same convention as
      // /objects/{name}/{proc}. The list itself keeps ?ns= (a collection
      // filter, not an identity component).
      if (segs[2]) {
        return { view: "tableDetail", name: decodeURIComponent(segs[2]), namespace: decodeURIComponent(segs[1]!) };
      }
      if (segs[1]) {
        return { view: "tableDetail", name: decodeURIComponent(segs[1]) };
      }
      const raw = search ? (search.startsWith("?") ? search.slice(1) : search) : "";
      const ns = new URLSearchParams(raw).get("ns");
      return { view: "tables", ...(ns ? { namespace: ns } : {}) };
    }
    case "library":
      if (segs[1]) return { view: "libraryDetail", name: decodeURIComponent(segs[1]) };
      return { view: "dashboard" };
    case "diagrams": {
      const raw = search ? (search.startsWith("?") ? search.slice(1) : search) : "";
      const sp = new URLSearchParams(raw);
      const kind = sp.get("kind");
      if (kind && (DIAGRAM_KINDS as readonly string[]).includes(kind)) {
        return { view: "diagrams", kind: kind as DiagramKind };
      }
      return { view: "diagrams" };
    }
    case "queries": {
      const raw = search ? (search.startsWith("?") ? search.slice(1) : search) : "";
      const sp = new URLSearchParams(raw);
      const sql = sp.get("sql");
      if (sql) return { view: "queries", sqlText: sql };
      const q = sp.get("q");
      if (!q) return { view: "queries" };
      const params: Record<string, string> = {};
      for (const [k, v] of sp.entries()) {
        if (k.startsWith("p_")) params[k.slice(2)] = v;
      }
      return { view: "queries", queryName: q, queryParams: params };
    }
    case "search":     return { view: "search" };
    case "explore":    return { view: "explore" };
    case "errors":     return { view: "errors" };
    case "dead-code":    return { view: "deadCode" };
    case "taint": {
      if (segs[1] && /^\d+$/.test(segs[1])) {
        return { view: "taintPathView", pathId: parseInt(segs[1], 10) };
      }
      return { view: "taintExplorer" };
    }
    case "slice":
      if (segs[1] && segs[2] && segs[3]) {
        const raw = search ? (search.startsWith("?") ? search.slice(1) : search) : "";
        const sp = new URLSearchParams(raw);
        const dir = sp.get("dir") === "forward" ? "forward" : "backward";
        return {
          view: "sliceView",
          object: decodeURIComponent(segs[1]),
          proc: decodeURIComponent(segs[2]),
          line: parseInt(segs[3], 10),
          direction: dir,
        };
      }
      return { view: "dashboard" };
    case "reports":      return { view: "formalReports" };
    case "launch":       return { view: "launch" };
    case "procedures":   return { view: "proceduresList" };
    case "analysis":
      if (segs[1] === "cfg" && segs[2] && segs[3]) {
        return {
          view: "cfgDiagram",
          object: decodeURIComponent(segs[2]),
          proc:   decodeURIComponent(segs[3]),
        };
      }
      return { view: "dashboard" };
    default:             return { view: "dashboard" };
  }
}
