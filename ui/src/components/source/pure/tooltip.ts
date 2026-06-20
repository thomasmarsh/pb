import type { KnownProcInfo, LocalSymbolInfo, ProcedureInfo } from "../../../types/api.js";

export const PROC_COLORS: Record<string, string> = {
  function: "proc-function",
  subroutine: "proc-subroutine",
  event: "proc-event",
  on: "proc-on",
};

export const PROC_BADGE_COLORS: Record<string, string> = {
  function: "#a78bfa",
  subroutine: "#fb923c",
  event: "#facc15",
  on: "#4ade80",
};

export interface TooltipContent { html: string; color: string }

export function buildObjectTooltip(
  linkName: string,
  obj: { name: string; kind: string } | undefined,
): TooltipContent {
  const kind = obj?.kind ?? "object";
  const color = kind === "datawindow" ? "#56A85D" : "#5B8DD9";
  return {
    color,
    html: `<div class="tt-name" style="color:${color}">${linkName}</div><div class="tt-meta">${kind}</div>`,
  };
}

export function buildProcTooltip(
  linkName: string,
  proc: KnownProcInfo | undefined,
  counts: { caller_count: number; callee_count: number } | undefined,
): TooltipContent {
  const color = proc ? (PROC_BADGE_COLORS[proc.proc_type] ?? "#a78bfa") : "#a78bfa";
  let html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
  if (proc) {
    const ret = proc.return_type ? ` → ${proc.return_type}` : "";
    html += `<div class="tt-meta">${proc.proc_type}${ret}</div>`;
    if (proc.params) html += `<div class="tt-meta">(${proc.params})</div>`;
    html += `<div class="tt-meta">${proc.object}</div>`;
    if (proc.cyclomatic != null) {
      html += `<div class="tt-cc"><span class="badge badge-cc">CC: ${proc.cyclomatic}</span></div>`;
    }
    if (counts) {
      html += `<div class="tt-meta">Callers: ${counts.caller_count} · Callees: ${counts.callee_count}</div>`;
    }
  }
  return { color, html };
}

export function buildVarTooltip(
  linkName: string,
  sym: LocalSymbolInfo | undefined,
): TooltipContent | null {
  if (!sym) return null;
  const color = sym.is_parameter ? "#4fc1ff" : "#9cdcfe";
  const badge = sym.is_parameter
    ? `<span class="badge badge-param">param</span>`
    : `<span class="badge badge-var">local</span>`;
  const kindColor = sym.resolved_kind === "object" ? "#5B8DD9"
    : sym.resolved_kind === "primitive" ? "#4ec9b0"
    : "#9cdcfe";
  let html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
  html += `<div class="tt-meta" style="color:${kindColor}">${sym.raw_type}</div>`;
  html += `<div class="tt-cc">${badge}</div>`;
  if (sym.resolved_target) {
    html += `<div class="tt-meta" style="color:#5B8DD9">${sym.resolved_target}</div>`;
  }
  return { color, html };
}

export function buildProcBarTooltip(
  p: ProcedureInfo,
  counts: { caller_count: number; callee_count: number } | undefined,
  badgeColor: string,
  viewedObjectName: string,
): string {
  const displayName = p.owner && p.owner !== viewedObjectName
    ? `${p.owner} · ${p.name}` : p.name;
  const cc = p.cyclomatic != null ? `CC: ${p.cyclomatic}` : "";
  const ret = p.return_type ? ` → ${p.return_type}` : "";
  return `<div class="tt-name" style="color:${badgeColor}">${displayName}</div>` +
    `<div class="tt-meta">${p.proc_type} ${p.modifiers ?? ""}${ret}</div>` +
    (p.params ? `<div class="tt-meta">(${p.params})</div>` : "") +
    `<div class="tt-meta">Lines ${p.start_line}–${p.end_line}</div>` +
    (cc ? `<div class="tt-cc"><span class="badge badge-cc">${cc}</span></div>` : "") +
    (counts ? `<div class="tt-meta">Callers: ${counts.caller_count} · Callees: ${counts.callee_count}</div>` : "");
}
