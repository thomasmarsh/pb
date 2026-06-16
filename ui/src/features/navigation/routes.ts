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
    case "datawindows":      return "/datawindows";
    case "dwDetail":         return "/datawindows/" + encodeURIComponent(route.name);
    case "tables":           return "/tables";
    case "tableDetail":      return "/tables/"      + encodeURIComponent(route.name);
    case "diagrams":         return "/diagrams";
    case "queries":          return "/queries";
    case "search":           return "/search";
    case "explore":          return "/explore";
    case "errors":           return "/errors";
  }
}

export function parse(path: string): Route {
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
    case "diagrams":  return { view: "diagrams" };
    case "queries":   return { view: "queries" };
    case "search":    return { view: "search" };
    case "explore":   return { view: "explore" };
    case "errors":    return { view: "errors" };
    default:          return { view: "dashboard" };
  }
}
