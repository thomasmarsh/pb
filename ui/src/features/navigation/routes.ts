// features/navigation/routes.ts — Typed route codec.

import type { Route } from "./types.js";

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
    case "tables":           return "/tables";
    case "tableDetail":      return "/tables/"      + encodeURIComponent(route.name);
    case "libraryDetail":    return "/library/"     + encodeURIComponent(route.name);
    case "diagrams":         return "/diagrams";
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
    case "formalReports":    return "/reports";
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
    case "tables":
      if (segs[1]) return { view: "tableDetail", name: decodeURIComponent(segs[1]) };
      return { view: "tables" };
    case "library":
      if (segs[1]) return { view: "libraryDetail", name: decodeURIComponent(segs[1]) };
      return { view: "dashboard" };
    case "diagrams":   return { view: "diagrams" };
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
    case "taint":        return { view: "taintExplorer" };
    case "reports":      return { view: "formalReports" };
    case "procedures":   return { view: "proceduresList" };
    default:             return { view: "dashboard" };
  }
}
