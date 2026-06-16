// format.ts — Shared formatting utilities.

export function procBadge(t: string): string {
  return { function: "badge-func", subroutine: "badge-sub", event: "badge-event", on: "badge-on" }[t] ?? "badge-func";
}

export function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

export function chevron(expanded: boolean): string {
  return expanded ? "▾" : "▸";
}
