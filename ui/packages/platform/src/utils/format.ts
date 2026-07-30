// format.ts — Shared formatting utilities.

export function procBadge(t: string): string {
  return { function: "badge-func", subroutine: "badge-sub", event: "badge-event", on: "badge-on" }[t] ?? "badge-func";
}

export function shortFile(f: string | null | undefined): string {
  if (!f) return "";
  return f.replace(/\\/g, "/").split("/").slice(-2).join("/");
}

export const LINT_LABELS: Record<string, string> = {
  select_star: "SELECT *",
  write_no_where: "No WHERE",
  sql_in_loop: "In loop",
};

export const LINT_SEVERITY: Record<string, "warning" | "error"> = {
  select_star: "warning",
  write_no_where: "error",
  sql_in_loop: "warning",
};

export function lintLabel(code: string): string {
  return LINT_LABELS[code] ?? code;
}

export function lintSeverity(code: string): "warning" | "error" {
  return LINT_SEVERITY[code] ?? "warning";
}

export function lintDescription(code: string): string {
  return `SQL lint: ${lintLabel(code)}`;
}
