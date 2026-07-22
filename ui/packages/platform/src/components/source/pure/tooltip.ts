import type { ProcedureInfo, ResolvedCallInfo, ResolvedVarRefInfo } from "@pb/platform";

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

const CALL_KIND_COLORS: Record<ResolvedCallInfo["kind"], string> = {
  virtual: "#a78bfa",
  static: "#4ec9b0",
  inherited: "#56b6c2",
  unresolved: "#6b7280",
};

export function buildProcTooltip(
  linkName: string,
  call: ResolvedCallInfo | undefined,
  counts: { caller_count: number; callee_count: number } | undefined,
): TooltipContent {
  const color = call ? CALL_KIND_COLORS[call.kind] : "#a78bfa";
  let html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
  if (call) {
    const target = call.target_object
      ? `${call.target_object}.${call.target_proc ?? call.to_name}`
      : call.to_name;
    html += `<div class="tt-meta">${call.kind} → ${target}</div>`;
    html += `<div class="tt-cc"><span class="badge badge-cc">${call.confidence}</span></div>`;
    if (counts) {
      html += `<div class="tt-meta">Callers: ${counts.caller_count} · Callees: ${counts.callee_count}</div>`;
    }
  }
  return { color, html };
}

const VAR_KIND_COLORS: Record<ResolvedVarRefInfo["kind"], string> = {
  local: "#9cdcfe",
  param: "#4fc1ff",
  instance: "#98c379",
  global: "#fb923c",
  control: "#4ade80",
  class: "#5B8DD9",
  builtin_property: "#dcdcaa",
  unresolved: "#6b7280",
};

const VAR_KIND_BADGES: Record<ResolvedVarRefInfo["kind"], string> = {
  local: `<span class="badge badge-var">local</span>`,
  param: `<span class="badge badge-param">param</span>`,
  instance: `<span class="badge badge-instance">instance</span>`,
  global: `<span class="badge badge-global">global</span>`,
  control: `<span class="badge badge-control">control</span>`,
  class: `<span class="badge badge-class">class</span>`,
  builtin_property: `<span class="badge badge-builtin">builtin</span>`,
  unresolved: `<span class="badge">unresolved</span>`,
};

export function buildVarTooltip(
  linkName: string,
  ref: ResolvedVarRefInfo | undefined,
): TooltipContent | null {
  if (!ref) return null;
  const color = VAR_KIND_COLORS[ref.kind];
  const badge = VAR_KIND_BADGES[ref.kind];
  let html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
  html += `<div class="tt-cc">${badge}</div>`;
  if (ref.target_object) {
    html += `<div class="tt-meta" style="color:#5B8DD9">${ref.target_object}</div>`;
  }
  html += `<div class="tt-meta">${ref.access}${ref.confidence !== "high" ? ` · ${ref.confidence}` : ""}</div>`;
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
